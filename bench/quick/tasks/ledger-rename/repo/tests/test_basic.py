import unittest
from ledger.fmt import money
from ledger.report import monthly_totals, render
from ledger.store import Store


class T(unittest.TestCase):
    def test_money(self):
        self.assertEqual(money(-1250), "-12.50")

    def test_totals(self):
        s = Store()
        s.load("2024-01-05,-10.00,food\n2024-01-20,5.50,refund\n2024-02-01,-1.00,food\n")
        self.assertEqual(monthly_totals(s), {"2024-01": -450, "2024-02": -100})
        self.assertIn("2024-01", render(s))


if __name__ == "__main__":
    unittest.main()
