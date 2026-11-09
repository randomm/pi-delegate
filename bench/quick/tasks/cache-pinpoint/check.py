import unittest
from cache import Cache
class FakeClock:
    def __init__(self):
        self.t = 0.0
    def __call__(self):
        return self.t
    def advance(self, dt):
        self.t += dt
class T(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.c = Cache(2, ttl=10.0, clock=self.clock)
    def test_lru_keeps_read_entry(self):
        self.c.put("a", 1)
        self.c.put("b", 2)
        self.assertEqual(self.c.get("a"), 1)   # a is now the most recently used
        self.c.put("c", 3)                     # must evict b, not a
        self.assertEqual(self.c.get("a"), 1)
        self.assertIsNone(self.c.get("b"))
        self.assertEqual(self.c.get("c"), 3)
    def test_lru_read_protects_during_eviction_run(self):
        self.c.put("a", 1)
        self.c.put("b", 2)
        for i in range(5):
            self.c.get("a")
            self.c.put(f"t{i}", i)
        self.assertEqual(self.c.get("a"), 1)
    def test_ttl_still_expires(self):
        self.c.put("a", 1)
        self.clock.advance(9.9)
        self.assertEqual(self.c.get("a"), 1)
        self.clock.advance(0.2)
        self.assertIsNone(self.c.get("a"))
    def test_put_refreshes_ttl(self):
        self.c.put("a", 1)
        self.clock.advance(9.0)
        self.c.put("a", 2)
        self.clock.advance(9.0)
        self.assertEqual(self.c.get("a"), 2)
    def test_update_existing_does_not_grow(self):
        self.c.put("a", 1)
        self.c.put("a", 2)
        self.assertEqual(len(self.c), 1)
        self.assertEqual(self.c.get("a"), 2)
    def test_capacity_validation(self):
        with self.assertRaises(ValueError):
            Cache(0, ttl=1.0)
unittest.main()
