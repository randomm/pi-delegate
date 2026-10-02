import subprocess, unittest
from datetime import date
from ledger.models import Transaction, parse_line
from ledger.report import monthly_totals
from ledger.store import Store
class T(unittest.TestCase):
    def test_field(self):
        t = Transaction(date(2024, 1, 2), 500, "x")
        self.assertEqual(t.cents, 500)
        self.assertFalse(hasattr(t, "amount_cents"))
        self.assertEqual(parse_line("2024-01-02,-1.25,food").cents, -125)
    def test_totals(self):
        s = Store(); s.load("2024-01-05,-10.00,food\n2024-01-20,5.50,refund\n")
        self.assertEqual(monthly_totals(s), {"2024-01": -450})
    def test_no_old_name(self):
        out = subprocess.run("grep -rn amount_cents --include=*.py ledger tests", shell=True, capture_output=True, text=True).stdout
        self.assertEqual(out, "")
unittest.main()
