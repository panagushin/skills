# Ownership Matrix

| Task type | Zone | Intake stream | Execution stream | Required handoff | Validation evidence |
|---|---|---|---|---|---|
| Feature change | backend-gamecore | strategy -> operator | delivery/backend/BE-GameCore | ux signoff if flow changes | tests + task doc + commit |
| Incident hotfix | backend-reliability | operator | delivery/backend/BE-Reliability | post-incident review to strategy | incident log + rollback plan |

## Routing Rules

- If change touches multiple zones, create one parent task and child tasks per zone.
- Sequence by dependency gates; do not run dependent zones in parallel.
