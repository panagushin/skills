#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT_DIR_DEFAULT" ]]; then
  ROOT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ROOT_DIR="${STREAM_ROOT:-$ROOT_DIR_DEFAULT}"
STREAM_INPUT=""
INTERVAL=60
MODEL=""
ONCE=0
RUNTIME_DIR="$ROOT_DIR/docs/stream-state/runtime"
HEARTBEAT_FILE=""
HEARTBEAT_TICK=30
RUNNING_HEARTBEAT_PID=""

usage() {
  cat <<'EOF'
Usage: scripts/run_stream_executor.sh --stream <stream> [options]

Options:
  --stream <name>       Stream key: D-BE, D-FE, D-INT
                        or long form: delivery-backend, delivery-frontend, delivery-integration
  --root <path>         Target repository root (default: STREAM_ROOT or current git root)
  --interval <sec>      Polling interval in seconds (default: 60)
  --model <name>        Optional model override passed to codex exec
  --heartbeat-tick <s>  Running heartbeat cadence in seconds (default: 30)
  --once                Run exactly one executor cycle and exit
  -h, --help            Show help
EOF
}

has_control_chars() {
  local value="$1"
  [[ "$value" =~ [[:cntrl:]] ]]
}

validate_model_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._:+/-]+$ ]]
}

sanitize_single_line() {
  local value="$1"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

normalize_stream() {
  case "$1" in
    D-BE|delivery-backend|backend) echo "D-BE" ;;
    D-FE|delivery-frontend|frontend) echo "D-FE" ;;
    D-INT|delivery-integration|integration) echo "D-INT" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

lane_for_stream() {
  case "$1" in
    D-BE) echo "backend" ;;
    D-FE) echo "frontend" ;;
    D-INT) echo "integration" ;;
    *)
      echo "unknown"
      ;;
  esac
}

task_pattern_for_stream() {
  case "$1" in
    D-BE) echo "delivery-backend-*.md" ;;
    D-FE) echo "delivery-frontend*.md" ;;
    D-INT) echo "delivery-integration*.md" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

extract_backtick_field() {
  local file="$1"
  local field_name="$2"
  awk -F'`' -v key="$field_name" '$0 ~ "^- " key ":" {print $2; exit}' "$file"
}

task_status() {
  local file="$1"
  extract_backtick_field "$file" "Status"
}

find_task_for_status() {
  local target_status="$1"
  local pattern
  local candidate
  local status

  pattern="$(task_pattern_for_stream "$STREAM_KEY")"
  while IFS= read -r candidate; do
    status="$(task_status "$candidate" || true)"
    if [[ "$status" == "$target_status" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$ROOT_DIR/docs/stream-tasks" -type f -name "$pattern" | sort)

  return 1
}

find_next_task() {
  local next_task
  next_task="$(find_task_for_status "in_progress" || true)"
  if [[ -n "$next_task" ]]; then
    printf '%s\n' "$next_task"
    return 0
  fi

  next_task="$(find_task_for_status "todo" || true)"
  if [[ -n "$next_task" ]]; then
    printf '%s\n' "$next_task"
    return 0
  fi

  return 1
}

build_prompt() {
  local stream_key="$1"
  local task_doc="$2"
  local master_doc="$3"
  local lane="$4"
  local backend_substream="$5"

  cat <<EOF
You are the dedicated Delivery executor for stream \`$stream_key\` (lane: \`$lane\`, backend_substream: \`$backend_substream\`).

Task package:
- Stream doc: \`$task_doc\`
- Master doc: \`$master_doc\`

Execution rules:
1. Read AGENTS instructions and keep Aeonic invariants from \`docs/system-prompt.md\`.
2. Execute only this stream task. Do not take operator/strategy/analytics/ux ownership.
3. Implement required changes to satisfy Objective and Acceptance Criteria.
4. Run focused validation commands relevant to the change.
5. Update task docs before finishing:
   - stream doc status/log/deliverables/completion sections
   - matching status row in master doc
   - unblock downstream handoff doc if stream task is completed
6. If blocked, set status to \`blocked\` with precise blocker and required next owner/action.
7. If task status is \`done\` and code/docs changed, create a commit in this stream before finishing.
   - Commit only files relevant to this stream task.
   - Use a concise conventional message (e.g. \`fix(ui): ...\`, \`fix(api): ...\`, \`docs(stream): ...\`).
   - If there are no file changes, explicitly state \`no changes to commit\`.
   - Never commit operator-only management artifacts (\`docs/stream-state/*\`, \`docs/stream-state/checkpoints/*\`) unless this task explicitly targets operator stream tooling.

Return a concise summary with:
- status (\`done\` or \`blocked\`)
- changed files
- validation command results
EOF
}

write_heartbeat() {
  local hb_status="$1"
  local hb_task="${2:-none}"
  local hb_detail="${3:-none}"
  local now_utc

  if [[ -z "$HEARTBEAT_FILE" ]]; then
    return 0
  fi

  mkdir -p "$RUNTIME_DIR"
  hb_task="$(sanitize_single_line "$hb_task")"
  hb_detail="$(sanitize_single_line "$hb_detail")"
  now_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  {
    echo "timestamp_utc=$now_utc"
    echo "stream=$STREAM_KEY"
    echo "pid=$$"
    echo "status=$hb_status"
    echo "task=$hb_task"
    echo "detail=$hb_detail"
  } > "$HEARTBEAT_FILE"
}

start_running_heartbeat_loop() {
  local hb_task="$1"
  local hb_task_status="$2"
  local hb_tick="${HEARTBEAT_TICK}"

  if [[ -z "$HEARTBEAT_FILE" || "$hb_tick" -le 0 ]]; then
    return 0
  fi

  stop_running_heartbeat_loop
  (
    while true; do
      sleep "$hb_tick" || exit 0
      write_heartbeat "running" "$hb_task" "cycle running (task_status=$hb_task_status)"
    done
  ) &
  RUNNING_HEARTBEAT_PID="$!"
}

stop_running_heartbeat_loop() {
  if [[ -n "${RUNNING_HEARTBEAT_PID:-}" ]]; then
    kill "$RUNNING_HEARTBEAT_PID" >/dev/null 2>&1 || true
    wait "$RUNNING_HEARTBEAT_PID" 2>/dev/null || true
    RUNNING_HEARTBEAT_PID=""
  fi
}

run_executor_cycle() {
  local task_doc
  local status
  local master_doc
  local lane
  local backend_substream
  local prompt_file
  local rc=0
  local timestamp

  timestamp="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
  task_doc="$(find_next_task || true)"
  if [[ -z "$task_doc" ]]; then
    echo "[$timestamp][$STREAM_KEY] no runnable tasks (statuses in_progress/todo)."
    write_heartbeat "idle" "none" "no runnable tasks"
    return 0
  fi

  status="$(task_status "$task_doc" || true)"
  master_doc="$(extract_backtick_field "$task_doc" "Source master" || true)"
  if [[ -z "$master_doc" ]]; then
    master_doc="$(cd "$(dirname "$task_doc")" && pwd)/master.md"
  fi
  lane="$(lane_for_stream "$STREAM_KEY")"
  backend_substream="$(extract_backtick_field "$task_doc" "Backend substream" || true)"
  if [[ -z "$backend_substream" ]]; then
    backend_substream="n/a"
  fi

  prompt_file="$(mktemp)"
  build_prompt "$STREAM_KEY" "$task_doc" "$master_doc" "$lane" "$backend_substream" > "$prompt_file"

  echo "[$timestamp][$STREAM_KEY] executor cycle started for: $task_doc (status=$status)"
  write_heartbeat "running" "$task_doc" "cycle started (task_status=$status)"
  start_running_heartbeat_loop "$task_doc" "$status"
  if [[ -n "$MODEL" ]]; then
    if ! codex exec --ephemeral --sandbox danger-full-access -C "$ROOT_DIR" --model "$MODEL" - < "$prompt_file"; then
      rc=$?
      echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')][$STREAM_KEY] codex exec failed with exit code $rc"
    fi
  else
    if ! codex exec --ephemeral --sandbox danger-full-access -C "$ROOT_DIR" - < "$prompt_file"; then
      rc=$?
      echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')][$STREAM_KEY] codex exec failed with exit code $rc"
    fi
  fi

  stop_running_heartbeat_loop
  rm -f "$prompt_file"
  if [[ "$rc" -eq 0 ]]; then
    status="$(task_status "$task_doc" || true)"
    write_heartbeat "idle" "$task_doc" "cycle complete (task_status=${status:-unknown})"
  else
    write_heartbeat "error" "$task_doc" "codex exec failed (rc=$rc)"
  fi
  return "$rc"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stream)
      STREAM_INPUT="${2:-}"
      shift 2
      ;;
    --root)
      ROOT_DIR="${2:-}"
      if [[ -z "$ROOT_DIR" ]]; then
        echo "Error: --root requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --interval)
      INTERVAL="${2:-}"
      if [[ -z "$INTERVAL" || ! "$INTERVAL" =~ ^[0-9]+$ ]]; then
        echo "Error: --interval must be an integer number of seconds." >&2
        exit 1
      fi
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      if [[ -z "$MODEL" ]]; then
        echo "Error: --model requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --heartbeat-tick)
      HEARTBEAT_TICK="${2:-}"
      if [[ -z "$HEARTBEAT_TICK" || ! "$HEARTBEAT_TICK" =~ ^[0-9]+$ ]]; then
        echo "Error: --heartbeat-tick must be an integer number of seconds." >&2
        exit 1
      fi
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'." >&2
      usage
      exit 1
      ;;
  esac
done

if has_control_chars "$ROOT_DIR"; then
  echo "Error: --root contains control characters." >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: ROOT_DIR does not exist: $ROOT_DIR" >&2
  exit 1
fi

ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
RUNTIME_DIR="$ROOT_DIR/docs/stream-state/runtime"

if [[ -z "$STREAM_INPUT" ]]; then
  echo "Error: --stream is required." >&2
  usage
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex CLI is not available in PATH." >&2
  exit 1
fi

if [[ -n "$MODEL" ]] && ! validate_model_name "$MODEL"; then
  echo "Error: --model contains unsupported characters." >&2
  exit 1
fi

STREAM_KEY="$(normalize_stream "$STREAM_INPUT" || true)"
if [[ -z "$STREAM_KEY" ]]; then
  echo "Error: invalid --stream '$STREAM_INPUT'." >&2
  exit 1
fi

HEARTBEAT_FILE="$RUNTIME_DIR/${STREAM_KEY}.heartbeat"

on_exit() {
  local rc=$?
  stop_running_heartbeat_loop
  write_heartbeat "stopped" "none" "executor process exited (rc=$rc)"
}
trap on_exit EXIT

echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')][$STREAM_KEY] stream executor started (interval=${INTERVAL}s, model=${MODEL:-default}, hb_tick=${HEARTBEAT_TICK}s)"
write_heartbeat "started" "none" "executor booted (interval=${INTERVAL}, model=${MODEL:-default}, hb_tick=${HEARTBEAT_TICK})"
while true; do
  cycle_rc=0
  if ! run_executor_cycle; then
    cycle_rc=$?
  fi

  if [[ "$ONCE" -eq 1 ]]; then
    exit "$cycle_rc"
  fi

  sleep "$INTERVAL"
done
