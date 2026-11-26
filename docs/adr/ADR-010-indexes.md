# ADR-010: Add indexes for recurring category, report, and audit lookups

- **Status:** Accepted after post-index measurements
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

The source tables have only primary-key indexes. The recursive category report follows
`categories.parent_id` and joins products by category. Auditors look up movements by
product or order. The per-customer running-total query filters orders by customer and
orders them by date. The materialized Monday summary itself already has indexes created
with the report.

## Decision

Add indexes on category parent, product category, inventory-log product/date and non-NULL
order id, and a partial order index for statuses included in the report. Run `ANALYZE`
after creating them. The post-index plan uses the order index for a one-customer running
total query.

## Alternatives considered

### Add broad indexes to every join and filter column

- **Why attractive:** might help queries that have not been measured yet.
- **Why rejected:** each index uses disk and adds work to writes. Only recurring query
  paths identified by the project are indexed.

### Rely only on the report's materialized-view indexes

- **Why attractive:** report reads are already fast and the full output took less than a
  second.
- **Why rejected:** it does not support the category tree, audit links, or a single
  customer's order-level running total on source tables.

## Consequences

- **What this buys:** source lookups have indexes aligned with the category, audit, and
  customer/date access paths.
- **What this costs:** storage and extra write work, especially on the inventory log.
  Index creation should be scheduled for setup or a maintenance window.
- **Measured effect:** the single-customer running-total query went from about 14 ms to
  0.2 ms and the plan changed from a parallel orders scan to an index-only scan. The full
  report was about 0.63 s before and 0.56 s after; that smaller difference can vary with
  cache state. The category rollup was about 0.76 s before and 0.61 s after.
- **What would make me remove or change an index:** `EXPLAIN (ANALYZE, BUFFERS)` showing
  the planner never uses it, or measured write overhead that outweighs lookup savings.

## What this survives

- **Implemented:** definitions are in `sql/solution/07_indexes.sql`.
- **Verified:** post-index plans and timings are saved in
  `results/performance/monday_report_after_indexes.txt` and
  `results/performance/category_rollup_after_indexes.txt`.
