# ADR-009: Prioritize physical stock counts instead of auto-correcting

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

The diagnosis found 144 products where `stock_quantity` differs from the net inventory
log, including 87 with no likely explanation. The supplied data does not identify which
number is true, so updating one side to match the other could make a bad count look
consistent without making it correct.

## Decision

Create `inventory_reconciliation_queue`, which lists products whose current counter differs
from logged net movement. Rank the list by the absolute unit difference times the current
product price, then by unit difference. Include both numbers, the gap, movement count, and
last movement date. Use it to direct physical counts; never update stock from this view.

Add `CHECK (stock_quantity >= 0) NOT VALID`. This leaves the 14 existing negative-stock
products untouched while rejecting negative quantities on new or updated product rows.
Existing negative rows must be physically counted and corrected before unrelated edits to
those rows can pass the check.

## Alternatives considered

### Set every counter equal to the sum of the log

- **Why attractive:** it would make the diagnosis show no differences.
- **Why rejected:** the log contains questionable recount entries and has no proven opening
  balance for every product. Matching the two would not prove the shelf quantity.

### Leave the findings as a one-time diagnosis

- **Why attractive:** it avoids changing the schema or adding a daily query.
- **Why rejected:** operations would have no prioritized list to take to the stock room.
  The queue turns an aggregate finding into an actionable count list.

## Consequences

- **What this buys:** count work can start with the largest approximate value exposure.
- **What this costs:** current product price is only an estimate of value at risk, not
  accounting loss. The log/counter gap is a review signal, not proof of which number is
  correct.
- **What it costs Nana if the check is too strict:** updates to legacy negative rows will
  fail until those rows are corrected. The exception is intentional so the old bad data
  cannot spread into fresh writes.

## What this survives

- **Implemented:** the view and `NOT VALID` check are in
  `sql/solution/06_constraints_and_reconciliation.sql`.
- **Verified:** after a clean reload, the queue contained 144 products and the priority
  numbers were consecutive
  (`results/diagnosis/reconciliation_queue_checks_fresh_load.txt`). The queue is not a
  substitute for physical counts.
