-- 02_place_order.sql
-- Purpose : place one order for one product so that two buyers can never take the same
--           last unit. Contract fixed by race_test.py.
-- Input   : place_order(customer id, product id, quantity).
-- Output  : one row (success, order_id, message).
-- Safety  : rerunnable (CREATE OR REPLACE). Writes only inside the function's own transaction.
--
-- Decisions (each defended in docs/3_key_decisions.md):
--   * A function, not a procedure: race_test.py calls it inside a SELECT, and a function
--     is one atomic unit that either does everything or nothing.
--   * Row lock (FOR UPDATE) rather than Serializable plus retries: the second buyer waits
--     a few milliseconds, then re-reads the new stock and is refused cleanly. No error can
--     reach the client, so no retry loop is needed.
--   * One product per call (the contract's signature), so there is only one lock to take
--     and no deadlock is possible. A multi-item checkout would need a second function that
--     locks products in ascending product_id order.
--   * The customer is checked before the lock is taken, to keep the lock held as briefly
--     as possible; everything between the lock and the end of the function is cheap.
--   * Status 'pending' and log reason 'sale': assumption, see docs/3_key_decisions.md.
--
-- Naming: RETURNS TABLE creates variables called success, order_id and message, so every
-- column reference below is qualified with its table name to avoid ambiguity.

CREATE OR REPLACE FUNCTION place_order(
    p_customer_id bigint,
    p_product_id  bigint,
    p_quantity    integer
)
RETURNS TABLE (
    success  boolean,
    order_id bigint,
    message  text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price        products.price%TYPE;
    v_stock        products.stock_quantity%TYPE;
    v_new_order_id bigint;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Invalid quantity: must be at least 1'::text;
        RETURN;
    END IF;

    -- No foreign key exists, so a missing customer would create an orphan order.
    IF NOT EXISTS (SELECT 1
                   FROM customers
                   WHERE customers.customer_id = p_customer_id) THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Customer not found'::text;
        RETURN;
    END IF;

    -- Take the row lock. A second buyer for the same product waits here until the first
    -- commits, then reads the updated stock instead of the stale value.
    SELECT products.price,
           products.stock_quantity
    INTO v_price, v_stock
    FROM products
    WHERE products.product_id = p_product_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Product not found'::text;
        RETURN;
    END IF;

    IF v_price IS NULL THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Product has no price'::text;
        RETURN;
    END IF;

    IF v_stock IS NULL OR v_stock < p_quantity THEN
        RETURN QUERY SELECT false,
                            NULL::bigint,
                            format('Out of stock: %s unit(s) available, %s requested',
                                   greatest(coalesce(v_stock, 0), 0),
                                   p_quantity)::text;
        RETURN;
    END IF;

    UPDATE products
    SET stock_quantity = stock_quantity - p_quantity
    WHERE products.product_id = p_product_id;

    v_new_order_id := nextval('orders_order_id_seq');

    -- Decision: total_amount is written from the price and quantity, matching the
    -- header-equals-items rule the clean part of the existing data follows.
    INSERT INTO orders (order_id, customer_id, order_date, status, total_amount)
    VALUES (v_new_order_id, p_customer_id, now(), 'pending', v_price * p_quantity);

    INSERT INTO order_items (order_item_id, order_id, product_id, quantity, unit_price)
    VALUES (nextval('order_items_order_item_id_seq'),
            v_new_order_id,
            p_product_id,
            p_quantity,
            v_price);

    INSERT INTO inventory_log (log_id, product_id, change_qty, reason, created_at, note, order_id)
    VALUES (nextval('inventory_log_log_id_seq'),
            p_product_id,
            -p_quantity,
            'sale',
            now(),
            'placed by place_order',
            v_new_order_id);

    RETURN QUERY SELECT true, v_new_order_id, 'Order placed'::text;
END;
$$;

COMMENT ON FUNCTION place_order(bigint, bigint, integer) IS
    'Places one order. Guarantees: stock never goes below zero through this function, '
    'and the order, item and stock movement are written together or not at all. '
    'Holds only for writers that go through this function.';
