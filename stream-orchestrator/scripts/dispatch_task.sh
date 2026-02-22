#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT_DIR_DEFAULT" ]]; then
  ROOT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ROOT_DIR="${STREAM_ROOT:-$ROOT_DIR_DEFAULT}"
TASKS_DIR="$ROOT_DIR/docs/stream-tasks"

TITLE=""
GOAL=""
DEADLINE=""
OWNER="operator"
TASK_ID=""
STREAMS_RAW="strategy,analytics,ux,delivery-backend,delivery-frontend,delivery-integration"
BACKEND_SUBSTREAMS_RAW="BE-Platform,BE-GameCore,BE-Finance,BE-Contracts,BE-Reliability"

usage() {
  cat <<'EOF'
Usage: scripts/dispatch_task.sh --title "<title>" [options]

Options:
  --root "<path>"               Target repository root (default: STREAM_ROOT or current git root)
  --title "<text>"              Task title (required)
  --goal "<text>"               Goal/intent (default: same as title)
  --deadline "<text>"           Deadline or target date/time
  --owner "<text>"              Task owner/initiator (default: operator)
  --task-id "<id>"              Explicit task id (default: generated)
  --streams "<csv>"             Streams to include (default: strategy,analytics,ux,delivery-backend,delivery-frontend,delivery-integration)
  --backend-substreams "<csv>"  Backend substreams (default: all five)
  -h, --help                    Show help

Allowed stream values:
  operator, strategy, analytics, ux, delivery-backend, delivery-frontend, delivery-integration

Allowed backend substreams:
  BE-Platform, BE-GameCore, BE-Finance, BE-Contracts, BE-Reliability
EOF
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

slugify() {
  local input="$1"
  input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  input="$(printf '%s' "$input" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  if [[ -z "$input" ]]; then
    input="task"
  fi
  printf '%s' "${input:0:48}"
}

normalize_stream() {
  case "$1" in
    operator|o) echo "operator" ;;
    strategy|s) echo "strategy" ;;
    analytics|a) echo "analytics" ;;
    ux|u) echo "ux" ;;
    delivery-backend|d-be|backend) echo "delivery-backend" ;;
    delivery-frontend|d-fe|frontend) echo "delivery-frontend" ;;
    delivery-integration|d-int|integration) echo "delivery-integration" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

normalize_backend_substream() {
  case "$1" in
    BE-Platform|be-platform) echo "BE-Platform" ;;
    BE-GameCore|be-gamecore) echo "BE-GameCore" ;;
    BE-Finance|be-finance) echo "BE-Finance" ;;
    BE-Contracts|be-contracts) echo "BE-Contracts" ;;
    BE-Reliability|be-reliability) echo "BE-Reliability" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

has_control_chars() {
  local value="$1"
  [[ "$value" =~ [[:cntrl:]] ]]
}

validate_task_id() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$value" != .* ]] || return 1
  [[ "$value" != *..* ]] || return 1
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="${2:-}"
      if [[ -z "$ROOT_DIR" ]]; then
        echo "Error: --root requires a value." >&2
        exit 1
      fi
      TASKS_DIR="$ROOT_DIR/docs/stream-tasks"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --goal)
      GOAL="${2:-}"
      shift 2
      ;;
    --deadline)
      DEADLINE="${2:-}"
      shift 2
      ;;
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    --task-id)
      TASK_ID="${2:-}"
      shift 2
      ;;
    --streams)
      STREAMS_RAW="${2:-}"
      shift 2
      ;;
    --backend-substreams)
      BACKEND_SUBSTREAMS_RAW="${2:-}"
      shift 2
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
TASKS_DIR="$ROOT_DIR/docs/stream-tasks"

TITLE="$(trim "$TITLE")"
GOAL="$(trim "$GOAL")"
DEADLINE="$(trim "$DEADLINE")"
OWNER="$(trim "$OWNER")"

if [[ -z "$TITLE" ]]; then
  echo "Error: --title is required." >&2
  usage
  exit 1
fi

if [[ -z "$GOAL" ]]; then
  GOAL="$TITLE"
fi

if [[ -z "$TASK_ID" ]]; then
  TASK_ID="$(date -u '+%Y%m%d-%H%M')-$(slugify "$TITLE")"
fi

if ! validate_task_id "$TASK_ID"; then
  echo "Error: invalid --task-id '$TASK_ID'. Use only letters, digits, '.', '_' and '-' (no '..')." >&2
  exit 1
fi

mkdir -p "$TASKS_DIR"
TASK_DIR="$TASKS_DIR/$TASK_ID"
if [[ -e "$TASK_DIR" ]]; then
  echo "Error: task directory already exists: $TASK_DIR" >&2
  exit 1
fi
mkdir -p "$TASK_DIR"

declare -a STREAMS=()
IFS=',' read -r -a STREAM_TOKENS <<< "$STREAMS_RAW"
for raw in "${STREAM_TOKENS[@]}"; do
  token="$(trim "$raw")"
  [[ -z "$token" ]] && continue
  canon="$(normalize_stream "$token" || true)"
  if [[ -z "$canon" ]]; then
    echo "Error: invalid stream token '$token'." >&2
    exit 1
  fi
  if [[ "${#STREAMS[@]}" -eq 0 ]] || ! array_contains "$canon" "${STREAMS[@]}"; then
    STREAMS+=("$canon")
  fi
done

if [[ "${#STREAMS[@]}" -eq 0 ]]; then
  echo "Error: no valid streams selected." >&2
  exit 1
fi

declare -a BACKEND_SUBSTREAMS=()
IFS=',' read -r -a BACKEND_TOKENS <<< "$BACKEND_SUBSTREAMS_RAW"
for raw in "${BACKEND_TOKENS[@]}"; do
  token="$(trim "$raw")"
  [[ -z "$token" ]] && continue
  canon="$(normalize_backend_substream "$token" || true)"
  if [[ -z "$canon" ]]; then
    echo "Error: invalid backend substream '$token'." >&2
    exit 1
  fi
  if [[ "${#BACKEND_SUBSTREAMS[@]}" -eq 0 ]] || ! array_contains "$canon" "${BACKEND_SUBSTREAMS[@]}"; then
    BACKEND_SUBSTREAMS+=("$canon")
  fi
done

if [[ "${#BACKEND_SUBSTREAMS[@]}" -eq 0 ]]; then
  BACKEND_SUBSTREAMS=("BE-Platform")
fi

created_at_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"

declare -a TABLE_ROWS=()
declare -a CREATED_DOCS=()

write_stream_doc() {
  local stream="$1"
  local lane="$2"
  local backend_substream="$3"
  local model="$4"
  local reasoning="$5"
  local file_name="$6"

  local stream_doc="$TASK_DIR/$file_name"
  local deadline_line
  local backend_line
  local lane_line

  if [[ -n "$DEADLINE" ]]; then
    deadline_line="$DEADLINE"
  else
    deadline_line="not set"
  fi

  if [[ -n "$lane" ]]; then
    lane_line="$lane"
  else
    lane_line="n/a"
  fi

  if [[ -n "$backend_substream" ]]; then
    backend_line="$backend_substream"
  else
    backend_line="n/a"
  fi

  cat > "$stream_doc" <<EOF
# Stream Task: $TITLE

- Task ID: \`$TASK_ID\`
- Stream: \`$stream\`
- Lane: \`$lane_line\`
- Backend substream: \`$backend_line\`
- Status: \`todo\`
- Owner: \`unassigned\`
- Requested by: \`$OWNER\`
- Model: \`$model\`
- Reasoning: \`$reasoning\`
- Deadline: \`$deadline_line\`
- Source master: \`$ROOT_DIR/docs/stream-tasks/$TASK_ID/master.md\`

## Objective
$GOAL

## Acceptance Criteria
- [ ] Scope is confirmed for this stream.
- [ ] Deliverable is produced and linked.
- [ ] Handoff is filled if another stream is required.
- [ ] Status is updated in this file and in master table.

## Deliverables
- Main output:
- Supporting output:
- Links:

## Execution Log
- $created_at_utc: created in \`todo\`.

## Completion
- Final status:
- Summary:
- Next handoff (if any):
EOF

  CREATED_DOCS+=("$stream_doc")
  TABLE_ROWS+=("| $stream | $lane_line | $backend_line | $model | $reasoning | todo | \`$ROOT_DIR/docs/stream-tasks/$TASK_ID/$file_name\` |")
}

for stream in "${STREAMS[@]}"; do
  case "$stream" in
    operator)
      write_stream_doc "operator" "" "" "Codex-Spark" "low" "operator.md"
      ;;
    strategy)
      write_stream_doc "strategy" "" "" "Codex" "high" "strategy.md"
      ;;
    analytics)
      write_stream_doc "analytics" "" "" "Codex" "high" "analytics.md"
      ;;
    ux)
      write_stream_doc "ux" "" "" "Codex" "high" "ux.md"
      ;;
    delivery-frontend)
      write_stream_doc "delivery" "frontend" "" "Codex" "medium" "delivery-frontend.md"
      ;;
    delivery-integration)
      write_stream_doc "delivery" "integration" "" "Codex" "high" "delivery-integration.md"
      ;;
    delivery-backend)
      for substream in "${BACKEND_SUBSTREAMS[@]}"; do
        substream_slug="$(printf '%s' "$substream" | tr '[:upper:]' '[:lower:]')"
        substream_slug="${substream_slug//-/_}"
        write_stream_doc "delivery" "backend" "$substream" "Codex" "high" "delivery-backend-${substream_slug}.md"
      done
      ;;
  esac
done

master_doc="$TASK_DIR/master.md"
cat > "$master_doc" <<EOF
# Master Task: $TITLE

- Task ID: \`$TASK_ID\`
- Created at (UTC): \`$created_at_utc\`
- Requested by: \`$OWNER\`
- Overall status: \`todo\`
- Deadline: \`${DEADLINE:-not set}\`
- Primary goal: $GOAL

## Routing Plan

| Stream | Lane | Backend substream | Model | Reasoning | Status | Doc |
|---|---|---|---|---|---|---|
$(printf '%s\n' "${TABLE_ROWS[@]}")

## Dependencies and Order

- Dependency notes:
- Required handoffs:
- Blocking risks:

## Completion Gate

- [ ] All mandatory stream docs are in \`done\` or \`skipped\` with reason.
- [ ] All handoffs are resolved.
- [ ] Final summary and links are written.

## Final Summary (fill on close)

- What was done:
- What was not done:
- Follow-up tasks:
EOF

echo "Created task package:"
echo "  Master: $master_doc"
for doc in "${CREATED_DOCS[@]}"; do
  echo "  Stream: $doc"
done
