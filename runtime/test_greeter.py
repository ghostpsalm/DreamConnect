#!/usr/bin/env python3
"""Unit tests for greeter mode's pure translation layer and argv construction.

No Xvfb, no RDP server, no X connection: everything here is the part that must
be right *before* any process is spawned — the evdev->X11 input translation the
control socket depends on, and the command lines that decide whether a
credential leaks into argv.
Run: python3 -m unittest runtime.test_greeter  (or: python3 runtime/test_greeter.py)
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_greeter as g  # noqa: E402


class TestKeycodeTranslation(unittest.TestCase):
    def test_evdev_to_x_keycode_applies_xkb_offset(self):
        # KEY_A (30) is X keycode 38 on every XKB keymap.
        self.assertEqual(g.evdev_to_x_keycode(30), 38)

    def test_offset_is_constant_across_the_range(self):
        for evdev in (1, 30, 57, 111):
            self.assertEqual(g.evdev_to_x_keycode(evdev), evdev + 8)


class TestButtonTranslation(unittest.TestCase):
    def test_the_three_real_buttons(self):
        self.assertEqual(g.evdev_to_x_button(g.BTN_LEFT), 1)
        self.assertEqual(g.evdev_to_x_button(g.BTN_MIDDLE), 2)
        self.assertEqual(g.evdev_to_x_button(g.BTN_RIGHT), 3)

    def test_middle_and_right_are_not_swapped(self):
        # evdev numbers them LEFT, RIGHT, MIDDLE; X numbers them left, middle,
        # right. Transcribing in order silently swaps two buttons.
        self.assertNotEqual(g.evdev_to_x_button(g.BTN_RIGHT), 2)

    def test_unknown_button_is_dropped_not_raised(self):
        self.assertIsNone(g.evdev_to_x_button(0x117))


class TestAxisTranslation(unittest.TestCase):
    def test_vertical_direction(self):
        self.assertEqual(g.axis_to_x_button(g.AXIS_VERTICAL, 1), (5, 1))
        self.assertEqual(g.axis_to_x_button(g.AXIS_VERTICAL, -1), (4, 1))

    def test_horizontal_uses_the_second_pair(self):
        self.assertEqual(g.axis_to_x_button(g.AXIS_HORIZONTAL, 2), (7, 2))
        self.assertEqual(g.axis_to_x_button(g.AXIS_HORIZONTAL, -3), (6, 3))

    def test_zero_steps_is_a_no_op(self):
        self.assertEqual(g.axis_to_x_button(g.AXIS_VERTICAL, 0), (None, 0))

    def test_unknown_axis_is_dropped(self):
        self.assertEqual(g.axis_to_x_button(7, 1), (None, 0))


class TestShiftLevels(unittest.TestCase):
    """A capital typed without Shift silently arrives lowercase.

    This is the failure that has no symptom: a password goes in, PAM rejects
    it, and nothing anywhere says the characters were wrong. The lookup must
    report the shift level, not just the keycode.
    """

    class FakeX:
        # 'd'/'D' share a keycode; index 1 is the shifted level.
        MAP = {ord("d"): [(40, 0)], ord("D"): [(40, 1)],
               ord("1"): [(10, 0)], ord("!"): [(10, 1)]}

        def keysym_to_keycodes(self, keysym):
            return self.MAP.get(keysym, [])

    def setUp(self):
        self.s = g.GreeterSession.__new__(g.GreeterSession)
        self.s._x = self.FakeX()

    def test_lowercase_needs_no_shift(self):
        self.assertEqual(self.s._lookup_keysym(ord("d")), (40, False))

    def test_uppercase_needs_shift(self):
        self.assertEqual(self.s._lookup_keysym(ord("D")), (40, True))

    def test_shifted_punctuation_needs_shift(self):
        self.assertEqual(self.s._lookup_keysym(ord("!")), (10, True))

    def test_unmapped_keysym_reports_no_keycode(self):
        # Falls through to the scratch-keycode remap rather than typing nothing.
        self.assertEqual(self.s._lookup_keysym(0x01F600), (None, False))

    def test_shift_is_a_real_evdev_keycode(self):
        self.assertEqual(g.evdev_to_x_keycode(g.KEY_LEFTSHIFT), 50)


class TestCommandLines(unittest.TestCase):
    def test_password_is_never_an_argument(self):
        argv = g.xfreerdp_argv("127.0.0.1", 3389, "dreamconnect", 1920, 1080)
        self.assertIn("/from-stdin:force", argv)
        # The whole point of the stdin path: no element may carry a secret.
        self.assertFalse([a for a in argv if a.startswith("/p:")])

    def test_target_and_geometry_are_passed(self):
        argv = g.xfreerdp_argv("127.0.0.1", 3390, "op", 1280, 800)
        self.assertIn("/v:127.0.0.1:3390", argv)
        self.assertIn("/u:op", argv)
        self.assertIn("/size:1280x800", argv)

    def test_xvfb_does_not_listen_on_tcp(self):
        argv = g.xvfb_argv(":89", 1920, 1080)
        self.assertIn("-nolisten", argv)
        self.assertIn("tcp", argv)
        self.assertIn("1920x1080x24", argv)


class TestPipeline(unittest.TestCase):
    def test_targets_the_private_display(self):
        self.assertIn("display-name=:89", g.pipeline_desc(":89"))

    def test_damage_off_by_default(self):
        # A static greeter with use-damage=true emits nothing and reads as a
        # stalled capture.
        self.assertIn("use-damage=false", g.pipeline_desc(":89"))

    def test_format_matches_the_shm_writer(self):
        self.assertIn("format=BGRx", g.pipeline_desc(":89"))
        self.assertIn("appsink name=sink", g.pipeline_desc(":89"))


class TestControlSurface(unittest.TestCase):
    """GreeterSession must satisfy everything ControlServer.handle() calls."""

    def test_presents_the_session_surface(self):
        import dreamconnect_daemon as d
        required = ["motion_abs", "button", "axis_discrete", "key_code",
                    "key_sym", "type_string", "set_wake_lock", "set_blank",
                    "client_connected", "client_disconnected",
                    "_release_wake_lock", "_watchdog"]
        for name in required:
            self.assertTrue(callable(getattr(g.GreeterSession, name, None)),
                            f"GreeterSession is missing {name}(), which "
                            f"ControlServer or main() calls")
        # and the attributes the control commands read
        s = g.GreeterSession.__new__(g.GreeterSession)
        self.assertTrue(hasattr(d.ControlServer, "handle"))
        del s

    def test_password_file_is_required(self):
        s = g.GreeterSession.__new__(g.GreeterSession)
        s.password_file = None
        with self.assertRaises(RuntimeError):
            s._read_password()

    def test_password_file_is_read_with_exactly_one_newline(self):
        import tempfile
        s = g.GreeterSession.__new__(g.GreeterSession)
        with tempfile.NamedTemporaryFile("w", suffix=".pw", delete=False) as f:
            f.write("hunter2\n\n")
            s.password_file = f.name
        try:
            self.assertEqual(s._read_password(), b"hunter2\n")
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
