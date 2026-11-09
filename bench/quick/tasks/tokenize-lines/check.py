import unittest
from linefields import split_fields
class T(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(split_fields("a,b,c"), ["a", "b", "c"])
    def test_quoted_comma(self):
        self.assertEqual(split_fields('a,"b,c",d'), ["a", "b,c", "d"])
    def test_escaped_quote(self):
        self.assertEqual(split_fields('a,"b""c",d'), ["a", 'b"c', "d"])
    def test_double_escaped(self):
        self.assertEqual(split_fields('"a""""b"'), ['a""b'])
    def test_empty_fields(self):
        self.assertEqual(split_fields("a,,b"), ["a", "", "b"])
    def test_empty(self):
        self.assertEqual(split_fields(""), [""])
    def test_quoted_empty(self):
        self.assertEqual(split_fields('"",""'), ["", ""])
    def test_close_then_comma(self):
        self.assertEqual(split_fields('"a",b'), ["a", "b"])
unittest.main()
