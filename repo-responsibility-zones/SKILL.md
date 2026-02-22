---
name: repo-responsibility-zones
description: "Define repository responsibility zones (ownership boundaries), map them to streams, and enforce them with docs, CODEOWNERS, and scoped AGENTS. Use when a user asks to split a repo/monorepo by responsibility, reduce context drift between chats, or formalize who owns which paths."
---

# Repo Responsibility Zones

Create and maintain explicit ownership boundaries in a repository so work can be routed predictably and context does not sprawl across chats.

## Use This Skill When

- User asks to split a repository into clear ownership zones.
- User wants to map areas to streams/teams and reduce chat context drift.
- User asks for CODEOWNERS and governance around path ownership.
- User asks who should handle a task based on changed files.

## Core Outputs

For each rollout, produce or update these artifacts:

1. `docs/repository-zones/zone-catalog.md`
2. `docs/repository-zones/ownership-matrix.md`
3. `.github/CODEOWNERS` (or org equivalent)
4. Root and scoped `AGENTS.md` pointers for each zone (if AGENTS are used in repo)

Use templates from `references/`.

## Workflow

1. Discover repository shape.
- Inspect top-level folders and major modules.
- Group by runtime and responsibility, not by language alone.
- Keep each zone cohesive and operable by one primary owner.

2. Define zone boundaries.
- Assign one `primary_owner_stream` and one `backup_owner_stream`.
- Set explicit `in_scope` and `out_of_scope` for each zone.
- Define required interface contracts for cross-zone changes.

3. Map routing rules.
- For each zone, define intake stream and execution stream.
- Map escalation rules for blockers and cross-zone conflicts.
- Record dependency gates (what must be done before downstream work starts).

4. Enforce ownership.
- Add CODEOWNERS path rules that match zone boundaries.
- Align scoped AGENTS instructions with zone contracts.
- Require task docs to include `zone`, `owner`, and `handoff` sections.

5. Roll out safely.
- Prefer additive migration; avoid one-shot big-bang reshuffles.
- Start with `critical` zones first (prod runtime, settlement, money, auth, infra).
- Track exceptions and convert recurring exceptions into explicit boundary updates.

## Design Rules

- One path can have many collaborators but one accountable owner.
- Zone definitions must be path-based and machine-checkable.
- Cross-zone edits require a handoff note and acceptance criteria.
- Hotfixes can bypass normal flow, but must be backfilled into zone docs.
- Do not mix strategy intent and execution ownership in one zone definition.

## Stream Mapping Guidance

For stream-based operating model:

- Strategy: priorities, policy, sequencing, acceptance gates.
- Analytics: instrumentation ownership, KPI sources, anomaly checks.
- UX: flow quality, IA, usability acceptance.
- Delivery:
  - backend zones can be split further (example: BE-Platform, BE-GameCore, BE-Finance, BE-Contracts, BE-Reliability)
  - frontend zone
  - integration zone

Always encode backend substream routing in zone docs when backend is split.

## Required Deliverable Format

Use:
- `references/zone-catalog-template.md`
- `references/ownership-matrix-template.md`
- `references/codeowners-template.txt`
- `references/handoff-contract-template.md`

If the user asks for a proposal first, produce a draft plan without editing files, then wait for approval.

## Quality Gate

Before closing:
- [ ] Every major path in repo is covered by exactly one primary zone.
- [ ] CODEOWNERS entries are aligned with zone paths.
- [ ] Scoped AGENTS (if used) do not conflict with root guidance.
- [ ] Cross-zone handoff contract template is attached to task docs.
- [ ] At least one concrete routing example is documented.

## Commit Policy

- Commit governance artifacts only, unless user explicitly asked to implement code refactors.
- Keep zone-definition commits separate from product-code commits.
- Commit message pattern: `docs(zones): ...` or `chore(codeowners): ...`.
