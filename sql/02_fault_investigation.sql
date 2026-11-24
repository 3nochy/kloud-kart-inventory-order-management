-- 02_fault_investigation.sql
-- Purpose : explain the faults counted in 01/01b (patterns, direction, value) so each can be ranked by cost.
-- Input   : freshly loaded database. Output: aggregates and ids only. Read-only (temp tables only).

\echo '--- 1. ten biggest gaps between order total and item sum'
SELECT o.order_id, lower(trim(o.status)) AS status, o.total_amount, i.items_total,
       round(o.total_amount - i.items_total, 2) AS diff, i.lines, i.max_qty, i.max_unit_price
FROM orders o
JOIN (SELECT order_id, sum(quantity * unit_price) AS items_total, count(*) AS lines,
             max(quantity) AS max_qty, max(unit_price) AS max_unit_price
      FROM order_items GROUP BY order_id) i USING (order_id)
WHERE o.total_amount IS DISTINCT FROM i.items_total
ORDER BY abs(o.total_amount - i.items_total) DESC NULLS LAST
LIMIT 10;

\echo '--- 2. mismatches by size of total relative to items'
SELECT CASE WHEN o.total_amount IS NULL THEN 'null total'
            WHEN o.total_amount < 0.5 * i.items_total THEN 'total below 50% of items'
            WHEN o.total_amount < i.items_total THEN 'total 50-100% of items'
            ELSE 'total above items' END AS bucket,
       count(*) AS orders, round(sum(o.total_amount - i.items_total), 2) AS net_diff
FROM orders o
JOIN (SELECT order_id, sum(quantity * unit_price) AS items_total
      FROM order_items GROUP BY order_id) i USING (order_id)
WHERE o.total_amount IS DISTINCT FROM i.items_total
GROUP BY 1 ORDER BY 2 DESC;

\echo '--- 3. mismatch rate by cleaned status'
WITH t AS (
  SELECT CASE WHEN lower(trim(o.status)) IN ('complete', 'completed') THEN 'completed'
              WHEN lower(trim(o.status)) IN ('cancelled', 'canceled') THEN 'cancelled'
              ELSE lower(trim(o.status)) END AS s,
         (o.total_amount IS DISTINCT FROM i.items_total) AS bad
  FROM orders o
  JOIN (SELECT order_id, sum(quantity * unit_price) AS items_total
        FROM order_items GROUP BY order_id) i USING (order_id)
)
SELECT s AS status_clean, count(*) FILTER (WHERE bad) AS mismatched, count(*) AS orders,
       round(100.0 * count(*) FILTER (WHERE bad) / count(*), 2) AS pct
FROM t GROUP BY 1 ORDER BY 1;

\echo '--- 4. does unit_price differ from the current product price?'
SELECT count(*) AS items, count(*) FILTER (WHERE oi.unit_price IS DISTINCT FROM p.price) AS price_differs
FROM order_items oi JOIN products p USING (product_id);

\echo '--- 5. repeated product lines within one order: identical or different?'
WITH g AS (
  SELECT order_id, product_id, count(*) AS n,
         count(DISTINCT quantity::text || '/' || unit_price::text) AS variants
  FROM order_items GROUP BY order_id, product_id HAVING count(*) > 1
)
SELECT count(*) AS repeated_groups,
       count(*) FILTER (WHERE variants = 1) AS identical_lines,
       count(*) FILTER (WHERE variants > 1) AS different_lines
FROM g;

\echo '--- 6. stock gap valued at current price'
DROP TABLE IF EXISTS tmp_stock_gap;
CREATE TEMP TABLE tmp_stock_gap AS
SELECT p.product_id, p.price, p.stock_quantity - coalesce(l.logged, 0) AS gap
FROM products p
LEFT JOIN (SELECT product_id, sum(change_qty) AS logged FROM inventory_log GROUP BY product_id) l
       USING (product_id)
WHERE p.stock_quantity IS DISTINCT FROM coalesce(l.logged, 0);
SELECT count(*) AS products,
       count(*) FILTER (WHERE gap < 0) AS counter_below_log,
       count(*) FILTER (WHERE gap > 0) AS counter_above_log,
       sum(gap) AS net_units, round(sum(gap * price), 2) AS net_value,
       round(sum(abs(gap) * price), 2) AS gross_value
FROM tmp_stock_gap;
SELECT count(*) AS negative_products, sum(stock_quantity) AS units_oversold,
       round(sum(stock_quantity * price), 2) AS value_oversold
FROM products WHERE stock_quantity < 0;

\echo '--- 7. do log signs match their reasons?'
SELECT reason, count(*) AS log_rows,
       count(*) FILTER (WHERE change_qty > 0) AS positive,
       count(*) FILTER (WHERE change_qty < 0) AS negative,
       count(*) FILTER (WHERE change_qty = 0 OR change_qty IS NULL) AS zero_or_null
FROM inventory_log GROUP BY 1 ORDER BY 2 DESC;

\echo '--- 8. shapes of the free-text note column'
SELECT regexp_replace(coalesce(note, '<null>'), '[0-9]+', '#', 'g') AS note_pattern, count(*) AS n
FROM inventory_log GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

\echo '--- 9. units sold: order_items vs inventory_log'
SELECT (SELECT count(*) FROM order_items) AS order_item_rows,
       (SELECT count(*) FROM inventory_log WHERE reason = 'sale') AS sale_log_rows,
       (SELECT sum(quantity) FROM order_items) AS units_in_order_items,
       (SELECT sum(-change_qty) FROM inventory_log WHERE reason = 'sale') AS units_sold_in_log;

\echo '--- 10. effect of duplicate customers on the top 100 (cancelled orders excluded for this sizing only)'
WITH spend AS (
  SELECT c.customer_id, lower(trim(c.email)) AS e, coalesce(sum(o.total_amount), 0) AS s
  FROM customers c
  LEFT JOIN orders o ON o.customer_id = c.customer_id
       AND lower(trim(o.status)) NOT IN ('cancelled', 'canceled')
  GROUP BY c.customer_id, lower(trim(c.email))
), raw_top AS (
  SELECT e FROM spend ORDER BY s DESC, customer_id LIMIT 100
), merged_top AS (
  SELECT e FROM (SELECT e, sum(s) AS s FROM spend GROUP BY e) m ORDER BY s DESC, e LIMIT 100
), dup AS (
  SELECT e FROM spend WHERE s > 0 GROUP BY e HAVING count(*) > 1
)
SELECT (SELECT count(*) FROM merged_top WHERE e NOT IN (SELECT e FROM raw_top)) AS merged_top100_not_in_raw_top100,
       (SELECT count(*) FROM dup) AS email_groups_with_spend_on_several_rows;

\echo '--- 11. categories unreachable from a root, and what hangs beneath them'
WITH RECURSIVE reach AS (
  SELECT category_id FROM categories WHERE parent_id IS NULL
  UNION
  SELECT c.category_id FROM categories c JOIN reach r ON c.parent_id = r.category_id
)
SELECT (SELECT count(*) FROM categories WHERE parent_id IS NULL) AS roots,
       (SELECT count(*) FROM categories WHERE category_id NOT IN (SELECT category_id FROM reach)) AS categories_unreachable,
       (SELECT count(*) FROM products WHERE category_id IS NOT NULL
          AND category_id NOT IN (SELECT category_id FROM reach)) AS products_in_unreachable,
       (SELECT coalesce(sum(stock_quantity), 0) FROM products WHERE category_id IS NOT NULL
          AND category_id NOT IN (SELECT category_id FROM reach)) AS units_in_unreachable;
WITH RECURSIVE reach AS (
  SELECT category_id FROM categories WHERE parent_id IS NULL
  UNION
  SELECT c.category_id FROM categories c JOIN reach r ON c.parent_id = r.category_id
)
SELECT category_id, category_name, parent_id
FROM categories WHERE category_id NOT IN (SELECT category_id FROM reach) ORDER BY 1;

\echo '--- 12. dates against the database clock'
SELECT now()::timestamp AS db_clock,
       count(*) FILTER (WHERE order_date > now()) AS orders_after_now,
       round(sum(total_amount) FILTER (WHERE order_date > now()), 2) AS value_after_now,
       min(order_date) FILTER (WHERE order_date > now()) AS first_future_order
FROM orders;
SELECT 'inventory_log' AS tbl, min(created_at) AS first_date, max(created_at) AS last_date FROM inventory_log
UNION ALL SELECT 'products', min(created_at), max(created_at) FROM products
UNION ALL SELECT 'customers', min(registered_at), max(registered_at) FROM customers;
