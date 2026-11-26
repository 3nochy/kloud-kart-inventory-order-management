-- Apply the solution objects to a database after schema.sql and load.sql.
-- Run from the project root with psql -v ON_ERROR_STOP=1 -f sql/run_all.sql.
-- Stop immediately if any solution script fails.

\set ON_ERROR_STOP on

\echo '--- 01: sequences and audit link'
\ir solution/01_sequences_and_audit_link.sql

\echo '--- 02: concurrency-safe order placement'
\ir solution/02_place_order.sql

\echo '--- 03: Monday customer-spending report'
\ir solution/03_monday_report.sql

\echo '--- 04: recursive low-stock category rollup'
\ir solution/04_category_rollup.sql

\echo '--- 05: audit all stock changes'
\ir solution/05_stock_movement_audit.sql

\echo '--- 06: stock constraint and reconciliation queue'
\ir solution/06_constraints_and_reconciliation.sql

\echo '--- 07: supporting indexes'
\ir solution/07_indexes.sql

\echo '--- Kloud Kart solution objects installed'
