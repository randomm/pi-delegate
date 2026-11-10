"""Sales summary CLI."""
import argparse
import sys

from format import render
from report import summarize

DATA = [
    ("north", "widget", 3, 9.99),
    ("north", "gizmo", 1, 25.00),
    ("south", "widget", 2, 9.99),
]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    totals = summarize(DATA)
    if args.json:
        import json
        print(json.dumps(totals, sort_keys=True))
    else:
        print(render(totals))
    return 0


if __name__ == "__main__":
    sys.exit(main())
