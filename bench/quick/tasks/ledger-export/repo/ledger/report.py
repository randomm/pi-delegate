from collections import defaultdict

from .fmt import money
from .store import Store


def monthly_totals(store: Store) -> dict[str, int]:
    totals: dict[str, int] = defaultdict(int)
    for tx in store.all():
        totals[tx.month] += tx.amount_cents
    return dict(sorted(totals.items()))


def render(store: Store) -> str:
    lines = []
    for month, cents in monthly_totals(store).items():
        lines.append(f"{month}  {money(cents):>12}")
    return "\n".join(lines)
