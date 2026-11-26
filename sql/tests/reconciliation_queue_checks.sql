-- reconciliation_queue_checks.sql
-- Purpose : confirm the physical-count queue includes the diagnosed stock disagreements.
-- Input   : run after solution scripts 01 through 07.
-- Output  : top ten review items and an assertion against the supplied diagnosis.
-- Safety  : read-only.

\set ON_ERROR_STOP on

\echo '--- highest-priority physical counts'
SELECT review_priority,
       product_id,
       product_name,
       current_stock,
       logged_net_change,
       units_difference,
       estimated_value_at_current_price,
       review_reason
FROM inventory_reconciliation_queue
ORDER BY review_priority
LIMIT 10;

DO $$
DECLARE
    v_queue_count bigint;
BEGIN
    SELECT count(*)
    INTO v_queue_count
    FROM inventory_reconciliation_queue;

    IF v_queue_count <> 144 THEN
        RAISE EXCEPTION 'Expected 144 products in the reconciliation queue, found %', v_queue_count;
    END IF;

    IF (SELECT min(review_priority) FROM inventory_reconciliation_queue) <> 1
       OR (SELECT max(review_priority) FROM inventory_reconciliation_queue) <> v_queue_count THEN
        RAISE EXCEPTION 'Review priorities are not consecutive from 1 through %', v_queue_count;
    END IF;
END;
$$;

\echo '--- queue assertions passed: 144 products need physical review'
