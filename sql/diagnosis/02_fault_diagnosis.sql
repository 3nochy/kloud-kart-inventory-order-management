-- 02_fault_diagnosis.sql
-- Purpose : size each fault found by 01_integrity_checks.sql and test the explanations
--           behind the largest ones, so faults can be ranked by what they cost.
-- Input   : freshly loaded Kloud Kart database.
-- Output  : aggregates and ids only; no personal data is printed.
-- Safety  : read-only. Creates temporary views that vanish when the session ends.
-- Sections: A status spellings      B order totals vs items   C duplicate customers
--           D orphan rows           E stock counter vs log    F category tree
--           G dates                 H repeated lines, prices, names

-- ---------------------------------------------------------------------------
-- Shared definitions
-- ---------------------------------------------------------------------------

-- One row per order with the sum of its item lines.
CREATE OR REPLACE TEMP VIEW order_item_totals AS
SELECT order_items.order_id,
       sum(order_items.quantity * order_items.unit_price) AS items_total,
       count(*)                                           AS line_count,
       max(order_items.quantity)                          AS max_quantity,
       -- 100 is provisional: section B2 shows the quantity distribution it rests on.
       bool_or(order_items.quantity >= 100)               AS has_quantity_outlier
FROM order_items
GROUP BY order_items.order_id;

-- Orders with the 15 status spellings collapsed to 5 meanings.
CREATE OR REPLACE TEMP VIEW orders_with_clean_status AS
SELECT orders.order_id,
       orders.customer_id,
       orders.order_date,
       orders.total_amount,
       orders.status AS raw_status,
       CASE
           WHEN lower(trim(orders.status)) IN ('complete', 'completed') THEN 'completed'
           WHEN lower(trim(orders.status)) IN ('cancelled', 'canceled') THEN 'cancelled'
           ELSE lower(trim(orders.status))
       END AS clean_status
FROM orders;

-- Every order next to its item total, flagged when the two disagree.
CREATE OR REPLACE TEMP VIEW order_totals_compared AS
SELECT orders_with_clean_status.order_id,
       orders_with_clean_status.clean_status,
       orders_with_clean_status.total_amount,
       order_item_totals.items_total,
       orders_with_clean_status.total_amount - order_item_totals.items_total AS gap,
       order_item_totals.line_count,
       order_item_totals.max_quantity,
       order_item_totals.has_quantity_outlier,
       orders_with_clean_status.total_amount
           IS DISTINCT FROM order_item_totals.items_total AS is_mismatch
FROM orders_with_clean_status
JOIN order_item_totals
  ON order_item_totals.order_id = orders_with_clean_status.order_id;

-- Every product next to the sum of its inventory_log movements.
CREATE OR REPLACE TEMP VIEW stock_vs_log AS
SELECT products.product_id,
       products.price,
       products.stock_quantity,
       coalesce(log_totals.logged_units, 0)                           AS logged_units,
       products.stock_quantity - coalesce(log_totals.logged_units, 0) AS gap_units
FROM products
LEFT JOIN (SELECT inventory_log.product_id,
                  sum(inventory_log.change_qty) AS logged_units
           FROM inventory_log
           GROUP BY inventory_log.product_id) AS log_totals
       ON log_totals.product_id = products.product_id;

-- Categories reachable by walking down from a root (parent_id IS NULL).
-- UNION rather than UNION ALL so a cycle could never make the walk repeat forever.
CREATE OR REPLACE TEMP VIEW categories_reachable_from_root AS
WITH RECURSIVE walk_down AS (
    SELECT categories.category_id
    FROM categories
    WHERE categories.parent_id IS NULL

    UNION

    SELECT child_category.category_id
    FROM categories AS child_category
    JOIN walk_down
      ON child_category.parent_id = walk_down.category_id
)
SELECT walk_down.category_id
FROM walk_down;

-- ---------------------------------------------------------------------------
-- A. Order status spellings
-- ---------------------------------------------------------------------------

\echo '--- A1. order value by meaning of status'
SELECT orders_with_clean_status.clean_status,
       count(*)                                         AS order_count,
       round(sum(orders_with_clean_status.total_amount), 2) AS order_value
FROM orders_with_clean_status
GROUP BY orders_with_clean_status.clean_status
ORDER BY order_value DESC;

\echo '--- A2. completed orders that a filter on the exact word completed would see'
SELECT count(*) FILTER (WHERE raw_status = 'completed')   AS exact_word_only,
       count(*) FILTER (WHERE clean_status = 'completed') AS all_completed,
       round(100.0 * count(*) FILTER (WHERE raw_status = 'completed')
             / count(*) FILTER (WHERE clean_status = 'completed'), 1) AS pct_seen
FROM orders_with_clean_status;

-- ---------------------------------------------------------------------------
-- B. Order totals against their items
-- ---------------------------------------------------------------------------

\echo '--- B1. size of the total-versus-items mismatch'
SELECT count(*)                                        AS mismatched_orders,
       count(*) FILTER (WHERE total_amount IS NULL)    AS null_order_totals,
       count(*) FILTER (WHERE items_total IS NULL)     AS null_item_totals,
       count(*) FILTER (WHERE abs(gap) <= 0.05)        AS rounding_sized,
       round(min(gap), 2)                              AS smallest_gap,
       round(max(gap), 2)                              AS largest_gap,
       round(sum(gap), 2)                              AS net_gap,
       round(sum(abs(gap)), 2)                         AS gross_gap
FROM order_totals_compared
WHERE is_mismatch;

\echo '--- B2. quantity distribution in order_items'
SELECT CASE
           WHEN order_items.quantity BETWEEN 1 AND 10  THEN '1-10'
           WHEN order_items.quantity BETWEEN 11 AND 99 THEN '11-99'
           ELSE '100+ or invalid'
       END AS quantity_bucket,
       count(*)                  AS item_rows,
       max(order_items.quantity) AS largest_quantity,
       round(sum(order_items.quantity * order_items.unit_price), 2) AS item_value
FROM order_items
GROUP BY quantity_bucket
ORDER BY quantity_bucket;

\echo '--- B3. ten biggest gaps between order total and item total'
SELECT order_totals_compared.order_id,
       order_totals_compared.clean_status,
       order_totals_compared.total_amount,
       round(order_totals_compared.items_total, 2) AS items_total,
       round(order_totals_compared.gap, 2)         AS gap,
       order_totals_compared.line_count,
       order_totals_compared.max_quantity
FROM order_totals_compared
WHERE order_totals_compared.is_mismatch
ORDER BY abs(order_totals_compared.gap) DESC NULLS LAST
LIMIT 10;

\echo '--- B4. mismatches by size of the total relative to the items'
SELECT CASE
           WHEN total_amount IS NULL             THEN 'null total'
           WHEN items_total IS NULL              THEN 'null item total'
           WHEN total_amount < 0.5 * items_total THEN 'total below 50% of items'
           WHEN total_amount < items_total       THEN 'total 50-100% of items'
           ELSE 'total above items'
       END AS gap_bucket,
       count(*)           AS order_count,
       round(sum(gap), 2) AS net_gap
FROM order_totals_compared
WHERE is_mismatch
GROUP BY gap_bucket
ORDER BY order_count DESC;

\echo '--- B5. do orders with a 100+ quantity line explain the mismatches?'
SELECT order_totals_compared.has_quantity_outlier,
       count(*)                                                AS order_count,
       count(*) FILTER (WHERE is_mismatch)                     AS mismatched,
       round(sum(gap) FILTER (WHERE is_mismatch), 2)           AS net_gap
FROM order_totals_compared
GROUP BY order_totals_compared.has_quantity_outlier
ORDER BY order_totals_compared.has_quantity_outlier;

\echo '--- B6. mismatches without an outlier line: how far off is the total?'
SELECT round((total_amount / nullif(items_total, 0)) * 20) / 20 AS total_to_items_ratio,
       count(*)                                                 AS order_count
FROM order_totals_compared
WHERE is_mismatch
  AND NOT has_quantity_outlier
  AND total_amount IS NOT NULL
GROUP BY total_to_items_ratio
ORDER BY order_count DESC
LIMIT 15;

\echo '--- B7. mismatch rate by status meaning'
SELECT order_totals_compared.clean_status,
       count(*) FILTER (WHERE is_mismatch) AS mismatched,
       count(*)                            AS order_count,
       round(100.0 * count(*) FILTER (WHERE is_mismatch) / count(*), 2) AS pct_mismatched
FROM order_totals_compared
GROUP BY order_totals_compared.clean_status
ORDER BY order_totals_compared.clean_status;

\echo '--- B8. NULLs inside order_items that make an item total NULL'
SELECT count(*) FILTER (WHERE order_items.quantity IS NULL)   AS null_quantity,
       count(*) FILTER (WHERE order_items.unit_price IS NULL) AS null_unit_price
FROM order_items;

-- ---------------------------------------------------------------------------
-- C. Duplicate customers
-- ---------------------------------------------------------------------------

\echo '--- C1. customers sharing an email, and whether the names agree'
WITH email_groups AS (
    SELECT lower(trim(customers.email))                      AS email_key,
           count(*)                                          AS row_count,
           count(DISTINCT lower(trim(customers.full_name)))  AS distinct_names
    FROM customers
    WHERE customers.email IS NOT NULL
    GROUP BY lower(trim(customers.email))
    HAVING count(*) > 1
)
SELECT count(*)                                         AS email_groups,
       sum(row_count)                                   AS rows_in_groups,
       sum(row_count) - count(*)                        AS extra_rows,
       count(*) FILTER (WHERE distinct_names = 1)       AS groups_with_same_name,
       count(*) FILTER (WHERE distinct_names > 1)       AS groups_with_different_names
FROM email_groups;

\echo '--- C2. effect of duplicates on a top-100 spend ranking'
-- Cancelled orders are excluded here only to size the effect on a spend ranking.
-- Whether the Monday report counts them is a separate decision made at report stage.
WITH customer_spend AS (
    SELECT customers.customer_id,
           lower(trim(customers.email))                       AS email_key,
           coalesce(sum(spend_orders.total_amount), 0)        AS spend
    FROM customers
    LEFT JOIN orders_with_clean_status AS spend_orders
           ON spend_orders.customer_id = customers.customer_id
          AND spend_orders.clean_status <> 'cancelled'
    GROUP BY customers.customer_id, lower(trim(customers.email))
),
top100_as_stored AS (
    SELECT customer_spend.email_key
    FROM customer_spend
    ORDER BY customer_spend.spend DESC, customer_spend.customer_id
    LIMIT 100
),
top100_after_merging AS (
    SELECT spend_per_person.email_key
    FROM (SELECT customer_spend.email_key,
                 sum(customer_spend.spend) AS spend
          FROM customer_spend
          GROUP BY customer_spend.email_key) AS spend_per_person
    ORDER BY spend_per_person.spend DESC, spend_per_person.email_key
    LIMIT 100
),
emails_with_spend_on_several_rows AS (
    SELECT customer_spend.email_key
    FROM customer_spend
    WHERE customer_spend.spend > 0
    GROUP BY customer_spend.email_key
    HAVING count(*) > 1
)
SELECT (SELECT count(*)
        FROM top100_after_merging
        WHERE NOT EXISTS (SELECT 1
                          FROM top100_as_stored
                          WHERE top100_as_stored.email_key = top100_after_merging.email_key)
       ) AS merged_top100_missing_from_stored_top100,
       (SELECT count(*)
        FROM emails_with_spend_on_several_rows
       ) AS people_with_spend_split_across_rows;

-- ---------------------------------------------------------------------------
-- D. Orphan rows (relationships the schema does not enforce)
-- ---------------------------------------------------------------------------

\echo '--- D1. order_items whose order does not exist'
SELECT count(*)                                                     AS item_rows,
       count(DISTINCT order_items.order_id)                         AS missing_orders,
       min(order_items.order_id)                                    AS lowest_missing_order_id,
       max(order_items.order_id)                                    AS highest_missing_order_id,
       sum(order_items.quantity)                                    AS units,
       count(*) FILTER (WHERE order_items.quantity >= 100)          AS quantity_outliers,
       round(sum(order_items.quantity * order_items.unit_price), 2) AS item_value
FROM order_items
WHERE NOT EXISTS (SELECT 1
                  FROM orders
                  WHERE orders.order_id = order_items.order_id);

SELECT min(orders.order_id) AS lowest_existing_order_id,
       max(orders.order_id) AS highest_existing_order_id
FROM orders;

\echo '--- D2. orders whose customer does not exist'
SELECT count(*)                                  AS order_rows,
       count(DISTINCT orders.customer_id)        AS missing_customers,
       min(orders.customer_id)                   AS lowest_missing_customer_id,
       max(orders.customer_id)                   AS highest_missing_customer_id,
       round(sum(orders.total_amount), 2)        AS order_value,
       round(100.0 * sum(orders.total_amount)
             / (SELECT sum(all_orders.total_amount)
                FROM orders AS all_orders), 2)   AS pct_of_all_order_value
FROM orders
WHERE NOT EXISTS (SELECT 1
                  FROM customers
                  WHERE customers.customer_id = orders.customer_id);

SELECT min(customers.customer_id) AS lowest_existing_customer_id,
       max(customers.customer_id) AS highest_existing_customer_id
FROM customers;

\echo '--- D3. inventory_log rows whose product does not exist'
SELECT inventory_log.reason,
       count(*)                      AS log_rows,
       sum(inventory_log.change_qty) AS units,
       min(inventory_log.product_id) AS lowest_missing_product_id,
       max(inventory_log.product_id) AS highest_missing_product_id
FROM inventory_log
WHERE NOT EXISTS (SELECT 1
                  FROM products
                  WHERE products.product_id = inventory_log.product_id)
GROUP BY inventory_log.reason
ORDER BY log_rows DESC;

SELECT min(products.product_id) AS lowest_existing_product_id,
       max(products.product_id) AS highest_existing_product_id
FROM products;

-- ---------------------------------------------------------------------------
-- E. Stock counter against the inventory log
-- ---------------------------------------------------------------------------

\echo '--- E1. products whose counter disagrees with the log'
SELECT count(*)                                         AS products_off,
       count(*) FILTER (WHERE gap_units < 0)            AS counter_below_log,
       count(*) FILTER (WHERE gap_units > 0)            AS counter_above_log,
       count(*) FILTER (WHERE stock_quantity < 0)       AS negative_counter,
       sum(gap_units)                                   AS net_gap_units,
       sum(abs(gap_units))                              AS gross_gap_units,
       min(gap_units)                                   AS largest_shortfall,
       max(gap_units)                                   AS largest_surplus,
       round(sum(gap_units * price), 2)                 AS net_gap_value,
       round(sum(abs(gap_units) * price), 2)            AS gross_gap_value
FROM stock_vs_log
WHERE gap_units IS DISTINCT FROM 0;

\echo '--- E2. products with negative stock (oversold) and whether the log agrees'
SELECT count(*)                                  AS negative_stock_products,
       sum(stock_vs_log.stock_quantity)          AS units_oversold,
       round(sum(stock_vs_log.stock_quantity * stock_vs_log.price), 2) AS value_oversold,
       count(*) FILTER (WHERE gap_units = 0)     AS log_agrees_with_counter
FROM stock_vs_log
WHERE stock_vs_log.stock_quantity < 0;

\echo '--- E3. do log signs match their reasons?'
SELECT inventory_log.reason,
       count(*)                                                      AS log_rows,
       count(*) FILTER (WHERE inventory_log.change_qty > 0)          AS positive,
       count(*) FILTER (WHERE inventory_log.change_qty < 0)          AS negative,
       count(*) FILTER (WHERE inventory_log.change_qty = 0
                           OR inventory_log.change_qty IS NULL)      AS zero_or_null
FROM inventory_log
GROUP BY inventory_log.reason
ORDER BY log_rows DESC;

\echo '--- E4. shapes of the free-text note column'
SELECT regexp_replace(coalesce(inventory_log.note, '<null>'), '[0-9]+', '#', 'g') AS note_pattern,
       count(*) AS log_rows
FROM inventory_log
GROUP BY note_pattern
ORDER BY log_rows DESC
LIMIT 10;

\echo '--- E5. log rows dated after the database clock'
SELECT inventory_log.reason,
       count(*)                      AS log_rows,
       sum(inventory_log.change_qty) AS units
FROM inventory_log
WHERE inventory_log.created_at > now()
GROUP BY inventory_log.reason
ORDER BY log_rows DESC;

\echo '--- E6. can specific log rows explain the gap?'
-- If a product's gap equals minus the units of a group of log rows, that group explains
-- the drift: the counter was never updated for it, or was updated and the log was not.
WITH candidate_log_rows AS (
    SELECT inventory_log.product_id,
           sum(inventory_log.change_qty)
               FILTER (WHERE inventory_log.created_at > now())             AS future_dated_units,
           sum(inventory_log.change_qty)
               FILTER (WHERE inventory_log.reason = 'correction')          AS correction_units,
           sum(inventory_log.change_qty)
               FILTER (WHERE inventory_log.note = 'recount, not applied')  AS not_applied_units
    FROM inventory_log
    GROUP BY inventory_log.product_id
)
SELECT count(*) AS products_off,
       count(*) FILTER (WHERE stock_vs_log.gap_units = -candidate_log_rows.future_dated_units)
           AS gap_equals_minus_future_dated_rows,
       count(*) FILTER (WHERE stock_vs_log.gap_units = -candidate_log_rows.not_applied_units)
           AS gap_equals_minus_not_applied_notes,
       count(*) FILTER (WHERE stock_vs_log.gap_units = -candidate_log_rows.correction_units)
           AS gap_equals_minus_corrections,
       count(*) FILTER (WHERE stock_vs_log.gap_units = candidate_log_rows.correction_units)
           AS gap_equals_corrections,
       count(*) FILTER (WHERE coalesce(candidate_log_rows.future_dated_units, 0) = 0
                          AND coalesce(candidate_log_rows.not_applied_units, 0) = 0
                          AND coalesce(candidate_log_rows.correction_units, 0) = 0)
           AS no_candidate_rows
FROM stock_vs_log
LEFT JOIN candidate_log_rows
       ON candidate_log_rows.product_id = stock_vs_log.product_id
WHERE stock_vs_log.gap_units IS DISTINCT FROM 0;

\echo '--- E7. units sold: order_items (quantity under 100) against sale rows in the log'
SELECT orders_with_clean_status.clean_status,
       count(*)                      AS item_rows,
       sum(order_items.quantity)     AS units
FROM order_items
JOIN orders_with_clean_status
  ON orders_with_clean_status.order_id = order_items.order_id
WHERE order_items.quantity < 100
GROUP BY orders_with_clean_status.clean_status
ORDER BY orders_with_clean_status.clean_status;

SELECT count(*)                         AS sale_log_rows,
       sum(-inventory_log.change_qty)   AS sale_units_in_log
FROM inventory_log
WHERE inventory_log.reason = 'sale';

-- ---------------------------------------------------------------------------
-- F. Category tree
-- ---------------------------------------------------------------------------

\echo '--- F1. categories a rollup from the roots would never reach'
SELECT (SELECT count(*)
        FROM categories
        WHERE categories.parent_id IS NULL) AS roots,
       (SELECT count(*)
        FROM categories
        WHERE NOT EXISTS (SELECT 1
                          FROM categories_reachable_from_root
                          WHERE categories_reachable_from_root.category_id = categories.category_id)
       ) AS unreachable_categories,
       (SELECT count(*)
        FROM products
        WHERE products.category_id IS NOT NULL
          AND NOT EXISTS (SELECT 1
                          FROM categories_reachable_from_root
                          WHERE categories_reachable_from_root.category_id = products.category_id)
       ) AS products_under_unreachable,
       (SELECT coalesce(sum(products.stock_quantity), 0)
        FROM products
        WHERE products.category_id IS NOT NULL
          AND NOT EXISTS (SELECT 1
                          FROM categories_reachable_from_root
                          WHERE categories_reachable_from_root.category_id = products.category_id)
       ) AS units_under_unreachable;

\echo '--- F2. the unreachable categories'
SELECT categories.category_id,
       categories.category_name,
       categories.parent_id
FROM categories
WHERE NOT EXISTS (SELECT 1
                  FROM categories_reachable_from_root
                  WHERE categories_reachable_from_root.category_id = categories.category_id)
ORDER BY categories.category_id;

\echo '--- F3. cycle check: walk up from every category, capped at 20 steps'
WITH RECURSIVE walk_up AS (
    SELECT categories.category_id AS start_category_id,
           categories.parent_id   AS current_parent_id,
           1                      AS depth
    FROM categories

    UNION ALL

    SELECT walk_up.start_category_id,
           categories.parent_id,
           walk_up.depth + 1
    FROM walk_up
    JOIN categories
      ON categories.category_id = walk_up.current_parent_id
    WHERE walk_up.depth < 20
)
SELECT count(DISTINCT start_category_id)
           FILTER (WHERE current_parent_id = start_category_id) AS categories_inside_a_cycle,
       max(depth)
           FILTER (WHERE current_parent_id IS NULL)             AS deepest_chain_reaching_a_root
FROM walk_up;

-- ---------------------------------------------------------------------------
-- G. Dates
-- ---------------------------------------------------------------------------

\echo '--- G1. order dates against the database clock'
SELECT now()::timestamp                                                    AS database_clock,
       min(orders.order_date)                                              AS first_order,
       max(orders.order_date)                                              AS last_order,
       max(orders.order_date) FILTER (WHERE orders.order_date <= now())    AS last_order_not_in_future,
       count(*) FILTER (WHERE orders.order_date IS NULL)                   AS null_dates,
       count(*) FILTER (WHERE orders.order_date > now())                   AS orders_after_now,
       round(sum(orders.total_amount) FILTER (WHERE orders.order_date > now()), 2) AS value_after_now,
       min(orders.order_date) FILTER (WHERE orders.order_date > now())     AS first_future_order
FROM orders;

\echo '--- G2. date ranges of the other tables'
SELECT 'inventory_log' AS table_name,
       min(inventory_log.created_at) AS first_date,
       max(inventory_log.created_at) AS last_date
FROM inventory_log
UNION ALL
SELECT 'products',
       min(products.created_at),
       max(products.created_at)
FROM products
UNION ALL
SELECT 'customers',
       min(customers.registered_at),
       max(customers.registered_at)
FROM customers;

\echo '--- G3. stock held by products with no category'
SELECT count(*)                                   AS uncategorised_products,
       sum(products.stock_quantity)               AS units,
       round(sum(products.stock_quantity * products.price), 2) AS stock_value
FROM products
WHERE products.category_id IS NULL
  AND products.stock_quantity > 0;

-- ---------------------------------------------------------------------------
-- H. Repeated lines, prices and names (candidates for "looks wrong but is not")
-- ---------------------------------------------------------------------------

\echo '--- H1. the same product repeated within one order: identical or different?'
WITH repeated_lines AS (
    SELECT order_items.order_id,
           order_items.product_id,
           count(DISTINCT order_items.quantity::text || '/' || order_items.unit_price::text) AS variants
    FROM order_items
    GROUP BY order_items.order_id, order_items.product_id
    HAVING count(*) > 1
)
SELECT count(*)                                  AS repeated_groups,
       count(*) FILTER (WHERE variants = 1)      AS identical_lines,
       count(*) FILTER (WHERE variants > 1)      AS different_lines
FROM repeated_lines;

\echo '--- H2. for identical repeats, does the order total count every line or each once?'
WITH orders_with_identical_repeats AS (
    SELECT order_items.order_id
    FROM order_items
    GROUP BY order_items.order_id, order_items.product_id
    HAVING count(*) > 1
       AND count(DISTINCT order_items.quantity::text || '/' || order_items.unit_price::text) = 1
),
total_counting_every_line AS (
    SELECT order_items.order_id,
           sum(order_items.quantity * order_items.unit_price) AS line_total
    FROM order_items
    WHERE order_items.order_id IN (SELECT order_id FROM orders_with_identical_repeats)
    GROUP BY order_items.order_id
),
total_counting_each_line_once AS (
    SELECT distinct_lines.order_id,
           sum(distinct_lines.quantity * distinct_lines.unit_price) AS line_total
    FROM (SELECT DISTINCT order_items.order_id,
                          order_items.product_id,
                          order_items.quantity,
                          order_items.unit_price
          FROM order_items
          WHERE order_items.order_id IN (SELECT order_id FROM orders_with_identical_repeats)
         ) AS distinct_lines
    GROUP BY distinct_lines.order_id
)
SELECT count(*) AS orders_with_identical_repeats,
       count(*) FILTER (WHERE orders.total_amount = every_line.line_total)
           AS total_matches_every_line,
       count(*) FILTER (WHERE orders.total_amount = each_once.line_total
                          AND orders.total_amount IS DISTINCT FROM every_line.line_total)
           AS total_matches_each_line_once
FROM orders
JOIN total_counting_every_line AS every_line
  ON every_line.order_id = orders.order_id
JOIN total_counting_each_line_once AS each_once
  ON each_once.order_id = orders.order_id;

\echo '--- H3. item prices that differ from the current product price'
-- unit_price is the price at the time of sale, so a difference is expected after a price change.
SELECT count(*)                                                        AS item_rows,
       count(*) FILTER (WHERE order_items.unit_price IS DISTINCT FROM products.price) AS price_differs
FROM order_items
JOIN products
  ON products.product_id = order_items.product_id;

\echo '--- H4. other duplicate and date sanity checks'
SELECT 'products sharing a name' AS check_name,
       count(*)                  AS n
FROM products
WHERE lower(trim(products.product_name)) IN
      (SELECT lower(trim(same_name.product_name))
       FROM products AS same_name
       WHERE same_name.product_name IS NOT NULL
       GROUP BY lower(trim(same_name.product_name))
       HAVING count(*) > 1)

UNION ALL
SELECT 'orders dated before the customer registered',
       count(*)
FROM orders
JOIN customers
  ON customers.customer_id = orders.customer_id
WHERE orders.order_date < customers.registered_at;
