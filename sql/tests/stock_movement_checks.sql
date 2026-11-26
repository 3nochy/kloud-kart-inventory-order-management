-- stock_movement_checks.sql
-- Purpose : check helper and trigger audit paths without retaining fixture changes.
-- Input   : run after 01_sequences_and_audit_link.sql and 05_stock_movement_audit.sql.
-- Output  : movement function results and an assertion block; errors fail psql.
-- Safety  : all fixture rows, movements, and stock edits are rolled back.

\set ON_ERROR_STOP on
\timing on

BEGIN;

CREATE TEMP TABLE stock_audit_fixture ON COMMIT DROP AS
SELECT (coalesce(max(products.product_id), 0) + 2000)::integer AS product_id
FROM products;

INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)
SELECT stock_audit_fixture.product_id,
       'STOCK AUDIT TEST FIXTURE',
       NULL,
       1.00,
       10,
       now()
FROM stock_audit_fixture;

\echo '--- restock: add five units'
SELECT record_stock_movement(stock_audit_fixture.product_id, 5, 'restock', 'Test supplier delivery')
FROM stock_audit_fixture;

\echo '--- correction: remove two units'
SELECT record_stock_movement(stock_audit_fixture.product_id, -2, 'correction', 'Test count correction')
FROM stock_audit_fixture;

\echo '--- direct stock update: trigger should log as correction'
UPDATE products
SET stock_quantity = products.stock_quantity + 3
FROM stock_audit_fixture
WHERE products.product_id = stock_audit_fixture.product_id;

\echo '--- refused movement: stock must remain unchanged and no log row should be added'
SELECT record_stock_movement(stock_audit_fixture.product_id, -100, 'correction', 'Test underflow refusal')
FROM stock_audit_fixture;

DO $$
DECLARE
    v_product_id integer;
    v_stock integer;
    v_log_count bigint;
BEGIN
    SELECT stock_audit_fixture.product_id
    INTO v_product_id
    FROM stock_audit_fixture;

    SELECT products.stock_quantity
    INTO v_stock
    FROM products
    WHERE products.product_id = v_product_id;

    SELECT count(*)
    INTO v_log_count
    FROM inventory_log
    WHERE inventory_log.product_id = v_product_id;

    IF v_stock <> 16 THEN
        RAISE EXCEPTION 'Expected fixture stock 16, found %', v_stock;
    END IF;

    IF v_log_count <> 3 THEN
        RAISE EXCEPTION 'Expected exactly 3 movement rows, found %', v_log_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM inventory_log
        WHERE inventory_log.product_id = v_product_id
          AND inventory_log.reason = 'restock'
          AND inventory_log.change_qty = 5
          AND inventory_log.note = 'Test supplier delivery'
          AND inventory_log.changed_by = session_user
    ) THEN
        RAISE EXCEPTION 'Restock movement was not logged as expected';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM inventory_log
        WHERE inventory_log.product_id = v_product_id
          AND inventory_log.reason = 'correction'
          AND inventory_log.change_qty = -2
          AND inventory_log.note = 'Test count correction'
          AND inventory_log.changed_by = session_user
    ) THEN
        RAISE EXCEPTION 'Correction movement was not logged as expected';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM inventory_log
        WHERE inventory_log.product_id = v_product_id
          AND inventory_log.reason = 'correction'
          AND inventory_log.change_qty = 3
          AND inventory_log.note = 'Direct stock update; reason not supplied'
          AND inventory_log.changed_by = session_user
    ) THEN
        RAISE EXCEPTION 'Direct stock update was not logged with fallback context';
    END IF;

    IF EXISTS (
        SELECT 1 FROM inventory_log
        WHERE inventory_log.product_id = v_product_id
          AND inventory_log.note = 'Test underflow refusal'
    ) THEN
        RAISE EXCEPTION 'Refused movement unexpectedly created an audit row';
    END IF;

    BEGIN
        INSERT INTO products (
            product_id, product_name, price, stock_quantity, created_at
        )
        VALUES (
            v_product_id + 1, 'NEGATIVE STOCK MUST BE REJECTED', 1.00, -1, now()
        );
        RAISE EXCEPTION 'Negative stock insert was accepted';
    EXCEPTION
        WHEN check_violation THEN
            NULL;
    END;
END;
$$;

\echo '--- all stock-movement assertions passed; rolling fixture back'
ROLLBACK;
