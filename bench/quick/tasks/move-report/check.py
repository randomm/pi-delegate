import importlib, io, unittest
from contextlib import redirect_stdout
class T(unittest.TestCase):
    def test_moved(self):
        report = importlib.import_module("report")
        fmt = importlib.import_module("format")
        self.assertEqual(
            report.summarize([("n", "w", 3, 10.0)]), {"n": {"w": 30.0}})
        self.assertEqual(fmt.render({"n": {"w": 30.0}}), "n:\n  w 30.00")
    def test_no_leftover_copies(self):
        src = open("cli.py").read()
        self.assertNotIn("def summarize", src)
        self.assertNotIn("def render", src)
    def test_cli_behaviour_unchanged(self):
        import cli
        b = io.StringIO()
        with redirect_stdout(b):
            self.assertEqual(cli.main([]), 0)
        self.assertEqual(b.getvalue(), "north:\n  gizmo 25.00\n  widget 29.97\nsouth:\n  widget 19.98\n")
    def test_cli_json_unchanged(self):
        import cli, json
        b = io.StringIO()
        with redirect_stdout(b):
            self.assertEqual(cli.main(["--json"]), 0)
        got = json.loads(b.getvalue())
        self.assertEqual(sorted(got), ["north", "south"])
        self.assertAlmostEqual(got["north"]["widget"], 29.97)
        self.assertAlmostEqual(got["south"]["widget"], 19.98)
        self.assertEqual(got["north"]["gizmo"], 25.0)
unittest.main()
