-- 03_fault_overlaps.sql
-- Purpose : show how the faults found in 01 and 02 overlap, so the diagnosis can say which
--           explanation applies to which order instead of adding up counts that overlap.
-- Input   : freshly loaded Kloud Kart database.
-- Output  : aggregates only; no personal data is printed.
-- Safety  : read-only. Creates a temporary view that vanishes when the session ends.

\echo '--- A. NULL unit_price: whole orders or some lines?'
-- sum() skips NULLs: an order with only some NULL prices gets a silently low item total,
-- while an order with every price NULL gets a NULL item total.
WITH order_line_summary AS (
    SELECT order_items.order_id,
           count(*)                                               AS line_count,
           count(*) FILTER (WHERE order_items.unit_price IS NULL) AS null_price_lines,
           sum(order_items.quantity * order_items.unit_price)     AS items_total
    FROM order_items
    GROUP BY order_items.order_id
)
SELECT CASE
           WHEN order_line_summary.null_price_lines = 0                           THEN 'no null price'
           WHEN order_line_summary.null_price_lines = order_line_summary.line_count THEN 'every line null'
           ELSE 'some lines null'
       END AS null_price_pattern,
       count(*) AS order_count,
       count(*) FILTER (WHERE orders.total_amount
                              IS DISTINCT FROM order_line_summary.items_total) AS mismatched_orders
FROM orders
JOIN order_line_summary
  ON order_line_summary.order_id = orders.order_id
GROUP BY null_price_pattern
ORDER BY null_price_pattern;

-- One likely cause per mismatched order, checked in this priority order so no order is
-- counted twice: quantity typo, then NULL price, then a repeated line, then unexplained.
CREATE OR REPLACE TEMP VIEW mismatch_causes AS
WITH order_line_summary AS (
    SELECT order_items.order_id,
           sum(order_items.quantity * order_items.unit_price)     AS items_total,
           bool_or(order_items.quantity >= 100)                   AS has_quantity_outlier,
           count(*) FILTER (WHERE order_items.unit_price IS NULL) AS null_price_lines
    FROM order_items
    GROUP BY order_items.order_id
),
total_without_repeated_lines AS (
    SELECT distinct_lines.order_id,
           sum(distinct_lines.quantity * distinct_lines.unit_price) AS deduplicated_total
    FROM (SELECT DISTINCT order_items.order_id,
                          order_items.product_id,
                          order_items.quantity,
                          order_items.unit_price
          FROM order_items) AS distinct_lines
    GROUP BY distinct_lines.order_id
)
SELECT orders.order_id,
       orders.total_amount,
       order_line_summary.items_total,
       CASE
           WHEN order_line_summary.has_quantity_outlier
               THEN '1 quantity typo (100+)'
           WHEN order_line_summary.null_price_lines > 0
               THEN '2 null unit_price'
           WHEN total_without_repeated_lines.deduplicated_total = orders.total_amount
               THEN '3 repeated line counted twice'
           ELSE '4 unexplained'
       END AS likely_cause
FROM orders
JOIN order_line_summary
  ON order_line_summary.order_id = orders.order_id
JOIN total_without_repeated_lines
  ON total_without_repeated_lines.order_id = orders.order_id
WHERE orders.total_amount IS DISTINCT FROM order_line_summary.items_total;

\echo '--- B. mismatched orders by likely cause'
SELECT mismatch_causes.likely_cause,
       count(*)                                                        AS order_count,
       round(sum(mismatch_causes.total_amount
                 - mismatch_causes.items_total), 2)                    AS net_gap
FROM mismatch_causes
GROUP BY mismatch_causes.likely_cause
ORDER BY mismatch_causes.likely_cause;

\echo '--- C. the unexplained orders: how far is the total from the items?'
SELECT round((mismatch_causes.total_amount
              / nullif(mismatch_causes.items_total, 0)) * 20) / 20 AS total_to_items_ratio,
       count(*)                                                    AS order_count
FROM mismatch_causes
WHERE mismatch_causes.likely_cause = '4 unexplained'
GROUP BY total_to_items_ratio
ORDER BY order_count DESC
LIMIT 12;

\echo '--- D. which log reasons carry the note recount, not applied?'
SELECT inventory_log.reason,
       count(*) AS log_rows
FROM inventory_log
WHERE inventory_log.note = 'recount, not applied'
GROUP BY inventory_log.reason
ORDER BY log_rows DESC;
