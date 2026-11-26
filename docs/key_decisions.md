# Key decisions: Kloud Kart inventory and order management

Each decision is recorded in its own file under `docs/adr/`, using the architecture decision record template. Evidence for every figure is in `results/`.

| ADR | Decision | Status |
|-----|----------|--------|
| [ADR-001](adr/ADR-001-lock-product-row.md) | Stop overselling by locking the product row inside one function | Accepted |
| [ADR-002](adr/ADR-002-function-one-product-per-call.md) | A function that takes one product per call | Accepted |
| [ADR-003](adr/ADR-003-log-sale-at-placement.md) | Log the sale, and set the order to pending, at placement | Proposed |
| [ADR-004](adr/ADR-004-link-log-to-order.md) | Link each stock movement to its order | Accepted |
| [ADR-005](adr/ADR-005-ids-from-sequences.md) | New ids from sequences that start above every id in use | Accepted |
| [ADR-006](adr/ADR-006-recursive-low-stock-rollup.md) | Roll up stock at any category depth; default low-stock threshold is five units | Accepted |
| [ADR-007](adr/ADR-007-audit-every-stock-change.md) | Audit stock updates with a trigger and a reasoned movement function | Accepted |
| [ADR-008](adr/ADR-008-monday-report.md) | Use charged order totals and precompute the Monday report | Accepted for this lab |
| [ADR-009](adr/ADR-009-stock-reconciliation-queue.md) | Prioritize physical stock counts; never auto-correct disagreements | Accepted |
| [ADR-010](adr/ADR-010-indexes.md) | Add measured-use indexes for report, category, and audit lookups | Accepted after post-index timings |

## Where the brief's three questions are answered

- **How the overselling was solved, and whether triggers alone would have fixed it:** ADR-001 (triggers are Alternative A).
- **How the report was made fast:** ADR-008 records the materialized summaries, refresh trade-off, and measured query times.
- **Where the brief left something open and an assumption was made:** ADR-002 (one product per call), ADR-003 (status and when the sale is logged), ADR-004 (linking the log to orders), ADR-005 (id generation), ADR-006 (five-unit low-stock threshold), ADR-008 (spend/status/as-of rules), and ADR-009 (physical reconciliation instead of automatic correction).
