#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT_DIR_DEFAULT" ]]; then
  ROOT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ROOT_DIR="${STREAM_ROOT:-$ROOT_DIR_DEFAULT}"
STATE_DIR="$ROOT_DIR/docs/stream-state"
CHECKPOINT_DIR="$STATE_DIR/checkpoints"

STREAM_INPUT=""
STATUS="in_progress"
TASK_REF="not set"
SUMMARY=""
NEXT_STEP="not set"
BLOCKERS="none"
MODEL="not set"
REASONING="not set"
BACKEND_SUBSTREAM="n/a"
NO_GLOBAL=0

usage() {
  cat <<'EOF'
Usage: scripts/checkpoint_streams.sh --stream <stream> --summary "<text>" [options]

Options:
  --root "<path>"           Target repository root (default: STREAM_ROOT or current git root)
  --stream <name>           Stream key: O,S,A,U,D-BE,D-FE,D-INT
                            or long form: operator,strategy,analytics,ux,delivery-backend,delivery-frontend,delivery-integration
  --status <value>          todo|in_progress|blocked|done|skipped (default: in_progress)
  --task "<path|id>"        Task reference (master or stream doc)
  --summary "<text>"        Short summary (required)
  --next "<text>"           Next action
  --blockers "<text>"       Blockers list
  --model "<name>"          Model used
  --reasoning "<level>"     Reasoning level
  --backend-substream "<s>" Backend substream (for D-BE), e.g. BE-Contracts
  --no-global               Skip writing checkpoint snapshot file
  -h, --help                Show help
EOF
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_stream() {
  case "$1" in
    O|operator) echo "O" ;;
    S|strategy) echo "S" ;;
    A|analytics) echo "A" ;;
    U|ux) echo "U" ;;
    D-BE|delivery-backend) echo "D-BE" ;;
    D-FE|delivery-frontend) echo "D-FE" ;;
    D-INT|delivery-integration) echo "D-INT" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

display_stream_name() {
  case "$1" in
    O) echo "operator" ;;
    S) echo "strategy" ;;
    A) echo "analytics" ;;
    U) echo "ux" ;;
    D-BE) echo "delivery" ;;
    D-FE) echo "delivery" ;;
    D-INT) echo "delivery" ;;
    *) echo "unknown" ;;
  esac
}

display_lane_name() {
  case "$1" in
    D-BE) echo "backend" ;;
    D-FE) echo "frontend" ;;
    D-INT) echo "integration" ;;
    *) echo "n/a" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="${2:-}"
      if [[ -z "$ROOT_DIR" ]]; then
        echo "Error: --root requires a value." >&2
        exit 1
      fi
      STATE_DIR="$ROOT_DIR/docs/stream-state"
      CHECKPOINT_DIR="$STATE_DIR/checkpoints"
      shift 2
      ;;
    --stream)
      STREAM_INPUT="${2:-}"
      shift 2
      ;;
    --status)
      STATUS="${2:-}"
      shift 2
      ;;
    --task)
      TASK_REF="${2:-}"
      shift 2
      ;;
    --summary)
      SUMMARY="${2:-}"
      shift 2
      ;;
    --next)
      NEXT_STEP="${2:-}"
      shift 2
      ;;
    --blockers)
      BLOCKERS="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --reasoning)
      REASONING="${2:-}"
      shift 2
      ;;
    --backend-substream)
      BACKEND_SUBSTREAM="${2:-}"
      shift 2
      ;;
    --no-global)
      NO_GLOBAL=1
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

STREAM_INPUT="$(trim "$STREAM_INPUT")"
STATUS="$(trim "$STATUS")"
SUMMARY="$(trim "$SUMMARY")"
TASK_REF="$(trim "$TASK_REF")"
NEXT_STEP="$(trim "$NEXT_STEP")"
BLOCKERS="$(trim "$BLOCKERS")"
MODEL="$(trim "$MODEL")"
REASONING="$(trim "$REASONING")"
BACKEND_SUBSTREAM="$(trim "$BACKEND_SUBSTREAM")"

if [[ -z "$STREAM_INPUT" ]]; then
  echo "Error: --stream is required." >&2
  usage
  exit 1
fi

if [[ -z "$SUMMARY" ]]; then
  echo "Error: --summary is required." >&2
  usage
  exit 1
fi

case "$STATUS" in
  todo|in_progress|blocked|done|skipped) ;;
  *)
    echo "Error: invalid --status '$STATUS'." >&2
    exit 1
    ;;
esac

STREAM_KEY="$(normalize_stream "$STREAM_INPUT" || true)"
if [[ -z "$STREAM_KEY" ]]; then
  echo "Error: invalid --stream '$STREAM_INPUT'." >&2
  exit 1
fi

STREAM_NAME="$(display_stream_name "$STREAM_KEY")"
LANE_NAME="$(display_lane_name "$STREAM_KEY")"

if [[ "$STREAM_KEY" != "D-BE" ]]; then
  BACKEND_SUBSTREAM="n/a"
elif [[ -z "$BACKEND_SUBSTREAM" || "$BACKEND_SUBSTREAM" == "n/a" ]]; then
  BACKEND_SUBSTREAM="not set"
fi

mkdir -p "$STATE_DIR" "$CHECKPOINT_DIR"

STATE_FILE="$STATE_DIR/${STREAM_KEY}.md"
if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" <<EOF
# Stream State: $STREAM_KEY

- Stream: \`$STREAM_NAME\`
- Lane: \`$LANE_NAME\`
- Backend substream: \`n/a\`

## Active Work
- Task:
- Status:
- Next step:
- Blockers:

## Log
EOF
fi

timestamp_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
timestamp_file="$(date -u '+%Y%m%d-%H%M%S')"

cat >> "$STATE_FILE" <<EOF

### $timestamp_utc
- Task: \`$TASK_REF\`
- Status: \`$STATUS\`
- Model: \`$MODEL\`
- Reasoning: \`$REASONING\`
- Lane: \`$LANE_NAME\`
- Backend substream: \`$BACKEND_SUBSTREAM\`
- Summary: $SUMMARY
- Next: $NEXT_STEP
- Blockers: $BLOCKERS
EOF

if [[ "$NO_GLOBAL" -eq 0 ]]; then
  CHECKPOINT_FILE="$CHECKPOINT_DIR/${timestamp_file}-${STREAM_KEY}.md"
  BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
  LAST_COMMIT="$(git -C "$ROOT_DIR" log -1 --oneline 2>/dev/null || echo "unknown")"

  {
    echo "# Checkpoint: $timestamp_utc"
    echo
    echo "- Stream key: \`$STREAM_KEY\`"
    echo "- Stream: \`$STREAM_NAME\`"
    echo "- Lane: \`$LANE_NAME\`"
    echo "- Backend substream: \`$BACKEND_SUBSTREAM\`"
    echo "- Task: \`$TASK_REF\`"
    echo "- Status: \`$STATUS\`"
    echo "- Summary: $SUMMARY"
    echo "- Next: $NEXT_STEP"
    echo "- Blockers: $BLOCKERS"
    echo "- Model: \`$MODEL\`"
    echo "- Reasoning: \`$REASONING\`"
    echo "- Branch: \`$BRANCH\`"
    echo "- Last commit: \`$LAST_COMMIT\`"
    echo
    echo "## git status -sb"
    echo
    echo '```text'
    git -C "$ROOT_DIR" status -sb
    echo '```'
  } > "$CHECKPOINT_FILE"

  echo "Wrote stream state: $STATE_FILE"
  echo "Wrote checkpoint: $CHECKPOINT_FILE"
else
  echo "Wrote stream state: $STATE_FILE"
fi
