"""Tiny TTL cache; when full, the oldest entry is evicted.

Users report that entries they just read are still evicted first: reads
should count as use, so the *least recently used* entry is the one that
must go when the cache is full.
"""
import time


class Cache:
    def __init__(self, capacity, ttl, clock=time.monotonic):
        if capacity < 1:
            raise ValueError("capacity must be >= 1")
        self.capacity = capacity
        self.ttl = ttl
        self.clock = clock
        self._store = {}   # key -> [value, written_at], dict order = age

    def get(self, key):
        hit = self._store.get(key)
        if hit is None:
            return None
        value, written = hit
        if self.clock() - written >= self.ttl:
            del self._store[key]
            return None
        return value

    def put(self, key, value):
        if key in self._store:
            self._store[key] = [value, self.clock()]
            return
        while len(self._store) >= self.capacity:
            oldest = next(iter(self._store))
            del self._store[oldest]
        self._store[key] = [value, self.clock()]

    def __len__(self):
        return len(self._store)
