#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT_DIR_DEFAULT" ]]; then
  ROOT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ROOT_DIR="${STREAM_ROOT:-$ROOT_DIR_DEFAULT}"
SESSION_NAME="aeonic-streams"
ATTACH=1
AUTO_EXECUTORS=1
EXECUTOR_INTERVAL=60
EXECUTOR_MODEL=""
REFRESH_EXISTING=1
OPERATOR_WATCH=1
WATCH_INTERVAL=30
WATCH_STALE_SECONDS=180

usage() {
  cat <<'EOF'
Usage: scripts/start_streams.sh [options]

Options:
  --root <path>      target repository root (default: STREAM_ROOT or current git root)
  --session <name>   tmux session name (default: aeonic-streams)
  --no-attach        create/refresh session but do not attach
  --no-executors     do not auto-run delivery executors in D-BE/D-FE/D-INT windows
  --executor-interval <sec>
                     polling interval for delivery executors (default: 60)
  --executor-model <name>
                     optional model override passed to codex exec
  --no-refresh       if session exists, do not restart/refresh existing windows
  --no-operator-watch
                     keep O window informational only (disable active watch loop)
  --watch-interval <sec>
                     operator watch polling interval (default: 30)
  --watch-stale-seconds <sec>
                     stale heartbeat threshold for active tasks (default: 180)
  -h, --help         show help
EOF
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
    --no-attach)
      ATTACH=0
      shift
      ;;
    --no-executors)
      AUTO_EXECUTORS=0
      shift
      ;;
    --executor-interval)
      EXECUTOR_INTERVAL="${2:-}"
      if [[ -z "$EXECUTOR_INTERVAL" ]]; then
        echo "Error: --executor-interval requires a value." >&2
        exit 1
      fi
      if ! [[ "$EXECUTOR_INTERVAL" =~ ^[0-9]+$ ]]; then
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
    --no-refresh)
      REFRESH_EXISTING=0
      shift
      ;;
    --no-operator-watch)
      OPERATOR_WATCH=0
      shift
      ;;
    --watch-interval)
      WATCH_INTERVAL="${2:-}"
      if [[ -z "$WATCH_INTERVAL" || ! "$WATCH_INTERVAL" =~ ^[0-9]+$ ]]; then
        echo "Error: --watch-interval must be an integer number of seconds." >&2
        exit 1
      fi
      shift 2
      ;;
    --watch-stale-seconds)
      WATCH_STALE_SECONDS="${2:-}"
      if [[ -z "$WATCH_STALE_SECONDS" || ! "$WATCH_STALE_SECONDS" =~ ^[0-9]+$ ]]; then
        echo "Error: --watch-stale-seconds must be an integer number of seconds." >&2
        exit 1
      fi
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

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: ROOT_DIR does not exist: $ROOT_DIR" >&2
  exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
  echo "Error: tmux is not installed. Install tmux first." >&2
  exit 1
fi

mkdir -p \
  "$ROOT_DIR/docs/stream-state" \
  "$ROOT_DIR/docs/stream-state/checkpoints" \
  "$ROOT_DIR/docs/stream-state/runtime" \
  "$ROOT_DIR/docs/stream-tasks"

WINDOWS=("O" "S" "A" "U" "D-BE" "D-FE" "D-INT")

window_exists() {
  local window="$1"
  tmux list-windows -t "$SESSION_NAME" -F '#W' | grep -Fxq "$window"
}

ensure_window() {
  local window="$1"
  if ! window_exists "$window"; then
    tmux new-window -t "$SESSION_NAME" -n "$window" "bash"
  fi
}

state_file_for_window() {
  case "$1" in
    O) echo "docs/stream-state/O.md" ;;
    S) echo "docs/stream-state/S.md" ;;
    A) echo "docs/stream-state/A.md" ;;
    U) echo "docs/stream-state/U.md" ;;
    D-BE) echo "docs/stream-state/D-BE.md" ;;
    D-FE) echo "docs/stream-state/D-FE.md" ;;
    D-INT) echo "docs/stream-state/D-INT.md" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

bootstrap_info_window() {
  local window="$1"
  local state_rel
  local state_abs
  local cmd

  state_rel="$(state_file_for_window "$window")"
  state_abs="$ROOT_DIR/$state_rel"

  cmd="cd \"$ROOT_DIR\"; clear; echo \"[$window] Aeonic stream session\"; echo \"State file: $state_rel\"; echo; if [ -f \"$state_abs\" ]; then sed -n '1,120p' \"$state_abs\"; else echo \"State file missing: $state_rel\"; fi; echo; echo \"--- git status -sb ---\"; git status -sb; echo; echo \"--- recent task dirs ---\"; ls -1 \"$ROOT_DIR/docs/stream-tasks\" 2>/dev/null | tail -n 10"
  tmux send-keys -t "${SESSION_NAME}:${window}" C-c
  tmux send-keys -t "${SESSION_NAME}:${window}" "$cmd" C-m
}

bootstrap_operator_window() {
  local state_rel
  local state_abs
  local cmd
  local watch_cmd

  state_rel="$(state_file_for_window "O")"
  state_abs="$ROOT_DIR/$state_rel"

  if [[ "$OPERATOR_WATCH" -eq 1 ]]; then
    watch_cmd="\"$SCRIPT_DIR/operator_watch.sh\" --root \"$ROOT_DIR\" --session \"$SESSION_NAME\" --interval \"$WATCH_INTERVAL\" --stale-seconds \"$WATCH_STALE_SECONDS\""
    cmd="cd \"$ROOT_DIR\"; clear; echo \"[O] Operator watch loop\"; echo \"State file: $state_rel\"; echo \"Watch interval: ${WATCH_INTERVAL}s\"; echo \"Stale threshold: ${WATCH_STALE_SECONDS}s\"; echo; if [ -f \"$state_abs\" ]; then sed -n '1,80p' \"$state_abs\"; else echo \"State file missing: $state_rel\"; fi; echo; $watch_cmd"
  else
    cmd="cd \"$ROOT_DIR\"; clear; echo \"[O] Operator stream (manual mode)\"; echo \"State file: $state_rel\"; echo; if [ -f \"$state_abs\" ]; then sed -n '1,120p' \"$state_abs\"; else echo \"State file missing: $state_rel\"; fi; echo; echo \"Operator watch is disabled (--no-operator-watch).\""
  fi

  tmux send-keys -t "${SESSION_NAME}:O" C-c
  tmux send-keys -t "${SESSION_NAME}:O" "$cmd" C-m
}

bootstrap_delivery_window() {
  local window="$1"
  local state_rel
  local state_abs
  local cmd
  local executor_cmd

  state_rel="$(state_file_for_window "$window")"
  state_abs="$ROOT_DIR/$state_rel"

  if [[ "$AUTO_EXECUTORS" -eq 1 ]]; then
    executor_cmd="\"$SCRIPT_DIR/run_stream_executor.sh\" --stream \"$window\" --interval \"$EXECUTOR_INTERVAL\" --root \"$ROOT_DIR\""
    if [[ -n "$EXECUTOR_MODEL" ]]; then
      executor_cmd+=" --model \"$EXECUTOR_MODEL\""
    fi
    cmd="cd \"$ROOT_DIR\"; clear; echo \"[$window] Delivery executor loop\"; echo \"State file: $state_rel\"; echo \"Interval: ${EXECUTOR_INTERVAL}s\"; if [ -n \"$EXECUTOR_MODEL\" ]; then echo \"Model: $EXECUTOR_MODEL\"; else echo \"Model: default\"; fi; echo; if [ -f \"$state_abs\" ]; then sed -n '1,80p' \"$state_abs\"; else echo \"State file missing: $state_rel\"; fi; echo; $executor_cmd"
  else
    cmd="cd \"$ROOT_DIR\"; clear; echo \"[$window] Delivery stream (manual mode)\"; echo \"State file: $state_rel\"; echo; if [ -f \"$state_abs\" ]; then sed -n '1,120p' \"$state_abs\"; else echo \"State file missing: $state_rel\"; fi; echo; echo \"Executors are disabled (--no-executors).\""
  fi

  tmux send-keys -t "${SESSION_NAME}:${window}" C-c
  tmux send-keys -t "${SESSION_NAME}:${window}" "$cmd" C-m
}

bootstrap_window() {
  local window="$1"
  case "$window" in
    O)
      bootstrap_operator_window
      ;;
    D-BE|D-FE|D-INT)
      bootstrap_delivery_window "$window"
      ;;
    *)
      bootstrap_info_window "$window"
      ;;
  esac
}

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  echo "tmux session '$SESSION_NAME' already exists."
  for window in "${WINDOWS[@]}"; do
    ensure_window "$window"
  done
  if [[ "$REFRESH_EXISTING" -eq 1 ]]; then
    for window in "${WINDOWS[@]}"; do
      bootstrap_window "$window"
    done
    tmux select-window -t "${SESSION_NAME}:O"
    echo "Refreshed existing session '$SESSION_NAME'."
  else
    echo "Skipped refresh (--no-refresh)."
  fi
else
  tmux new-session -d -s "$SESSION_NAME" -n "${WINDOWS[0]}" "bash"

  for ((i = 1; i < ${#WINDOWS[@]}; i++)); do
    ensure_window "${WINDOWS[$i]}"
  done

  for window in "${WINDOWS[@]}"; do
    bootstrap_window "$window"
  done

  tmux select-window -t "${SESSION_NAME}:O"
  echo "Created tmux session '$SESSION_NAME' with stream windows."
fi

if [[ "$ATTACH" -eq 1 ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION_NAME"
  else
    tmux attach-session -t "$SESSION_NAME"
  fi
else
  echo "Session '$SESSION_NAME' is ready. Attach with:"
  echo "  tmux attach -t $SESSION_NAME"
fi
