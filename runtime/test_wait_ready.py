#!/usr/bin/env python3
"""Unit tests for the ScreenConnect start wait (#102).

No systemd and no real daemon: the readiness facts are files and a unix socket
built in a temp directory, and the clock and sleep are injected, so a daemon
that appears part-way through the wait is driven tick by tick.
Run: python3 runtime/test_wait_ready.py
"""
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_wait_ready as w  # noqa: E402
import dreamconnect_daemon as d  # noqa: E402


class _Session:
    """The surface ControlServer touches for a PING."""

    def client_connected(self):
        pass

    def client_disconnected(self):
        pass


class _FakeClock:
    """A clock that only moves when the wait sleeps, and can run a hook at a
    given time -- which is how the daemon 'comes up' mid-wait."""

    def __init__(self, at=None):
        self.now = 0.0
        self.sleeps = 0
        self.at = dict(at or {})

    def __call__(self):
        return self.now

    def sleep(self, secs):
        self.sleeps += 1
        self.now += secs
        for t in sorted(list(self.at)):
            if self.now >= t:
                self.at.pop(t)()


class _Fixture(unittest.TestCase):
    def setUp(self):
        # dir="/tmp" rather than the ambient TMPDIR, as test_daemon.py's socket
        # tests: sun_path is 108 bytes, and a long TMPDIR would make the bind
        # fail with "AF_UNIX path too long" -- a red for the wrong reason.
        self.dir = tempfile.mkdtemp(prefix="dc-wait-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.uid = os.getuid()
        self.shm = os.path.join(self.dir, "frame")
        self.sock = os.path.join(self.dir, "d.sock")
        self.env = os.path.join(self.dir, "display.env")
        self.registry = os.path.join(self.dir, "sessions")
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.close()

    def make_frame(self):
        """The frame the daemon publishes at startup, through the daemon's own
        FrameBuffer.publish: the wait ends on the file the daemon really makes,
        so a daemon that stopped publishing before its first client could not
        leave this suite green while ScreenConnect waited out its timeout."""
        d.FrameBuffer(self.shm).publish()

    def make_env(self):
        with open(self.env, "w") as f:
            f.write("DISPLAY=:2\n")

    def make_entry(self):
        os.makedirs(self.registry, exist_ok=True)
        with open(os.path.join(self.registry, str(self.uid)), "w") as f:
            f.write("uid=%d\n" % self.uid)

    def start_daemon(self):
        """The real ControlServer's protocol on a real socket, so a PING that
        the daemon would not answer PONG cannot pass here."""
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock)
        srv.listen(4)
        self.servers.append(srv)
        cs = d.ControlServer(self.sock, _Session())

        def serve():
            while True:
                try:
                    conn, _ = srv.accept()
                except OSError:
                    return
                threading.Thread(target=cs._client, args=(conn,), daemon=True).start()

        threading.Thread(target=serve, daemon=True).start()

    def make_all(self):
        self.make_frame()
        self.start_daemon()
        self.make_env()
        self.make_entry()

    def missing(self, answers=w.daemon_answers):
        return w.missing(self.uid, self.shm, self.sock, self.env, self.registry, answers)

    def argv(self, timeout=150):
        return ["--uid", str(self.uid), "--shm", self.shm, "--socket", self.sock,
                "--display-env", self.env, "--registry", self.registry,
                "--timeout", str(timeout)]


class TestMissing(_Fixture):
    def test_nothing_is_missing_once_everything_is_up(self):
        self.make_all()
        self.assertEqual(self.missing(), [])

    def test_a_fresh_boot_is_missing_all_four(self):
        self.assertEqual(len(self.missing()), 4, self.missing())

    def test_a_frame_owned_by_another_uid_is_not_ready(self):
        self.make_all()
        self.assertEqual(w.missing(self.uid + 1, self.shm, self.sock, self.env,
                                   self.registry, lambda _s: True)[0:1],
                         ["frame %s" % self.shm])

    def test_a_symlinked_frame_is_not_ready(self):
        # The agent's usableShm refuses a link however it is owned; ready must
        # mean what the agent will accept, or the wait ends too early.
        target = os.path.join(self.dir, "real")
        with open(target, "wb"):
            pass
        os.symlink(target, self.shm)
        self.assertIn("frame %s" % self.shm, self.missing(lambda _s: True))

    def test_a_socket_that_does_not_answer_pong_is_not_ready(self):
        self.make_frame()
        self.make_env()
        self.make_entry()
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock)
        srv.listen(1)
        self.servers.append(srv)

        def answer_wrong():
            conn, _ = srv.accept()
            with conn:
                conn.recv(64)
                conn.sendall(b"ERR unknown cmd PING\n")

        threading.Thread(target=answer_wrong, daemon=True).start()
        self.assertEqual(self.missing(), ["daemon %s" % self.sock])

    def test_the_real_daemon_protocol_answers_the_probe(self):
        self.start_daemon()
        self.assertTrue(w.daemon_answers(self.sock))


class TestWaitReady(_Fixture):
    def test_it_waits_for_a_daemon_that_comes_up_mid_wait(self):
        # The boot order #102 was reported for: the client starts first, the
        # backstage shell and daemon some seconds later.
        clock = _FakeClock(at={5: self.make_frame, 7: self.start_daemon,
                               9: self.make_env, 11: self.make_entry})
        left = w.wait_ready(self.missing, 150, clock=clock, sleep=clock.sleep)
        self.assertEqual(left, [])
        self.assertEqual(clock.now, 11, "returned as soon as the last fact held")

    def test_it_gives_up_at_the_timeout_and_says_what_is_missing(self):
        clock = _FakeClock()
        left = w.wait_ready(self.missing, 150, clock=clock, sleep=clock.sleep)
        self.assertEqual(clock.now, 150, "the wait is bounded by --timeout")
        self.assertEqual(len(left), 4, left)

    def test_a_ready_box_does_not_sleep(self):
        self.make_all()
        clock = _FakeClock()
        self.assertEqual(w.wait_ready(self.missing, 150, clock=clock, sleep=clock.sleep), [])
        self.assertEqual(clock.sleeps, 0)


class TestMain(_Fixture):
    def test_main_returns_once_the_daemon_is_up(self):
        clock = _FakeClock(at={3: self.make_all})
        self.assertEqual(w.main(self.argv(), clock=clock, sleep=clock.sleep), 0)
        self.assertEqual(clock.now, 3)

    def test_main_never_fails_the_unit_on_timeout(self):
        # ScreenConnect must still start with the bridge broken: it is the
        # operator's way in to fix it.
        clock = _FakeClock()
        self.assertEqual(w.main(self.argv(timeout=10), clock=clock, sleep=clock.sleep), 0)
        self.assertEqual(clock.now, 10)


if __name__ == "__main__":
    unittest.main()
