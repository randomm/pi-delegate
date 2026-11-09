"""Sales summary CLI — all logic currently lives here."""
import argparse
import sys


def summarize(rows):
    """rows: list of (region, product, qty, unit_price) -> nested totals."""
    totals = {}
    for region, product, qty, price in rows:
        region_totals = totals.setdefault(region, {})
        region_totals[product] = region_totals.get(product, 0) + qty * price
    return totals


def render(totals):
    lines = []
    for region in sorted(totals):
        lines.append(f"{region}:")
        for product in sorted(totals[region]):
            lines.append(f"  {product} {totals[region][product]:.2f}")
    return "\n".join(lines)


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
