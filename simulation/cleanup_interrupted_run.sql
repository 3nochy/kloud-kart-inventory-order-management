-- Remove fixtures left by a forcibly interrupted flash_sale_day.py run.
-- Run from the project root with the run id printed by the simulation:
--   docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 \
--     -v run_id=012345abcdef -f simulation/cleanup_interrupted_run.sql

\set ON_ERROR_STOP on
\if :{?run_id}
\else
    \echo 'Supply the simulation run id with -v run_id=<id>'
    \quit 3
\endif

BEGIN;

CREATE TEMP TABLE simulation_fixture_products ON COMMIT DROP AS
SELECT product_id
FROM products
WHERE product_name = 'SIMULATION FIXTURE ' || :'run_id';

CREATE TEMP TABLE simulation_fixture_customers ON COMMIT DROP AS
SELECT customer_id
FROM customers
WHERE full_name LIKE ('Simulation Buyer ' || :'run_id' || ' %');

CREATE TEMP TABLE simulation_fixture_categories ON COMMIT DROP AS
SELECT category_id
FROM categories
WHERE category_name IN (
    'Simulation Electronics [' || :'run_id' || ']',
    'Simulation Phones [' || :'run_id' || ']',
    'Simulation Phone Accessories [' || :'run_id' || ']',
    'Simulation Cases [' || :'run_id' || ']'
);

CREATE TEMP TABLE simulation_fixture_orders ON COMMIT DROP AS
SELECT orders.order_id
FROM orders
WHERE orders.customer_id IN (SELECT customer_id FROM simulation_fixture_customers)
   OR orders.order_id IN (
       SELECT order_items.order_id
       FROM order_items
       WHERE order_items.product_id IN (SELECT product_id FROM simulation_fixture_products)
   );

DELETE FROM inventory_log
WHERE product_id IN (SELECT product_id FROM simulation_fixture_products)
   OR order_id IN (SELECT order_id FROM simulation_fixture_orders);

DELETE FROM order_items
WHERE product_id IN (SELECT product_id FROM simulation_fixture_products)
   OR order_id IN (SELECT order_id FROM simulation_fixture_orders);

DELETE FROM orders
WHERE order_id IN (SELECT order_id FROM simulation_fixture_orders);

DELETE FROM products
WHERE product_id IN (SELECT product_id FROM simulation_fixture_products);

DELETE FROM customers
WHERE customer_id IN (SELECT customer_id FROM simulation_fixture_customers);

DELETE FROM categories
WHERE category_id IN (SELECT category_id FROM simulation_fixture_categories);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM products WHERE product_id IN (SELECT product_id FROM simulation_fixture_products))
       OR EXISTS (SELECT 1 FROM customers WHERE customer_id IN (SELECT customer_id FROM simulation_fixture_customers))
       OR EXISTS (SELECT 1 FROM categories WHERE category_id IN (SELECT category_id FROM simulation_fixture_categories))
       OR EXISTS (SELECT 1 FROM orders WHERE order_id IN (SELECT order_id FROM simulation_fixture_orders))
       OR EXISTS (SELECT 1 FROM order_items WHERE order_id IN (SELECT order_id FROM simulation_fixture_orders))
       OR EXISTS (SELECT 1 FROM order_items WHERE product_id IN (SELECT product_id FROM simulation_fixture_products))
       OR EXISTS (SELECT 1 FROM inventory_log WHERE product_id IN (SELECT product_id FROM simulation_fixture_products))
       OR EXISTS (SELECT 1 FROM inventory_log WHERE order_id IN (SELECT order_id FROM simulation_fixture_orders)) THEN
        RAISE EXCEPTION 'Simulation cleanup left fixture rows behind';
    END IF;
END;
$$;

COMMIT;

\echo '--- interrupted simulation fixtures removed; sequence counters remain advanced'
