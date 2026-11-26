-- monday_report_timing.sql
-- Purpose : time reading the finished report, with the plan for each read.
-- Output  : three EXPLAIN ANALYZE plans; the figure to quote is "Execution Time".
-- Safety  : read-only.

\echo '--- 1. the top 100'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM monday_top_100;

\echo '--- 2. the whole report, every customer'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM monday_report;

\echo '--- 3. one customer''s running total'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM customer_running_total WHERE customer_id = 100001;
