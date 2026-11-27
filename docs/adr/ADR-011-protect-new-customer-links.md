# ADR-011: Preserve old orphan orders and protect new customer links

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

The supplied database has 210 orders whose customer ids do not exist. A normal foreign
key would fail while being validated against those old rows. `place_order` also checked a
customer with a plain existence query, so a concurrent customer deletion could race with
the new order insert and leave another orphan.

## Decision

Add `orders_customer_id_fkey` as `NOT VALID`. PostgreSQL leaves the existing orphan orders
in place but enforces the relationship for new or changed customer references and prevents
deleting a customer that has orders. In `place_order`, take a `FOR KEY SHARE` lock on the
customer row during validation. That makes a concurrent deletion wait, allowing the
function to return `Customer not found` cleanly if the customer is already gone. The
foreign key then prevents deletion after the new order commits.

## Alternatives considered

### Repair every orphan and validate the foreign key

- **Why attractive:** the database could certify that every order has a customer.
- **Why rejected:** the historical rows do not identify the right customer, so inventing
  links would corrupt history. A business-approved cleanup is needed first.

### Keep only the function's existence check

- **Why attractive:** no schema change is needed.
- **Why rejected:** without a row lock and foreign key, a concurrent delete or another
  writer could still create a new orphan order.

## Consequences

- **What this buys:** new order links stay valid, including when a customer deletion races
  with order placement. Existing orphan orders remain visible and unchanged.
- **What this costs:** a customer referenced by an order cannot be deleted until the
  business changes or archives those orders. A changed customer reference on a legacy
  orphan order must be set to a real customer.
- **What it costs Nana if the delete rule is too strict:** staff may need an agreed
  customer-archiving process instead of deleting customers with orders.

## What this survives

- **Implemented:** the constraint is in
  `sql/solution/06_constraints_and_reconciliation.sql`; the key-share lock is in
  `sql/solution/02_place_order.sql`. The focused check is
  `customer_link_race_test.py`.
- **Verified after a clean reload:** `sql/run_all.sql` completed successfully, the
  rollback-safe order checks passed, and the fresh-load race test passed all 25 last-unit
  rounds; its 400-buyer test sold 50 of 50 units, refused 350, and had zero errors in
  2.46 seconds. Evidence is in `results/setup/run_all_fresh_load.txt`,
  `results/race_test/place_order_checks_fresh_load.txt`, and
  `results/race_test/race_test_fresh_load.txt`.
- **Verified customer-link behavior:** `customer_link_race_test.py` passed all three checks:
  the database rejected a direct order for a missing customer, refused to delete a customer
  with an order, and returned `Customer not found` during a concurrent delete/order race
  without leaving an order or stock change (`results/race_test/customer_link_checks.txt`).
- **Not verified:** customer-delete behavior with other transaction isolation levels or a
  production connection pool.
