#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT_DIR_DEFAULT" ]]; then
  ROOT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ROOT_DIR="${STREAM_ROOT:-$ROOT_DIR_DEFAULT}"
SESSION_NAME="aeonic-streams"
INTERVAL=30
STALE_SECONDS=180
ONCE=0
RUNTIME_DIR="$ROOT_DIR/docs/stream-state/runtime"
LATEST_FILE="$RUNTIME_DIR/operator-watch.latest"
AUTO_HEAL=1
EXECUTOR_INTERVAL=60
EXECUTOR_MODEL=""
RESTART_COOLDOWN=180

STREAMS=("D-BE" "D-FE" "D-INT")

usage() {
  cat <<'EOF'
Usage: scripts/operator_watch.sh [options]

Options:
  --root <path>            target repository root (default: STREAM_ROOT or current git root)
  --session <name>         tmux session name (default: aeonic-streams)
  --interval <sec>         poll interval in seconds (default: 30)
  --stale-seconds <sec>    heartbeat stale threshold for in_progress tasks (default: 180)
  --no-auto-heal           disable executor auto-restart
  --executor-interval <s>  restart interval for auto-healed executors (default: 60)
  --executor-model <name>  optional model for auto-healed executors
  --restart-cooldown <s>   min seconds between restarts per stream (default: 180)
  --once                   run one watch cycle and exit
  -h, --help               show help
EOF
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

count_tasks_for_status() {
  local stream="$1"
  local target_status="$2"
  local pattern
  local candidate
  local status
  local count=0

  pattern="$(task_pattern_for_stream "$stream")"
  while IFS= read -r candidate; do
    status="$(awk -F'`' '$0 ~ /^- Status:/ {print $2; exit}' "$candidate" || true)"
    if [[ "$status" == "$target_status" ]]; then
      count=$((count + 1))
    fi
  done < <(find "$ROOT_DIR/docs/stream-tasks" -type f -name "$pattern" | sort)

  echo "$count"
}

timestamp_to_epoch() {
  local ts="$1"
  local epoch=0

  if [[ -z "$ts" ]]; then
    echo 0
    return 0
  fi

  if epoch="$(date -j -u -f '%Y-%m-%d %H:%M:%SZ' "$ts" '+%s' 2>/dev/null)"; then
    echo "$epoch"
    return 0
  fi

  if epoch="$(date -u -d "$ts" '+%s' 2>/dev/null)"; then
    echo "$epoch"
    return 0
  fi

  echo 0
}

heartbeat_field() {
  local file="$1"
  local key="$2"
  awk -F'=' -v k="$key" '$1 == k {sub(/^[^=]*=/, "", $0); print $0; exit}' "$file"
}

restart_stamp_file() {
  local stream="$1"
  echo "$RUNTIME_DIR/${stream}.restart.epoch"
}

can_restart_stream() {
  local stream="$1"
  local now_epoch="$2"
  local stamp_file
  local last_restart=0

  stamp_file="$(restart_stamp_file "$stream")"
  if [[ -f "$stamp_file" ]]; then
    last_restart="$(cat "$stamp_file" 2>/dev/null || echo 0)"
  fi
  if [[ ! "$last_restart" =~ ^[0-9]+$ ]]; then
    last_restart=0
  fi

  if [[ $((now_epoch - last_restart)) -lt "$RESTART_COOLDOWN" ]]; then
    return 1
  fi
  return 0
}

record_restart_stream() {
  local stream="$1"
  local now_epoch="$2"
  mkdir -p "$RUNTIME_DIR"
  echo "$now_epoch" > "$(restart_stamp_file "$stream")"
}

ensure_stream_window() {
  local stream="$1"
  if ! tmux list-windows -t "$SESSION_NAME" -F '#W' | grep -Fxq "$stream"; then
    tmux new-window -t "$SESSION_NAME" -n "$stream" "bash"
  fi
}

restart_stream_executor() {
  local stream="$1"
  local reason="$2"
  local cmd

  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    return 1
  fi

  ensure_stream_window "$stream"
  cmd="cd \"$ROOT_DIR\"; clear; echo \"[$stream] executor auto-restarted ($reason)\"; \"$SCRIPT_DIR/run_stream_executor.sh\" --stream \"$stream\" --interval \"$EXECUTOR_INTERVAL\" --root \"$ROOT_DIR\""
  if [[ -n "$EXECUTOR_MODEL" ]]; then
    cmd="$cmd --model \"$EXECUTOR_MODEL\""
  fi

  tmux send-keys -t "${SESSION_NAME}:${stream}" C-c
  tmux send-keys -t "${SESSION_NAME}:${stream}" "$cmd" C-m
}

print_cycle() {
  local now_epoch
  local now_utc
  local stream
  local in_progress
  local todo
  local blocked
  local executor_state
  local pane_cmd
  local hb_file
  local hb_ts
  local hb_state
  local hb_detail
  local hb_epoch
  local hb_age
  local hb_age_seconds
  local alerts
  local active
  local restart_reason
  local auto_heal_note
  local log_lines=""

  mkdir -p "$RUNTIME_DIR"
  now_epoch="$(date -u '+%s')"
  now_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"

  if [[ -t 1 ]]; then
    clear
  fi
  echo "[operator-watch] $now_utc"
  echo "session=$SESSION_NAME interval=${INTERVAL}s stale_threshold=${STALE_SECONDS}s"
  echo
  printf '%-6s %-8s %-12s %-7s %-10s %-10s %-8s %s\n' "stream" "executor" "heartbeat" "hb_age" "in_progress" "todo" "blocked" "alerts"
  printf '%-6s %-8s %-12s %-7s %-10s %-10s %-8s %s\n' "------" "--------" "----------" "------" "----------" "----" "-------" "------"

  for stream in "${STREAMS[@]}"; do
    in_progress="$(count_tasks_for_status "$stream" "in_progress")"
    todo="$(count_tasks_for_status "$stream" "todo")"
    blocked="$(count_tasks_for_status "$stream" "blocked")"
    active=$((in_progress + todo))
    alerts="none"

    if pgrep -f "run_stream_executor.sh --stream $stream" >/dev/null 2>&1; then
      executor_state="up"
    else
      executor_state="down"
    fi

    hb_file="$RUNTIME_DIR/${stream}.heartbeat"
    hb_state="missing"
    hb_age="n/a"
    hb_age_seconds=-1
    hb_detail=""
    if [[ -f "$hb_file" ]]; then
      hb_ts="$(heartbeat_field "$hb_file" "timestamp_utc" || true)"
      hb_state="$(heartbeat_field "$hb_file" "status" || true)"
      hb_detail="$(heartbeat_field "$hb_file" "detail" || true)"
      hb_epoch="$(timestamp_to_epoch "$hb_ts")"
      if [[ "$hb_epoch" -gt 0 ]]; then
        hb_age_value="$((now_epoch - hb_epoch))"
        if [[ "$hb_age_value" -lt 0 ]]; then
          hb_age_value=0
        fi
        hb_age_seconds="$hb_age_value"
        hb_age="${hb_age_value}s"
      fi
    fi

    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      pane_cmd="$(tmux display-message -p -t "${SESSION_NAME}:${stream}" '#{pane_current_command}' 2>/dev/null || echo "n/a")"
    else
      pane_cmd="n/a"
    fi

    if [[ "$active" -gt 0 && "$executor_state" != "up" ]]; then
      alerts="executor_down_with_active_tasks"
    fi

    if [[ "$in_progress" -gt 0 ]]; then
      if [[ "$hb_state" == "missing" ]]; then
        alerts="${alerts};missing_heartbeat"
      elif [[ "$hb_age" != "n/a" ]]; then
        hb_age_value="${hb_age%s}"
        if [[ "$hb_age_value" -gt "$STALE_SECONDS" ]]; then
          alerts="${alerts};stale_heartbeat"
        fi
      fi
    fi

    restart_reason=""
    auto_heal_note=""
    if [[ "$AUTO_HEAL" -eq 1 ]]; then
      if [[ "$active" -gt 0 && "$executor_state" != "up" ]]; then
        restart_reason="executor_down"
      elif [[ "$in_progress" -gt 0 ]]; then
        if [[ "$hb_state" == "missing" ]]; then
          restart_reason="missing_heartbeat"
        elif [[ "$hb_age_seconds" -ge "$STALE_SECONDS" ]]; then
          restart_reason="stale_heartbeat"
        fi
      fi

      if [[ -n "$restart_reason" ]]; then
        if can_restart_stream "$stream" "$now_epoch"; then
          if restart_stream_executor "$stream" "$restart_reason"; then
            record_restart_stream "$stream" "$now_epoch"
            auto_heal_note="auto_restart:$restart_reason"
            executor_state="restarting"
          else
            auto_heal_note="auto_restart_failed:$restart_reason"
          fi
        else
          auto_heal_note="restart_cooldown"
        fi
      fi
    fi

    if [[ "$auto_heal_note" != "" ]]; then
      alerts="${alerts};${auto_heal_note}"
    fi
    if [[ "$alerts" == none\;* ]]; then
      alerts="${alerts#none;}"
    fi

    printf '%-6s %-8s %-12s %-7s %-10s %-10s %-8s %s\n' "$stream" "$executor_state" "$hb_state" "$hb_age" "$in_progress" "$todo" "$blocked" "$alerts"
    log_lines+="$stream executor=$executor_state heartbeat=$hb_state age=$hb_age in_progress=$in_progress todo=$todo blocked=$blocked pane=$pane_cmd alerts=$alerts"$'\n'
    if [[ -n "$hb_detail" ]]; then
      echo "       detail: $hb_detail"
    fi
  done

  {
    echo "timestamp_utc=$now_utc"
    echo "session=$SESSION_NAME"
    echo "interval_seconds=$INTERVAL"
    echo "stale_seconds=$STALE_SECONDS"
    printf '%s' "$log_lines"
  } > "$LATEST_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="${2:-}"
      if [[ -z "$ROOT_DIR" ]]; then
        echo "Error: --root requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --session)
      SESSION_NAME="${2:-}"
      if [[ -z "$SESSION_NAME" ]]; then
        echo "Error: --session requires a value." >&2
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
    --stale-seconds)
      STALE_SECONDS="${2:-}"
      if [[ -z "$STALE_SECONDS" || ! "$STALE_SECONDS" =~ ^[0-9]+$ ]]; then
        echo "Error: --stale-seconds must be an integer number of seconds." >&2
        exit 1
      fi
      shift 2
      ;;
    --no-auto-heal)
      AUTO_HEAL=0
      shift
      ;;
    --executor-interval)
      EXECUTOR_INTERVAL="${2:-}"
      if [[ -z "$EXECUTOR_INTERVAL" || ! "$EXECUTOR_INTERVAL" =~ ^[0-9]+$ ]]; then
        echo "Error: --executor-interval must be an integer number of seconds." >&2
        exit 1
      fi
      shift 2
      ;;
    --executor-model)
      EXECUTOR_MODEL="${2:-}"
      if [[ -z "$EXECUTOR_MODEL" ]]; then
        echo "Error: --executor-model requires a value." >&2
        exit 1
      fi
      shift 2
      ;;
    --restart-cooldown)
      RESTART_COOLDOWN="${2:-}"
      if [[ -z "$RESTART_COOLDOWN" || ! "$RESTART_COOLDOWN" =~ ^[0-9]+$ ]]; then
        echo "Error: --restart-cooldown must be an integer number of seconds." >&2
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

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: ROOT_DIR does not exist: $ROOT_DIR" >&2
  exit 1
fi

while true; do
  print_cycle
  if [[ "$ONCE" -eq 1 ]]; then
    exit 0
  fi
  sleep "$INTERVAL"
done
