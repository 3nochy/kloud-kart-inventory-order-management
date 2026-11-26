-- monday_report_naive.sql
-- Purpose : measure the "before" shape of the Monday report: one correlated subquery per
--           figure, re-run for every customer. This is the usual way such a report is
--           written, and the baseline the fast version is compared against.
-- Input   : freshly loaded database, before any index exists.
-- Output  : an EXPLAIN ANALYZE plan with timing; no report rows are printed.
-- Safety  : read-only. Limited to 500 customers with a 5-minute cap, because the full run
--           may not finish. The full-run time is an estimate, not a measurement:
--           40,420 customers / 500 = 80.84, so multiply the measured time by about 81.
-- Note    : this version covers only total spent, order count and trailing-12-month spend.
--           The real report also needs monthly columns, a running total and a ranking,
--           so the estimate is a lower bound.
-- Rules   : same counting rules as sql/solution/03_monday_report.sql (completed and
--           shipped orders, as-of date 2026-11-23), written out in full on purpose.

\timing on
SET statement_timeout = '300s';

EXPLAIN (ANALYZE, BUFFERS)
WITH report_window AS (
    SELECT timestamp '2026-11-24 00:00' AS end_exclusive,
           timestamp '2025-12-01 00:00' AS window_start
)
SELECT customers.customer_id,
       (SELECT coalesce(sum(customer_orders.total_amount), 0)
        FROM orders AS customer_orders
        WHERE customer_orders.customer_id = customers.customer_id
          AND lower(trim(customer_orders.status)) IN ('complete', 'completed', 'shipped')
          AND customer_orders.order_date < (SELECT end_exclusive FROM report_window)
       ) AS total_spent,
       (SELECT count(*)
        FROM orders AS customer_orders
        WHERE customer_orders.customer_id = customers.customer_id
          AND lower(trim(customer_orders.status)) IN ('complete', 'completed', 'shipped')
          AND customer_orders.order_date < (SELECT end_exclusive FROM report_window)
       ) AS order_count,
       (SELECT coalesce(sum(customer_orders.total_amount), 0)
        FROM orders AS customer_orders
        WHERE customer_orders.customer_id = customers.customer_id
          AND lower(trim(customer_orders.status)) IN ('complete', 'completed', 'shipped')
          AND customer_orders.order_date >= (SELECT window_start FROM report_window)
          AND customer_orders.order_date < (SELECT end_exclusive FROM report_window)
       ) AS spend_trailing_12_months
FROM customers
ORDER BY customers.customer_id
LIMIT 500;
