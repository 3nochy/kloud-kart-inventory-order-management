# ADR-006: Roll up low stock through the category tree

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

Nana needs a quick view of low stock across nested categories, and marketing can add
categories at any depth. The existing schema has no reorder threshold. It also contains
categories in a cycle, a category whose parent is missing, and products with no category.

## Decision

Provide `low_stock_by_category(threshold)` as a read-only SQL function. It follows the
category tree recursively without a fixed depth limit and returns each category's own
products plus all products assigned below it. The default threshold is five units and can
be changed on each call. A product is low stock when its known quantity is at or below
that threshold. A NULL stock count is reported as unknown, not as zero.

Products in rooted category trees appear in their category rows. Products assigned to
categories that cannot be reached from a root (including cycles) appear in a separate
bucket. Missing category references and products with no category each get their own
bucket, so the report does not silently drop them.

## Alternatives considered

### A single fixed threshold in the SQL

- **Why attractive:** simplest to read and run.
- **Why rejected:** different products may need different reorder points, and the brief
  does not give a business threshold. A function parameter lets Nana change the report
  without editing the query.

### Add a reorder-point column to products

- **Why attractive:** each product can have its own threshold.
- **Why deferred:** the business has not provided reorder points. Adding a default now
  would make an unverified policy look like a measured fact. The function can later be
  changed to read a per-product value once operations supplies it.

## Consequences

- **What this buys:** category totals work at any depth, and anomalous/unattached stock
  stays visible.
- **What this costs:** five units is only a useful default for the lab, not a confirmed
  operating rule. Cycle members are grouped as unattached because the data cannot tell us
  which one should be their parent.
- **What it costs Nana if the threshold is wrong:** a product may be flagged too early or
  too late. The threshold can be passed explicitly, and actual reorder points should come
  from operations before this becomes a daily control.

## What this survives

- **Implemented:** `sql/solution/04_category_rollup.sql` defines the recursive function
  and separate buckets for cyclic/unreachable, missing, and uncategorised assignments.
- **Verified:** 94 rows returned in the loaded database. Execution time was about 0.76
  seconds before source indexes and 0.61 seconds afterward
  (`results/performance/category_rollup_after.txt` and
  `results/performance/category_rollup_after_indexes.txt`).
- **Not verified:** the business appropriateness of a five-unit threshold.
