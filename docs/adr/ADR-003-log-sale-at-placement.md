# ADR-003: Log the sale, and set the order to pending, when the order is placed

- **Status:** Proposed
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

The contract requires a stock movement for every successful sale, and Test 4 checks that the log holds at least one row per sale made under contention. In the existing data the log appears to record sales at completion or shipping, not at placement: about 262,100 item lines sit on completed or shipped orders, against 261,968 `sale` rows for products that exist (262,088 minus 120 rows for products that do not exist). This cannot be proven, because `inventory_log` has no order id. `orders.status` is free text with 15 spellings that mean five things, and nothing in the brief says what a new order's status should be.

## Decision

A new order is written with status `'pending'`, and a `'sale'` row with a negative `change_qty` is written to `inventory_log` in the same transaction.

## Alternatives considered

### Alternative A: Log the sale only when the order completes

- **How it would work:** the stock counter and the log change when an order moves to completed or shipped.
- **Why it is attractive:** it matches what the existing data seems to do.
- **Why rejected:** between placement and completion the last unit could be sold again, which is the overselling problem. If only the counter dropped at placement and the log waited, the two would disagree for every pending order, the same relationship that already disagrees for 144 products.

### Alternative B: A reservation reason at placement and a sale reason at completion

- **How it would work:** write a `'reservation'` row at placement, convert it to `'sale'` on completion, and write a `'return'` row on cancellation.
- **Why it is attractive:** each reason keeps one meaning, and `'sale'` would stay consistent with the existing data.
- **Why rejected:** it needs a completion and cancellation flow that does not exist in this lab, and the data gives no sign of how Kloud Kart moves an order from pending to completed.

## Consequences

- **What this buys:** the stock counter and the log change together for every sale placed through the function, and no sale exists without a log row.
- **What this costs:** a cancelled or refunded order does not put its units back automatically. An operator can now record a `return` movement with `record_stock_movement`, but no cancellation workflow calls it or changes the order status. The log will contain `sale` rows for orders that are later cancelled. In the new rows `sale` means "placed", while in the existing rows it seems to mean "completed or shipped", so a report that counts sales from the log mixes two meanings.
- **What it costs the client if I am wrong:** products could show out of stock while units are on the shelf, and sales figures built from the log could count orders that were never fulfilled.
- **What would make me revisit this:** building the completion and cancellation flow (cancellation should write a `return` row linked to the order), or Nana confirming that stock should be logged at shipping.

## What this survives

- **Verified before the trigger-based audit change:** in the saved refusal checks the sale log row was linked to its order, and the race test recorded one movement per sale.
- **Verified after the trigger-based audit change:** run 4 of `race_test.py` recorded five movements for five successful sales; the rollback-safe place-order checks also showed one linked `sale` row. **Not verified:** cancellations/refunds and whether `'pending'` is the right starting status for Kloud Kart. This remains an assumption, which is why the status above is Proposed.
