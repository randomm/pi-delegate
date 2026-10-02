Add CSV export to the ledger package (run tests with
`python3 -m unittest discover -s tests`).

- New module `ledger/export.py` with `to_csv(store) -> str`: header
  `date,amount,category,memo`, then one row per transaction in `store.all()`
  order; `amount` formatted with `fmt.money`; fields quoted per RFC 4180 when
  they contain a comma, quote or newline (use the `csv` module, `\n` line
  terminator).
- `Store.filter(category=None, month=None)` returns the matching transactions
  (month like `2024-01`); `to_csv(store, category=None, month=None)` exports
  only those.
- CLI: `ledger export [--category C] [--month YYYY-MM]` prints exactly the CSV text, with no extra trailing blank line.
  The `command` choices in ledger/cli.py must keep `report`.

Standard library only; keep existing tests passing; add tests. Do not commit.

Verification command: `python3 -m unittest discover -s tests`
