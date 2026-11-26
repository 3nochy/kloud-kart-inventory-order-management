# Key decisions: Kloud Kart inventory and order management

Each decision is recorded in its own file under `docs/adr/`, using the architecture decision record template. Evidence for every figure is in `results/`.

| ADR | Decision | Status |
|-----|----------|--------|
| [ADR-001](adr/ADR-001-lock-product-row.md) | Stop overselling by locking the product row inside one function | Accepted |
| [ADR-002](adr/ADR-002-function-one-product-per-call.md) | A function that takes one product per call | Accepted |
| [ADR-003](adr/ADR-003-log-sale-at-placement.md) | Log the sale, and set the order to pending, at placement | Proposed |
| [ADR-004](adr/ADR-004-link-log-to-order.md) | Link each stock movement to its order | Accepted |
| [ADR-005](adr/ADR-005-ids-from-sequences.md) | New ids from sequences that start above every id in use | Accepted |

## Where the brief's three questions are answered

- **How the overselling was solved, and whether triggers alone would have fixed it:** ADR-001 (triggers are Alternative A).
- **How the report was made fast:** not recorded yet; it follows the report build and its measurements.
- **Where the brief left something open and an assumption was made:** ADR-002 (one product per call), ADR-003 (status and when the sale is logged), ADR-004 (linking the log to orders) and ADR-005 (id generation).
