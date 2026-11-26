-- monday_report_checks.sql
-- Purpose : prove the Monday report agrees with the raw orders.
-- Output  : one row per check with expected, actual and passed; every row must be true.
-- Safety  : refreshes report summaries and creates temporary objects in a transaction
--           that is rolled back; persistent report state remains unchanged.
-- Note    : the counting rules are written out again below, on purpose, so the report is
--           checked against an independent restatement instead of against itself.
-- Status  : the supplied data has 15 spellings across five meanings. Spend deliberately
--           includes normalized complete/completed/shipped spellings only. This expected
--           allow-list is independent of report_orders; a symmetric difference check
--           below fails if either rule changes without the other.

\set ON_ERROR_STOP on
BEGIN;

CREATE OR REPLACE TEMP VIEW expected_orders AS
SELECT orders.order_id,
       orders.customer_id,
       orders.order_date,
       orders.total_amount
FROM orders
WHERE lower(trim(orders.status)) IN ('complete', 'completed', 'shipped')
  AND orders.order_date < (SELECT report_settings.as_of_date + 1 FROM report_settings)
  AND orders.total_amount IS NOT NULL
  AND EXISTS (SELECT 1
              FROM customers
              WHERE customers.customer_id = orders.customer_id);

CREATE OR REPLACE TEMP VIEW check_window AS
SELECT date_trunc('month', report_settings.as_of_date::timestamp) - interval '11 months'
           AS oldest_month_start,
       date_trunc('month', report_settings.as_of_date::timestamp)
           AS newest_month_start
FROM report_settings;

CREATE OR REPLACE TEMP VIEW final_running_total AS
SELECT DISTINCT ON (customer_running_total.customer_id)
       customer_running_total.customer_id,
       customer_running_total.running_total
FROM customer_running_total
ORDER BY customer_running_total.customer_id,
         customer_running_total.order_date DESC,
         customer_running_total.order_id DESC;

-- Exercise the supported refresh path using the current cutoff. The final rollback below
-- restores the prior report settings and materialized-view contents.
SELECT report_settings.as_of_date AS report_as_of_date
FROM report_settings
\gset
CALL refresh_monday_report(:'report_as_of_date'::date);

CREATE TEMP TABLE monday_report_check_results ON COMMIT DROP AS
WITH results AS (
    SELECT 'totals: one row per customer' AS check_name,
           (SELECT count(*) FROM customers)::numeric             AS expected,
           (SELECT count(*) FROM customer_spend_totals)::numeric AS actual

    UNION ALL
    SELECT 'totals: total spent equals raw orders',
           (SELECT coalesce(sum(expected_orders.total_amount), 0) FROM expected_orders),
           (SELECT sum(customer_spend_totals.total_spent) FROM customer_spend_totals)

    UNION ALL
    SELECT 'totals: order count equals raw orders',
           (SELECT count(*) FROM expected_orders)::numeric,
           (SELECT sum(customer_spend_totals.order_count) FROM customer_spend_totals)::numeric

    UNION ALL
    SELECT 'orders: report rows match independent status allow-list',
           0::numeric,
           (SELECT count(*)
            FROM (
                (SELECT report_orders.order_id,
                        report_orders.customer_id,
                        report_orders.order_date,
                        report_orders.total_amount
                 FROM report_orders
                 EXCEPT
                 SELECT expected_orders.order_id,
                        expected_orders.customer_id,
                        expected_orders.order_date,
                        expected_orders.total_amount
                 FROM expected_orders)
                UNION ALL
                (SELECT expected_orders.order_id,
                        expected_orders.customer_id,
                        expected_orders.order_date,
                        expected_orders.total_amount
                 FROM expected_orders
                 EXCEPT
                 SELECT report_orders.order_id,
                        report_orders.customer_id,
                        report_orders.order_date,
                        report_orders.total_amount
                 FROM report_orders)
            ) AS differing_orders)::numeric

    UNION ALL
    SELECT 'monthly: 12 rows per customer',
           (SELECT count(*) * 12 FROM customers)::numeric,
           (SELECT count(*) FROM customer_monthly_spend)::numeric

    UNION ALL
    SELECT 'monthly: spend equals raw orders inside the window',
           (SELECT coalesce(sum(expected_orders.total_amount), 0)
            FROM expected_orders
            CROSS JOIN check_window
            WHERE expected_orders.order_date >= check_window.oldest_month_start),
           (SELECT sum(customer_monthly_spend.spend) FROM customer_monthly_spend)

    UNION ALL
    SELECT 'wide report: one row per customer',
           (SELECT count(*) FROM customers)::numeric,
           (SELECT count(*) FROM monday_report)::numeric

    UNION ALL
    SELECT 'wide report: newest month column equals raw spend in that month',
           (SELECT coalesce(sum(expected_orders.total_amount), 0)
            FROM expected_orders
            CROSS JOIN check_window
            WHERE expected_orders.order_date >= check_window.newest_month_start),
           (SELECT sum(monday_report.month_12_spend) FROM monday_report)

    UNION ALL
    SELECT 'wide report: oldest month column equals raw spend in that month',
           (SELECT coalesce(sum(expected_orders.total_amount), 0)
            FROM expected_orders
            CROSS JOIN check_window
            WHERE expected_orders.order_date >= check_window.oldest_month_start
              AND expected_orders.order_date < check_window.oldest_month_start + interval '1 month'),
           (SELECT sum(monday_report.month_01_spend) FROM monday_report)

    UNION ALL
    SELECT 'running total: customers whose last value differs from total spent',
           0::numeric,
           (SELECT count(*)
            FROM final_running_total
            JOIN customer_spend_totals
              ON customer_spend_totals.customer_id = final_running_total.customer_id
            WHERE final_running_total.running_total <> customer_spend_totals.total_spent)::numeric

    UNION ALL
    SELECT 'ranking: every customer has a distinct rank',
           (SELECT count(*) FROM customers)::numeric,
           (SELECT count(DISTINCT customer_spend_totals.spend_rank) FROM customer_spend_totals)::numeric

    UNION ALL
    SELECT 'top 100: exactly 100 rows',
           100::numeric,
           (SELECT count(*) FROM monday_top_100)::numeric

    UNION ALL
    SELECT 'top 100: customers outside it who spent more than its last place',
           0::numeric,
           (SELECT count(*)
            FROM customer_spend_totals
            WHERE customer_spend_totals.spend_rank > 100
              AND customer_spend_totals.total_spent >
                  (SELECT min(monday_top_100.total_spent) FROM monday_top_100))::numeric
)
SELECT results.check_name,
       results.expected,
       results.actual,
       results.expected = results.actual AS passed
FROM results;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM monday_report_check_results
        WHERE passed IS NOT TRUE
    ) THEN
        RAISE EXCEPTION 'One or more Monday report checks failed';
    END IF;
END;
$$;

SELECT check_name, expected, actual, passed
FROM monday_report_check_results
ORDER BY check_name;

ROLLBACK;
