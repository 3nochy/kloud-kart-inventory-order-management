-- 07_indexes.sql
-- Purpose : support recursive category reads, linked audit queries, and per-customer
--           report queries without changing report results.
-- Input   : loaded database after solution scripts 01 through 06.
-- Output  : six supporting indexes on existing source tables.
-- Safety  : rerunnable. Index creation can take locks and use disk space; apply during
--           setup or a suitable maintenance window on a busy server.

CREATE INDEX IF NOT EXISTS categories_parent_id_idx
    ON categories (parent_id);

CREATE INDEX IF NOT EXISTS products_category_id_idx
    ON products (category_id);

CREATE INDEX IF NOT EXISTS inventory_log_product_created_idx
    ON inventory_log (product_id, created_at DESC, log_id DESC);

CREATE INDEX IF NOT EXISTS inventory_log_order_id_idx
    ON inventory_log (order_id)
    WHERE order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS orders_report_customer_date_idx
    ON orders (customer_id, order_date, order_id)
    INCLUDE (total_amount)
    WHERE total_amount IS NOT NULL
      AND lower(trim(status)) IN ('complete', 'completed', 'shipped');

-- The report index above is partial, so it cannot support FK checks for every order.
CREATE INDEX IF NOT EXISTS orders_customer_id_fk_idx
    ON orders (customer_id);

ANALYZE categories;
ANALYZE products;
ANALYZE orders;
ANALYZE inventory_log;
