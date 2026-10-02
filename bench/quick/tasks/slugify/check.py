import unittest
from textutil import slugify
class T(unittest.TestCase):
    def test_all(self):
        self.assertEqual(slugify("Hello, World!"), "hello-world")
        self.assertEqual(slugify("  Café  au   lait "), "cafe-au-lait")
        self.assertEqual(slugify("--a__b--"), "a-b")
        self.assertEqual(slugify("!!!"), "")
        self.assertEqual(slugify(""), "")
        self.assertEqual(slugify("Ünïcödé 42"), "unicode-42")
unittest.main()
