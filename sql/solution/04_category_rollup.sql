-- 04_category_rollup.sql
-- Purpose : show stock and low-stock products rolled up through categories of any depth.
-- Input   : freshly loaded database; no earlier solution script is required.
-- Output  : low_stock_by_category(threshold), a read-only table function.
-- Decision: the brief gives no reorder point. Use 5 units as the default example, but
--           pass another non-negative threshold for a different product policy.
-- Safety  : rerunnable. Does not change existing tables or stock quantities.
-- Coverage: regular category trees, roots whose parent is missing, cyclic/unreachable
--           categories, products with a missing category, and uncategorised products.
--
-- Example:
--   SELECT * FROM low_stock_by_category(5)
--   ORDER BY category_path, depth, category_id;

CREATE OR REPLACE FUNCTION low_stock_by_category(p_threshold integer DEFAULT 5)
RETURNS TABLE (
    bucket_type              text,
    category_id              integer,
    category_name            text,
    parent_id                integer,
    depth                    integer,
    category_path            text,
    product_count            bigint,
    stock_units              bigint,
    low_stock_product_count  bigint,
    low_stock_units          bigint,
    unknown_stock_count      bigint
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_threshold IS NULL OR p_threshold < 0 THEN
        RAISE EXCEPTION 'Low-stock threshold must be zero or greater';
    END IF;

    RETURN QUERY
    WITH RECURSIVE category_forest (
        category_id,
        parent_id,
        category_name,
        root_id,
        depth,
        category_path,
        id_path,
        root_has_missing_parent
    ) AS (
        -- A category with no parent, or with a parent id that does not exist, starts
        -- a visible tree. The latter is labelled separately instead of being hidden.
        SELECT categories.category_id,
               categories.parent_id,
               categories.category_name,
               categories.category_id,
               0,
               coalesce(categories.category_name,
                        '[unnamed category ' || categories.category_id::text || ']'),
               ARRAY[categories.category_id],
               categories.parent_id IS NOT NULL
        FROM categories
        WHERE categories.parent_id IS NULL
           OR NOT EXISTS (
                SELECT 1
                FROM categories AS parent
                WHERE parent.category_id = categories.parent_id
           )

        UNION ALL

        -- Follow children without a depth limit. The path guard protects the query
        -- if bad data ever makes a cycle reachable from a root.
        SELECT child.category_id,
               child.parent_id,
               child.category_name,
               category_forest.root_id,
               category_forest.depth + 1,
               category_forest.category_path || ' / ' ||
                   coalesce(child.category_name,
                            '[unnamed category ' || child.category_id::text || ']'),
               category_forest.id_path || child.category_id,
               category_forest.root_has_missing_parent
        FROM category_forest
        JOIN categories AS child
          ON child.parent_id = category_forest.category_id
        WHERE NOT child.category_id = ANY(category_forest.id_path)
    ),
    category_subtree (report_category_id, descendant_category_id, id_path) AS (
        SELECT category_forest.category_id,
               category_forest.category_id,
               ARRAY[category_forest.category_id]
        FROM category_forest

        UNION ALL

        SELECT category_subtree.report_category_id,
               child.category_id,
               category_subtree.id_path || child.category_id
        FROM category_subtree
        JOIN category_forest AS child
          ON child.parent_id = category_subtree.descendant_category_id
        WHERE NOT child.category_id = ANY(category_subtree.id_path)
    ),
    tree_totals AS (
        SELECT category_subtree.report_category_id,
               count(products.product_id) AS product_count,
               coalesce(sum(products.stock_quantity), 0)::bigint AS stock_units,
               count(products.product_id) FILTER (
                   WHERE products.stock_quantity IS NOT NULL
                     AND products.stock_quantity <= p_threshold
               ) AS low_stock_product_count,
               coalesce(sum(products.stock_quantity) FILTER (
                   WHERE products.stock_quantity IS NOT NULL
                     AND products.stock_quantity <= p_threshold
               ), 0)::bigint AS low_stock_units,
               count(products.product_id) FILTER (
                   WHERE products.stock_quantity IS NULL
               ) AS unknown_stock_count
        FROM category_subtree
        LEFT JOIN products
          ON products.category_id = category_subtree.descendant_category_id
        GROUP BY category_subtree.report_category_id
    )
    SELECT CASE
               WHEN category_forest.root_has_missing_parent THEN 'orphan_tree'
               ELSE 'category_tree'
           END::text,
           category_forest.category_id,
           category_forest.category_name,
           category_forest.parent_id,
           category_forest.depth,
           category_forest.category_path,
           tree_totals.product_count,
           tree_totals.stock_units,
           tree_totals.low_stock_product_count,
           tree_totals.low_stock_units,
           tree_totals.unknown_stock_count
    FROM category_forest
    JOIN tree_totals
      ON tree_totals.report_category_id = category_forest.category_id

    UNION ALL

    -- Cycles have no root and cannot be placed in the normal tree. Keep their stock
    -- visible in one explicit bucket rather than inventing a parent/child order.
    SELECT 'cycle_unreachable'::text,
           NULL::integer,
           'Products assigned to cyclic or unreachable categories'::text,
           NULL::integer,
           0,
           'Unattached category assignments'::text,
           count(products.product_id),
           coalesce(sum(products.stock_quantity), 0)::bigint,
           count(products.product_id) FILTER (
               WHERE products.stock_quantity IS NOT NULL
                 AND products.stock_quantity <= p_threshold
           ),
           coalesce(sum(products.stock_quantity) FILTER (
               WHERE products.stock_quantity IS NOT NULL
                 AND products.stock_quantity <= p_threshold
           ), 0)::bigint,
           count(products.product_id) FILTER (
               WHERE products.stock_quantity IS NULL
           )
    FROM products
    JOIN categories
      ON categories.category_id = products.category_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM category_forest
        WHERE category_forest.category_id = products.category_id
    )
    HAVING count(products.product_id) > 0

    UNION ALL

    SELECT 'missing_category'::text,
           NULL::integer,
           'Products referencing a category that does not exist'::text,
           NULL::integer,
           0,
           'Missing category references'::text,
           count(products.product_id),
           coalesce(sum(products.stock_quantity), 0)::bigint,
           count(products.product_id) FILTER (
               WHERE products.stock_quantity IS NOT NULL
                 AND products.stock_quantity <= p_threshold
           ),
           coalesce(sum(products.stock_quantity) FILTER (
               WHERE products.stock_quantity IS NOT NULL
                 AND products.stock_quantity <= p_threshold
           ), 0)::bigint,
           count(products.product_id) FILTER (
               WHERE products.stock_quantity IS NULL
           )
    FROM products
    WHERE products.category_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM categories
          WHERE categories.category_id = products.category_id
      )
    HAVING count(products.product_id) > 0

    UNION ALL

    SELECT 'uncategorized'::text,
           NULL::integer,
           'Products with no category'::text,
           NULL::integer,
           0,
           'Uncategorized products'::text,
           count(products.product_id),
           coalesce(sum(products.stock_quantity), 0)::bigint,
           count(products.product_id) FILTER (
               WHERE products.stock_quantity IS NOT NULL
                 AND products.stock_quantity <= p_threshold
           ),
           coalesce(sum(products.stock_quantity) FILTER (
               WHERE products.stock_quantity IS NOT NULL
                 AND products.stock_quantity <= p_threshold
           ), 0)::bigint,
           count(products.product_id) FILTER (
               WHERE products.stock_quantity IS NULL
           )
    FROM products
    WHERE products.category_id IS NULL
    HAVING count(products.product_id) > 0;
END;
$$;

COMMENT ON FUNCTION low_stock_by_category(integer) IS
    'Rolls stock up through the category tree at any depth. Default low-stock threshold is 5 units. '
    'Reports cyclic/unreachable, missing-category, and uncategorized product buckets separately.';
