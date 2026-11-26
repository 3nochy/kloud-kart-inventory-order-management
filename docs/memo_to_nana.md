# Memo to Nana Adjei

**From:** Enoch Kumi Asamoah

**Date:** 26 November 2026

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
| Stop two buyers taking the same last unit | Done in the lab; run 5 passed. The 400-buyer test sold 50 units, refused 350, and had no errors. | [Race test run 5](../results/race_test/race_test_run_5.txt) |
| Monday customer-spending report | Done. All 13 checks passed; all 40,420 customers returned in about 0.56 seconds. Running balances are available in a separate order-level view. | [Report checks](../results/performance/monday_report_checks.txt), [timing](../results/performance/monday_report_after_indexes.txt) |
| Low-stock view through nested categories | Done. The tree has no fixed depth limit; the latest run took about 0.61 seconds. Five units is only a sample threshold. | [Category timing](../results/performance/category_rollup_after_indexes.txt) |
| Record stock movements | Done for changes made after installation. Sales, restocks, returns, damage, counts, corrections, and direct quantity updates are logged. | [Movement checks](../results/race_test/stock_movement_checks.txt) |

I also added a count queue that ranks the 144 stock/log disagreements by estimated value
so your team can decide which products to count first. It does not change quantities.

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
