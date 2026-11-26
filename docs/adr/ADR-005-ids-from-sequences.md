# ADR-005: Generate new ids from sequences that start above every id in use

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

`orders.order_id`, `order_items.order_item_id` and `inventory_log.log_id` are plain integer keys with no default, so the function has to create its own ids. Real orders run from 500,001 to 659,384, but 692 existing order items point at order ids between 900,101 and 999,862 that have no order.

## Decision

Three sequences supply the new ids. The orders sequence starts at the highest order id found in `orders`, `order_items`, or linked `inventory_log` rows (999,862 in the supplied data), so the first new order is 999,863. The other two start at their table's current maximum.

## Alternatives considered

### Alternative A: max(id) + 1 inside the function

- **How it would work:** read the highest id and add one.
- **Why it is attractive:** no new database objects.
- **Why rejected:** two simultaneous buyers can read the same maximum and collide on one id. It would also start at 659,385 and, at about 4,000 orders a day, reach the orphan range in roughly 60 days, when new orders would silently adopt the 692 orphan items.

### Alternative B: A sequence that starts just above the highest existing order

- **How it would work:** one sequence starting at 659,385.
- **Why it is attractive:** new ids stay next to the existing numbering.
- **Why rejected:** it has the same collision with the orphan range after about 60 days.

### Alternative C: Identity columns on the three tables

- **How it would work:** make the id columns `GENERATED ... AS IDENTITY`, so any writer gets ids by default.
- **Why it is attractive:** every writer would get safe ids, not only `place_order`. This is the closest rival.
- **Why rejected:** it changes the existing table definitions more than the contract needs, and it would need the same starting offset. Standalone sequences leave the tables as they are.

## Consequences

- **What this buys:** no duplicate ids under 400 simultaneous buyers, and no collision with the orphan rows.
- **What this costs:** a refused or rolled-back call still uses up a sequence value, so order ids will have gaps, and numbering jumps from 659,384 to 999,863. After a fresh load from the CSV files the sequences must be repositioned by running `sql/solution/01_sequences_and_audit_link.sql` again; it is safe to rerun, but only during setup or maintenance, because repositioning while orders are being placed could hand out an id that is already in use.
- **What it costs the client if I am wrong:** an auditor who expects consecutive order numbers will ask about the gaps. The money risk is low.
- **What would make me revisit this:** cleaning up the orphan items, after which the offset is no longer needed, or a second writer that inserts rows without going through `place_order`, in which case identity columns become worth it.

## What this survives

- **Verified:** the first order created in the refusal checks received id 999,863, one above the highest orphan id. The 400-buyer test created 50 orders without a duplicate-key error, which a repeated id would have caused (`results/race_test/`).
- **Not verified:** a database restored from a backup, and a second writer inserting directly.
