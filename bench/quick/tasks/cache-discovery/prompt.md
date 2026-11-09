The TTL cache in cache.py is misbehaving under memory pressure: entries a
user has just read are the first to disappear — a key read a moment ago is
evicted while a cold key nobody touches survives. Fix the cache so this
cannot happen; keep the TTL behaviour and the public API (`get`, `put`,
`len`, constructor signature) exactly as they are. You need to find the
cause yourself. Standard library only. Do not commit.

Verification command: `python3 -c "from cache import Cache; c = Cache(2, 100); c.put('a', 1); c.put('b', 2); c.get('a'); c.put('c', 3); assert c.get('a') == 1 and c.get('b') is None"`
