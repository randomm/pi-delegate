import signal, threading, unittest
import debounce

# Timing task (class ASYNC_TIMING): every scenario runs under a wall-clock
# alarm so an implementation (or a fix) that waits forever scores FAIL
# instead of hanging the harness.
ALARM = signal.SIGALRM if hasattr(signal, "SIGALRM") else None


class bounded(unittest.TestCase):
    def run(self, result):
        if ALARM is None:
            return super().run(result)
        def on_alarm(signum, frame):
            raise TimeoutError("flush did not return within the bound")
        old = signal.signal(ALARM, on_alarm)
        signal.alarm(10)
        try:
            return super().run(result)
        except TimeoutError:
            result.addError(self, sys_exc_info())
            return None
        finally:
            signal.alarm(0)
            signal.signal(ALARM, old)


def sys_exc_info():
    import sys
    return sys.exc_info()


class T(bounded):
    def setUp(self):
        self.delivered = []
        self.lock = threading.Lock()
        self.d = debounce.Debouncer(0.05, self._deliver)

    def _deliver(self, key, value):
        with self.lock:
            self.delivered.append((key, value))

    def test_flush_delivers_latest_of_burst(self):
        for i in range(5):
            self.d.submit("a", i)
        self.assertTrue(self.d.flush(2.0))
        self.assertEqual(self.delivered, [("a", 4)])

    def test_flush_two_keys(self):
        self.d.submit("a", 1)
        self.d.submit("b", 2)
        self.assertTrue(self.d.flush(2.0))
        self.assertEqual(sorted(self.delivered), [("a", 1), ("b", 2)])

    def test_flush_empty_is_true(self):
        self.assertTrue(self.d.flush(1.0))
        self.assertEqual(self.delivered, [])

    def test_flush_reports_false_on_timeout(self):
        # Timer fires in 30 s; a 0.1 s flush must report False, not hang.
        d = debounce.Debouncer(30.0, lambda k, v: None)
        d.submit("a", 1)
        self.assertFalse(d.flush(0.1))

    def test_new_submit_after_flush_still_delivers(self):
        self.d.submit("a", 1)
        self.d.flush(2.0)
        self.d.submit("a", 2)
        self.assertTrue(self.d.flush(2.0))
        self.assertEqual(sorted(self.delivered), [("a", 1), ("a", 2)])
unittest.main()
