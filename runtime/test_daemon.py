#!/usr/bin/env python3
"""Unit tests for the daemon's control-protocol parser (ControlServer.handle).

No live Wayland/D-Bus needed: a stub session records the calls handle() makes.
Run: python3 -m unittest runtime.test_daemon   (or: python3 runtime/test_daemon.py)
"""
import os
import sys
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


if __name__ == "__main__":
    unittest.main()
