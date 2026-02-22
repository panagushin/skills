# Stream Orchestrator Scripts (Portable)

These scripts are portable and do not hardcode a specific machine path.

## Root Resolution

Each script resolves target repo root in this order:
1. `--root <path>`
2. `STREAM_ROOT` environment variable
3. current git toplevel (`git rev-parse --show-toplevel`)
4. parent of the script directory

## Included Scripts

- `start_streams.sh` - create/refresh tmux stream session and boot operator watch + executors
- `operator_watch.sh` - monitor stream health; auto-heal stale/down executors
- `run_stream_executor.sh` - run one delivery stream loop (`D-BE`, `D-FE`, `D-INT`)
- `dispatch_task.sh` - create master/stream task package in `docs/stream-tasks`
- `checkpoint_streams.sh` - append stream state checkpoint and optional snapshot

## Minimal Usage

```bash
# from any folder
export STREAM_ROOT=/path/to/your/repo

./start_streams.sh --no-attach
./dispatch_task.sh --title "Example task" --goal "Do X" --owner "operator"
```

Or pass root explicitly:

```bash
./start_streams.sh --root /path/to/your/repo --no-attach
./dispatch_task.sh --root /path/to/your/repo --title "Example task"
```

## Repo Prerequisites

- `tmux` installed
- `codex` CLI installed (for executor scripts)
- repo has:
  - `docs/stream-tasks/`
  - `docs/stream-state/`

The scripts will create missing stream-state/task directories when possible.
