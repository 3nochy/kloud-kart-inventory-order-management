-- category_rollup_timing.sql
-- Purpose : show the category stock rollup and measure its execution time.
-- Input   : run after sql/solution/04_category_rollup.sql has created the function.
-- Output  : the visible category/bucket totals followed by an EXPLAIN ANALYZE plan.
-- Safety  : read-only. The function does not change stock or other source data.

\timing on

\echo '--- category rollup (default threshold: 5 units)'
SELECT bucket_type,
       category_path,
       depth,
       product_count,
       stock_units,
       low_stock_product_count,
       low_stock_units,
       unknown_stock_count
FROM low_stock_by_category(5)
ORDER BY category_path, depth, category_id;

\echo '--- execution plan and measured time'
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM low_stock_by_category(5);
