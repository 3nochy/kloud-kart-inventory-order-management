# Improvement beyond the brief: prioritized stock count queue

## The improvement

The brief asks for a stock movement trail and low-stock visibility. I also added
`inventory_reconciliation_queue`, a view that turns the diagnosed counter/log differences
into a practical list for the stock room. It ranks products by the size of the difference
times the current product price, then shows the counter, logged net movement, unit gap,
movement count, last movement date, and reason for review.

Run it with:

```sql
SELECT *
FROM inventory_reconciliation_queue
ORDER BY review_priority
LIMIT 25;
```

## Why it helps

The diagnosis found 144 products with mismatched counts, including 87 with no likely
explanation. Rather than asking Nana to inspect all of them in an arbitrary order, this
view helps staff start with the largest estimated value exposure. The first row in the
saved result is a 46-unit difference with an estimated value of ₵745,441.50 at the current
price. That amount is a review estimate, not a confirmed loss.

## Why it does not auto-correct

The data cannot tell us whether the product counter or the log is right. Automatically
changing either one could hide the real problem. The queue only guides a physical count;
staff must confirm the shelf quantity before correcting stock.

## Implementation and evidence

- SQL view and non-validated check: `sql/solution/06_constraints_and_reconciliation.sql`.
- Check blocks new negative stock without rewriting the 14 existing negative records.
- The saved check confirmed 144 queued products and consecutive review priorities:
  `results/diagnosis/reconciliation_queue_checks.txt`.
- ADR: `docs/adr/ADR-009-stock-reconciliation-queue.md`.
