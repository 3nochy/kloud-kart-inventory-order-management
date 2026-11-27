# Data diagnosis: Kloud Kart

**Scope:** read-only checks of the supplied extract, run with the scripts in `sql/diagnosis/`.
Every figure below comes from the saved outputs in `results/diagnosis/`. The extract has
total order value of ₵487,063,959.81 across 159,384 orders. These checks identify the
problems measured by the scripts; they do not prove which side of a disagreement is true.

## Ranking (by cost to a number Nana uses, not by row count)

| # | Fault | Size | Why it ranks here |
|---|-------|------|-------------------|
| 1 | Stock counter disagrees with the stock log | 144 products | Feeds Nana's main complaint; `place_order` trusts the counter |
| 2 | Order status written 15 ways | 159,384 orders | A filter on the exact word sees 19.8% of completed orders |
| 3 | Order total disagrees with its items | 2,426 orders, ₵5.21M gross | Decides what "total spent" means on the Monday report |
| 4 | Categories unreachable, products uncategorised | 37 products | Low-stock rollup would hide them |
| 5 | The same customer stored more than once | 535 extra rows | Customer count and spend per customer are off |
| 6 | Rows pointing at things that do not exist | 692 items, 210 orders, 120 log rows | Silently dropped by any join |
| 7 | Rows dated after the diagnosis-time database clock | 16 orders, 33 log rows | Forces a choice of "as of" date |

## 1. Stock counter disagrees with the stock log
- **What is wrong:** no constraint ties `products.stock_quantity` to the sum of `inventory_log.change_qty`. 144 of 4,023 products disagree. The counter is below the log for 122 and above for 22; net -2,375 units (₵-3,656,269.44), gross 2,553 units (₵3,865,699.34). 14 products have negative stock (-27 units, ₵-20,627.76).
- **How found:** `sql/diagnosis/02_fault_diagnosis.sql`, section E (view `stock_vs_log`).
- **What it costs:** Nana cannot trust stock counts, and `place_order` refuses or allows sales based on the counter. For 13 of the 14 negative products the log agrees with the counter, which is evidence of a stock deficit; a physical count is still needed to confirm the real quantity.
- **What explains it:** for 39 products the gap equals minus the units on log rows noted "recount, not applied" (all 40 such rows are `correction` rows): the log recorded a recount the counter never received. 87 products have no candidate explanation.
- **Fix and its risk:** do not auto-correct. Use `inventory_reconciliation_queue` to prioritize a physical count of the 87 unexplained products; the view does not choose whether the counter or log is right. A `NOT VALID` check now blocks new negative stock while leaving legacy rows for count and correction. Until those rows are corrected, other updates to a negative-stock product may be rejected by the check.
- **Cannot verify:** which side is right for the 87.

## 2. Order status written 15 ways
- **What is wrong:** `orders.status` is free text. 15 spellings mean five things: completed, pending, shipped, refunded, cancelled.
- **How found:** `GROUP BY status` in `01_integrity_checks.sql`; collapsed in `02_fault_diagnosis.sql`, section A.
- **What it costs:** a report filtering `status = 'completed'` sees 22,091 of 111,351 completed orders (19.8%). Completed orders are worth ₵339,609,366.03.
- **Current treatment:** the report maps known spellings to their meaning when reading; it does not rewrite the stored history. A canonical write rule and a status constraint still need a business decision. Risk: reading "complete" and "completed" as the same thing is an assumption; nothing in the data contradicts it.

## 3. Order total disagrees with its items
- **What is wrong:** `orders.total_amount` is a stored copy of what the items add up to, with nothing forcing agreement. 2,426 orders (1.5%) disagree; gross gap ₵5,214,733.92, net ₵-3,477,551.62.
- **How found:** `01_integrity_checks.sql`; causes classified in `03_fault_overlaps.sql` (one cause per order, in priority order).

| Cause | Orders | Gross gap | Which side looks wrong |
|-------|--------|-----------|------------------------|
| Quantity typo (999 or 9999) | 6 | ₵3,059,982.98 | Items |
| NULL unit_price (148 rows) | 146 | ₵323,142.93 | Items |
| Same line stored twice | 526 | ₵882,144.66 | Items |
| Unexplained | 1,748 | ₵949,463.35 | Unknown |

- **What it costs:** summing the item lines for "total spent" would add about ₵3.06M of spend that never happened (0.63% of order value), from 6 orders. One order alone (583621: total ₵87.35, quantity 9999) is worth ₵873k, enough to put a customer in the top 100.
- **The unexplained group:** 1,605 of the 1,748 round to four ratios of total to items (0.75, 0.90, 1.10, 1.25); 1,469 are exact to four decimals. A rule produced these totals, probably a price adjustment that was never recorded, so this may be legitimate. 25 orders have item totals of zero (header ₵14,320.30), and about 118 are not characterised at all.
- **Fix and its risk:** use `total_amount` as the source of truth for spend. Delete nothing. Risk: for the 1,748, the header may be the wrong side.
- **Cannot verify:** what produced the four ratios.

## 4. Categories unreachable, products uncategorised
- **What is wrong:** `categories.parent_id` has no foreign key. Categories 9001 and 9002 are each other's parent (a cycle) and 9003 points at 8999, which does not exist. Six products (440 units) sit under them. A further 31 products with 3,112 units (₵3,281,371.20 of stock) have no category.
- **How found:** `02_fault_diagnosis.sql`, section F (walk down from the roots, and walk up with a depth cap).
- **What it costs:** a low-stock rollup starting at the roots never sees these 37 products.
- **Fix and its risk:** the recursive rollup shows cyclic/unreachable and uncategorised buckets so product stock does not disappear. The correct parent for 9001-9003 is a business decision, so it is left alone.

## 5. The same customer stored more than once
- **What is wrong:** `customers.email` is not unique. 533 emails appear on 1,068 rows (535 extra), and in all 533 groups the names are identical.
- **How found:** `02_fault_diagnosis.sql`, section C.
- **What it costs:** the customer count is overstated by 535 (1.3%) and 502 people have spend split across rows. Merging them changes the top 100 by one customer.
- **Fix and its risk:** not merged in the report. Merging is a business decision, and two people sharing an email is possible, though identical names make it unlikely.

## 6. Rows pointing at things that do not exist
- **What is wrong:** the supplied schema has no foreign keys. 692 item rows (689 missing orders, ₵826,327.80), 210 orders (190 missing customers, ₵665,180.61, 0.14% of order value) and 120 log rows (111 missing products, -120 units).
- **How found:** `01_integrity_checks.sql`; `02_fault_diagnosis.sql`, section D.
- **Pattern:** the missing ids sit far outside the real ranges (orders 900101-999862 against real 500001-659384; customers 999007-999997 against 100001-140420; products 99011-99999 against 5001-9023), so these look like references that never existed, not deletions.
- **What it costs:** small in value, but any join drops them without a warning.
- **Current treatment:** solution script 06 adds a `NOT VALID` customer foreign key. It leaves the historical orphan orders untouched, while preventing new orders from pointing to missing customers and blocking deletion of customers that have orders. Other historical orphan links remain for a separate cleanup decision.

## 7. Rows dated after the diagnosis-time database clock
- At the time this diagnosis ran, 16 orders (₵41,348.75) and 33 log `sale` rows (-59 units) were dated after the database clock. This finding is time-sensitive: as the clock advances, some of those dates may no longer be in the future.
- **Report decision:** the initial report cutoff is the fixed baseline Monday, 2026-11-23. It excludes later-dated orders even after those dates have passed; advance the cutoff when producing a later Monday report.

## Looks wrong but is not
- `order_items.unit_price` differs from today's price on 4,264 rows: it is the price at the time of sale.
- All 90 `stock_take` log rows have change 0: a count that confirmed the stock.
- `inventory_log.reason` has 6 clean values and no spelling variants.
- 841 products share a name and 616 orders repeat a product line: not judged.

## What I could not stand behind
1. Which side is right for the 87 products with no explanation.
2. What produced the four exact ratios in 1,605 totals.
3. The 25 orders with item totals of zero, and the 118 uncharacterised mismatches.
4. Whether historical sales were logged at placement or at completion: the original log rows have no reliable `order_id` link, so timing cannot be proven from this extract. New sale movements are linked to their orders by the solution.
