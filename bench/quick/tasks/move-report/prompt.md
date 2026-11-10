Move the report logic out of cli.py, exactly, without behaviour change:

- `summarize` moves from cli.py to report.py.
- `render` moves from cli.py to format.py.
- cli.py imports both and keeps `DATA`, `main` and the `--json` flag
  behaviour byte-identical; no copy of the moved functions may remain in
  cli.py (`def summarize` / `def render` must be gone from that file).

Standard library only. Do not commit.

Verification command: `python3 -c "import cli; assert cli.main([]) == 0"`
