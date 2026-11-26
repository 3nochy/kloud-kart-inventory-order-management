-- place_order_checks.sql
-- Purpose : check the refusal paths and the atomic write of place_order.
-- Safety  : everything runs inside one transaction that is rolled back at the end,
--           so no order, item, log row or stock change is kept.

BEGIN;

\echo '--- 1. customer that does not exist (expect success = f, Customer not found)'
SELECT * FROM place_order(-1, 5001, 1);

\echo '--- 2. quantity zero (expect success = f, Invalid quantity)'
SELECT * FROM place_order(100001, 5001, 0);

\echo '--- 3. product that does not exist (expect success = f, Product not found)'
SELECT * FROM place_order(100001, 99999999, 1);

\echo '--- 4. more units than exist (expect success = f, Out of stock)'
SELECT * FROM place_order(100001, 5001, 1000000);

\echo '--- 5. a normal purchase (expect success = t); stock must fall by exactly 1'
SELECT stock_quantity AS stock_before
FROM products
WHERE product_id = (SELECT min(products.product_id)
                    FROM products
                    WHERE products.stock_quantity > 0);

SELECT * FROM place_order(
    100001,
    (SELECT min(products.product_id) FROM products WHERE products.stock_quantity > 0),
    1);

SELECT stock_quantity AS stock_after
FROM products
WHERE product_id = (SELECT min(products.product_id)
                    FROM products
                    WHERE products.stock_quantity > 0);

\echo '--- 6. the movement was logged against the new order (expect 1 row)'
SELECT inventory_log.reason,
       inventory_log.change_qty,
       inventory_log.order_id IS NOT NULL AS linked_to_order
FROM inventory_log
WHERE inventory_log.order_id = (SELECT max(orders.order_id) FROM orders);

ROLLBACK;
