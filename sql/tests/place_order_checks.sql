-- place_order_checks.sql
-- Purpose : assert refusal paths and the atomic stock/order/audit write.
-- Input   : run after sql/run_all.sql on a loaded lab database.
-- Output  : raises an error if any check fails.
-- Safety  : fixture order and stock changes roll back at the end.

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE place_order_check_fixture ON COMMIT DROP AS
SELECT (SELECT min(customers.customer_id) FROM customers) AS customer_id,
       (SELECT min(products.product_id)
        FROM products
        WHERE products.stock_quantity > 0
          AND products.stock_quantity < 2147483647) AS product_id;

DO $$
DECLARE
    v_customer_id bigint;
    v_product_id bigint;
    v_stock_before integer;
    v_stock_after integer;
    v_order_id bigint;
    v_result record;
BEGIN
    SELECT place_order_check_fixture.customer_id,
           place_order_check_fixture.product_id
    INTO v_customer_id, v_product_id
    FROM place_order_check_fixture;

    IF v_customer_id IS NULL OR v_product_id IS NULL THEN
        RAISE EXCEPTION 'Checks need at least one customer and one in-stock product';
    END IF;

    SELECT products.stock_quantity
    INTO v_stock_before
    FROM products
    WHERE products.product_id = v_product_id;

    SELECT * INTO v_result
    FROM place_order(-9223372036854775808, v_product_id, 1);
    IF v_result.success OR v_result.message <> 'Customer not found' THEN
        RAISE EXCEPTION 'Missing-customer check failed: %', row_to_json(v_result);
    END IF;

    SELECT * INTO v_result FROM place_order(v_customer_id, v_product_id, 0);
    IF v_result.success OR v_result.message NOT LIKE 'Invalid quantity:%' THEN
        RAISE EXCEPTION 'Invalid-quantity check failed: %', row_to_json(v_result);
    END IF;

    SELECT * INTO v_result
    FROM place_order(v_customer_id, -9223372036854775808, 1);
    IF v_result.success OR v_result.message <> 'Product not found' THEN
        RAISE EXCEPTION 'Missing-product check failed: %', row_to_json(v_result);
    END IF;

    SELECT * INTO v_result
    FROM place_order(v_customer_id, v_product_id, v_stock_before + 1);
    IF v_result.success OR v_result.message NOT LIKE 'Out of stock:%' THEN
        RAISE EXCEPTION 'Out-of-stock check failed: %', row_to_json(v_result);
    END IF;

    SELECT * INTO v_result FROM place_order(v_customer_id, v_product_id, 1);
    IF NOT v_result.success OR v_result.message <> 'Order placed' THEN
        RAISE EXCEPTION 'Successful-order check failed: %', row_to_json(v_result);
    END IF;
    v_order_id := v_result.order_id;

    SELECT products.stock_quantity
    INTO v_stock_after
    FROM products
    WHERE products.product_id = v_product_id;

    IF v_stock_after <> v_stock_before - 1 THEN
        RAISE EXCEPTION 'Expected stock to decrease by one; before %, after %',
            v_stock_before, v_stock_after;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM inventory_log
        WHERE inventory_log.order_id = v_order_id
          AND inventory_log.product_id = v_product_id
          AND inventory_log.reason = 'sale'
          AND inventory_log.change_qty = -1
    ) THEN
        RAISE EXCEPTION 'Successful order % has no matching sale movement', v_order_id;
    END IF;

END;
$$;

\echo 'All place_order checks passed'

ROLLBACK;
