# Zone Catalog

| Zone | Paths | Primary owner stream | Backup owner stream | In scope | Out of scope | Contracts/interfaces | Criticality |
|---|---|---|---|---|---|---|---|
| Example: backend-platform | `src/platform/**` | `delivery/backend/BE-Platform` | `delivery/backend/BE-Reliability` | runtime wiring, shared infra adapters | game rules, settlement formulas | service interfaces, db migration policy | high |

## Notes

- Add one row per zone.
- Paths should be precise and non-overlapping whenever possible.
- If overlap is unavoidable, add explicit precedence rules.
