# ADR-004: Link each stock movement to its order with a new column

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

Nana asked for a trail an auditor could walk through. Today nothing links a log row to the order that caused it: `inventory_log` has only a free-text `reason` and `note`, and `note` is empty on 281,927 of 282,352 rows.

## Decision

Add a nullable integer column `inventory_log.order_id`. `place_order` fills it for every sale. The existing rows stay NULL and no foreign key is added.

## Alternatives considered

### Alternative A: Put the order id in the free-text note

- **How it would work:** write something like `order 999863` into `inventory_log.note`.
- **Why it is attractive:** no schema change.
- **Why rejected:** the note column is free text, nearly always empty, and the rest holds hand-written phrases, so an auditor could not rely on it, and a join would need string matching.

### Alternative B: A foreign key from the new column to orders

- **How it would work:** `order_id REFERENCES orders (order_id)`, so a log row cannot point at a missing order.
- **Why it is attractive:** it prevents the kind of orphan row the diagnosis found elsewhere.
- **Why rejected:** the supplied test's cleanup deletes its fixture orders before it deletes their log rows, so a plain foreign key would make that cleanup fail. With `ON DELETE SET NULL` the cleanup would pass, but the trail would lose its link whenever an order is deleted, which defeats the purpose. The existing schema has no foreign keys, and adding them is a separate cleanup decision.

## Consequences

- **What this buys:** an auditor can go from a stock movement to its order and back with a join on `order_id`.
- **What this costs:** the 282,352 existing rows stay NULL, so only new sales are traceable. Without a foreign key a log row could point at a missing order, the same fault family as the 692 orphan order items. There is no index on the new column, so a join from orders to the log scans the whole log.
- **What it costs the client if I am wrong:** an auditor finds a movement with no matching order, or cannot match an old movement at all.
- **What would make me revisit this:** cleaning up the orphans and adding foreign keys across the schema in one go, or audit queries becoming slow, in which case the column gets an index.

## What this survives

- **Verified:** in the refusal checks the new sale's log row came back with `linked_to_order = t` (`results/race_test/place_order_checks.txt`).
- **Not verified:** query speed on the new column, and backfilling the existing rows, which I did not attempt because nothing reliable links them to orders.
