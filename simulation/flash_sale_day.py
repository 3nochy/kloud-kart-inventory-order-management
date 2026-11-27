#!/usr/bin/env python3
"""Run a disposable, end-to-end Kloud Kart flash-sale simulation.

The script uses the existing PostgreSQL database, creates isolated negative-id
fixtures, and removes them in a finally block. It writes a self-contained HTML
dashboard and a JSON summary under results/simulation/.

Run from the project root with DATABASE_URL set:
    python simulation/flash_sale_day.py
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from html import escape
import json
import os
from pathlib import Path
import random
import secrets
import statistics
import sys
import threading
import time
import uuid

try:
    import psycopg2
    from psycopg2 import sql
except ImportError:
    sys.exit("psycopg2 is not installed. Run: pip install -r requirements.txt")


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "results" / "simulation"
DSN = os.environ.get("DATABASE_URL")
CATEGORY_NAMES = (
    "Simulation Electronics",
    "Simulation Phones",
    "Simulation Phone Accessories",
    "Simulation Cases",
)
CONNECTION_RESERVE = 8
CONNECT_TIMEOUT_SECONDS = 20
ORDER_TIMEOUT_SECONDS = 45
FIXTURE_PRICE = Decimal("100.00")


@dataclass
class Fixture:
    run_id: str
    category_ids: list[int]
    product_id: int
    customer_ids: list[int]
    created: bool = False


@dataclass
class Attempt:
    success: bool = False
    message: str = ""
    error: str = ""
    latency_seconds: float = 0.0


def connect(*, autocommit: bool = False):
    if not DSN:
        raise RuntimeError("Set DATABASE_URL to the Kloud Kart PostgreSQL database")
    connection = psycopg2.connect(DSN, connect_timeout=CONNECT_TIMEOUT_SECONDS)
    connection.autocommit = autocommit
    return connection


@contextmanager
def managed_connection():
    """Commit on success, roll back on error, and always close the socket."""
    connection = connect()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def unused_negative_ids(cursor, table: str, column: str, count: int) -> list[int]:
    """Choose random unused negative integers without relying on max(id)+offset."""
    chosen: list[int] = []
    while len(chosen) < count:
        candidates = [-(secrets.randbelow(2_000_000_000) + 1) for _ in range(count * 3)]
        query = sql.SQL("SELECT {column} FROM {table} WHERE {column} = ANY(%s)").format(
            column=sql.Identifier(column),
            table=sql.Identifier(table),
        )
        cursor.execute(query, (candidates,))
        occupied = {row[0] for row in cursor.fetchall()}
        for candidate in candidates:
            if candidate not in occupied and candidate not in chosen:
                chosen.append(candidate)
                if len(chosen) == count:
                    break
    return chosen


def inspect_server(buyers: int) -> dict[str, int]:
    with managed_connection() as connection, connection.cursor() as cursor:
        cursor.execute("SHOW max_connections")
        max_connections = int(cursor.fetchone()[0])
        cursor.execute("SELECT count(*) FROM pg_stat_activity")
        current_connections = int(cursor.fetchone()[0])
        if current_connections + buyers + CONNECTION_RESERVE > max_connections:
            available = max(0, max_connections - current_connections - CONNECTION_RESERVE)
            raise RuntimeError(
                f"This server has room for about {available} simulation connections after "
                f"reserving {CONNECTION_RESERVE}; requested {buyers}. Reduce --buyers or "
                "use a lab server with more connection capacity."
            )

        cursor.execute("SELECT count(*) FROM inventory_reconciliation_queue")
        stock_log_mismatches = int(cursor.fetchone()[0])
        cursor.execute(
            """WITH item_totals AS (
                   SELECT order_id,
                          sum(quantity * unit_price) AS items_total
                   FROM order_items
                   GROUP BY order_id
               )
               SELECT
                   (SELECT count(*)
                    FROM orders
                    JOIN item_totals USING (order_id)
                    WHERE orders.total_amount IS DISTINCT FROM item_totals.items_total),
                   (SELECT count(*)
                    FROM orders
                    WHERE orders.customer_id IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM customers
                          WHERE customers.customer_id = orders.customer_id
                      )),
                   (SELECT count(*) FROM orders WHERE customer_id IS NULL),
                   (SELECT count(DISTINCT status) FROM orders)"""
        )
        (
            order_total_item_mismatches,
            orphan_orders,
            orders_with_null_customer,
            distinct_status_spellings,
        ) = (int(value) for value in cursor.fetchone())
    return {
        "max_connections": max_connections,
        "connections_before_run": current_connections,
        "stock_log_mismatches_before_run": stock_log_mismatches,
        "order_total_item_mismatches_before_run": order_total_item_mismatches,
        "orphan_orders_before_run": orphan_orders,
        "orders_with_null_customer_before_run": orders_with_null_customer,
        "distinct_status_spellings_before_run": distinct_status_spellings,
    }


def create_fixtures(run_id: str, buyers: int, stock: int) -> Fixture:
    fixture = Fixture(run_id, [], 0, [])
    with managed_connection() as connection, connection.cursor() as cursor:
        fixture.category_ids = unused_negative_ids(cursor, "categories", "category_id", 4)
        fixture.product_id = unused_negative_ids(cursor, "products", "product_id", 1)[0]
        fixture.customer_ids = unused_negative_ids(cursor, "customers", "customer_id", buyers)

        for index, (category_id, category_name) in enumerate(
            zip(fixture.category_ids, CATEGORY_NAMES, strict=True)
        ):
            parent_id = fixture.category_ids[index - 1] if index else None
            cursor.execute(
                "INSERT INTO categories (category_id, category_name, parent_id) "
                "VALUES (%s, %s, %s)",
                (category_id, f"{category_name} [{run_id}]", parent_id),
            )

        cursor.execute(
            """INSERT INTO products
               (product_id, product_name, category_id, price, stock_quantity, created_at)
               VALUES (%s, %s, %s, %s, 0, now())""",
            (
                fixture.product_id,
                f"SIMULATION FIXTURE {run_id}",
                fixture.category_ids[-1],
                FIXTURE_PRICE,
            ),
        )

        for buyer_number, customer_id in enumerate(fixture.customer_ids, start=1):
            cursor.execute(
                """INSERT INTO customers (customer_id, full_name, email, registered_at)
                   VALUES (%s, %s, %s, now())""",
                (
                    customer_id,
                    f"Simulation Buyer {run_id} {buyer_number:04d}",
                    f"{uuid.uuid4()}@example.invalid",
                ),
            )

        # Record the simulated opening inventory, so the movement log reconciles to
        # the final stock after the sale instead of starting from an unexplained 50.
        cursor.execute(
            "SELECT success, new_stock, message FROM record_stock_movement(%s, %s, %s, %s)",
            (
                fixture.product_id,
                stock,
                "restock",
                f"Simulation {run_id}: opening inventory",
            ),
        )
        success, new_stock, message = cursor.fetchone()
        if not success or new_stock != stock:
            raise RuntimeError(f"Could not record simulation opening stock: {message}")
        connection.commit()
        fixture.created = True
    return fixture


def place_one_order(
    customer_id: int,
    product_id: int,
    barrier: threading.Barrier,
    result: Attempt,
) -> None:
    connection = None
    try:
        connection = connect(autocommit=True)
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT set_config('statement_timeout', %s, false)",
                (f"{ORDER_TIMEOUT_SECONDS}s",),
            )
            barrier.wait(timeout=ORDER_TIMEOUT_SECONDS)
            started = time.perf_counter()
            cursor.execute(
                "SELECT success, message FROM place_order(%s, %s, 1)",
                (customer_id, product_id),
            )
            row = cursor.fetchone()
            result.latency_seconds = time.perf_counter() - started
            if row is None:
                result.error = "place_order returned no row"
            else:
                result.success = bool(row[0])
                result.message = row[1] or ""
    except threading.BrokenBarrierError:
        result.error = "buyer group could not reach the start barrier"
    except Exception as error:  # surfaced in the dashboard as a failed call
        result.error = type(error).__name__
        try:
            barrier.abort()
        except Exception:
            pass
    finally:
        if connection is not None:
            connection.close()


def run_sale(fixture: Fixture, buyers: int, seed: int) -> tuple[list[Attempt], float]:
    customers = fixture.customer_ids.copy()
    random.Random(seed).shuffle(customers)
    barrier = threading.Barrier(buyers)
    attempts = [Attempt() for _ in range(buyers)]
    threads = [
        threading.Thread(
            target=place_one_order,
            args=(customers[index], fixture.product_id, barrier, attempts[index]),
            name=f"simulation-buyer-{index + 1}",
            daemon=True,
        )
        for index in range(buyers)
    ]

    started = time.perf_counter()
    started_threads = []
    try:
        for thread in threads:
            thread.start()
            started_threads.append(thread)
    except Exception:
        barrier.abort()
        for thread in started_threads:
            thread.join()
        raise

    deadline = time.monotonic() + ORDER_TIMEOUT_SECONDS + 10
    try:
        for thread in started_threads:
            thread.join(timeout=max(0, deadline - time.monotonic()))
            if time.monotonic() >= deadline:
                break
    except KeyboardInterrupt:
        barrier.abort()
        for thread in started_threads:
            thread.join()
        raise
    elapsed = time.perf_counter() - started

    still_running = [thread.name for thread in started_threads if thread.is_alive()]
    if still_running:
        barrier.abort()
        for thread in started_threads:
            thread.join()
        raise RuntimeError(
            f"Some buyer workers did not finish: {', '.join(still_running[:5])}"
        )
    return attempts, elapsed


def complete_simulated_orders(fixture: Fixture) -> int:
    """Move successful test orders from pending to completed for the report stage."""
    with managed_connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            """UPDATE orders
               SET status = 'completed'
               WHERE order_id IN (
                   SELECT DISTINCT order_items.order_id
                   FROM order_items
                   WHERE order_items.product_id = %s
               )""",
            (fixture.product_id,),
        )
        updated = cursor.rowcount
        connection.commit()
    return updated


def inventory_snapshot(fixture: Fixture, threshold: int) -> dict:
    with managed_connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            "SELECT stock_quantity FROM products WHERE product_id = %s",
            (fixture.product_id,),
        )
        stock_after = int(cursor.fetchone()[0])

        cursor.execute(
            """SELECT count(*) FILTER (WHERE reason = 'restock'),
                      count(*) FILTER (WHERE reason = 'sale'),
                      count(*) FILTER (WHERE order_id IS NOT NULL),
                      coalesce(sum(change_qty), 0)
               FROM inventory_log
               WHERE product_id = %s""",
            (fixture.product_id,),
        )
        opening_rows, sale_rows, linked_sale_rows, logged_net_stock = cursor.fetchone()

        cursor.execute(
            "SELECT count(*) FROM inventory_reconciliation_queue WHERE product_id = %s",
            (fixture.product_id,),
        )
        reconciliation_rows = int(cursor.fetchone()[0])

        cursor.execute(
            """SELECT bucket_type, category_id, category_name, depth, category_path,
                      product_count, stock_units, low_stock_product_count,
                      low_stock_units
               FROM low_stock_by_category(%s)
               WHERE category_id = ANY(%s)
               ORDER BY depth""",
            (threshold, fixture.category_ids),
        )
        category_rows = [
            {
                "bucket_type": row[0],
                "category_id": row[1],
                "category_name": row[2],
                "depth": row[3],
                "category_path": row[4],
                "product_count": int(row[5]),
                "stock_units": int(row[6]),
                "low_stock_product_count": int(row[7]),
                "low_stock_units": int(row[8]),
            }
            for row in cursor.fetchall()
        ]

    return {
        "stock_after": stock_after,
        "opening_movement_rows": int(opening_rows),
        "sale_movement_rows": int(sale_rows),
        "order_linked_movement_rows": int(linked_sale_rows),
        "logged_net_stock": int(logged_net_stock),
        "reconciliation_queue_rows": reconciliation_rows,
        "category_rollup": category_rows,
    }


def simulate_report(fixture: Fixture) -> dict:
    """Refresh/read the report in a transaction, then roll it all back."""
    connection = connect()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT CURRENT_DATE")
            report_date = cursor.fetchone()[0]

            started = time.perf_counter()
            cursor.execute("CALL refresh_monday_report(%s)", (report_date,))
            refresh_seconds = time.perf_counter() - started

            started = time.perf_counter()
            cursor.execute(
                """SELECT count(*),
                          coalesce(sum(total_spent), 0),
                          coalesce(sum(order_count), 0),
                          count(*) FILTER (WHERE spend_rank <= 100),
                          min(spend_rank), max(spend_rank),
                          coalesce(sum(month_12_spend), 0)
                   FROM monday_report
                   WHERE customer_id = ANY(%s)""",
                (fixture.customer_ids,),
            )
            (
                customer_rows,
                spend,
                order_count,
                top_100_customers,
                lowest_rank,
                highest_rank,
                current_month_spend,
            ) = cursor.fetchone()

            cursor.execute(
                """SELECT count(*), coalesce(sum(running_total), 0)
                   FROM (
                       SELECT DISTINCT ON (customer_id)
                              customer_id, running_total
                       FROM customer_running_total
                       WHERE customer_id = ANY(%s)
                       ORDER BY customer_id, order_date DESC, order_id DESC
                   ) AS final_customer_balances""",
                (fixture.customer_ids,),
            )
            running_customer_count, running_total_sum = cursor.fetchone()
            report_read_seconds = time.perf_counter() - started

        # Preserve the project report settings and the stored report snapshots.
        connection.rollback()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    return {
        "as_of_date": report_date.isoformat(),
        "refresh_seconds": refresh_seconds,
        "fixture_read_seconds": report_read_seconds,
        "fixture_customers": int(customer_rows),
        "fixture_spend": float(spend),
        "fixture_order_count": int(order_count),
        "fixture_customers_in_top_100": int(top_100_customers),
        "lowest_fixture_rank": int(lowest_rank) if lowest_rank is not None else None,
        "highest_fixture_rank": int(highest_rank) if highest_rank is not None else None,
        "fixture_current_month_spend": float(current_month_spend),
        "fixture_customers_with_running_total": int(running_customer_count),
        "fixture_running_total_sum": float(running_total_sum),
        "refresh_rolled_back": True,
    }


def cleanup_fixtures(fixture: Fixture) -> None:
    if not fixture.created:
        return
    with managed_connection() as connection, connection.cursor() as cursor:
        cursor.execute(
            "SELECT order_id FROM orders WHERE customer_id = ANY(%s)",
            (fixture.customer_ids,),
        )
        order_ids = [row[0] for row in cursor.fetchall()]
        cursor.execute(
            "DELETE FROM inventory_log WHERE product_id = %s OR order_id = ANY(%s)",
            (fixture.product_id, order_ids),
        )
        if order_ids:
            cursor.execute("DELETE FROM order_items WHERE order_id = ANY(%s)", (order_ids,))
            cursor.execute("DELETE FROM orders WHERE order_id = ANY(%s)", (order_ids,))
        cursor.execute("DELETE FROM products WHERE product_id = %s", (fixture.product_id,))
        cursor.execute("DELETE FROM customers WHERE customer_id = ANY(%s)", (fixture.customer_ids,))
        cursor.execute("DELETE FROM categories WHERE category_id = ANY(%s)", (fixture.category_ids,))
        cursor.execute(
            """SELECT
                   (SELECT count(*) FROM products WHERE product_id = %s),
                   (SELECT count(*) FROM customers WHERE customer_id = ANY(%s)),
                   (SELECT count(*) FROM categories WHERE category_id = ANY(%s)),
                   (SELECT count(*) FROM orders WHERE customer_id = ANY(%s)),
                   (SELECT count(*) FROM order_items WHERE product_id = %s),
                   (SELECT count(*) FROM inventory_log WHERE product_id = %s)""",
            (
                fixture.product_id,
                fixture.customer_ids,
                fixture.category_ids,
                fixture.customer_ids,
                fixture.product_id,
                fixture.product_id,
            ),
        )
        remaining = cursor.fetchone()
        if any(remaining):
            raise RuntimeError("one or more simulation fixture rows remain after cleanup")
        connection.commit()


def percentile(values: list[float], percent: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = round((len(ordered) - 1) * percent)
    return ordered[index]


def build_payload(args, baseline: dict, fixture: Fixture, attempts: list[Attempt],
                  elapsed_seconds: float, inventory: dict, report: dict,
                  timeline: list[dict]) -> dict:
    succeeded = sum(attempt.success for attempt in attempts)
    failed_stock = sum(
        not attempt.success and not attempt.error
        and "out of stock" in attempt.message.lower()
        for attempt in attempts
    )
    errors = len(attempts) - succeeded - failed_stock
    latencies = [attempt.latency_seconds for attempt in attempts if attempt.latency_seconds > 0]
    expected_sales = min(args.buyers, args.stock)
    expected_end_stock = args.stock - expected_sales
    category_rows = inventory["category_rollup"]
    root = next((row for row in category_rows if row["depth"] == 0), None)

    checks = {
        "accepted orders equal the available stock or buyer count": succeeded == expected_sales,
        "every refused buyer received an out-of-stock response": failed_stock == args.buyers - expected_sales,
        "no buyer call errored": errors == 0,
        "ending stock equals opening stock less successful sales": inventory["stock_after"] == expected_end_stock,
        "audit log stock movement totals equal ending stock": inventory["logged_net_stock"] == expected_end_stock,
        "each successful sale has one order-linked movement": inventory["order_linked_movement_rows"] == succeeded,
        "sale movement count equals successful sales": inventory["sale_movement_rows"] == succeeded,
        "the simulated product is absent from the reconciliation queue": inventory["reconciliation_queue_rows"] == 0,
        "recursive rollup includes the complete four-level path": len(category_rows) == len(fixture.category_ids),
        "root rollup flags the simulated product at the low-stock threshold": bool(
            root
            and root["low_stock_product_count"] == (1 if expected_end_stock <= args.threshold else 0)
            and root["stock_units"] == expected_end_stock
        ),
        "Monday report includes all simulated customers and completed sales": (
            report["fixture_customers"] == args.buyers
            and report["fixture_order_count"] == succeeded
            and round(report["fixture_spend"], 2) == round(float(FIXTURE_PRICE * succeeded), 2)
            and round(report["fixture_current_month_spend"], 2)
            == round(float(FIXTURE_PRICE * succeeded), 2)
            and report["fixture_customers_with_running_total"] == succeeded
            and round(report["fixture_running_total_sum"], 2)
            == round(float(FIXTURE_PRICE * succeeded), 2)
        ),
        "report refresh transaction was rolled back": report["refresh_rolled_back"],
    }

    return {
        "title": "Kloud Kart Flash-Sale Day Simulation",
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "run_id": fixture.run_id,
        "scenario": {
            "buyers": args.buyers,
            "opening_stock": args.stock,
            "unit_price": float(FIXTURE_PRICE),
            "low_stock_threshold": args.threshold,
            "seed": args.seed,
            "category_path": " / ".join(
                f"{category_name} [{fixture.run_id}]" for category_name in CATEGORY_NAMES
            ),
        },
        "baseline": baseline,
        "flash_sale": {
            "accepted_orders": succeeded,
            "out_of_stock_responses": failed_stock,
            "errors": errors,
            "wall_clock_seconds": elapsed_seconds,
            "median_call_ms": statistics.median(latencies) * 1000 if latencies else 0,
            "p95_call_ms": percentile(latencies, 0.95) * 1000 if latencies else 0,
        },
        "inventory": inventory,
        "report": report,
        "timeline": timeline,
        "checks": checks,
        "passed": all(checks.values()),
    }


def render_html(payload: dict) -> str:
    sale = payload["flash_sale"]
    inventory = payload["inventory"]
    report = payload["report"]
    scenario = payload["scenario"]
    good = payload["passed"]
    cleanup_succeeded = payload["checks"].get("all disposable fixtures were removed", False)
    cleanup_note = (
        "All simulation fixtures were removed when the run finished."
        if cleanup_succeeded
        else "Fixture cleanup did not finish; use the run id with cleanup_interrupted_run.sql."
    )
    check_rows = "\n".join(
        "<tr><td>{}</td><td class=\"{}\">{}</td></tr>".format(
            escape(label), "pass" if passed else "fail", "PASS" if passed else "FAIL"
        )
        for label, passed in payload["checks"].items()
    )
    timeline_rows = "\n".join(
        "<tr><td>{}</td><td>{:.2f}s</td><td>{}</td></tr>".format(
            escape(item["stage"]),
            item["seconds"],
            escape(item["detail"]),
        )
        for item in payload["timeline"]
    )
    category_rows = "\n".join(
        "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
            escape(row["category_path"]),
            row["stock_units"],
            row["low_stock_product_count"],
            row["low_stock_units"],
            scenario["low_stock_threshold"],
        )
        for row in inventory["category_rollup"]
    )
    ratio = sale["accepted_orders"] / max(scenario["buyers"], 1)
    accepted_width = round(ratio * 100, 1)
    refused_width = round(sale["out_of_stock_responses"] / max(scenario["buyers"], 1) * 100, 1)
    error_width = max(0, round(100 - accepted_width - refused_width, 1))
    status_text = "ALL CHECKS PASSED" if good else "CHECKS NEED ATTENTION"

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(payload['title'])}</title>
  <style>
    :root {{ color-scheme: light; --ink:#172235; --muted:#64748b; --line:#dbe3ef;
      --paper:#f4f7fb; --card:#fff; --blue:#2457d6; --green:#138a5b; --red:#c43d4b; }}
    * {{ box-sizing:border-box; }} body {{ margin:0; background:var(--paper); color:var(--ink);
      font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif; }}
    main {{ max-width:1100px; margin:0 auto; padding:32px 20px 56px; }}
    header {{ background:#132544; color:white; padding:28px; border-radius:18px; }}
    header h1 {{ margin:0 0 6px; font-size:clamp(25px,4vw,38px); }}
    header p {{ color:#d4dff2; margin:0; }}
    .badge {{ display:inline-block; margin-top:18px; padding:6px 11px; border-radius:99px;
      background:#173d35; color:#b5f1d5; font-size:12px; font-weight:800; letter-spacing:.06em; }}
    .badge.fail {{ background:#542a32; color:#ffd0d2; }}
    .grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:14px; margin:18px 0; }}
    .card {{ background:var(--card); border:1px solid var(--line); border-radius:14px; padding:18px; }}
    .metric {{ font-size:29px; line-height:1.15; font-weight:750; margin:5px 0; }}
    .label {{ color:var(--muted); font-size:13px; }} h2 {{ margin:28px 0 10px; font-size:21px; }}
    table {{ border-collapse:collapse; width:100%; background:var(--card); border-radius:12px;
      overflow:hidden; border:1px solid var(--line); }} th,td {{ text-align:left; padding:10px 12px;
      border-bottom:1px solid var(--line); vertical-align:top; }} th {{ background:#edf2fa; font-size:13px; }}
    tr:last-child td {{ border-bottom:0; }} .pass {{ color:var(--green); font-weight:800; }}
    .fail {{ color:var(--red); font-weight:800; }} .bar {{ display:flex; height:22px; overflow:hidden;
      border-radius:99px; background:#e7edf6; margin:12px 0 6px; }}
    .sold {{ width:{accepted_width}%; background:var(--green); }}
    .refused {{ width:{refused_width}%; background:#e4a83c; }}
    .errored {{ width:{error_width}%; background:var(--red); }}
    .legend {{ display:flex; gap:18px; color:var(--muted); font-size:13px; }}
    .note {{ color:var(--muted); font-size:13px; }} code {{ background:#edf2fa; padding:2px 5px; border-radius:4px; }}
    @media(max-width:600px) {{ main {{ padding:16px 12px 36px; }} header {{ padding:21px; }} th,td {{ padding:8px; }} }}
  </style>
</head>
<body><main>
  <header>
    <h1>{escape(payload['title'])}</h1>
    <p>Repeatable lab run · {scenario['buyers']} buyers · {scenario['opening_stock']} units ·
       {escape(scenario['category_path'])}</p>
    <span class="badge {'fail' if not good else ''}">{status_text}</span>
  </header>

  <section class="grid" aria-label="Simulation scorecard">
    <article class="card"><div class="label">Orders accepted</div><div class="metric">{sale['accepted_orders']}</div>
      <div class="label">of {scenario['buyers']} attempts</div></article>
    <article class="card"><div class="label">Out-of-stock replies</div><div class="metric">{sale['out_of_stock_responses']}</div>
      <div class="label">clear refusals, with no order</div></article>
    <article class="card"><div class="label">Ending stock</div><div class="metric">{inventory['stock_after']}</div>
      <div class="label">logged net: {inventory['logged_net_stock']}</div></article>
    <article class="card"><div class="label">Flash-sale elapsed</div><div class="metric">{sale['wall_clock_seconds']:.2f}s</div>
      <div class="label">median call {sale['median_call_ms']:.1f} ms · p95 {sale['p95_call_ms']:.1f} ms</div></article>
    <article class="card"><div class="label">Report refresh</div><div class="metric">{report['refresh_seconds']:.2f}s</div>
      <div class="label">rolled back after the report snapshot</div></article>
    <article class="card"><div class="label">Starting stock/log differences</div><div class="metric">{payload['baseline']['stock_log_mismatches_before_run']}</div>
      <div class="label">from the reconciliation queue</div></article>
  </section>

  <h2>Buyer outcomes</h2>
  <div class="bar" role="img" aria-label="Accepted, out-of-stock, and error buyer outcomes">
    <div class="sold"></div><div class="refused"></div><div class="errored"></div>
  </div>
  <div class="legend"><span>■ Accepted: {sale['accepted_orders']}</span>
    <span>■ Out of stock: {sale['out_of_stock_responses']}</span>
    <span>Errors: {sale['errors']}</span></div>

  <h2>Starting data-quality signals</h2>
  <p class="note">These are measurements from the loaded lab data before fixtures were added.
     The simulation reports them; it does not guess which side is correct or alter them.</p>
  <table><thead><tr><th>Signal</th><th>Rows or values</th></tr></thead><tbody>
    <tr><td>Products with counter/log differences</td><td>{payload['baseline']['stock_log_mismatches_before_run']}</td></tr>
    <tr><td>Orders whose header differs from item totals</td><td>{payload['baseline']['order_total_item_mismatches_before_run']}</td></tr>
    <tr><td>Orders linked to a missing customer</td><td>{payload['baseline']['orphan_orders_before_run']}</td></tr>
    <tr><td>Orders with a null customer id</td><td>{payload['baseline']['orders_with_null_customer_before_run']}</td></tr>
    <tr><td>Distinct stored status spellings</td><td>{payload['baseline']['distinct_status_spellings_before_run']}</td></tr>
  </tbody></table>

  <h2>Inventory and category rollup</h2>
  <p class="note">The opening restock and each sale were written to the movement log. The recursive
     rollup follows the full nested path; the threshold is {scenario['low_stock_threshold']} units.</p>
  <table><thead><tr><th>Category path</th><th>Stock units</th><th>Low-stock products</th>
    <th>Low-stock units</th><th>Threshold</th></tr></thead><tbody>{category_rows}</tbody></table>
  <p class="note">Audit movements: {inventory['opening_movement_rows']} opening restock,
     {inventory['sale_movement_rows']} sale rows, {inventory['order_linked_movement_rows']}
     linked to orders. Reconciliation-queue entries for the test product:
     {inventory['reconciliation_queue_rows']}.</p>

  <h2>Monday report preview</h2>
  <p>The simulation temporarily marked successful test orders completed, refreshed the report
     through {escape(report['as_of_date'])}, and read only its synthetic customers. The
     transaction was rolled back, so the lab report cutoff and stored summaries were preserved.</p>
  <div class="grid">
    <article class="card"><div class="label">Synthetic customers shown</div><div class="metric">{report['fixture_customers']}</div></article>
    <article class="card"><div class="label">Completed simulated orders</div><div class="metric">{report['fixture_order_count']}</div></article>
    <article class="card"><div class="label">Simulated spend</div><div class="metric">GHS {report['fixture_spend']:,.2f}</div></article>
    <article class="card"><div class="label">Spend in report's current month</div><div class="metric">GHS {report['fixture_current_month_spend']:,.2f}</div></article>
    <article class="card"><div class="label">Synthetic customers in top 100</div><div class="metric">{report['fixture_customers_in_top_100']}</div>
      <div class="label">report read: {report['fixture_read_seconds']:.3f}s</div></article>
    <article class="card"><div class="label">Running totals matched</div><div class="metric">{report['fixture_customers_with_running_total']}</div>
      <div class="label">final balances sum to GHS {report['fixture_running_total_sum']:,.2f}</div></article>
  </div>

  <h2>Checks</h2>
  <table><thead><tr><th>Invariant</th><th>Result</th></tr></thead><tbody>{check_rows}</tbody></table>

  <h2>Event timeline</h2>
  <table><thead><tr><th>Stage</th><th>Time</th><th>What happened</th></tr></thead>
    <tbody>{timeline_rows}</tbody></table>

  <h2>Run details</h2>
  <p class="note">Run id <code>{escape(payload['run_id'])}</code> · seed {scenario['seed']} ·
     generated {escape(payload['generated_at'])}. {escape(cleanup_note)}</p>
  <p class="note">PostgreSQL sequence counters still advance, so the removed orders leave normal
     gaps in generated ids. If the process is forcibly stopped, recovery instructions are in
     <code>docs/flash_sale_simulation.md</code>.</p>
  <p class="note">This is a local lab result, not a production-capacity guarantee. The 400-buyer
     case opens 400 database connections and should only run where PostgreSQL has room for them.</p>
</main></body></html>
"""


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--buyers", type=int, default=400, help="simultaneous one-unit buyers (default: 400)")
    parser.add_argument("--stock", type=int, default=50, help="opening units for the test product (default: 50)")
    parser.add_argument("--threshold", type=int, default=5, help="low-stock threshold (default: 5)")
    parser.add_argument("--seed", type=int, default=20261127, help="buyer launch-order seed")
    args = parser.parse_args()
    if not 1 <= args.buyers <= 400:
        parser.error("--buyers must be between 1 and 400")
    if not 1 <= args.stock <= 2_147_483_647:
        parser.error("--stock must be a positive PostgreSQL integer")
    if not 0 <= args.threshold <= 2_147_483_647:
        parser.error("--threshold must be a non-negative PostgreSQL integer")
    return args


def main() -> int:
    args = parse_args()
    run_id = uuid.uuid4().hex[:12]
    fixture = Fixture(run_id, [], 0, [])
    baseline = inspect_server(args.buyers)
    attempts: list[Attempt] = []
    elapsed_seconds = 0.0
    payload = None
    cleanup_error = None
    timeline = []

    print("Kloud Kart Flash-Sale Day Simulation")
    print(f"Scenario: {args.buyers} buyers, {args.stock} units, threshold {args.threshold}")
    print(f"Fixture run id: {run_id}")
    print(f"Baseline stock/log differences: {baseline['stock_log_mismatches_before_run']}")

    try:
        stage_started = time.perf_counter()
        fixture = create_fixtures(run_id, args.buyers, args.stock)
        timeline.append({
            "stage": "Create fixtures and opening stock",
            "seconds": time.perf_counter() - stage_started,
            "detail": f"{args.buyers} synthetic customers and the four-level test category",
        })

        stage_started = time.perf_counter()
        attempts, elapsed_seconds = run_sale(fixture, args.buyers, args.seed)
        timeline.append({
            "stage": "Flash sale",
            "seconds": time.perf_counter() - stage_started,
            "detail": f"{args.buyers} simultaneous order attempts",
        })

        stage_started = time.perf_counter()
        completed_orders = complete_simulated_orders(fixture)
        timeline.append({
            "stage": "Complete successful test orders",
            "seconds": time.perf_counter() - stage_started,
            "detail": f"{completed_orders} orders advanced to completed for report preview",
        })

        stage_started = time.perf_counter()
        inventory = inventory_snapshot(fixture, args.threshold)
        timeline.append({
            "stage": "Audit and category rollup",
            "seconds": time.perf_counter() - stage_started,
            "detail": "Check stock movements, reconciliation queue, and all category levels",
        })

        stage_started = time.perf_counter()
        report = simulate_report(fixture)
        timeline.append({
            "stage": "Monday report preview",
            "seconds": time.perf_counter() - stage_started,
            "detail": "Refresh and read synthetic customers inside a rolled-back transaction",
        })
        payload = build_payload(
            args, baseline, fixture, attempts, elapsed_seconds, inventory, report, timeline
        )
        payload["completed_orders"] = completed_orders
    finally:
        cleanup_started = time.perf_counter()
        try:
            cleanup_fixtures(fixture)
            timeline.append({
                "stage": "Fixture cleanup",
                "seconds": time.perf_counter() - cleanup_started,
                "detail": "Remove test customers, product, categories, orders, and stock movements",
            })
        except Exception as error:
            cleanup_error = type(error).__name__

    if payload is None:
        raise RuntimeError("Simulation stopped before a report could be produced")
    if cleanup_error:
        payload["checks"]["all disposable fixtures were removed"] = False
        payload["passed"] = False
        payload["cleanup_error"] = cleanup_error
    else:
        payload["checks"]["all disposable fixtures were removed"] = True
        payload["passed"] = all(payload["checks"].values())
    payload["timeline"] = timeline

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    json_path = OUTPUT_DIR / "flash_sale_day.json"
    html_path = OUTPUT_DIR / "flash_sale_day.html"
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    html_path.write_text(render_html(payload), encoding="utf-8")

    print(f"Accepted: {payload['flash_sale']['accepted_orders']}")
    print(f"Out of stock: {payload['flash_sale']['out_of_stock_responses']}")
    print(f"Errors: {payload['flash_sale']['errors']}")
    print(f"Checks: {'PASSED' if payload['passed'] else 'FAILED'}")
    print(f"Dashboard: {html_path.relative_to(ROOT)}")
    print(f"Machine-readable summary: {json_path.relative_to(ROOT)}")
    return 0 if payload["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Simulation interrupted; fixture cleanup was attempted.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        print(f"Simulation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
