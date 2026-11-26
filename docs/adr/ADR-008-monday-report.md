# ADR-008: Build the Monday report from charged order totals

- **Status:** Accepted for this lab
- **Date:** 2026-11-26
- **Decision owner:** Enoch Kumi Asamoah

## Context

The report must include customer totals, order counts, twelve months of spend, running
totals, and a top-100 ranking. The source has 2,426 mismatched order headers, including
quantity outliers, missing item prices, duplicated lines, and unexplained gaps. Recomputing
spend from item lines would treat several known bad item records as real purchases.

## Decision

Use `orders.total_amount` as the amount spent because it is the value recorded on the order
header as charged at checkout. Count orders whose normalized status is `complete`,
`completed`, or `shipped`; leave pending, cancelled, and refunded orders out of spend. Keep
customers as stored: duplicate emails are not merged. Exclude orders without a matching
customer so every report row represents a known customer.

The report is anchored to `report_settings.as_of_date`, initially 2026-11-23, the last
non-future order date in the extract. Total spend and order count cover all included orders
through that date. Monthly columns cover the twelve calendar months ending in the as-of
month, which is partial. `customer_running_total` is a separate order-level view: it shows
the cumulative spend after each included order for each customer. The summary view remains
one row per customer.

Store the totals/rank and monthly values in materialized views so routine Monday reads do
not rescan the raw order table for every customer. `monday_top_100` uses the stored rank;
customer id breaks ties consistently. Refresh the materialized views after new data arrives.

## Alternatives considered

### Sum order item lines for spend

- **Why attractive:** item lines appear to provide a detail-level explanation of each
  order total.
- **Why rejected:** 6 quantity outliers would add about ₵3.06M of item value not supported
  by the header totals. Missing prices and repeated lines also make the item sum
  unreliable. The header may still be wrong for the 1,748 unexplained mismatches.

### Recalculate the complete report from raw orders on every read

- **Why attractive:** it always reflects the latest rows and needs no refresh step.
- **Why rejected:** the baseline ran for about 10.2 seconds while returning only 500
  customers and three measures. A linear extrapolation to 40,420 customers is roughly
  13.8 minutes, and it still omits monthly columns, ranking, and running totals. This is an
  estimate, not a full-run measurement.

### Merge duplicate customers by email

- **Why attractive:** 502 people's spend is split across duplicate rows, and merging moves
  one customer into the stored top 100.
- **Why rejected:** email is not proof of identity, and no trusted merge key is supplied.
  Merging could combine two real people or alter their histories irreversibly.

## Consequences

- **What this buys:** on the measured database, the full report read returned 40,420
  customers in about 0.56 seconds after adding source indexes; the top 100 took about
  0.008 seconds in that run. The monthly values and rankings are precomputed, so a normal
  read is quick.
- **What this costs:** figures are as of the last refresh, not live. The two materialized
  views refresh separately, so a read between refreshes can briefly combine snapshots.
  Rebuilding with the solution script drops and recreates report objects and should happen
  when readers are not using them.
- **What it costs Nana if the spend rule is wrong:** if the header amount is inaccurate,
  customer totals and rankings inherit that error. In particular, the source does not
  explain the ratios in many of the 1,748 unexplained mismatches.
- **What would make me revisit this:** an authoritative payment ledger, a confirmed
  cancellation/refund workflow, or customer identity data that supports safe merges.

## What this survives

- **Verified:** twelve independent checks passed in
  `results/performance/monday_report_checks.txt`. The full report timing and query plan are
  in `results/performance/monday_report_after_indexes.txt`.
- **Comparison limit:** the baseline is a 500-customer sample with fewer fields, while the
  optimized result times the top 100 and the complete report. The baseline full-run figure
  is estimated, not measured; the readings demonstrate the different query shapes and
  current response time, not an exact same-workload speedup ratio.
- **Not verified:** Monday refresh under concurrent business traffic, an authoritative
  source for refunds, and whether duplicate customers should ever be merged.
