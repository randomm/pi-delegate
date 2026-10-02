import contextlib, io, unittest
from ledger.cli import main
from ledger.report import over_budget
from ledger.store import Store
TXT = ("#budget,food,300.00\n#comment,ignored\n"
       "2024-01-03,-200.00,food\n2024-01-10,-150.00,food\n2024-01-11,50.00,food\n"
       "2024-02-01,-100.00,food\n2024-01-05,-999.00,travel\n")
class T(unittest.TestCase):
    def test_api(self):
        s = Store(); s.load(TXT)
        self.assertEqual(s.budgets(), {"food": 30000})
        self.assertEqual(over_budget(s), [("2024-01", "food", 35000, 30000)])
        s.set_budget("travel", 50000)
        self.assertEqual(over_budget(s)[1], ("2024-01", "travel", 99900, 50000))
        with self.assertRaises(ValueError):
            s.set_budget("x", 0)
    def test_cli(self):
        b = io.StringIO()
        with contextlib.redirect_stdout(b):
            main(["over-budget"], stdin=io.StringIO(TXT))
        self.assertEqual(b.getvalue().split(), "2024-01 food spent 350.00 / budget 300.00".split())
unittest.main()
