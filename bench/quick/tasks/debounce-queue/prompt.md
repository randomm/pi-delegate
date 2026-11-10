`Debouncer.flush()` in debounce.py is broken: it inspects `_pending` under
the lock and returns without waiting for the in-flight timers, so items
still inside their quiet window are never delivered and the boolean verdict
is wrong. Fix `flush(timeout=None)` to block until every pending submit has
been delivered and return True, or return False once `timeout` seconds have
elapsed (None = wait as long as needed). Coalescing and delivery stay as
they are; do not busy-wait — reuse the existing timer objects. Add tests
under `tests/` covering: burst coalescing delivered by flush, flush of two
keys, flush on an empty debouncer, and the timeout path (a delivery that
never completes must make flush return False, not hang). Standard library
only. Do not commit.

Verification command: `python3 -m unittest discover -s tests`
