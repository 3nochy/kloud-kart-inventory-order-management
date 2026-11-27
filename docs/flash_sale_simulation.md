# Flash-Sale Day Simulation

## Purpose

`simulation/flash_sale_day.py` runs a disposable business-day scenario through the
project's existing PostgreSQL solution. It connects order placement, the stock audit,
the recursive low-stock rollup, and the Monday report in one repeatable run. It uses no
external service or additional database.

## What one run does

1. Checks PostgreSQL's connection limit and counts the existing stock/log mismatches.
2. Creates synthetic customers, a product, and a four-level category tree with unused
   negative IDs. It records the opening stock through `record_stock_movement` as a
   restock, so the test product's movement log has a known starting point.
3. Releases one order attempt per synthetic buyer together at a barrier. Each call uses
   the project's `place_order` function and a separate PostgreSQL connection.
4. Marks successful test orders completed so the report's documented status rule includes
   them in the preview. It checks final stock against accepted orders and the movement log.
5. Queries the category rollup for every level of the test tree and checks the test product
   against the selected low-stock threshold.
6. Calls `refresh_monday_report` using the database's current date, reads synthetic
   customers' totals, current-month spend, order counts, running balances, and top-100
   positions, then rolls the transaction back. The normal report cutoff and stored
   summaries therefore remain as they were before the preview.
7. Deletes the synthetic customers, product, category rows, orders, order items, and
   inventory movements. The report files contain counts and timings, not customer emails
   or database connection details. PostgreSQL sequence counters are not rolled back, so
   the removed orders leave normal gaps in generated ids.

## Checks shown in the scorecard

- Accepted sales equal the lesser of buyer count and opening stock.
- Every remaining buyer receives an out-of-stock response, and no call errors.
- Ending stock equals opening stock minus successful sales.
- Opening and sale movements reconcile to ending stock; every successful sale has a
  movement linked to its order.
- The simulated product no longer appears in `inventory_reconciliation_queue`.
- The recursive rollup includes the entire four-level path and applies the threshold.
- The report preview includes the fixture customers, completed simulated orders, current-
  month spend, and running balances.
- The report refresh transaction is rolled back and fixtures are cleaned up.

The HTML dashboard is saved at `results/simulation/flash_sale_day.html`; the matching
machine-readable summary is `results/simulation/flash_sale_day.json`. Each new run replaces
these latest-run files. The random run ID separates its disposable fixtures from other lab
data. A fixed seed controls buyer launch order, but operating-system scheduling means the
identity of the winning buyers can differ from run to run.

## Run and limits

```sh
python simulation/flash_sale_day.py
```

The default run opens 400 concurrent database connections, so the script stops before
starting if the server does not appear to have enough free capacity. This is a significant
load on a small server. Run it against the lab database when it is idle, not while the
business is using the database. `--buyers`, `--stock`, `--threshold`, and `--seed` can
change the scenario.

The simulation is a controlled lab demonstration, not a production load test. It exercises
one product and one order line per checkout, and its report preview refreshes the full
materialized summaries. Local timings do not prove how a networked production system will
behave. Cleanup runs on normal completion, Python exceptions, and a handled interrupt; a
forced process kill or machine failure can stop cleanup midway. The run id is printed before
fixtures are created. If interruption leaves fixtures behind, remove them with:

```sh
docker exec -w /lab -i kloudkart psql -U postgres -v ON_ERROR_STOP=1 \
  -v run_id=012345abcdef -f simulation/cleanup_interrupted_run.sql
```

Replace the example with the printed run id. Cleanup removes that run's fixtures; generated
sequence counters remain advanced.
