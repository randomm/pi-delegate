import threading


class Debouncer:
    """Coalesce rapid submits per key: `deliver(key, value)` runs once per
    key, `delay` seconds after the last submit for that key.

    A pending burst for one key must result in exactly one delivery of the
    latest value.
    """

    def __init__(self, delay, deliver):
        self.delay = delay
        self.deliver = deliver
        self._lock = threading.Lock()
        self._pending = {}
        self._timers = {}

    def submit(self, key, value):
        with self._lock:
            self._pending[key] = value
            t = self._timers.get(key)
            if t is not None:
                t.cancel()
            t = threading.Timer(self.delay, self._fire, args=(key,))
            t.daemon = True
            self._timers[key] = t
            t.start()

    def _fire(self, key):
        with self._lock:
            value = self._pending.pop(key, None)
            self._timers.pop(key, None)
        if value is not None:
            self.deliver(key, value)

    def flush(self, timeout=None):
        """Deliver every pending submit and return True; return False if the
        wait exceeds `timeout` seconds (None = wait as long as needed).

        BUG: does not wait at all. Items still inside their quiet window
        are not delivered, and the method reports the wrong verdict. (The
        daemon flag on the timers keeps a never-fired timer from blocking
        interpreter shutdown; keep it.)
        """
        with self._lock:
            n = len(self._pending)
        return n == 0
