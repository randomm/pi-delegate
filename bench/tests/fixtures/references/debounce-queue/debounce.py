import threading
import time


class Debouncer:
    """Coalesce rapid submits per key: `deliver(key, value)` runs once per
    key, `delay` seconds after the last submit for that key."""

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
        if value is not None:
            self.deliver(key, value)
        # Drop the timer only after deliver() returned, so flush() — which
        # joins live timers — cannot return before the delivery happened.
        with self._lock:
            self._timers.pop(key, None)

    def flush(self, timeout=None):
        """Wait until every pending submit has been delivered; return True,
        or False once `timeout` seconds have elapsed (None = wait forever).
        """
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            with self._lock:
                timers = list(self._timers.values())
            if not timers:
                return True
            for t in timers:
                if deadline is None:
                    t.join()
                    continue
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                t.join(remaining)
