"""Tiny TTL cache with true LRU eviction when full."""
import time


class Cache:
    def __init__(self, capacity, ttl, clock=time.monotonic):
        if capacity < 1:
            raise ValueError("capacity must be >= 1")
        self.capacity = capacity
        self.ttl = ttl
        self.clock = clock
        self._store = {}   # key -> [value, written_at], dict order = LRU..MRU

    def get(self, key):
        hit = self._store.get(key)
        if hit is None:
            return None
        value, written = hit
        if self.clock() - written >= self.ttl:
            del self._store[key]
            return None
        # A read counts as use: move the entry to the most-recently-used
        # end so eviction drops the least recently *used* entry.
        self._store.pop(key)
        self._store[key] = hit
        return value

    def put(self, key, value):
        self._store.pop(key, None)
        while len(self._store) >= self.capacity:
            oldest = next(iter(self._store))
            del self._store[oldest]
        self._store[key] = [value, self.clock()]

    def __len__(self):
        return len(self._store)
