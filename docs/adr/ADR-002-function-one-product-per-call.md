# ADR-002: Place orders with a function that takes one product per call

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

The contract in `race_test.py` fixes the signature, `place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer)` returning `(success, order_id, message)`, and the test calls it as `SELECT ... FROM place_order(...)` on an autocommit connection. In the existing data orders usually have several lines: 336,559 item rows across 159,384 orders, about 2.1 per order.

## Decision

`place_order` is a PL/pgSQL function, not a procedure, and it handles one product per call, so each call takes one row lock and does one stock check.

## Alternatives considered

### Alternative A: A procedure called with CALL

- **How it would work:** a procedure can commit and roll back inside itself, so it could retry a failed attempt on its own.
- **Why it is attractive:** it gives the routine control over its own transactions.
- **Why rejected:** a procedure cannot be called from a `SELECT`, and the test calls the routine that way, so it would not satisfy the contract.

### Alternative B: A function that takes a whole basket

- **How it would work:** the function accepts a list of (product, quantity) lines and places them as one order.
- **Why it is attractive:** it matches how most real orders look, at about 2.1 lines each.
- **Why rejected:** the signature is fixed by the contract. A basket also needs its locks taken in ascending `product_id` order to avoid two baskets deadlocking, and nothing in the supplied test exercises that, so I could not verify it.

## Consequences

- **What this buys:** one lock per call, so two products can never deadlock inside a call, and one atomic unit: on the test's autocommit connection a function call runs as a single transaction, so everything it writes is kept or none of it is.
- **What this costs:** a customer buying two products needs two calls and gets two separate orders, with no all-or-nothing across them.
- **What it costs the client if I am wrong:** if the shop sells multi-item carts through this function, a cart could end up partly fulfilled.
- **What would make me revisit this:** building a multi-item checkout, which would need a second function that locks products in ascending `product_id` order.

## What this survives

- **Verified:** the refusal checks and the race test call the function exactly as the contract describes (`results/race_test/`).
- **Not verified:** multi-item orders, because neither the supplied test nor my checks place more than one product per order.
