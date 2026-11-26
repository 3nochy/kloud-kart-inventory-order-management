# ADR-001: Stop overselling by locking the product row inside one function

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

Last month two orders arrived at the same moment, both read a stock level of 1, and both sold it. At PostgreSQL's default isolation level (Read Committed) each statement sees only committed data, so both buyers read the stock before either change was committed. `race_test.py` calls `place_order` inside a `SELECT` on its own autocommit connection, releases up to 400 buyers together, and counts any error that reaches the client as a failure. The original schema had no stock check, and 14 products already held negative stock (27 units in total); solution script 06 adds a non-validated check for new and updated rows.

## Decision

`place_order` locks the product row with `SELECT ... FOR UPDATE` before it checks the stock. In the same transaction it then decrements the stock and writes the order, the order item and the stock movement. A second buyer waits at the lock, re-reads the new stock and is refused with "Out of stock".

## Alternatives considered

### Alternative A: Triggers alone

- **How it would work:** a trigger on `order_items` checks the stock before each insert and raises an error if there is too little.
- **Why it is attractive:** it cannot be bypassed by the application, and the rule lives in one place.
- **Why rejected:** two orders arriving together each start their own transaction and fire their own copy of the trigger. Neither sees the other's uncommitted work, so both still believe the unit is available. A trigger that took the row lock would work, but then the lock is what fixes the problem. A separate stock-change trigger is now used for auditing (ADR-007); it records movements but does not replace the row lock in `place_order`.

### Alternative B: Serializable isolation with retries

- **How it would work:** run each order at the Serializable level. PostgreSQL aborts one of two conflicting transactions with a serialization failure, and the caller retries it.
- **Why it is attractive:** it guards against more than this one race without naming a lock.
- **Why rejected:** the test connects with the default isolation level and has no retry loop, so a serialization failure would reach it and count as a failure. A retry inside the same transaction would still see the same snapshot, and the isolation level cannot be changed once a query has run. A procedure could commit and retry, but a procedure cannot be called from a `SELECT` (ADR-002).

### Alternative C: One atomic conditional UPDATE

- **How it would work:** `UPDATE products SET stock_quantity = stock_quantity - q WHERE product_id = p AND stock_quantity >= q`, treating zero rows updated as "out of stock".
- **Why it is attractive:** it is the shortest correct version, and it also holds a row lock until the transaction ends. It would also pass the test.
- **Why rejected:** the explicit lock keeps the sequence readable for Nana's team (find the product, check the price, check the stock, then write), and it lets the refusal say how many units were available. The cost of that choice is more lines for the same protection.

## Consequences

- **What this buys:** exactly one buyer gets the last unit, the other gets a clear refusal, no error reaches the client, and the stock change, order, item and stock movement are written together or not at all.
- **What this costs:** buyers of one product are served one at a time, each waiting for those ahead. Each waiting buyer holds a database connection, so the server needs `max_connections` above the number of simultaneous buyers (500 in this lab; the default of 100 makes the test unrunnable). No `lock_timeout` is set, so a waiting buyer waits without limit.
- **What it costs the client if I am wrong:** if a writer skips the lock, overselling returns, with the refunds, apologies and reviews Nana cannot undo. If the queue is slower in production than in the test, customers wait on a spinner during a flash sale.
- **What would make me revisit this:** measured waits of several seconds in a real sale, a multi-item checkout, or a profile showing the locked section is the bottleneck, in which case the atomic `UPDATE` is worth trying.

## What this survives

- **Verified:** the first three saved race-test runs passed on the original logging implementation. Run 4 passed after switching sales to the audit trigger: Test 1 passed all 25 one-unit races; Test 2 sold 50 of 50 units to 400 buyers, refused 350, and reported zero errors in 4.06 s including connection setup. Test 4 recorded five movements for five successful calls. The refusal paths (unknown customer, quantity 0, unknown product, too many units) also behave as intended (`results/race_test/place_order_checks.txt`).
- **Not verified:** a real flash sale over a network, an application connection pool in front of the database, multi-item orders, and cancelled orders returning stock.
- **The guarantee and its limit:** `place_order` keeps its stock change, order, item and trigger-written movement in one transaction. The audit trigger records ordinary direct stock updates, while the `products_stock_nonnegative` check blocks new or updated negative quantities. Because that check is `NOT VALID`, the 14 legacy negative rows remain for physical review. A direct update can still bypass the order/item workflow.
