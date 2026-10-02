import io, json, unittest
from contextlib import redirect_stdout
import cli
def run(*a):
    b = io.StringIO()
    with redirect_stdout(b):
        rc = cli.main(list(a))
    return rc, b.getvalue()
class T(unittest.TestCase):
    def test_json(self):
        rc, out = run("--json", "1", "2", "3")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), {"count": 3, "min": 1.0, "max": 3.0, "mean": 2.0})
        self.assertEqual(out.strip(), json.dumps(json.loads(out), sort_keys=True))
    def test_default(self):
        self.assertEqual(run("4", "6")[1], "count: 2\nmin: 4.0\nmax: 6.0\nmean: 5.0\n")
    def test_noargs(self):
        with self.assertRaises(SystemExit) as c:
            run()
        self.assertEqual(c.exception.code, 2)
unittest.main()
