-- 01b_fault_costing.sql
-- Purpose : attach a size (value, units, pattern) to each fault counted in 01.
-- Input   : freshly loaded database. Output: aggregates only (no personal rows).
-- Note    : only temp tables are created; nothing in the real schema changes.

\echo '--- A. order_items whose order does not exist'
SELECT count(*) AS items, count(DISTINCT oi.order_id) AS missing_orders,
       min(oi.order_id) AS min_order_id, max(oi.order_id) AS max_order_id,
       round(sum(oi.quantity * oi.unit_price), 2) AS value
FROM order_items oi
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);
SELECT min(order_id) AS orders_min_id, max(order_id) AS orders_max_id FROM orders;

\echo '--- B. orders whose customer does not exist'
SELECT count(*) AS orders, count(DISTINCT o.customer_id) AS missing_customers,
       round(sum(o.total_amount), 2) AS value,
       round(100.0 * sum(o.total_amount) / (SELECT sum(total_amount) FROM orders), 2) AS pct_of_all_orders_value
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id);

\echo '--- C. order total vs sum of its items'
DROP TABLE IF EXISTS tmp_total_diff;
CREATE TEMP TABLE tmp_total_diff AS
SELECT o.order_id, o.total_amount - i.items_total AS diff
FROM orders o
JOIN (SELECT order_id, sum(quantity * unit_price) AS items_total
      FROM order_items GROUP BY order_id) i USING (order_id)
WHERE o.total_amount IS DISTINCT FROM i.items_total;
SELECT count(*) AS mismatched,
       count(*) FILTER (WHERE diff IS NULL) AS null_totals,
       count(*) FILTER (WHERE abs(diff) <= 0.05) AS rounding_sized,
       round(min(diff), 2) AS min_diff, round(max(diff), 2) AS max_diff,
       round(sum(diff), 2) AS net_diff, round(sum(abs(diff)), 2) AS gross_diff
FROM tmp_total_diff;
\echo '--- C2. most common differences'
SELECT round(diff, 2) AS diff, count(*) AS orders
FROM tmp_total_diff GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

\echo '--- D. stock counter vs inventory log'
DROP TABLE IF EXISTS tmp_stock_gap;
CREATE TEMP TABLE tmp_stock_gap AS
SELECT p.product_id, p.stock_quantity, coalesce(l.logged, 0) AS logged,
       p.stock_quantity - coalesce(l.logged, 0) AS gap
FROM products p
LEFT JOIN (SELECT product_id, sum(change_qty) AS logged
           FROM inventory_log GROUP BY product_id) l USING (product_id)
WHERE p.stock_quantity IS DISTINCT FROM coalesce(l.logged, 0);
SELECT count(*) AS products,
       count(*) FILTER (WHERE stock_quantity IS NULL) AS null_stock,
       count(*) FILTER (WHERE stock_quantity < 0) AS negative_stock,
       sum(gap) AS net_gap_units, sum(abs(gap)) AS gross_gap_units,
       min(gap) AS min_gap, max(gap) AS max_gap
FROM tmp_stock_gap;
\echo '--- D2. negative stock that the log agrees with'
SELECT count(*) AS negative_stock_matching_log
FROM products p
WHERE p.stock_quantity < 0
  AND NOT EXISTS (SELECT 1 FROM tmp_stock_gap g WHERE g.product_id = p.product_id);

\echo '--- E. order status after cleaning spelling'
SELECT CASE WHEN lower(trim(status)) IN ('complete', 'completed') THEN 'completed'
            WHEN lower(trim(status)) IN ('cancelled', 'canceled') THEN 'cancelled'
            ELSE lower(trim(status)) END AS status_clean,
       count(*) AS orders, round(sum(total_amount), 2) AS value
FROM orders GROUP BY 1 ORDER BY 3 DESC;

\echo '--- F. customers sharing an email'
WITH g AS (
  SELECT lower(trim(email)) AS e, count(*) AS n,
         count(DISTINCT lower(trim(full_name))) AS names
  FROM customers WHERE email IS NOT NULL GROUP BY 1 HAVING count(*) > 1
)
SELECT count(*) AS email_groups, sum(n) AS rows_in_groups, sum(n) - count(*) AS extra_rows,
       count(*) FILTER (WHERE names = 1) AS groups_with_same_name,
       count(*) FILTER (WHERE names > 1) AS groups_with_different_names
FROM g;
SELECT count(*) AS customers_with_null_email FROM customers WHERE email IS NULL;

\echo '--- G. category tree health (depth capped at 20)'
WITH RECURSIVE walk AS (
  SELECT category_id AS start_id, parent_id AS cur, 1 AS depth FROM categories
  UNION ALL
  SELECT w.start_id, c.parent_id, w.depth + 1
  FROM walk w JOIN categories c ON c.category_id = w.cur
  WHERE w.depth < 20
)
SELECT count(DISTINCT start_id) FILTER (WHERE cur = start_id) AS categories_inside_a_cycle,
       max(depth) FILTER (WHERE cur IS NULL) AS deepest_chain_reaching_a_root
FROM walk;

\echo '--- H. order date range'
SELECT min(order_date) AS first_order, max(order_date) AS last_order,
       count(*) FILTER (WHERE order_date IS NULL) AS null_dates
FROM orders;

\echo '--- I. inventory_log rows for products that do not exist'
SELECT count(*) AS log_rows, count(DISTINCT product_id) AS missing_products,
       sum(change_qty) AS net_units
FROM inventory_log l
WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id);

\echo '--- J. other duplicate and sanity checks'
SELECT 'products sharing a name' AS check_name, count(*) AS n
FROM products
WHERE lower(trim(product_name)) IN (SELECT lower(trim(product_name)) FROM products
                                    WHERE product_name IS NOT NULL GROUP BY 1 HAVING count(*) > 1)
UNION ALL SELECT 'order_items: product repeated within an order', count(*)
FROM (SELECT 1 FROM order_items GROUP BY order_id, product_id HAVING count(*) > 1) x
UNION ALL SELECT 'orders dated before customer registered', count(*)
FROM orders o JOIN customers c USING (customer_id) WHERE o.order_date < c.registered_at
UNION ALL SELECT 'products: null stock', count(*) FROM products WHERE stock_quantity IS NULL;
