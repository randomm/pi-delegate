Add monthly budgets to the ledger package (run tests with
`python3 -m unittest discover -s tests`).

- `Store.set_budget(category: str, cents: int)` stores a monthly spending
  limit per category (cents > 0). `Store.budgets()` returns a dict
  category -> cents.
- Spending is the sum of negative amounts (as positive cents) in a category in
  a month. New function `ledger.report.over_budget(store) -> list[tuple[str,
  str, int, int]]` returning `(month, category, spent_cents, budget_cents)`
  for every month/category where spent > budget, sorted by month then
  category. Categories without a budget are ignored; refunds (positive
  amounts) do not reduce spending below zero.
- Budgets can also be declared in the loaded text as a line
  `#budget,<category>,<amount>` (e.g. `#budget,food,300.00`); `Store.load`
  must apply them (they are currently ignored as comments). Other `#` lines
  stay comments.
- CLI: `ledger over-budget` prints one line per result:
  `YYYY-MM  <category>  spent <money> / budget <money>` (use `fmt.money`).

Standard library only; keep existing tests passing; add tests for the new
behaviour. Do not commit.

Verification command: `python3 -m unittest discover -s tests`
