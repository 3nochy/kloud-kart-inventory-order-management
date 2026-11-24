-- 03_fault_hypotheses.sql
-- Purpose : test the explanations behind the largest faults (quantity typos, repeated
--           lines, stock drift, orphans). Read-only apart from temp tables. Aggregates only.

\echo '--- A. quantity distribution in order_items'
SELECT CASE WHEN quantity BETWEEN 1 AND 10 THEN '1-10'
            WHEN quantity BETWEEN 11 AND 99 THEN '11-99'
            ELSE '100+' END AS qty_bucket,
       count(*) AS items, round(sum(quantity * unit_price), 2) AS value, max(quantity) AS max_qty
FROM order_items GROUP BY 1 ORDER BY 1;

\echo '--- A2. total vs items: orders with and without a 100+ quantity line'
WITH items AS (
  SELECT order_id, sum(quantity * unit_price) AS items_total, bool_or(quantity >= 100) AS has_outlier
  FROM order_items GROUP BY order_id
)
SELECT i.has_outlier, count(*) AS orders,
       count(*) FILTER (WHERE o.total_amount IS DISTINCT FROM i.items_total) AS mismatched,
       round(sum(o.total_amount - i.items_total)
             FILTER (WHERE o.total_amount IS DISTINCT FROM i.items_total), 2) AS net_diff
FROM orders o JOIN items i USING (order_id)
GROUP BY 1 ORDER BY 1;

\echo '--- B. mismatches without outliers: total/items ratio (buckets of 0.05)'
WITH items AS (
  SELECT order_id, sum(quantity * unit_price) AS items_total, bool_or(quantity >= 100) AS has_outlier
  FROM order_items GROUP BY order_id
)
SELECT round((o.total_amount / nullif(i.items_total, 0)) * 20) / 20 AS ratio_bucket, count(*) AS orders
FROM orders o JOIN items i USING (order_id)
WHERE NOT i.has_outlier AND o.total_amount IS NOT NULL
  AND o.total_amount IS DISTINCT FROM i.items_total
GROUP BY 1 ORDER BY 2 DESC LIMIT 15;

\echo '--- C. orders with a NULL total'
SELECT count(*) AS null_total_orders, round(sum(i.items_total), 2) AS items_value
FROM orders o
JOIN (SELECT order_id, sum(quantity * unit_price) AS items_total FROM order_items GROUP BY order_id) i
  USING (order_id)
WHERE o.total_amount IS NULL;

\echo '--- D. identical repeated lines: does the order total include both copies?'
WITH rep AS (
  SELECT order_id FROM order_items GROUP BY order_id, product_id
  HAVING count(*) > 1 AND count(DISTINCT quantity::text || '/' || unit_price::text) = 1
), full_t AS (
  SELECT order_id, sum(quantity * unit_price) AS s FROM order_items
  WHERE order_id IN (SELECT order_id FROM rep) GROUP BY order_id
), dedup AS (
  SELECT order_id, sum(q * p) AS s
  FROM (SELECT DISTINCT order_id, product_id, quantity AS q, unit_price AS p FROM order_items
        WHERE order_id IN (SELECT order_id FROM rep)) d
  GROUP BY order_id
)
SELECT count(*) AS orders_with_identical_repeats,
       count(*) FILTER (WHERE o.total_amount = f.s) AS total_matches_all_lines,
       count(*) FILTER (WHERE o.total_amount = d.s AND o.total_amount IS DISTINCT FROM f.s) AS total_matches_deduplicated
FROM orders o
JOIN full_t f USING (order_id)
JOIN dedup d USING (order_id);

\echo '--- E1. inventory_log rows dated after the database clock'
SELECT reason, count(*) AS log_rows, sum(change_qty) AS units
FROM inventory_log WHERE created_at > now() GROUP BY 1 ORDER BY 2 DESC;

\echo '--- E2. can the stock gap be explained by specific log rows?'
DROP TABLE IF EXISTS tmp_gap;
CREATE TEMP TABLE tmp_gap AS
SELECT p.product_id,
       p.stock_quantity - coalesce(l.logged, 0) AS gap,
       coalesce(l.future, 0) AS future,
       coalesce(l.corr, 0) AS corr,
       coalesce(l.not_applied, 0) AS not_applied
FROM products p
LEFT JOIN (
  SELECT product_id,
         sum(change_qty) AS logged,
         sum(change_qty) FILTER (WHERE created_at > now()) AS future,
         sum(change_qty) FILTER (WHERE reason = 'correction') AS corr,
         sum(change_qty) FILTER (WHERE note = 'recount, not applied') AS not_applied
  FROM inventory_log GROUP BY product_id
) l USING (product_id)
WHERE p.stock_quantity IS DISTINCT FROM coalesce(l.logged, 0);
SELECT count(*) AS gap_products,
       count(*) FILTER (WHERE future <> 0 AND gap = -future) AS gap_equals_future_rows,
       count(*) FILTER (WHERE not_applied <> 0 AND gap = -not_applied) AS gap_equals_not_applied_notes,
       count(*) FILTER (WHERE corr <> 0 AND gap = -corr) AS gap_equals_corrections,
       count(*) FILTER (WHERE corr <> 0 AND gap = corr) AS gap_equals_corrections_flipped,
       count(*) FILTER (WHERE future = 0 AND not_applied = 0 AND corr = 0) AS no_candidate_rows
FROM tmp_gap;

\echo '--- E3. units in order_items (quantity < 100) by cleaned status vs sale units in the log'
SELECT status_clean, count(*) AS items, sum(quantity) AS units
FROM (SELECT oi.quantity,
             CASE WHEN lower(trim(o.status)) IN ('complete', 'completed') THEN 'completed'
                  WHEN lower(trim(o.status)) IN ('cancelled', 'canceled') THEN 'cancelled'
                  ELSE lower(trim(o.status)) END AS status_clean
      FROM order_items oi JOIN orders o USING (order_id)
      WHERE oi.quantity < 100) x
GROUP BY 1 ORDER BY 1;
SELECT count(*) AS sale_rows, sum(-change_qty) AS sale_units_in_log
FROM inventory_log WHERE reason = 'sale';

\echo '--- F1. orders with a missing customer: id range vs real customers'
SELECT (SELECT min(customer_id) FROM customers) AS customers_min,
       (SELECT max(customer_id) FROM customers) AS customers_max,
       min(o.customer_id) AS missing_min, max(o.customer_id) AS missing_max,
       count(*) AS orders, count(DISTINCT o.customer_id) AS distinct_missing
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id);

\echo '--- F2. orphan order_items: units and quantity outliers'
SELECT count(*) AS items, sum(quantity) AS units,
       count(*) FILTER (WHERE quantity >= 100) AS outliers, max(quantity) AS max_qty
FROM order_items oi
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);

\echo '--- F3. inventory_log rows for products that do not exist'
SELECT reason, count(*) AS log_rows, sum(change_qty) AS units,
       min(product_id) AS min_pid, max(product_id) AS max_pid
FROM inventory_log l
WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id)
GROUP BY 1 ORDER BY 2 DESC;
SELECT min(product_id) AS products_min, max(product_id) AS products_max FROM products;

\echo '--- G. dates and uncategorised stock'
SELECT max(order_date) FILTER (WHERE order_date <= now()) AS last_order_not_in_future,
       count(*) FILTER (WHERE order_date > now()) AS future_orders
FROM orders;
SELECT count(*) AS uncategorised_products, sum(stock_quantity) AS units,
       round(sum(stock_quantity * price), 2) AS stock_value
FROM products WHERE category_id IS NULL AND stock_quantity > 0;
