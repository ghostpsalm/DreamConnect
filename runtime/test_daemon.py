#!/usr/bin/env python3
"""Unit tests for the daemon's control-protocol parser (ControlServer.handle)
and for the backstage/virtual-monitor capture wiring.

No live Wayland/D-Bus needed: a stub session records the calls handle() makes,
and the virtual-mode tests only exercise pure string/argument construction.
Run: python3 -m unittest runtime.test_daemon   (or: python3 runtime/test_daemon.py)
"""
import os
import pwd
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_daemon as d  # noqa: E402

SOCK = "/tmp/dreamconnect-test-unused.sock"  # never bound: we only call handle()


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

    def test_existing_commands_unchanged_when_display_and_label_are_set(self):
        # Issue #50: "Existing commands (PING, GEOM, NODE, WHO, input) unchanged."
        cs = d.ControlServer(SOCK, self.s, display=":0", label="[Backstage]")
        self.assertEqual(cs.handle("PING"), "PONG")
        self.assertEqual(cs.handle("GEOM"), "1920 1080")
        self.assertEqual(cs.handle("NODE"), "66")
        self.assertIsNone(cs.handle("M 100 200"))
        self.assertEqual(self.s.calls[-1], ("M", 100.0, 200.0))
        self.assertTrue(cs.handle("BOGUS").startswith("ERR"))


class TestDisplayCommand(unittest.TestCase):
    """Issue #50: 'New control-socket command DISPLAY replies the daemon's
    session X display (e.g. :0), or UNKNOWN when the daemon could not learn it.'
    """

    def setUp(self):
        self.s = StubSession()

    def test_display_replies_the_session_x_display(self):
        cs = d.ControlServer(SOCK, self.s, display=":0")
        self.assertEqual(cs.handle("DISPLAY"), ":0")

    def test_display_replies_unknown_when_the_daemon_could_not_learn_it(self):
        cs = d.ControlServer(SOCK, self.s)
        self.assertEqual(cs.handle("DISPLAY"), "UNKNOWN")


class TestDisplayResolutionOrder(unittest.TestCase):
    """Issue #50: '--display arg wins, else $DISPLAY env, else unknown.'

    Asserted through the protocol reply (the observable seam), so the internal
    representation of "unknown" is the builder's choice. main() is expected to
    wire these together as ControlServer(..., display=resolve_display(args.display,
    os.environ)); the env is passed in explicitly here to keep the test pure.
    """

    def setUp(self):
        self.s = StubSession()

    def _display_reply(self, arg, env):
        return d.ControlServer(SOCK, self.s, display=d.resolve_display(arg, env)).handle("DISPLAY")

    def test_display_arg_wins_over_env(self):
        # backstage units pass --display (slice 4) into a shell that may also
        # carry a $DISPLAY of its own; the arg is authoritative.
        self.assertEqual(self._display_reply(":1", {"DISPLAY": ":0"}), ":1")

    def test_env_display_used_when_no_arg(self):
        # a classic daemon under graphical-session.target inherits $DISPLAY.
        self.assertEqual(self._display_reply(None, {"DISPLAY": ":0"}), ":0")

    def test_unknown_when_neither_arg_nor_env(self):
        self.assertEqual(self._display_reply(None, {}), "UNKNOWN")


class TestWhoLabel(unittest.TestCase):
    """Issue #50: 'New --label arg: when set, WHO replies it verbatim (backstage
    answers [Backstage]); when unset, WHO behaviour is unchanged (login name).'
    """

    def setUp(self):
        self.s = StubSession()

    def test_who_replies_the_label_verbatim(self):
        cs = d.ControlServer(SOCK, self.s, label="[Backstage]")
        self.assertEqual(cs.handle("WHO"), "[Backstage]")

    def test_who_is_the_login_name_when_no_label(self):
        # "login name" read from the passwd database, independently of however
        # the daemon derives it.
        cs = d.ControlServer(SOCK, self.s)
        self.assertEqual(cs.handle("WHO"), pwd.getpwuid(os.getuid()).pw_name)


BLANKS = ("", " ", "   ", "\t", " \t ", "\n")


class TestBlankArgsAreUnset(unittest.TestCase):
    """Owner rider on pd-066f33ba1c55 (factory/decision-consumption), verbatim:
    'empty/whitespace --display or --label is treated as unset (UNKNOWN /
    login name)'.

    A systemd unit that expands an unset variable ships a blank argument, so
    blank must not reach the agent's picker as a display or an entry name.
    """

    def setUp(self):
        self.s = StubSession()

    def test_blank_display_arg_is_unset_so_env_is_used(self):
        for arg in BLANKS:
            with self.subTest(arg=repr(arg)):
                self.assertEqual(d.resolve_display(arg, {"DISPLAY": ":0"}), ":0")

    def test_blank_display_arg_with_no_env_resolves_to_unknown(self):
        for arg in BLANKS:
            with self.subTest(arg=repr(arg)):
                self.assertIsNone(d.resolve_display(arg, {}))
                cs = d.ControlServer(SOCK, self.s, display=d.resolve_display(arg, {}))
                self.assertEqual(cs.handle("DISPLAY"), "UNKNOWN")

    def test_display_command_reports_unknown_for_a_blank_display(self):
        # Defence in depth at the protocol seam itself: whatever route put a
        # blank there, the agent is told UNKNOWN, never whitespace.
        for blank in BLANKS:
            with self.subTest(display=repr(blank)):
                cs = d.ControlServer(SOCK, self.s, display=blank)
                self.assertEqual(cs.handle("DISPLAY"), "UNKNOWN")

    def test_who_falls_back_to_the_login_name_for_a_blank_label(self):
        for blank in BLANKS:
            with self.subTest(label=repr(blank)):
                cs = d.ControlServer(SOCK, self.s, label=blank)
                self.assertEqual(cs.handle("WHO"), pwd.getpwuid(os.getuid()).pw_name)


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


class TestStallWatchdog(unittest.TestCase):
    """The capture pipeline can stop delivering frames while the RemoteDesktop
    session stays alive (input still works) — Mutter pausing the screencast, a
    PipeWire node going away with no GStreamer error, etc. Nothing recovered it,
    so the operator saw a frozen desktop with a live cursor: 'sticky, can't do
    anything'. The watchdog restarts the session when a client is attached but
    frames have stopped. `keepalive-time` guarantees a healthy pipeline emits
    >=1 fps even on a static screen, so 'no frame for N seconds while attached'
    reliably means stalled, not merely idle."""

    def _session(self, **kw):
        s = d.Session(None, "HDMI-2", None, virtual=(1920, 1080), **kw)
        return s

    def test_fresh_session_is_not_stalled(self):
        s = self._session()
        s.active_clients = 1
        # No frame yet, but the session just started: the grace is that a zero
        # last-frame time is seeded to "now" when the pipeline starts, so it is
        # never reported stalled before it has had a chance to produce a frame.
        s.note_frame(1000)          # pipeline start seeds the clock
        self.assertFalse(s.is_stalled(1000))
        self.assertFalse(s.is_stalled(1000 + s.stall_timeout_ms - 1))

    def test_stalled_when_attached_and_no_frames_past_timeout(self):
        s = self._session()
        s.active_clients = 1
        s.note_frame(1000)
        self.assertTrue(s.is_stalled(1000 + s.stall_timeout_ms + 1))

    def test_not_stalled_when_no_client_attached(self):
        # With nobody reading, the daemon intentionally does not care that frames
        # stopped — restarting the whole session for an empty stream is churn.
        s = self._session()
        s.active_clients = 0
        s.note_frame(1000)
        self.assertFalse(s.is_stalled(1000 + s.stall_timeout_ms * 10))

    def test_a_frame_clears_the_stall(self):
        s = self._session()
        s.active_clients = 1
        s.note_frame(1000)
        self.assertTrue(s.is_stalled(1000 + s.stall_timeout_ms + 1))
        s.note_frame(1000 + s.stall_timeout_ms + 1)   # a frame arrives
        self.assertFalse(s.is_stalled(1000 + s.stall_timeout_ms + 2))

    def test_timeout_is_configurable_and_has_a_sane_default(self):
        self.assertEqual(self._session().stall_timeout_ms, 4000)
        self.assertEqual(self._session(stall_timeout_ms=1500).stall_timeout_ms, 1500)

    def test_never_stalled_before_the_first_frame_is_seeded(self):
        # If the pipeline never produced even one frame (last_frame_ms still 0),
        # is_stalled must not fire on a huge clock — the seed happens at pipeline
        # start, and until then there is nothing to compare against.
        s = self._session()
        s.active_clients = 1
        self.assertFalse(s.is_stalled(10_000_000))


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
