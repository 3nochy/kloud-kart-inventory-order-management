# Memo to Nana Adjei

**From:** Enoch Kumi Asamoah

**Date:** 27 November 2026

**Subject:** Inventory accuracy and Monday reporting

## What I found

The stock counter and movement log disagree for 144 products; 14 products have negative
stock. I also found 2,426 orders whose header totals differ from their item lines, with a
gross difference of about ₵5.21 million. The extract has missing order/customer links,
duplicate customer records, and category assignments that cannot be reached through the
normal tree. The data does not prove which side is right for many of these records.

## What I built

| What you asked for | Status | Evidence |
|---|---|---|
| Stop two buyers taking the same last unit | Passed after a clean reload: 25/25 last-unit rounds succeeded; the 400-buyer run sold 50 units, refused 350, and had no errors. | [Fresh-load race test](../results/race_test/race_test_fresh_load.txt) |
| Monday customer-spending report | Passed all 13 fresh-load checks; all 40,420 customers returned in about 0.53 seconds. Running balances are available in a separate order-level view. | [Fresh-load report checks](../results/performance/monday_report_checks_fresh_load.txt), [fresh-load timing](../results/performance/monday_report_timing_fresh_load.txt) |
| Low-stock view through nested categories | Passed after a clean reload. The tree has no fixed depth limit; the latest run took about 0.63 seconds. Five units is only a sample threshold. | [Fresh-load category timing](../results/performance/category_rollup_timing_fresh_load.txt) |
| Record stock movements | Passed after a clean reload. Sales, restocks, returns, damage, counts, corrections, and direct quantity updates are logged. | [Fresh-load movement checks](../results/race_test/stock_movement_checks_fresh_load.txt) |

I also added a count queue that ranks the 144 stock/log disagreements by estimated value
so your team can decide which products to count first. It does not change quantities.
The clean-load check again found 144 products in that queue: [fresh-load queue output](../results/diagnosis/reconciliation_queue_checks_fresh_load.txt).

## What I recommend

Physically count the 87 products whose differences have no likely explanation. Set real
reorder levels for products, connect cancellations to return movements, and give the
application a trusted staff identity for the movement record. Do not automatically replace
the stock counter with the log total.

## What I could not stand behind

I cannot confirm the true historical shelf quantities, explain every order-total
difference, or guarantee these local timings during a real networked flash sale. The audit
record identifies the PostgreSQL login, which may be shared, and a database owner can
change or delete audit rows. The saved race test is a lab result, not a production traffic
guarantee.
