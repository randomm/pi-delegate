import unittest
from ranges import merge
class T(unittest.TestCase):
    def test_all(self):
        self.assertEqual(merge([(1, 2), (2, 3)]), [(1, 3)])
        self.assertEqual(merge([(1, 10), (2, 3)]), [(1, 10)])
        self.assertEqual(merge([(5, 6), (1, 2), (2, 4)]), [(1, 4), (5, 6)])
        self.assertEqual(merge([]), [])
        self.assertEqual(merge([(1, 2), (4, 5)]), [(1, 2), (4, 5)])
unittest.main()
