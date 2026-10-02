Add recurring transactions to this ledger package (run tests with
`python3 -m unittest discover -s tests`).

- A line may have a fifth CSV field `repeat=monthly`
  (`YYYY-MM-DD,amount,category,memo,repeat=monthly`; memo may be empty).
  `Transaction` gets an optional `repeat` field (None or "monthly").
- `Store.expand(until: date)` returns all transactions sorted like `all()`,
  with each monthly-repeating transaction repeated on the same day of every
  following month up to and including `until` (clamp the day to the month
  length, e.g. the 31st -> 28/29/30). Non-repeating ones appear once.
- `monthly_totals(store, until=None)` and `render(store, until=None)` use
  `expand(until)` when `until` is given, otherwise behave as before.
- CLI: `ledger report --until YYYY-MM-DD`.

Standard library only; keep existing tests passing; add tests for the new
behaviour. Do not commit.

Verification command: `python3 -m unittest discover -s tests`
