-- 03_monday_report.sql
-- Purpose : the Monday customer-spending report: total spent, order count, monthly spend
--           for the trailing 12 months, a running total per customer, and a top-100 ranking.
-- Input   : freshly loaded database, after 01_sequences_and_audit_link.sql.
-- Output  : report_settings (table); report_as_of, report_orders, customer_running_total,
--           monday_report, monday_top_100 (views); customer_monthly_spend and
--           customer_spend_totals (materialized views).
-- Safety  : rerunnable. Changes no existing table; the first draft of this report, if
--           present, is removed (see the first section).
-- Rules   : decisions are recorded in docs/adr/ once the report has been measured.
--           * Spend counts orders whose status means completed or shipped.
--           * "Total spent" is orders.total_amount, the figure charged at checkout.
--           * The report is as of the date in report_settings, not the clock, so the same
--             data always gives the same figures. The data holds 16 orders dated after
--             2026-11-23; they are excluded until the date is moved.
--           * Duplicate customers (same email and name) are not merged.
-- Refresh : figures are as of the last refresh. To refresh without blocking readers:
--             REFRESH MATERIALIZED VIEW CONCURRENTLY customer_spend_totals;
--             REFRESH MATERIALIZED VIEW CONCURRENTLY customer_monthly_spend;
--           The two refreshes are separate, so a read between them can mix old and new.

-- ---------------------------------------------------------------------------
-- Clean up, in dependency order, so the script can be rerun
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS monday_top_100;
DROP VIEW IF EXISTS monday_report;
DROP MATERIALIZED VIEW IF EXISTS monday_customer_report;   -- first draft of this report
DROP MATERIALIZED VIEW IF EXISTS customer_spend_totals;
DROP MATERIALIZED VIEW IF EXISTS customer_monthly_spend;
DROP VIEW IF EXISTS customer_running_total;
DROP VIEW IF EXISTS report_orders;
DROP VIEW IF EXISTS report_as_of;

-- ---------------------------------------------------------------------------
-- The as-of date
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS report_settings (
    as_of_date date NOT NULL
);

-- At most one row: the report reads a single as-of date.
CREATE UNIQUE INDEX IF NOT EXISTS report_settings_single_row
    ON report_settings ((true));

INSERT INTO report_settings (as_of_date)
SELECT date '2026-11-23'
WHERE NOT EXISTS (SELECT 1 FROM report_settings);

-- end_exclusive is the first instant after the as-of day.
-- window_start is the first day of the oldest of the 12 months; the newest month is the
-- as-of date's own month, so it is partial.
CREATE VIEW report_as_of AS
SELECT report_settings.as_of_date,
       report_settings.as_of_date + 1 AS end_exclusive,
       date_trunc('month', report_settings.as_of_date::timestamp) - interval '11 months'
           AS window_start
FROM report_settings;

-- ---------------------------------------------------------------------------
-- Orders that count towards spend
-- ---------------------------------------------------------------------------
-- Fifteen spellings of status collapse to the meanings 'completed' and 'shipped'.
-- Pending, cancelled and refunded orders are excluded: the money is not kept or not final.
CREATE VIEW report_orders AS
SELECT orders.order_id,
       orders.customer_id,
       orders.order_date,
       orders.total_amount
FROM orders
JOIN customers
  ON customers.customer_id = orders.customer_id
CROSS JOIN report_as_of
WHERE lower(trim(orders.status)) IN ('complete', 'completed', 'shipped')
  AND orders.order_date < report_as_of.end_exclusive
  AND orders.total_amount IS NOT NULL;

-- Running total per customer, in date order. order_id breaks ties between orders at the
-- same instant, and ROWS (not the default RANGE frame) counts those orders one by one.
CREATE VIEW customer_running_total AS
SELECT report_orders.customer_id,
       report_orders.order_id,
       report_orders.order_date,
       report_orders.total_amount,
       sum(report_orders.total_amount) OVER (
           PARTITION BY report_orders.customer_id
           ORDER BY report_orders.order_date, report_orders.order_id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_total
FROM report_orders;

-- ---------------------------------------------------------------------------
-- Monthly spend: one row per customer per month of the window, zero when no orders
-- ---------------------------------------------------------------------------
-- month_number 1 is the oldest month and 12 is the as-of date's month.
CREATE MATERIALIZED VIEW customer_monthly_spend AS
WITH window_months AS (
    SELECT month_series.month_start,
           row_number() OVER (ORDER BY month_series.month_start) AS month_number
    FROM report_as_of
    CROSS JOIN LATERAL generate_series(
        report_as_of.window_start,
        report_as_of.window_start + interval '11 months',
        interval '1 month'
    ) AS month_series (month_start)
),
spend_per_customer_month AS (
    SELECT report_orders.customer_id,
           date_trunc('month', report_orders.order_date) AS month_start,
           sum(report_orders.total_amount)               AS spend
    FROM report_orders
    CROSS JOIN report_as_of
    WHERE report_orders.order_date >= report_as_of.window_start
    GROUP BY report_orders.customer_id,
             date_trunc('month', report_orders.order_date)
)
SELECT customers.customer_id,
       window_months.month_start,
       window_months.month_number,
       coalesce(spend_per_customer_month.spend, 0) AS spend
FROM customers
CROSS JOIN window_months
LEFT JOIN spend_per_customer_month
       ON spend_per_customer_month.customer_id = customers.customer_id
      AND spend_per_customer_month.month_start = window_months.month_start;

-- Required by REFRESH ... CONCURRENTLY.
CREATE UNIQUE INDEX customer_monthly_spend_customer_month_idx
    ON customer_monthly_spend (customer_id, month_start);

-- ---------------------------------------------------------------------------
-- Totals and ranking: one row per customer
-- ---------------------------------------------------------------------------
-- Ties are broken by customer_id, so the top 100 is always exactly 100 rows. Which of two
-- tied customers takes the last place is arbitrary but stable.
CREATE MATERIALIZED VIEW customer_spend_totals AS
WITH spend_per_customer AS (
    SELECT report_orders.customer_id,
           sum(report_orders.total_amount) AS total_spent,
           count(*)                        AS order_count
    FROM report_orders
    GROUP BY report_orders.customer_id
)
SELECT customers.customer_id,
       customers.full_name,
       coalesce(spend_per_customer.total_spent, 0) AS total_spent,
       coalesce(spend_per_customer.order_count, 0) AS order_count,
       row_number() OVER (
           ORDER BY coalesce(spend_per_customer.total_spent, 0) DESC,
                    customers.customer_id
       ) AS spend_rank
FROM customers
LEFT JOIN spend_per_customer
       ON spend_per_customer.customer_id = customers.customer_id;

CREATE UNIQUE INDEX customer_spend_totals_customer_idx
    ON customer_spend_totals (customer_id);

CREATE INDEX customer_spend_totals_rank_idx
    ON customer_spend_totals (spend_rank);

ANALYZE customer_monthly_spend;
ANALYZE customer_spend_totals;

-- ---------------------------------------------------------------------------
-- The report as Adwoa reads it
-- ---------------------------------------------------------------------------
-- One row per customer, months laid out as columns (month_01 oldest, month_12 newest).
CREATE VIEW monday_report AS
SELECT customer_spend_totals.customer_id,
       customer_spend_totals.full_name,
       customer_spend_totals.total_spent,
       customer_spend_totals.order_count,
       customer_spend_totals.spend_rank,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 1)  AS month_01_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 2)  AS month_02_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 3)  AS month_03_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 4)  AS month_04_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 5)  AS month_05_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 6)  AS month_06_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 7)  AS month_07_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 8)  AS month_08_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 9)  AS month_09_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 10) AS month_10_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 11) AS month_11_spend,
       sum(customer_monthly_spend.spend) FILTER (WHERE customer_monthly_spend.month_number = 12) AS month_12_spend
FROM customer_spend_totals
JOIN customer_monthly_spend
  ON customer_monthly_spend.customer_id = customer_spend_totals.customer_id
GROUP BY customer_spend_totals.customer_id,
         customer_spend_totals.full_name,
         customer_spend_totals.total_spent,
         customer_spend_totals.order_count,
         customer_spend_totals.spend_rank;

CREATE VIEW monday_top_100 AS
SELECT monday_report.*
FROM monday_report
WHERE monday_report.spend_rank <= 100
ORDER BY monday_report.spend_rank;
