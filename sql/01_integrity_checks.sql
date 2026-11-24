-- 01_integrity_checks.sql
-- Purpose : count every integrity fault the schema permits (read-only, changes nothing).
-- Input   : freshly loaded Kloud Kart database.
-- Output  : (1) one row per check with a count; (2) order status vocabulary;
--           (3) inventory_log reason vocabulary.
-- Note    : a count is a measurement, not yet a finding. Each non-zero row still
--           needs "what would the correct value be?" before it is reported.

SELECT 'orders: null customer_id' AS check_name, count(*) AS n FROM orders WHERE customer_id IS NULL
UNION ALL SELECT 'orders: customer missing', count(*) FROM orders o
  WHERE o.customer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id)
UNION ALL SELECT 'order_items: order missing', count(*) FROM order_items oi
  WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id)
UNION ALL SELECT 'order_items: product missing', count(*) FROM order_items oi
  WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = oi.product_id)
UNION ALL SELECT 'order_items: null order/product', count(*) FROM order_items
  WHERE order_id IS NULL OR product_id IS NULL
UNION ALL SELECT 'order_items: qty <= 0', count(*) FROM order_items WHERE quantity <= 0
UNION ALL SELECT 'orders without items', count(*) FROM orders o
  WHERE NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.order_id)
UNION ALL SELECT 'orders: total <> sum(items)', count(*) FROM orders o
  JOIN (SELECT order_id, sum(quantity * unit_price) AS s FROM order_items GROUP BY order_id) i USING (order_id)
  WHERE o.total_amount IS DISTINCT FROM i.s
UNION ALL SELECT 'products: negative stock', count(*) FROM products WHERE stock_quantity < 0
UNION ALL SELECT 'products: null/neg price', count(*) FROM products WHERE price IS NULL OR price < 0
UNION ALL SELECT 'products: category missing', count(*) FROM products p
  WHERE p.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories c WHERE c.category_id = p.category_id)
UNION ALL SELECT 'products: null category', count(*) FROM products WHERE category_id IS NULL
UNION ALL SELECT 'categories: parent missing', count(*) FROM categories c
  WHERE c.parent_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories p WHERE p.category_id = c.parent_id)
UNION ALL SELECT 'customers: rows sharing an email', count(*) FROM customers
  WHERE lower(trim(email)) IN (SELECT lower(trim(email)) FROM customers WHERE email IS NOT NULL
                               GROUP BY 1 HAVING count(*) > 1)
UNION ALL SELECT 'inventory_log: product missing', count(*) FROM inventory_log l
  WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id)
UNION ALL SELECT 'products: stock <> sum(log)', count(*) FROM products p
  WHERE p.stock_quantity IS DISTINCT FROM (SELECT coalesce(sum(change_qty), 0) FROM inventory_log l WHERE l.product_id = p.product_id)
ORDER BY 1;

SELECT status, count(*) AS n FROM orders GROUP BY 1 ORDER BY 2 DESC;
SELECT reason, count(*) AS n FROM inventory_log GROUP BY 1 ORDER BY 2 DESC;
