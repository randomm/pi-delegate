"""Report building."""


def summarize(rows):
    """rows: list of (region, product, qty, unit_price) -> nested totals."""
    totals = {}
    for region, product, qty, price in rows:
        region_totals = totals.setdefault(region, {})
        region_totals[product] = region_totals.get(product, 0) + qty * price
    return totals
