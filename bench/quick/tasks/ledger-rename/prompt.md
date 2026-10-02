Rename the `amount_cents` field of `Transaction` (ledger/models.py) to
`cents` everywhere in the ledger package and its tests, keeping behaviour
identical. Update every use (models, store, report, cli, tests). Do not leave
the old name anywhere under ledger/ or tests/. Standard library only; keep the
tests passing. Do not commit.

Verification command: `python3 -m unittest discover -s tests`
