import io, unittest
from datetime import date
from ledger.cli import main
from ledger.models import parse_line
from ledger.report import monthly_totals
from ledger.store import Store
class T(unittest.TestCase):
    def test_parse(self):
        t = parse_line("2024-01-31,-10.00,rent,flat,repeat=monthly")
        self.assertEqual(t.repeat, "monthly")
        self.assertIsNone(parse_line("2024-01-31,-10.00,rent").repeat)
        self.assertIsNone(parse_line("2024-01-31,-10.00,rent,memo").repeat)
        self.assertEqual(parse_line("2024-01-31,-10.00,rent,,repeat=monthly").repeat, "monthly")
    def test_expand(self):
        s = Store()
        s.load("2024-01-31,-10.00,rent,,repeat=monthly\n2024-02-10,1.00,x\n")
        days = [(t.day, t.category) for t in s.expand(date(2024, 4, 30))]
        self.assertEqual(days, [(date(2024,1,31),"rent"),(date(2024,2,10),"x"),(date(2024,2,29),"rent"),(date(2024,3,31),"rent"),(date(2024,4,30),"rent")])
    def test_totals(self):
        s = Store()
        s.load("2024-01-31,-10.00,rent,,repeat=monthly\n")
        self.assertEqual(monthly_totals(s), {"2024-01": -1000})
        self.assertEqual(monthly_totals(s, date(2024, 3, 31)), {"2024-01": -1000, "2024-02": -1000, "2024-03": -1000})
    def test_cli(self):
        import contextlib
        b = io.StringIO()
        with contextlib.redirect_stdout(b):
            main(["report", "--until", "2024-02-29"], stdin=io.StringIO("2024-01-31,-10.00,rent,,repeat=monthly\n"))
        self.assertIn("2024-02", b.getvalue())
unittest.main()
