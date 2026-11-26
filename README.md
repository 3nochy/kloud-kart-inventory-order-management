# Kloud Kart inventory and order management

PostgreSQL lab project for diagnosing the supplied inventory data, preventing stock
oversells, building a fast customer-spending report, rolling low stock through nested
categories, and recording stock movements.

## Requirements

- PostgreSQL in the existing Docker container named `kloudkart`.
- PostgreSQL 11 or newer. The source index uses the `INCLUDE` index feature introduced
  in PostgreSQL 11.
- The project folder mounted in that container at `/lab`.
- The six supplied CSV files in `data/`. Git intentionally ignores this input bundle, so
  it must be provided separately when someone gets a fresh clone of the project.
- For the concurrency test: Python 3.10 or newer, `psycopg2-binary`, and a host-accessible
  `DATABASE_URL` for the same database.

The race test opens 400 database connections together. Before running it, check the server
connection limit with `SHOW max_connections;` and make sure it can admit all 400 test
connections plus normal application and admin sessions. Changing this server setting may
require a PostgreSQL restart.

Install the Python test dependency in your virtual environment if needed:

```sh
pip install -r requirements.txt
```

## Load a fresh lab database

Run these from the project root. **`schema.sql` drops and recreates the project tables.**
Use it only when you intend to reset this lab database and reload the supplied data.

```sh
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f schema.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f load.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/run_all.sql
```

`sql/run_all.sql` applies the solution scripts in order and stops at the first error.
It expects the tables and data to be loaded first. It rebuilds report objects and
repositions sequences, so run it after a fresh load or during maintenance, not while
customers are placing orders.

## Run the checks

The order and stock-movement checks roll back their fixture changes. The report checks
and timing scripts only read data.

```sh
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/place_order_checks.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/stock_movement_checks.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/monday_report_checks.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/monday_report_timing.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/category_rollup_timing.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/reconciliation_queue_checks.sql
```

Check that customer links reject missing customers and handle a delete/order race using
disposable customer and product fixtures:

```sh
set -o pipefail
python customer_link_race_test.py | tee results/race_test/customer_link_checks.txt
```

The script needs the same `DATABASE_URL` as `race_test.py` and a database login that can
see its own sessions in `pg_stat_activity`. It removes its fixtures and rolls back its
test orders and stock changes.

Run the unmodified concurrency test from the project root with your virtual environment
active and `DATABASE_URL` set in the host terminal. A URL may look like this:

```sh
export DATABASE_URL='postgresql://postgres:<password>@localhost:5432/postgres'
python race_test.py
```

Use your own connection details; do not commit the URL or password. To save a race-test
run, pipe it to a numbered result file, for example:

```sh
set -o pipefail
python race_test.py | tee results/race_test/race_test_run_6.txt
```

## Use the reports

Show the low-stock rollup with the default threshold of five units:

```sql
SELECT *
FROM low_stock_by_category()
ORDER BY category_path, depth, category_id;
```

Choose a different threshold by passing it to the function, for example
`low_stock_by_category(10)`. The result includes category subtree totals and separate
buckets for cyclic or unreachable categories, missing category references, and products
with no category. Five units is a lab default, not a confirmed Kloud Kart reorder policy.

The customer summary is available through `monday_report` and `monday_top_100`. The
order-level cumulative balances are available through `customer_running_total`. The report
counts orders with completed or shipped statuses, uses `orders.total_amount` as spend, and uses
the date in `report_settings` as its as-of date. The report starts with 2026-11-23, the last
non-future order date found in the supplied data. The customer rows are not merged by
email.

The report totals and monthly spend are materialized views. After new orders arrive, set
`report_settings.as_of_date` to the report's cutoff date, then use the two refresh
statements documented at the top of `sql/solution/03_monday_report.sql`. For example:

```sql
UPDATE report_settings SET as_of_date = DATE '2026-11-30';
```

Then refresh `customer_spend_totals` and `customer_monthly_spend` as documented. The views
refresh separately, so a report read between the refreshes can briefly combine snapshots.
Re-running the solution script rebuilds those objects and should be done when readers are
not using the report.

Record non-sale stock changes through the helper so the log has a reason and note:

```sql
SELECT * FROM record_stock_movement(5001, 10, 'restock', 'Received supplier order 123');
```

Positive quantities add stock; negative quantities remove it. The trigger also logs direct
stock quantity updates as corrections, but using the helper gives the movement a useful
reason and explanation. `changed_by` records the PostgreSQL login, which may be a shared
application account rather than a staff member. Historical rows and the audit log are not
tamper-proof.

The stock reconciliation improvement ranks counter/log differences to help plan physical
counts; it does not change stock values:

```sql
SELECT *
FROM inventory_reconciliation_queue
ORDER BY review_priority
LIMIT 25;
```

The non-validated stock check blocks new negative quantities while leaving legacy negative
rows for physical reconciliation. Because PostgreSQL checks updated rows, other changes to
a legacy negative-stock product may fail until its quantity is corrected.

Solution script 06 also adds a non-validated customer foreign key. It leaves the existing
orphan orders unchanged, while requiring valid customer links for new or changed order
references and preventing deletion of a customer who has orders.

## Project layout

- `sql/diagnosis/` — read-only checks for the supplied data problems.
- `sql/solution/` — ordered schema changes, functions, triggers, report objects, and indexes.
- `sql/tests/` — report, order, movement, and timing checks.
- `sql/baseline/` — slow report shape used for the before measurement.
- `customer_link_race_test.py` — checks customer foreign-key enforcement and the
  delete/order race with disposable fixtures.
- `results/` — saved diagnosis, race-test, and performance output.
- `docs/data_diagnosis.md` — risk-ranked diagnosis of the supplied data.
- `docs/key_decisions.md` and `docs/adr/` — project decisions and supporting records.
- `docs/memo_to_nana.md` — client memo in the supplied template.
- `docs/improvement.md` — the extra stock reconciliation improvement.
