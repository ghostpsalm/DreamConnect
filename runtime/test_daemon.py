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


class _Unpackable:
    """Stands in for a GLib.Variant reply: the daemon only ever does
    `.unpack()[0]` on what call_sync returns."""

    def __init__(self, value):
        self._value = value

    def unpack(self):
        return (self._value,)


class FakeBus:
    """Records every D-Bus call the session makes and answers plausibly.

    Every Mutter interaction in Session goes through bus.call_sync, so this is
    the whole seam: no Mutter, no GLib main loop, no PipeWire. Method names are
    what the assertions read; the paths it hands back are unique per call so a
    test can tell one session from its replacement.
    """

    def __init__(self, fail_on=(), fail_nth_create=None):
        self.calls = []             # (path, iface, method)
        self.unsubscribed = []
        self.fail_on = set(fail_on)
        self.fail_nth_create = fail_nth_create
        self._creates = 0
        self._n = 0

    def call_sync(self, dest, path, iface, method, args, reply_type, flags,
                  timeout, cancellable):
        self.calls.append((path, iface, method))
        self._n += 1
        if method in self.fail_on:
            raise RuntimeError("fake bus: %s refused (session already gone)" % method)
        if method == "CreateSession":
            if iface == d.RD_IFACE:
                self._creates += 1
                if self._creates == self.fail_nth_create:
                    raise RuntimeError("fake bus: CreateSession #%d failed" % self._creates)
                return _Unpackable("/rd/session/u%d" % self._creates)
            return _Unpackable("/sc/session/u%d" % self._n)
        if method == "Get":
            return _Unpackable("sess-id-%d" % self._n)
        if method in ("RecordVirtual", "RecordMonitor", "RecordArea"):
            return _Unpackable("/stream/u%d" % self._n)
        return _Unpackable(None)

    def signal_subscribe(self, *a, **kw):
        self._n += 1
        return self._n

    def signal_unsubscribe(self, sid):
        self.unsubscribed.append(sid)

    # --- readers the tests use ------------------------------------------
    def methods(self):
        return [c[2] for c in self.calls]

    def stops(self):
        return [c[0] for c in self.calls if c[2] == "Stop"]


class TestSessionRestartStopsThePreviousSession(unittest.TestCase):
    """Issue #55, reported from a live backstage session: "two displays, one of
    them black", no top bar, no apps.

    Diagnosed live: the backstage X screen had grown to 2560x720 — TWO 1280x720
    virtual monitors side by side — and the journal showed `Added virtual
    monitor` 25 times. Every start() calls RecordVirtual, which makes Mutter
    conjure a monitor, and the previous RemoteDesktop session is never stopped,
    so each restart leaves its monitor behind. We capture one of them;
    ScreenConnect sizes its canvas from the whole X screen, so the operator gets
    a black half. Worse, GNOME puts the top bar on the PRIMARY monitor — the one
    we are not capturing — so a healthy desktop looks broken.

    _recover() fires on a Mutter session close, a GStreamer error/EOS, or the
    stall watchdog, so this is the ordinary path, not an edge case.

    What is pinned here is the property, not the mechanism: before a replacement
    session is created, the previous one is Stopped, and the identifiers are
    cleared so nothing can later aim a Stop at a dead session. Whether that
    lives in start() or in a teardown helper is the implementer's choice.
    """

    def _session(self, bus):
        # Backstage/virtual: the path that conjures a monitor, and the one the
        # operator was on. It returns from start() right after subscribing, so
        # no GStreamer or PipeWire is involved.
        return d.Session(bus, None, None, virtual=(1280, 720))

    def test_first_start_stops_nothing(self):
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        self.assertEqual(bus.stops(), [],
                         "a first start has no previous session to stop")
        self.assertEqual(s.rd_path, "/rd/session/u1")
        self.assertIn("RecordVirtual", bus.methods())

    def test_second_start_stops_the_previous_remote_desktop_session(self):
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        first_rd = s.rd_path
        s.start()
        self.assertEqual(bus.stops(), [first_rd],
                         "the replacement session stops exactly the previous "
                         "RemoteDesktop session (%s), which is what releases its "
                         "virtual monitor" % first_rd)
        self.assertNotEqual(s.rd_path, first_rd, "and a new session replaces it")

    def test_the_stop_comes_before_the_replacement_is_created(self):
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        s.start()
        methods = bus.methods()
        self.assertIn("Stop", methods,
                      "the replacement start issues no Stop at all, so there is no "
                      "ordering to check: %s" % methods)
        stop_at = methods.index("Stop")
        creates = [i for i, m in enumerate(methods) if m == "CreateSession"]
        self.assertGreater(len(creates), 2, "two starts create at least two sessions")
        self.assertLess(stop_at, creates[2],
                        "the old session is stopped BEFORE the new one is created: "
                        "stopping afterwards would still leave both monitors present "
                        "for the moment Mutter sizes the screen (order was %s)" % methods)

    def test_a_failing_stop_does_not_prevent_the_new_session(self):
        # The commonest restart trigger IS a Mutter-closed session, where Stop
        # legitimately fails. Refusing to recover from that would be worse than
        # the leak this fixes.
        bus = FakeBus(fail_on=("Stop",))
        s = self._session(bus)
        s.start()
        s.start()
        self.assertEqual(s.rd_path, "/rd/session/u2",
                         "a Stop that raises is tolerated and the replacement is "
                         "still established")
        methods = bus.methods()
        self.assertIn("Stop", methods,
                      "the replacement start issues no Stop at all: %s" % methods)
        self.assertIn("RecordVirtual", methods[methods.index("Stop"):],
                      "including the RecordVirtual that gives the operator a picture")

    def test_the_restart_path_goes_through_the_same_teardown(self):
        # _recover() -> (1s timer) -> _restart() -> start(). The timer is the
        # only part not exercised here; scheduling it is asserted separately.
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        first_rd = s.rd_path
        s._restart()
        self.assertEqual(bus.stops(), [first_rd],
                         "the route that actually causes this in production — a "
                         "Mutter close, a GStreamer error, or the stall watchdog — "
                         "goes through the teardown, so the fix cannot be bypassed")
        self.assertFalse(s._restarting, "and a successful restart clears the guard")

    def test_recover_schedules_the_restart_that_does_the_teardown(self):
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        scheduled = []
        real_timeout = d.GLib.timeout_add_seconds
        d.GLib.timeout_add_seconds = lambda secs, fn, *a: scheduled.append((secs, fn)) or 1
        try:
            s._recover()
        finally:
            d.GLib.timeout_add_seconds = real_timeout
        self.assertEqual([fn for _, fn in scheduled], [s._restart],
                         "_recover schedules _restart, which is where the teardown "
                         "must live for a Mutter close to release its monitor")

    def test_n_restarts_produce_n_stops(self):
        # The property the operator actually cares about: the journal showed
        # `Added virtual monitor` 25 times and the X screen was 2560 wide. One
        # stop per restart is what keeps that at one monitor.
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        expected = []
        for _ in range(5):
            expected.append(s.rd_path)
            s._restart()
        self.assertEqual(bus.stops(), expected,
                         "five restarts stop five sessions, each the one it replaced "
                         "— anything less accumulates virtual monitors")
        self.assertEqual(bus.methods().count("RecordVirtual"), 6,
                         "six RecordVirtual calls, five of them replacing a stopped "
                         "session rather than adding to it")

    def test_a_failed_restart_leaves_no_stale_session_to_stop(self):
        # If creating the replacement fails, the identifiers must not still name
        # the session we just stopped: a later Stop would then be aimed at a dead
        # path, and (worse) a later start would believe it had a session.
        bus = FakeBus(fail_nth_create=2)
        s = self._session(bus)
        s.start()
        stopped = s.rd_path
        with self.assertRaises(Exception):
            s.start()
        self.assertIsNone(s.rd_path,
                          "rd_path is cleared by the teardown, not left naming the "
                          "session that was just stopped")
        self.assertIsNone(s.stream_path, "and so is the stream")
        self.assertIsNone(s.node_id, "and the PipeWire node id")

        bus.calls.clear()
        s.start()
        self.assertEqual(bus.stops(), [],
                         "so the next start stops nothing — there is no session to "
                         "stop, and aiming a Stop at %s would be aiming at a corpse"
                         % stopped)




class TestHeadlessCaptureFallback(unittest.TestCase):
    """A session with no monitors can only be captured virtually.

    RecordArea over a zero-monitor desktop and RecordMonitor against a connector
    that is not there both fail on the Mutter call, which is what made session
    discovery crash the moment it attached to a headless session -- and every
    remote-login and backstage session is headless.
    """

    def _session(self, has_monitors, virtual=None):
        s = d.Session.__new__(d.Session)
        s.virtual = virtual
        s.all_monitors = True
        s.monitor = "HDMI-2"
        s._has_monitors = lambda: has_monitors
        return s

    @staticmethod
    def _choose(s):
        """The decision _start_stream makes before it calls Mutter."""
        if not s.virtual and not s._has_monitors():
            s.virtual = d.DEFAULT_VIRTUAL_SIZE
        return s.virtual

    def test_no_monitors_switches_to_virtual(self):
        self.assertEqual(self._choose(self._session(False)), d.DEFAULT_VIRTUAL_SIZE)

    def test_monitors_present_leaves_capture_alone(self):
        self.assertIsNone(self._choose(self._session(True)))

    def test_an_explicit_virtual_size_is_never_overridden(self):
        s = self._session(False, virtual=(1280, 800))
        self.assertEqual(self._choose(s), (1280, 800))

    def test_the_default_is_a_sane_resolution(self):
        w, h = d.DEFAULT_VIRTUAL_SIZE
        self.assertGreater(w, 0)
        self.assertGreater(h, 0)
        self.assertLessEqual(max(w, h), d.MAX_DIMENSION)


if __name__ == "__main__":
    unittest.main()
