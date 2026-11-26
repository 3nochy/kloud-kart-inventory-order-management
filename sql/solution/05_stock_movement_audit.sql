-- 05_stock_movement_audit.sql
-- Purpose : record every post-install stock quantity change and provide a safe path for
--           restocks, returns, damage, stock counts, and corrections.
-- Input   : run after 01_sequences_and_audit_link.sql. Apply together with the updated
--           02_place_order.sql so sales are logged once and linked to their order.
-- Output  : changed_by audit column, an update trigger, and record_stock_movement(...).
-- Safety  : rerunnable. Existing log rows remain unchanged and changed_by stays NULL on
--           historical entries because their actor cannot be recovered reliably.
--
-- Direct stock_quantity updates are still allowed, but the trigger records them as
-- corrections with the database login as actor and a note that the reason was omitted.
-- Prefer record_stock_movement(...) so the intended reason and note are recorded.

ALTER TABLE inventory_log
    ADD COLUMN IF NOT EXISTS changed_by text;

COMMENT ON COLUMN inventory_log.changed_by IS
    'Database login that made the movement. NULL for historical rows recorded before auditing was installed.';

CREATE OR REPLACE FUNCTION audit_product_stock_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_change_qty       bigint;
    v_reason           text;
    v_note             text;
    v_order_id_text    text;
    v_actor            text;
BEGIN
    IF NEW.stock_quantity IS NOT DISTINCT FROM OLD.stock_quantity THEN
        RETURN NEW;
    END IF;

    IF NEW.stock_quantity IS NULL OR OLD.stock_quantity IS NULL THEN
        RAISE EXCEPTION 'Cannot audit a stock change from or to an unknown quantity for product %',
            NEW.product_id;
    END IF;

    -- Existing negative values are left for physical reconciliation. Do not allow a
    -- new update to make one worse. The NOT VALID table check still requires the final
    -- quantity of any updated row to be non-negative.
    IF NEW.stock_quantity < 0 AND NEW.stock_quantity < OLD.stock_quantity THEN
        RAISE EXCEPTION 'Stock change would make product % stock more negative', NEW.product_id;
    END IF;

    v_change_qty := NEW.stock_quantity::bigint - OLD.stock_quantity::bigint;
    IF v_change_qty < -2147483648 OR v_change_qty > 2147483647 THEN
        RAISE EXCEPTION 'Stock movement for product % exceeds inventory_log.change_qty range',
            NEW.product_id;
    END IF;

    v_reason := nullif(current_setting('kloudkart.stock_reason', true), '');
    IF v_reason IS NULL THEN
        v_reason := 'correction';
    END IF;

    IF v_reason NOT IN ('sale', 'restock', 'return', 'damage', 'correction', 'stock_take') THEN
        RAISE EXCEPTION 'Unsupported stock movement reason: %', v_reason;
    END IF;

    v_note := nullif(current_setting('kloudkart.stock_note', true), '');
    IF v_note IS NULL THEN
        v_note := 'Direct stock update; reason not supplied';
    END IF;

    v_order_id_text := nullif(current_setting('kloudkart.stock_order_id', true), '');
    v_actor := coalesce(nullif(current_setting('kloudkart.stock_actor', true), ''), session_user);

    INSERT INTO inventory_log (
        log_id,
        product_id,
        change_qty,
        reason,
        created_at,
        note,
        order_id,
        changed_by
    )
    VALUES (
        nextval('inventory_log_log_id_seq'),
        NEW.product_id,
        v_change_qty::integer,
        v_reason,
        now(),
        v_note,
        v_order_id_text::integer,
        v_actor
    );

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS products_stock_change_audit ON products;

CREATE TRIGGER products_stock_change_audit
AFTER UPDATE OF stock_quantity ON products
FOR EACH ROW
WHEN (OLD.stock_quantity IS DISTINCT FROM NEW.stock_quantity)
EXECUTE FUNCTION audit_product_stock_change();

CREATE OR REPLACE FUNCTION record_stock_movement(
    p_product_id bigint,
    p_change_qty integer,
    p_reason     text,
    p_note       text
)
RETURNS TABLE (
    success   boolean,
    new_stock integer,
    message   text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock       products.stock_quantity%TYPE;
    v_new_stock   bigint;
    v_reason      text;
BEGIN
    IF p_product_id IS NULL THEN
        RETURN QUERY SELECT false, NULL::integer, 'Product id is required'::text;
        RETURN;
    END IF;

    IF p_change_qty IS NULL THEN
        RETURN QUERY SELECT false, NULL::integer, 'Change quantity is required'::text;
        RETURN;
    END IF;

    v_reason := lower(trim(coalesce(p_reason, '')));
    IF v_reason NOT IN ('restock', 'return', 'damage', 'correction', 'stock_take') THEN
        RETURN QUERY SELECT false, NULL::integer,
                            'Reason must be restock, return, damage, correction, or stock_take'::text;
        RETURN;
    END IF;

    IF nullif(trim(coalesce(p_note, '')), '') IS NULL THEN
        RETURN QUERY SELECT false, NULL::integer, 'A note explaining the movement is required'::text;
        RETURN;
    END IF;

    IF v_reason IN ('restock', 'return') AND p_change_qty <= 0 THEN
        RETURN QUERY SELECT false, NULL::integer,
                            format('%s movements must add at least one unit', v_reason)::text;
        RETURN;
    END IF;

    IF v_reason = 'damage' AND p_change_qty >= 0 THEN
        RETURN QUERY SELECT false, NULL::integer,
                            'Damage movements must remove at least one unit'::text;
        RETURN;
    END IF;

    IF p_change_qty = 0 AND v_reason <> 'stock_take' THEN
        RETURN QUERY SELECT false, NULL::integer,
                            'A zero change is allowed only for a stock_take count'::text;
        RETURN;
    END IF;

    SELECT products.stock_quantity
    INTO v_stock
    FROM products
    WHERE products.product_id = p_product_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::integer, 'Product not found'::text;
        RETURN;
    END IF;

    IF v_stock IS NULL THEN
        RETURN QUERY SELECT false, NULL::integer,
                            'Current stock is unknown; record a physical count before applying a movement'::text;
        RETURN;
    END IF;

    v_new_stock := v_stock::bigint + p_change_qty::bigint;
    IF v_new_stock < 0 THEN
        RETURN QUERY SELECT false, v_stock,
                            format('Movement refused: only %s unit(s) are recorded in stock', v_stock)::text;
        RETURN;
    END IF;

    IF v_new_stock > 2147483647 THEN
        RETURN QUERY SELECT false, v_stock,
                            'Movement exceeds the supported stock quantity range'::text;
        RETURN;
    END IF;

    -- A zero-change stock take still deserves a log row even though it does not fire
    -- the UPDATE trigger.
    IF p_change_qty = 0 THEN
        INSERT INTO inventory_log (
            log_id, product_id, change_qty, reason, created_at, note, order_id, changed_by
        )
        VALUES (
            nextval('inventory_log_log_id_seq'),
            p_product_id,
            0,
            v_reason,
            now(),
            trim(p_note),
            NULL,
            session_user
        );

        RETURN QUERY SELECT true, v_stock, 'Stock count recorded; quantity unchanged'::text;
        RETURN;
    END IF;

    PERFORM set_config('kloudkart.stock_reason', v_reason, true);
    PERFORM set_config('kloudkart.stock_note', trim(p_note), true);
    PERFORM set_config('kloudkart.stock_order_id', '', true);
    PERFORM set_config('kloudkart.stock_actor', session_user, true);

    UPDATE products
    SET stock_quantity = v_new_stock::integer
    WHERE products.product_id = p_product_id;

    -- Do not let a later direct update in the same transaction inherit this context.
    PERFORM set_config('kloudkart.stock_reason', '', true);
    PERFORM set_config('kloudkart.stock_note', '', true);
    PERFORM set_config('kloudkart.stock_order_id', '', true);
    PERFORM set_config('kloudkart.stock_actor', '', true);

    RETURN QUERY SELECT true, v_new_stock::integer, 'Stock movement recorded'::text;
END;
$$;

COMMENT ON FUNCTION record_stock_movement(bigint, integer, text, text) IS
    'Applies a restock, return, damage, correction, or stock_take change under a product row lock. '
    'The products_stock_change_audit trigger writes the matching inventory_log row.';
