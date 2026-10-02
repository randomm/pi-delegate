from .models import Transaction, parse_line


class Store:
    def __init__(self):
        self._items: list[Transaction] = []

    def add(self, tx: Transaction) -> None:
        self._items.append(tx)

    def load(self, text: str) -> None:
        for line in text.splitlines():
            if line.strip() and not line.startswith("#"):
                self.add(parse_line(line))

    def all(self) -> list[Transaction]:
        return sorted(self._items, key=lambda t: (t.day, t.category))

    def by_category(self, category: str) -> list[Transaction]:
        return [t for t in self.all() if t.category == category]
