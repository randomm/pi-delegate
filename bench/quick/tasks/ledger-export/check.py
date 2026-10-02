import contextlib, io, unittest
from ledger.cli import main
from ledger.export import to_csv
from ledger.store import Store
from datetime import date
from ledger.models import Transaction
TXT = '2024-02-01,5.50,refund\n2024-01-20,-3.00,coffee,x\n'
def mk():
    s = Store(); s.load(TXT)
    s.add(Transaction(date(2024, 1, 5), -1000, "food", 'lunch, with "team"'))
    return s
class T(unittest.TestCase):
    def test_csv(self):
        s = mk()
        self.assertEqual(to_csv(s).splitlines()[0], "date,amount,category,memo")
        self.assertIn('2024-01-05,-10.00,food,"lunch, with ""team"""', to_csv(s))
        self.assertEqual(len(to_csv(s).splitlines()), 4)
        self.assertEqual(len(to_csv(s, month="2024-01").splitlines()), 3)
        self.assertEqual(len(to_csv(s, category="refund").splitlines()), 2)
        self.assertEqual(len(s.filter(category="food", month="2024-01")), 1)
    def test_cli(self):
        b = io.StringIO()
        with contextlib.redirect_stdout(b):
            main(["export", "--month", "2024-02"], stdin=io.StringIO(TXT))
        self.assertEqual(b.getvalue().splitlines(), ["date,amount,category,memo", "2024-02-01,5.50,refund,"])
unittest.main()
