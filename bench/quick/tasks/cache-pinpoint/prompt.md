`Cache` in cache.py evicts by insertion age, not use: `get()` returns a
hit without touching `self._store` order, so `put()`'s eviction loop drops
`next(iter(self._store))` — the oldest *written* entry, even one read a
moment ago. Fix it so a read counts as use (move the hit key to the
most-recently-used end; plain dict order is enough, no new imports). Keep
TTL behaviour and the public API identical. Standard library only. Do not
commit.

Verification command: `python3 -c "from cache import Cache; c = Cache(2, 100); c.put('a', 1); c.put('b', 2); c.get('a'); c.put('c', 3); assert c.get('a') == 1 and c.get('b') is None"`
