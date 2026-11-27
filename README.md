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
- For the concurrency tests: Python 3.10 or newer, `psycopg2-binary==2.9.13`, and a
  host-accessible `DATABASE_URL` for the same database.

The race test and default simulation each open 400 database connections together. Before
running either, check the server connection limit with `SHOW max_connections;` and make
sure it can admit all 400 test connections plus normal application and admin sessions.
The simulation checks capacity before starting. Changing the server setting may require a
PostgreSQL restart.

The CSV bundle is pinned by `data_bundle.sha256`. After placing the supplied files in
`data/`, verify them from the project root before loading:

```sh
sha256sum -c data_bundle.sha256
```

Install the Python test dependency in your virtual environment if needed:

```sh
pip install -r requirements.txt
```

## Load a fresh lab database

Run these from the project root. **`schema.sql` drops and recreates the project tables,
report cutoff, and solution id sequences.** Use it only when you intend to reset this lab
database and reload the supplied data.

```sh
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f schema.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f load.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/run_all.sql
```

`sql/run_all.sql` applies the solution scripts in order and stops at the first error.
It expects the tables and data to be loaded first. It rebuilds report objects and
repositions sequences, so run it after a fresh load or during maintenance, not while
customers are placing orders.

The solution scripts run in this order:

1. `01_sequences_and_audit_link.sql`
2. `02_place_order.sql`
3. `03_monday_report.sql`
4. `04_category_rollup.sql`
5. `05_stock_movement_audit.sql`
6. `06_constraints_and_reconciliation.sql`
7. `07_indexes.sql`

## Run the checks

The order and stock-movement checks roll back their fixture changes. The Monday report
check refreshes summaries inside a transaction and rolls it back; timing scripts only
read data.

```sh
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/place_order_checks.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/stock_movement_checks.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/monday_report_checks.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/monday_report_timing.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/category_rollup_timing.sql
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 -f sql/tests/reconciliation_queue_checks.sql
```

Check customer-link enforcement and the customer deletion/order race with disposable
fixtures. The script removes its fixtures and rolls back its test orders and stock changes:

```sh
set -o pipefail
python customer_link_race_test.py | tee results/race_test/customer_link_checks.txt
```

The script needs the same `DATABASE_URL` as `race_test.py` and a database login that can
see its own sessions in `pg_stat_activity`.

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

## Run the end-to-end simulation

After loading the data and applying `sql/run_all.sql`, the flash-sale-day simulation
exercises order placement, stock auditing, the recursive category rollup, and the Monday
report in one run. It uses the existing database and
temporary fixtures; it does not need another app or service. The default scenario starts
400 buyers together for 50 units and checks that the result matches the available stock.
It checks PostgreSQL connection capacity before opening the buyer connections.

Run it from the project root with the virtual environment active and `DATABASE_URL` set:

```sh
python simulation/flash_sale_day.py
```

Open `results/simulation/flash_sale_day.html` in a browser for the scorecard and timeline.
The companion `flash_sale_day.json` contains the same run's machine-readable results.
Both files are overwritten by the next run. Use `--buyers`, `--stock`, `--threshold`, or
`--seed` to change the scenario; for example, `python simulation/flash_sale_day.py --buyers 50 --stock 10`.

The script records the opening inventory as a restock, runs one concurrent order attempt
per simulated customer, marks successful fixture orders completed for the report preview,
and refreshes the report inside a transaction that is rolled back. It then removes the
fixture customers, product, categories, orders, and movement rows. Cleanup runs on normal
completion and handled errors. PostgreSQL sequence counters still advance, leaving normal
gaps in generated ids after fixtures are removed. The simulation can consume 400 PostgreSQL
connections, so use it only against the lab server when it has enough room. Its timings are
local lab measurements, not a production-capacity promise. See
`docs/flash_sale_simulation.md` for the detailed lifecycle and assumptions.

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
order-level cumulative balances are available through `customer_running_total`. Spend uses
`orders.total_amount`, the order-header amount recorded as charged at checkout. The report
counts statuses whose trimmed lowercase value is `complete`, `completed`, or `shipped`.
The supplied data has 15 spellings across five status meanings; pending, cancelled, and
refunded orders are excluded because they are not completed spend kept by the business.
See `docs/adr/ADR-008-monday-report.md` for the assumption and its risks. The report uses
the date in `report_settings` as its as-of date. It starts with 2026-11-23, the last
non-future order date in the supplied data. Customer rows are not merged by email.

The report totals and monthly spend are materialized views. After new orders arrive, update
the report cutoff and refresh both summaries together with the procedure:

```sql
CALL refresh_monday_report(DATE '2026-11-30');
```

The procedure changes the cutoff and refreshes both views in one transaction, so report
readers see the old or new snapshot, not a mix. It uses regular materialized-view refreshes,
which may briefly block report readers while the summaries are rebuilt. Re-running the
solution script rebuilds those objects and should happen when readers are not using the report.

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

The non-validated stock check blocks new negative quantities while leaving the 14 supplied
legacy negative rows for physical reconciliation. List those products with:

```sql
SELECT product_id, product_name, stock_quantity
FROM products
WHERE stock_quantity < 0
ORDER BY product_id;
```

Physically count a product first. If the recorded quantity is -3 and the confirmed shelf
count is 8, record a correction of +11. Use the actual product id, count, date, and staff
member in the call:

```sql
SELECT *
FROM record_stock_movement(
    1234,
    11,
    'correction',
    'Physical count on 2026-11-26; counted by staff member'
);
```

The product id and quantities above are an example; replace them with the result of the
physical count. Do not run the example unchanged.

The correction must bring the final quantity to zero or above. Until then, PostgreSQL may
reject even an unrelated update to that negative-stock row.

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
- `simulation/flash_sale_day.py` — runs the integrated flash-sale scenario and writes a
  local HTML scorecard plus JSON output.
- `results/` — saved diagnosis, race-test, and performance output. The final product-stock
  race evidence is `results/race_test/race_test_run_5.txt`; the final customer-link evidence
  is `results/race_test/customer_link_checks.txt`. Runs 1–4 are earlier history.
- `docs/data_diagnosis.md` — risk-ranked diagnosis of the supplied data.
- `docs/key_decisions.md` and `docs/adr/` — project decisions and supporting records.
- `docs/memo_to_nana.md` — client memo in the supplied template.
- `docs/improvement.md` — the extra stock reconciliation improvement.
- `docs/flash_sale_simulation.md` — simulation scope, checks, cleanup, and limitations.

Never save `DATABASE_URL`, passwords, or customer email addresses in `results/`. The
diagnosis scripts and their saved outputs use aggregates and ids instead of customer contact
details; the checked-in results contain no connection URLs or email addresses.
