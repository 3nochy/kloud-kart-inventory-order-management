-- 06_constraints_and_reconciliation.sql
-- Purpose : block new negative stock and prioritize products for physical reconciliation.
-- Input   : run after 05_stock_movement_audit.sql.
-- Output  : NOT VALID integrity constraints and inventory_reconciliation_queue view.
-- Safety  : leaves existing quantities and log rows unchanged. Legacy negative counts
--           remain visible for physical review; do not auto-correct them.
-- Improvement: gives Nana a prioritized count queue without assuming the counter or log
--               is correct when they disagree.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'products'::regclass
          AND conname = 'products_stock_nonnegative'
    ) THEN
        ALTER TABLE products
            ADD CONSTRAINT products_stock_nonnegative
            CHECK (stock_quantity >= 0) NOT VALID;
    END IF;
END;
$$;

-- Existing orders contain customer ids that do not exist. NOT VALID keeps those old
-- rows intact, while the constraint protects new orders and prevents referenced
-- customers from being deleted. place_order also key-share locks the customer while
-- checking it, so deletion cannot race between validation and insertion.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'orders'::regclass
          AND conname = 'orders_customer_id_fkey'
    ) THEN
        ALTER TABLE orders
            ADD CONSTRAINT orders_customer_id_fkey
            FOREIGN KEY (customer_id) REFERENCES customers (customer_id) NOT VALID;
    END IF;
END;
$$;

COMMENT ON CONSTRAINT orders_customer_id_fkey ON orders IS
    'Not validated against legacy orders with missing customers. Enforces valid customer links for new or changed references and prevents deleting a referenced customer.';

COMMENT ON CONSTRAINT products_stock_nonnegative ON products IS
    'Not validated against legacy rows. Enforces non-negative stock for new or updated rows; reconcile existing negative counts physically.';

CREATE OR REPLACE VIEW inventory_reconciliation_queue AS
WITH logged_stock AS (
    SELECT inventory_log.product_id,
           sum(inventory_log.change_qty)::bigint AS logged_net_change,
           count(*)::bigint AS movement_rows,
           max(inventory_log.created_at) AS last_movement_at
    FROM inventory_log
    GROUP BY inventory_log.product_id
),
differences AS (
    SELECT products.product_id,
           products.product_name,
           products.stock_quantity AS current_stock,
           coalesce(logged_stock.logged_net_change, 0)::bigint AS logged_net_change,
           products.stock_quantity::bigint
               - coalesce(logged_stock.logged_net_change, 0)::bigint AS units_difference,
           products.price,
           coalesce(logged_stock.movement_rows, 0)::bigint AS movement_rows,
           logged_stock.last_movement_at
    FROM products
    LEFT JOIN logged_stock
      ON logged_stock.product_id = products.product_id
    WHERE products.stock_quantity IS NULL
       OR products.stock_quantity::bigint
            IS DISTINCT FROM coalesce(logged_stock.logged_net_change, 0)::bigint
)
SELECT row_number() OVER (
           ORDER BY abs(differences.units_difference * coalesce(differences.price, 0)) DESC NULLS LAST,
                    abs(differences.units_difference) DESC NULLS LAST,
                    differences.product_id
       ) AS review_priority,
       differences.product_id,
       differences.product_name,
       differences.current_stock,
       differences.logged_net_change,
       differences.units_difference,
       round(abs(differences.units_difference) * differences.price, 2) AS estimated_value_at_current_price,
       differences.movement_rows,
       differences.last_movement_at,
       CASE
           WHEN differences.current_stock IS NULL THEN 'unknown stock count'
           WHEN differences.units_difference > 0 THEN 'counter above logged net change'
           WHEN differences.units_difference < 0 THEN 'counter below logged net change'
           ELSE 'unknown'
       END AS review_reason
FROM differences;

COMMENT ON VIEW inventory_reconciliation_queue IS
    'Products whose current counter differs from logged net movement. Prioritizes physical review; neither side is assumed correct and no values are changed.';
