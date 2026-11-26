# ADR-001: Stop overselling by locking the product row inside one function

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

Last month two orders arrived at the same moment, both read a stock level of 1, and both sold it. At PostgreSQL's default isolation level (Read Committed) each statement sees only committed data, so both buyers read the stock before either change was committed. `race_test.py` calls `place_order` inside a `SELECT` on its own autocommit connection, releases up to 400 buyers together, and counts any error that reaches the client as a failure. The schema has no CHECK on stock, and 14 products already hold negative stock (27 units in total).

## Decision

`place_order` locks the product row with `SELECT ... FOR UPDATE` before it checks the stock. In the same transaction it then decrements the stock and writes the order, the order item and the stock movement. A second buyer waits at the lock, re-reads the new stock and is refused with "Out of stock".

## Alternatives considered

### Alternative A: Triggers alone

- **How it would work:** a trigger on `order_items` checks the stock before each insert and raises an error if there is too little.
- **Why it is attractive:** it cannot be bypassed by the application, and the rule lives in one place.
- **Why rejected:** two orders arriving together each start their own transaction and fire their own copy of the trigger. Neither sees the other's uncommitted work, so both still believe the unit is available. A trigger that took the row lock would work, but then the lock is what fixes the problem. Triggers remain a good fit for the audit trail, because they cannot be forgotten; none is built here.

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

- **Verified:** `race_test.py` passes. Test 1 ran 25 rounds of two buyers for one unit, all 25 correct. Test 2 ran 400 buyers for 50 units: 50 sold, 350 refused, none errored, 2.74 s wall clock including opening the 400 connections, on one laptop with the database in a container on the same machine. The three saved runs (`results/race_test/race_test_run_1.txt` to `race_test_run_3.txt`) all report PASSED. The refusal paths (unknown customer, quantity 0, unknown product, too many units) behave as intended (`results/race_test/place_order_checks.txt`).
- **Not verified:** a real flash sale over a network, an application connection pool in front of the database, multi-item orders, and cancelled orders returning stock.
- **The guarantee and its limit:** stock never goes below zero through `place_order`, and the order, item and stock movement are written together. This holds only for writers that go through `place_order`. A manual `UPDATE products SET stock_quantity` bypasses it, and no CHECK on stock has been added yet.
