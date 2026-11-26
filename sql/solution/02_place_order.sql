-- 02_place_order.sql
-- Purpose : place one order for one product so that two buyers can never take the same
--           last unit. Contract fixed by race_test.py.
-- Input   : place_order(customer id, product id, quantity).
-- Output  : one row (success, order_id, message).
-- Safety  : rerunnable (CREATE OR REPLACE). The call is atomic in its caller's transaction.
--
-- Decisions, recorded in full in:
--   docs/adr/ADR-001-lock-product-row.md
--   docs/adr/ADR-002-function-one-product-per-call.md
--   docs/adr/ADR-003-log-sale-at-placement.md
--   docs/adr/ADR-004-link-log-to-order.md
--   docs/adr/ADR-005-ids-from-sequences.md
--   docs/adr/ADR-007-audit-every-stock-change.md
--   docs/adr/ADR-011-protect-new-customer-links.md
-- Summary:
--   * A function, not a procedure: race_test.py calls it inside a SELECT, and a function
--     is one atomic unit that either does everything or nothing.
--   * Row lock (FOR UPDATE) rather than Serializable plus retries: the second buyer waits
--     a few milliseconds, then re-reads the new stock and is refused cleanly. No error can
--     reach the client, so no retry loop is needed.
--   * One product per call (the contract's signature), so only one stock row is locked.
--     The customer key-share lock is compatible with other orders for that customer.
--     A multi-item checkout would need to lock products in ascending product_id order.
--   * The customer row is key-share locked during validation. A NOT VALID foreign key
--     also protects new orders and prevents later customer deletion from orphaning them.
--   * Status 'pending' and log reason 'sale': see docs/adr/ADR-003-log-sale-at-placement.md.
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

    -- Protect validation from a concurrent delete. The NOT VALID FK in script 06 also
    -- protects other writers and prevents deleting a customer with an order.
    PERFORM 1
    FROM customers
    WHERE customers.customer_id = p_customer_id
    FOR KEY SHARE;

    IF NOT FOUND THEN
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

    v_new_order_id := nextval('orders_order_id_seq');

    -- The stock-change trigger writes the audit row. These transaction-local values
    -- tell it that this movement is a sale and link it to the order being created.
    PERFORM set_config('kloudkart.stock_reason', 'sale', true);
    PERFORM set_config('kloudkart.stock_note', 'placed by place_order', true);
    PERFORM set_config('kloudkart.stock_order_id', v_new_order_id::text, true);
    PERFORM set_config('kloudkart.stock_actor', session_user, true);

    UPDATE products
    SET stock_quantity = stock_quantity - p_quantity
    WHERE products.product_id = p_product_id;

    -- Clear context so a later stock edit in the same explicit transaction is not
    -- accidentally labelled as this sale.
    PERFORM set_config('kloudkart.stock_reason', '', true);
    PERFORM set_config('kloudkart.stock_note', '', true);
    PERFORM set_config('kloudkart.stock_order_id', '', true);
    PERFORM set_config('kloudkart.stock_actor', '', true);

    -- Note: total_amount is written from the price and quantity, matching the
    -- header-equals-items rule the clean part of the existing data follows.
    INSERT INTO orders (order_id, customer_id, order_date, status, total_amount)
    VALUES (v_new_order_id, p_customer_id, now(), 'pending', v_price * p_quantity);

    INSERT INTO order_items (order_item_id, order_id, product_id, quantity, unit_price)
    VALUES (nextval('order_items_order_item_id_seq'),
            v_new_order_id,
            p_product_id,
            p_quantity,
            v_price);

    RETURN QUERY SELECT true, v_new_order_id, 'Order placed'::text;
END;
$$;

COMMENT ON FUNCTION place_order(bigint, bigint, integer) IS
    'Places one order. Guarantees: stock never goes below zero through this function, '
    'and the order, item and trigger-written stock movement are written together or not at all. '
    'Requires the audit_product_stock_change trigger from 05_stock_movement_audit.sql.';
