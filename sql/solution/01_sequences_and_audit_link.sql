-- 01_sequences_and_audit_link.sql
-- Purpose : give new rows safe ids and let an auditor link a stock movement to its order.
-- Input   : freshly loaded Kloud Kart database.
-- Output  : inventory_log.order_id column; three sequences positioned above every id in use.
-- Safety  : rerunnable. Changes the schema; recorded in
--           docs/adr/ADR-004-link-log-to-order.md and
--           docs/adr/ADR-005-ids-from-sequences.md.

-- Decision: nothing links inventory_log to orders today (only free-text reason and note).
-- A nullable column keeps the 282,352 existing rows valid; they stay NULL.
ALTER TABLE inventory_log
    ADD COLUMN IF NOT EXISTS order_id integer;

COMMENT ON COLUMN inventory_log.order_id IS
    'Order that caused this movement. NULL for movements recorded before this column existed.';

-- Decision: the key columns have no defaults, so ids come from sequences.
-- The orders sequence starts above the highest order_id found in orders OR order_items,
-- because 692 existing order_items point at order ids (up to 999862) that have no order.
-- Starting at 659385 would let new orders silently adopt those orphan items.
CREATE SEQUENCE IF NOT EXISTS orders_order_id_seq;
SELECT setval('orders_order_id_seq',
              greatest((SELECT coalesce(max(orders.order_id), 0) FROM orders),
                       (SELECT coalesce(max(order_items.order_id), 0) FROM order_items),
                       1)
             ) AS orders_sequence_position;

CREATE SEQUENCE IF NOT EXISTS order_items_order_item_id_seq;
SELECT setval('order_items_order_item_id_seq',
              greatest((SELECT coalesce(max(order_items.order_item_id), 0) FROM order_items), 1)
             ) AS order_items_sequence_position;

CREATE SEQUENCE IF NOT EXISTS inventory_log_log_id_seq;
SELECT setval('inventory_log_log_id_seq',
              greatest((SELECT coalesce(max(inventory_log.log_id), 0) FROM inventory_log), 1)
             ) AS inventory_log_sequence_position;
