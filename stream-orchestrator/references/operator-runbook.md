# Operator Runbook (SOP)

## 1) Intake

1. Normalize request into one sentence goal.
2. Detect if request is single-stream or multi-stream.
3. If ambiguous ownership, create parent operator task and split into child stream tasks.

## 2) Task creation

1. Create master doc with stream table.
2. Create stream docs with clear acceptance criteria.
3. Set initial statuses to `todo`.
4. Post first dispatch instructions to executors.

## 3) Monitoring cadence

1. Poll active streams on a short cadence.
2. Escalate idle streams quickly:
- warning ping at ~8 minutes without movement
- restart/reassign at ~15 minutes without movement
3. Keep stream-state checkpoints updated.

## 4) Blocker handling

1. Classify blocker as `spec`, `dependency`, or `environment`.
2. Route blocker to owning stream.
3. If cross-stream, open explicit handoff task.
4. If user decision is required, ask one concrete question with options.

## 5) Completion gates

1. Confirm each stream doc status is terminal.
2. Confirm implementation streams committed their changes.
3. Confirm evidence commands or notes are present.
4. Publish final operator summary and next-step recommendation.

## 6) Non-negotiables

1. Operator does not implement delivery code.
2. Operator does not mark done without evidence.
3. Operator does not stop while unresolved tasks exist.
