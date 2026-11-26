#!/usr/bin/env python3
"""Check that customer links stay valid, including a delete/order race.

Run from the project root with DATABASE_URL set. The script creates temporary lab
fixtures, rolls back every order attempt, and removes the fixtures before exiting.
"""

from __future__ import annotations

import os
import sys
import threading
import time
import uuid

try:
    import psycopg2
    from psycopg2.errors import ForeignKeyViolation
except ImportError:
    sys.exit("psycopg2 is not installed. Run: pip install -r requirements.txt")


DSN = os.environ.get("DATABASE_URL")
ORDER_APP_NAME = "kloudkart_customer_delete_race_test"
WAIT_TIMEOUT_SECONDS = 15
MAX_INT = 2_147_483_647
MIN_INT = -2_147_483_648
MISSING_CUSTOMER_ID_SEARCH_SIZE = 11


def connect(*, application_name: str | None = None, autocommit: bool = False):
    if not DSN:
        raise RuntimeError("Set DATABASE_URL to the Kloud Kart PostgreSQL database")
    kwargs = {"application_name": application_name} if application_name else {}
    connection = psycopg2.connect(DSN, **kwargs)
    connection.autocommit = autocommit
    return connection


def create_fixtures() -> tuple[int, int]:
    connection = connect()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT coalesce(max(customer_id), 0) + 1 FROM customers")
            customer_id = cursor.fetchone()[0]
            cursor.execute("SELECT coalesce(max(product_id), 0) + 1 FROM products")
            product_id = cursor.fetchone()[0]

            if customer_id > MAX_INT or product_id > MAX_INT:
                raise RuntimeError("No unused integer id remains for a temporary test fixture")

            cursor.execute(
                """
                INSERT INTO customers (customer_id, full_name, email, registered_at)
                VALUES (%s, %s, %s, now())
                """,
                (customer_id, "Customer link race test", f"{uuid.uuid4()}@example.invalid"),
            )
            cursor.execute(
                """
                INSERT INTO products (
                    product_id, product_name, price, stock_quantity, created_at
                )
                VALUES (%s, 'Customer link race test fixture', 1.00, 1, now())
                """,
                (product_id,),
            )
        connection.commit()
        return customer_id, product_id
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def cleanup_fixtures(customer_id: int, product_id: int) -> None:
    connection = connect(autocommit=True)
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                DELETE FROM inventory_log
                WHERE product_id = %s
                   OR order_id IN (SELECT order_id FROM orders WHERE customer_id = %s)
                """,
                (product_id, customer_id),
            )
            cursor.execute(
                "DELETE FROM order_items WHERE order_id IN "
                "(SELECT order_id FROM orders WHERE customer_id = %s)",
                (customer_id,),
            )
            cursor.execute("DELETE FROM orders WHERE customer_id = %s", (customer_id,))
            cursor.execute("DELETE FROM customers WHERE customer_id = %s", (customer_id,))
            cursor.execute("DELETE FROM products WHERE product_id = %s", (product_id,))
    finally:
        connection.close()


def check_invalid_customer_is_rejected() -> None:
    connection = connect()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT candidate
                FROM generate_series(%s, %s) AS candidates(candidate)
                WHERE NOT EXISTS (
                    SELECT 1 FROM customers WHERE customers.customer_id = candidate
                )
                LIMIT 1
                """,
                (MIN_INT, MIN_INT + MISSING_CUSTOMER_ID_SEARCH_SIZE - 1),
            )
            row = cursor.fetchone()
            if row is None:
                raise RuntimeError("Could not find an unused customer id for the FK check")
            missing_customer_id = row[0]

            rejected = False
            try:
                cursor.execute(
                    """
                    INSERT INTO orders (order_id, customer_id, order_date, status, total_amount)
                    VALUES (nextval('orders_order_id_seq'), %s, now(), 'pending', 1.00)
                    """,
                    (missing_customer_id,),
                )
            except ForeignKeyViolation:
                rejected = True
            finally:
                connection.rollback()

            if not rejected:
                raise AssertionError("The customer foreign key accepted a missing customer")
    finally:
        connection.close()


def check_referenced_customer_cannot_be_deleted(customer_id: int, product_id: int) -> None:
    connection = connect()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT success, order_id, message FROM place_order(%s, %s, 1)",
                (customer_id, product_id),
            )
            success, order_id, message = cursor.fetchone()
            if not success:
                raise AssertionError(f"Fixture order failed: {message}")

            cursor.execute("SAVEPOINT before_customer_delete")
            rejected = False
            try:
                cursor.execute("DELETE FROM customers WHERE customer_id = %s", (customer_id,))
            except ForeignKeyViolation:
                rejected = True
                cursor.execute("ROLLBACK TO SAVEPOINT before_customer_delete")

            if not rejected:
                raise AssertionError(f"Customer with order {order_id} was deletable")
    finally:
        # The test order, stock decrease and audit row are all discarded.
        connection.rollback()
        connection.close()


def check_delete_race(customer_id: int, product_id: int) -> None:
    delete_connection = connect(application_name="kloudkart_customer_delete_test")
    order_result: dict[str, object] = {}
    worker_started = threading.Event()
    worker_done = threading.Event()

    def place_order_while_delete_is_open() -> None:
        connection = None
        try:
            connection = connect(application_name=ORDER_APP_NAME)
            with connection.cursor() as cursor:
                worker_started.set()
                cursor.execute(
                    "SELECT success, order_id, message FROM place_order(%s, %s, 1)",
                    (customer_id, product_id),
                )
                order_result["row"] = cursor.fetchone()
        except Exception as error:  # surfaced below as a test failure
            order_result["error"] = f"{type(error).__name__}: {error}"
        finally:
            try:
                if connection is not None:
                    try:
                        connection.rollback()
                    finally:
                        connection.close()
            finally:
                worker_done.set()

    worker = None
    observer = None
    delete_committed = False
    try:
        with delete_connection.cursor() as cursor:
            cursor.execute(
                "SELECT customer_id FROM customers WHERE customer_id = %s FOR UPDATE",
                (customer_id,),
            )
            if cursor.fetchone() is None:
                raise AssertionError("Temporary customer fixture is missing")
            cursor.execute("DELETE FROM customers WHERE customer_id = %s", (customer_id,))

        worker = threading.Thread(target=place_order_while_delete_is_open, daemon=True)
        worker.start()
        if not worker_started.wait(timeout=WAIT_TIMEOUT_SECONDS):
            raise AssertionError("Order worker did not start")

        observer = connect(autocommit=True)
        deadline = time.monotonic() + WAIT_TIMEOUT_SECONDS
        saw_database_lock_wait = False
        while time.monotonic() < deadline:
            with observer.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT wait_event_type
                    FROM pg_stat_activity
                    WHERE application_name = %s AND state = 'active'
                    """,
                    (ORDER_APP_NAME,),
                )
                rows = cursor.fetchall()
            if any(row[0] == "Lock" for row in rows):
                saw_database_lock_wait = True
                break
            if worker_done.is_set():
                break
            time.sleep(0.02)

        # Release the delete so the blocked order call can finish.
        delete_connection.commit()
        delete_committed = True
        worker.join(timeout=WAIT_TIMEOUT_SECONDS)
        if worker.is_alive():
            raise AssertionError("Order worker did not finish after the delete committed")
        if not saw_database_lock_wait:
            raise AssertionError("Order call did not wait for the in-flight customer delete")
        if "error" in order_result:
            raise AssertionError(f"Order call raised an error: {order_result['error']}")

        result = order_result.get("row")
        if result is None or result[0] or result[1] is not None:
            raise AssertionError(f"Expected a clean customer refusal, got: {result}")
        if "customer not found" not in result[2].lower():
            raise AssertionError(f"Expected 'Customer not found', got: {result[2]}")

        with observer.cursor() as cursor:
            cursor.execute("SELECT count(*) FROM orders WHERE customer_id = %s", (customer_id,))
            order_count = cursor.fetchone()[0]
            cursor.execute("SELECT stock_quantity FROM products WHERE product_id = %s", (product_id,))
            stock = cursor.fetchone()[0]
        if order_count != 0 or stock != 1:
            raise AssertionError(f"Unexpected side effect: orders={order_count}, stock={stock}")
    finally:
        if not delete_committed and not delete_connection.closed:
            delete_connection.rollback()
        if worker is not None:
            worker.join(timeout=WAIT_TIMEOUT_SECONDS)
        if observer is not None:
            observer.close()
        delete_connection.close()


def main() -> int:
    customer_id = product_id = None
    exit_code = 0
    try:
        check_invalid_customer_is_rejected()
        print("PASS — database rejected an order linked to a missing customer")

        customer_id, product_id = create_fixtures()
        check_referenced_customer_cannot_be_deleted(customer_id, product_id)
        print("PASS — database refused to delete a customer with an order")

        # The previous check rolled its order back, so this customer has no orders.
        # The concurrent check deletes the fixture and proves place_order handles that race.
        check_delete_race(customer_id, product_id)
        print("PASS — concurrent delete returned Customer not found with no order or stock change")
    except Exception as error:
        print(f"FAILED — {type(error).__name__}: {error}", file=sys.stderr)
        exit_code = 1
    finally:
        if customer_id is not None and product_id is not None:
            try:
                cleanup_fixtures(customer_id, product_id)
            except Exception as error:
                print(f"Fixture cleanup failed: {error}", file=sys.stderr)
                exit_code = 1

    if exit_code == 0:
        print("PASSED — all customer-link checks completed and fixtures were removed")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
