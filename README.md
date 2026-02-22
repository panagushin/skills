# skills

Reusable Codex skills.

## Included skills

- `stream-orchestrator`: non-executing orchestration skill for routing, dispatching, monitoring, escalation, and closeout across multiple workstreams.
  - includes portable shell scripts in `stream-orchestrator/scripts/` (`start_streams.sh`, `operator_watch.sh`, `run_stream_executor.sh`, `dispatch_task.sh`, `checkpoint_streams.sh`)
- `repo-responsibility-zones`: defines repository ownership boundaries (zones), maps zones to streams, and enforces governance with templates for zone catalog, ownership matrix, CODEOWNERS, and cross-zone handoff contracts.

## Install

### Option 1: via Codex skill installer

Use the `$skill-installer` skill and point it to this repository path.

### Option 2: manual

Copy the folder into your local Codex skills directory:

```bash
mkdir -p "$CODEX_HOME/skills"
cp -R stream-orchestrator "$CODEX_HOME/skills/"
cp -R repo-responsibility-zones "$CODEX_HOME/skills/"
```

## Usage

Mention the skill in prompt:

```text
Use $stream-orchestrator to split this request into stream tasks, dispatch owners, and monitor until done.
Use $repo-responsibility-zones to define repository zones, owners, and CODEOWNERS governance.
```
