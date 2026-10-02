from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class Transaction:
    day: date
    amount_cents: int
    category: str
    memo: str = ""

    def __post_init__(self):
        if not self.category:
            raise ValueError("category required")
        if not isinstance(self.amount_cents, int):
            raise TypeError("amount_cents must be int")

    @property
    def month(self) -> str:
        return f"{self.day.year:04d}-{self.day.month:02d}"


def parse_line(line: str) -> Transaction:
    """Parse 'YYYY-MM-DD,amount,category[,memo]' (amount like -12.50)."""
    parts = line.strip().split(",", 3)
    if len(parts) < 3:
        raise ValueError(f"bad line: {line!r}")
    y, m, d = (int(x) for x in parts[0].split("-"))
    amount = round(float(parts[1]) * 100)
    memo = parts[3] if len(parts) > 3 else ""
    return Transaction(date(y, m, d), amount, parts[2], memo)
