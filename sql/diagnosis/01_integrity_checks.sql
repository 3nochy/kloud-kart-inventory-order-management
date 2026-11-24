-- 01_integrity_checks.sql
-- Purpose : count every integrity fault the schema permits, one row per check.
-- Input   : freshly loaded Kloud Kart database (schema.sql, then load.sql).
-- Output  : (1) one row per check with a count of faulty rows;
--           (2) the order status vocabulary;
--           (3) the inventory_log reason vocabulary.
-- Safety  : read-only; creates and changes nothing.
-- Note    : a count is a measurement, not yet a finding. Sizing and causes are in
--           02_fault_diagnosis.sql.

SELECT 'orders: null customer_id' AS check_name,
       count(*)                   AS n
FROM orders
WHERE orders.customer_id IS NULL

UNION ALL
SELECT 'orders: customer missing',
       count(*)
FROM orders
WHERE orders.customer_id IS NOT NULL
  AND NOT EXISTS (SELECT 1
                  FROM customers
                  WHERE customers.customer_id = orders.customer_id)

UNION ALL
SELECT 'orders: null total_amount',
       count(*)
FROM orders
WHERE orders.total_amount IS NULL

UNION ALL
SELECT 'orders without items',
       count(*)
FROM orders
WHERE NOT EXISTS (SELECT 1
                  FROM order_items
                  WHERE order_items.order_id = orders.order_id)

UNION ALL
SELECT 'orders: total <> sum(items)',
       count(*)
FROM orders
JOIN (SELECT order_items.order_id,
             sum(order_items.quantity * order_items.unit_price) AS items_total
      FROM order_items
      GROUP BY order_items.order_id) AS item_totals
  ON item_totals.order_id = orders.order_id
WHERE orders.total_amount IS DISTINCT FROM item_totals.items_total

UNION ALL
SELECT 'order_items: order missing',
       count(*)
FROM order_items
WHERE NOT EXISTS (SELECT 1
                  FROM orders
                  WHERE orders.order_id = order_items.order_id)

UNION ALL
SELECT 'order_items: product missing',
       count(*)
FROM order_items
WHERE NOT EXISTS (SELECT 1
                  FROM products
                  WHERE products.product_id = order_items.product_id)

UNION ALL
SELECT 'order_items: null order/product',
       count(*)
FROM order_items
WHERE order_items.order_id IS NULL
   OR order_items.product_id IS NULL

UNION ALL
SELECT 'order_items: null quantity or unit_price',
       count(*)
FROM order_items
WHERE order_items.quantity IS NULL
   OR order_items.unit_price IS NULL

UNION ALL
SELECT 'order_items: qty <= 0',
       count(*)
FROM order_items
WHERE order_items.quantity <= 0

UNION ALL
SELECT 'products: category missing',
       count(*)
FROM products
WHERE products.category_id IS NOT NULL
  AND NOT EXISTS (SELECT 1
                  FROM categories
                  WHERE categories.category_id = products.category_id)

UNION ALL
SELECT 'products: null category',
       count(*)
FROM products
WHERE products.category_id IS NULL

UNION ALL
SELECT 'products: negative stock',
       count(*)
FROM products
WHERE products.stock_quantity < 0

UNION ALL
SELECT 'products: null/neg price',
       count(*)
FROM products
WHERE products.price IS NULL
   OR products.price < 0

UNION ALL
SELECT 'products: stock <> sum(log)',
       count(*)
FROM products
WHERE products.stock_quantity IS DISTINCT FROM
      (SELECT coalesce(sum(inventory_log.change_qty), 0)
       FROM inventory_log
       WHERE inventory_log.product_id = products.product_id)

UNION ALL
SELECT 'categories: parent missing',
       count(*)
FROM categories AS child_category
WHERE child_category.parent_id IS NOT NULL
  AND NOT EXISTS (SELECT 1
                  FROM categories AS parent_category
                  WHERE parent_category.category_id = child_category.parent_id)

UNION ALL
SELECT 'customers: rows sharing an email',
       count(*)
FROM customers
WHERE lower(trim(customers.email)) IN
      (SELECT lower(trim(same_email.email))
       FROM customers AS same_email
       WHERE same_email.email IS NOT NULL
       GROUP BY lower(trim(same_email.email))
       HAVING count(*) > 1)

UNION ALL
SELECT 'inventory_log: product missing',
       count(*)
FROM inventory_log
WHERE NOT EXISTS (SELECT 1
                  FROM products
                  WHERE products.product_id = inventory_log.product_id)

ORDER BY check_name;

SELECT orders.status,
       count(*) AS n
FROM orders
GROUP BY orders.status
ORDER BY count(*) DESC;

SELECT inventory_log.reason,
       count(*) AS n
FROM inventory_log
GROUP BY inventory_log.reason
ORDER BY count(*) DESC;
