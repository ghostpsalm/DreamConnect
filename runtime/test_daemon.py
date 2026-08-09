#!/usr/bin/env python3
"""Unit tests for the daemon's control-protocol parser (ControlServer.handle)
and for the backstage/virtual-monitor capture wiring.

No live Wayland/D-Bus needed: a stub session records the calls handle() makes,
and the virtual-mode tests only exercise pure string/argument construction.
Run: python3 -m unittest runtime.test_daemon   (or: python3 runtime/test_daemon.py)
"""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_daemon as d  # noqa: E402


class StubSession:
    def __init__(self):
        self.calls = []
        self.width, self.height, self.node_id = 1920, 1080, 66

    def motion_abs(self, x, y): self.calls.append(("M", x, y))
    def button(self, b, s): self.calls.append(("B", b, s))
    def axis_discrete(self, a, s): self.calls.append(("W", a, s))
    def key_code(self, k, s): self.calls.append(("K", k, s))
    def key_sym(self, k, s): self.calls.append(("KS", k, s))


class TestHandle(unittest.TestCase):
    def setUp(self):
        self.s = StubSession()
        self.cs = d.ControlServer("/tmp/dreamconnect-test-unused.sock", self.s)

    # control commands reply
    def test_ping(self):
        self.assertEqual(self.cs.handle("PING"), "PONG")

    def test_geom(self):
        self.assertEqual(self.cs.handle("GEOM"), "1920 1080")

    def test_node(self):
        self.assertEqual(self.cs.handle("NODE"), "66")

    def test_empty_is_ignored(self):
        self.assertIsNone(self.cs.handle(""))

    def test_unknown_command_errors(self):
        self.assertTrue(self.cs.handle("BOGUS").startswith("ERR"))

    # input commands are fire-and-forget (return None) and dispatch correctly
    def test_move_returns_none_and_dispatches(self):
        self.assertIsNone(self.cs.handle("M 100 200"))
        self.assertEqual(self.s.calls[-1], ("M", 100.0, 200.0))

    def test_button_press(self):
        self.assertIsNone(self.cs.handle("B 272 1"))
        self.assertEqual(self.s.calls[-1], ("B", 272, True))

    def test_button_release(self):
        self.assertIsNone(self.cs.handle("B 272 0"))
        self.assertEqual(self.s.calls[-1], ("B", 272, False))

    def test_wheel(self):
        self.assertIsNone(self.cs.handle("W 0 -1"))
        self.assertEqual(self.s.calls[-1], ("W", 0, -1))

    def test_key(self):
        self.assertIsNone(self.cs.handle("K 30 0"))
        self.assertEqual(self.s.calls[-1], ("K", 30, False))

    def test_keysym(self):
        self.assertIsNone(self.cs.handle("KS 97 1"))
        self.assertEqual(self.s.calls[-1], ("KS", 97, True))

    # malformed input must not reply (no desync) and must not dispatch
    def test_malformed_input_returns_none_and_stream_stays_aligned(self):
        self.assertIsNone(self.cs.handle("M"))          # missing args
        self.assertIsNone(self.cs.handle("K notanint 1"))
        self.assertEqual(self.s.calls, [])              # nothing dispatched
        # the next control command still replies correctly
        self.assertEqual(self.cs.handle("PING"), "PONG")


class TestFrameBufferReclaim(unittest.TestCase):
    """A stale /dev/shm frame left by a previous install — a different account,
    e.g. after switching to a display-host account — makes every write fail with
    EACCES and the operator sees a permanently frozen desktop (issue #27). The
    daemon must reclaim the path rather than log the same error forever."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "frame")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_creates_a_frame_when_the_path_is_free(self):
        fb = d.FrameBuffer(self.path)
        fb.ensure(4, 2, 16)
        self.assertTrue(os.path.exists(self.path))
        self.assertEqual((fb.width, fb.height, fb.stride), (4, 2, 16))

    def test_reclaims_a_frame_it_cannot_open(self):
        # Stand in for "owned by another uid": a file we cannot open read-write.
        with open(self.path, "wb") as f:
            f.write(b"stale")
        os.chmod(self.path, 0o000)
        fb = d.FrameBuffer(self.path)
        fb.ensure(4, 2, 16)          # must not raise
        self.assertEqual((fb.width, fb.height, fb.stride), (4, 2, 16))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_reclaimed_frame_is_actually_writable(self):
        with open(self.path, "wb") as f:
            f.write(b"stale")
        os.chmod(self.path, 0o000)
        fb = d.FrameBuffer(self.path)
        fb.write(b"\xff" * 32, 4, 2, 16)
        self.assertEqual(fb.seq, 1)

    def test_gives_an_actionable_error_when_it_cannot_reclaim(self):
        # Unlink blocked too (no write permission on the directory) — the daemon
        # cannot fix this itself, so it must say who owns the path.
        with open(self.path, "wb") as f:
            f.write(b"stale")
        os.chmod(self.path, 0o000)
        os.chmod(self.dir, 0o500)
        try:
            fb = d.FrameBuffer(self.path)
            with self.assertRaises(OSError) as caught:
                fb.ensure(4, 2, 16)
            self.assertIn(self.path, str(caught.exception))
        finally:
            os.chmod(self.dir, 0o700)


class TestParseResolution(unittest.TestCase):
    """--virtual takes WxH and must refuse anything that would reach Mutter as
    a nonsense virtual monitor size."""

    def test_parses_a_plain_resolution(self):
        self.assertEqual(d.parse_resolution("1920x1080"), (1920, 1080))

    def test_accepts_uppercase_x(self):
        self.assertEqual(d.parse_resolution("1280X720"), (1280, 720))

    def test_tolerates_surrounding_whitespace(self):
        self.assertEqual(d.parse_resolution("  1600x900 "), (1600, 900))

    def test_rejects_missing_separator(self):
        with self.assertRaises(ValueError):
            d.parse_resolution("1920")

    def test_rejects_non_numeric(self):
        with self.assertRaises(ValueError):
            d.parse_resolution("wide x tall")

    def test_rejects_zero_and_negative(self):
        for bad in ("0x1080", "1920x0", "-1920x1080"):
            with self.assertRaises(ValueError, msg=bad):
                d.parse_resolution(bad)

    def test_rejects_absurdly_large(self):
        # A typo like 192000x1080 would have the daemon allocate a ~800 MB shm
        # frame per update; refuse it at the boundary instead.
        with self.assertRaises(ValueError):
            d.parse_resolution("192000x1080")

    def test_accepts_the_documented_maximum(self):
        self.assertEqual(d.parse_resolution("16384x16384"), (16384, 16384))


class TestPipelineDescription(unittest.TestCase):
    """RecordVirtual hands back a stream with no intrinsic size: the consumer
    must request one or PipeWire negotiates 1x1 (verified against mutter 50.1).
    The RecordMonitor/RecordArea paths must keep negotiating freely, because
    there the size comes from the monitor."""

    def _session(self, **kw):
        return d.Session(None, "HDMI-2", None, **kw)

    def test_virtual_mode_pins_the_requested_size(self):
        s = self._session(virtual=(1600, 900))
        s.node_id = 42
        desc = s._pipeline_desc()
        self.assertIn("width=1600", desc)
        self.assertIn("height=900", desc)

    def test_monitor_mode_requests_no_size(self):
        s = self._session()
        s.node_id = 42
        desc = s._pipeline_desc()
        self.assertNotIn("width=", desc)
        self.assertNotIn("height=", desc)

    def test_both_modes_keep_the_node_and_the_bgrx_format(self):
        for kw in ({}, {"virtual": (1920, 1080)}):
            s = self._session(**kw)
            s.node_id = 77
            desc = s._pipeline_desc()
            self.assertIn("path=77", desc)
            self.assertIn("format=BGRx", desc)
            self.assertIn("appsink name=sink", desc)

    def test_virtual_mode_is_off_by_default(self):
        self.assertIsNone(self._session().virtual)


if __name__ == "__main__":
    unittest.main()
