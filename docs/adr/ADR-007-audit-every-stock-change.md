# ADR-007: Audit every stock quantity change

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

`place_order` records sales, but restocks, returns, damage, and direct product stock edits
also change the inventory count. A helper function alone could be bypassed by a direct
`UPDATE`, so the database needs a safeguard that records stock changes regardless of which
normal SQL path made the update.

## Decision

Add an `AFTER UPDATE OF stock_quantity` trigger on `products`. When the quantity changes,
the trigger inserts one `inventory_log` row in the same transaction. If the transaction
does not also write the log, the stock update rolls back. The trigger blocks a new stock
change that makes a non-negative count negative, or makes an existing negative count
worse. The `NOT VALID` table check still requires an updated row's final quantity to be
non-negative, so a legacy negative quantity must be corrected to the physically counted
non-negative amount in one movement; a partial adjustment that remains negative is refused.

Provide `record_stock_movement(product_id, change_qty, reason, note)` for restocks, returns,
damage, corrections, and stock takes. It locks the product row, refuses a result below
zero, checks sign rules for the movement reason, and updates stock; the trigger supplies
the corresponding audit row. A zero-change stock take is logged by the function because
no quantity-changing trigger event occurs. `place_order` supplies a transaction-local sale
context so the same trigger logs its movement with the new order id.

The actor is the PostgreSQL `session_user`. This identifies the database login, which may
be a shared application account rather than a particular staff member. Historical log
rows remain without an actor because the source data does not say who made them.

## Alternatives considered

### Require every caller to use the movement function

- **Why attractive:** the reason and note are explicit, and the update logic has one path.
- **Why rejected:** the project has no known application role to revoke direct `UPDATE`
  access from. A direct edit would bypass the helper and leave no audit row.

### Log changes only inside `place_order`

- **Why attractive:** it is enough to satisfy the race test's sale-trail check.
- **Why rejected:** it leaves restocks, corrections, and other stock edits outside the trail.

## Consequences

- **What this buys:** every ordinary update that changes `products.stock_quantity` also
  writes a log row atomically, including direct updates. The approved helper gives those
  movements a specific reason and note.
- **What this costs:** a direct update without context is labelled `correction` and its
  note says the reason was not supplied. An operator can still supply misleading context,
  and a database owner can alter the trigger or delete audit rows. This is an operational
  trail, not tamper-proof evidence.
- **What it costs Nana if the actor label is too broad:** if all application connections
  use one shared PostgreSQL login, the trail identifies the application, not the staff
  member. A future authenticated actor field should come from trusted application identity.
- **Important limit:** changing `orders` directly without changing product stock is not a
  stock movement and does not create a log row. Order creation should continue through
  `place_order`.

## What this survives

- **Implemented:** `sql/solution/05_stock_movement_audit.sql` installs the trigger and
  movement function; the updated `sql/solution/02_place_order.sql` uses the trigger for
  linked sale rows.
- **Verified:** the rollback-safe stock movement check passed for a restock, a correction,
  a direct update, and a refused underflow (`results/race_test/stock_movement_checks.txt`).
  Race test run 4 passed after the trigger was installed
  (`results/race_test/race_test_run_4.txt`).
- **Not verified:** a trusted per-person identity when Kloud Kart uses a shared database
  login, and the handling of automated cancellations/refunds.
