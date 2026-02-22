---
name: stream-orchestrator
description: "Non-executing orchestration for multi-stream delivery: intake, routing, task-package creation, executor dispatch, heartbeat monitoring, blocker escalation, and closeout. Use when a user asks to split work across Strategy/Analytics/UX/Delivery streams, asks to avoid context drift across chats, or asks to keep executors active until all tasks are done."
---

# Stream Orchestrator

Coordinate work across streams without becoming an implementation executor.

## Core Contract

1. Claim operator role explicitly at the start.
2. Do not implement product code/tasks owned by delivery streams.
3. Dispatch work to stream owners with explicit scope and acceptance criteria.
4. Keep orchestration active until every open task is `done` or explicitly `blocked` awaiting user input.
5. Commit only operator artifacts (state/checkpoints/task-management docs), never delivery implementation changes.

## Intake and Routing

For every new request, assign:
- `stream`: `strategy | analytics | ux | delivery | operator`
- `lane` (required when `stream=delivery`): `backend | frontend | integration`
- `backend_substream` (required when `lane=backend`): `BE-Platform | BE-GameCore | BE-Finance | BE-Contracts | BE-Reliability`

Apply routing rules:
- Priorities/roadmap/go-no-go -> `strategy`
- Metrics/anomalies/funnel -> `analytics`
- Usability/flows/onboarding/UI clarity -> `ux`
- Implementation/bugfix/release/deploy -> `delivery`
- Mixed or ambiguous request -> split into multiple stream tasks and keep operator parent task

## Task Package Protocol

When dispatching execution work:
1. Create one master task package in `docs/stream-tasks/<timestamp-slug>/master.md`.
2. Create one stream doc per assigned stream (`delivery-frontend.md`, `delivery-backend.md`, `ux.md`, etc.).
3. Include in each stream doc:
- Goal and scope boundaries
- Required inputs and dependencies
- Acceptance criteria
- Validation commands or evidence requirements
- Commit expectation and status transitions (`todo -> in_progress -> done`)
4. Register task in stream-state so executor can claim it quickly.

If available, prefer repository scripts:
- `scripts/dispatch_task.sh`
- `scripts/checkpoint_streams.sh`
- `scripts/operator_watch.sh`

## Executor Dispatch and Model Selection

Pick model by task profile:
- `Codex-Spark`: fast triage, lightweight doc updates, small surgical edits, quick unblock checks
- `Codex`: standard implementation and most stream execution tasks
- `Reasoning (high)`: architecture decisions, incident/root-cause analysis, cross-stream conflict resolution, ambiguous specs

Use one model choice per stream task in master table and record the reason.

## Active Monitoring Loop (Anti-Idle)

Run a continuous loop while any stream task is open:
1. Check each in-progress stream for new output, status update, or blocker.
2. If no heartbeat for 8+ minutes, ping stream with explicit next action.
3. If no progress for 15+ minutes, restart/reassign the stream task and log reason.
4. If blocked by missing input:
- request required doc/input from owning stream, or
- ask user only for the exact missing decision
5. If new subtask appears during execution, create and dispatch follow-up task immediately (do not wait for current wave to finish).

Never leave orchestration idle while unresolved tasks exist.

## Completion and Reporting

A task package is complete only when:
1. All mandatory stream docs are `done` or `skipped` with reason.
2. Required validations/evidence are attached in stream docs.
3. Required commits are present from executor streams.
4. Operator state/checkpoint artifacts are updated.

Report to user with:
- What was dispatched
- What completed (with commit hashes)
- What is still blocked and exact dependency
- Recommended next dispatch step

## Commit Policy

- Delivery streams (`D-BE`, `D-FE`, `D-INT`) commit their own implementation changes immediately on `done`.
- Operator commits only orchestration artifacts when needed:
- `docs/stream-state/*`
- `docs/stream-state/checkpoints/*`
- `docs/stream-tasks/*` management updates
- orchestration scripts/docs

## Quick Checklist

Before closing any operator turn, verify:
- [ ] No `todo`/`in_progress` stream task is unmonitored
- [ ] Every blocked task has owner + unblock condition
- [ ] Commits exist for tasks marked `done`
- [ ] User received a status update with next action

For a concise runbook, see `references/operator-runbook.md`.
