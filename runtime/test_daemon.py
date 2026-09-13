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
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_daemon as d  # noqa: E402

SOCK = "/tmp/dreamconnect-test-unused.sock"  # never bound: we only call handle()


class StubSession:
    def __init__(self):
        self.calls = []
        # Geometry is published as one pair, not two fields, so a reader can
        # never observe half of a resolution change (issue #44). The double
        # mirrors that shape: a stub still carrying .width/.height would let a
        # two-load reader pass here while tearing against the real session.
        self.geom, self.node_id = (1920, 1080), 66

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

    def test_keysym_above_ascii_is_forwarded_whole(self):
        # Issue #40 routes VK_SEPARATOR as XK_KP_Separator
        # (/usr/include/X11/keysymdef.h:303, 0xffac = 65452) — the first KS
        # value the agent sends outside the ASCII range every other KSYM entry
        # sits in. The parse is meant to be value-agnostic and the D-Bus arg is
        # uint32, so this is a standing guard rather than new behaviour: it is
        # expected to pass before the agent-side change as well as after, and
        # exists to fail if anyone ever narrows the parse. A byte-sized one
        # would forward 65452 & 0xFF = 172 (XK_onehalf) and type the wrong
        # character with no error anywhere.
        self.assertIsNone(self.cs.handle("KS 65452 1"))
        self.assertEqual(self.s.calls[-1], ("KS", 65452, True))

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


class FlickeringGeomSession:
    """A session whose published geometry changes between every observation.

    Models the capture thread landing a resolution change while the socket
    thread is answering GEOM. Each read of a published geometry field advances
    to the next mode, so a reader that observes the geometry *twice* sees two
    different modes and can only reply with a torn pair, while a reader that
    takes a single snapshot always replies with one mode intact. Both modes are
    themselves coherent: nothing here can produce "1920 720" except the reader
    mixing two observations.

    .width/.height are kept alongside .geom on purpose. They are not part of the
    session interface any more, but without them a two-load reader would die on
    a missing attribute, which proves only that a rename happened; with them it
    is caught replying with the torn pair, which is the defect itself.
    """

    MODES = ((1920, 1080), (1280, 720))

    def __init__(self):
        self.observations = 0
        self.node_id = 66

    def _observe(self):
        mode = self.MODES[self.observations % len(self.MODES)]
        self.observations += 1
        return mode

    @property
    def geom(self):
        return self._observe()

    @property
    def width(self):
        return self._observe()[0]

    @property
    def height(self):
        return self._observe()[1]


class TestGeomIsAtomic(unittest.TestCase):
    """Issue #44 (2026-07-31 review, F1): "a GEOM issued during the single frame
    a resolution change lands can return the new width with the old height (or
    vice-versa)". runtime/README.md:56 defines the reply as the *stream size* —
    one size — so both numbers must come from a single observation of the pair.
    """

    def test_geom_reply_is_one_published_pair_never_a_mix_of_two(self):
        s = FlickeringGeomSession()
        reply = d.ControlServer(SOCK, s).handle("GEOM")
        self.assertIn(
            reply,
            {f"{w} {h}" for w, h in FlickeringGeomSession.MODES},
            f"GEOM replied {reply!r}, which is neither published geometry: it "
            f"mixed {s.observations} observations of a changing pair",
        )


class FlickeringAreaSession(d.Session):
    """A session whose published capture-area origin changes between every
    observation.

    Models a monitor-layout change landing on the D-Bus thread (start() picks a
    fresh RecordArea bounding box) while the socket thread is shifting a pointer
    coordinate. Each read of a published origin field advances to the next
    layout, so a reader that observes the origin *twice* subtracts x from one
    layout and y from the other, while a reader that takes a single snapshot
    always shifts by one whole origin. Both layouts are themselves coherent:
    nothing here can produce a half-shifted point except the reader mixing two
    observations.

    .area_x/.area_y are kept alongside .area_origin on purpose, for the same
    reason FlickeringGeomSession keeps .width/.height: without them a two-load
    reader would die on a missing attribute, which proves only that a rename
    happened; with them it is caught mis-shifting the pointer, which is the
    defect itself.

    Session.__init__ is deliberately not chained. It wants a bus, a monitor and
    a frame buffer that this test has no use for, and it *assigns* the published
    origin, which is a read-only property here -- chaining would abort in the
    constructor instead of exercising motion_abs. Only the state motion_abs
    touches is set up. _rd is stubbed rather than driven through a FakeBus
    because the coordinates are the whole assertion and FakeBus records method
    names, not arguments; going through the real _rd would only add a GLib
    Variant round-trip between the reader and the value under test.
    """

    ORIGINS = ((1920, 200), (640, 100))

    def __init__(self):
        self.observations = 0
        self.stream_path = "/org/gnome/Mutter/ScreenCast/Session/u1/Stream/u2"
        self._lock = threading.Lock()
        self.rd_calls = []

    def _observe(self):
        origin = self.ORIGINS[self.observations % len(self.ORIGINS)]
        self.observations += 1
        return origin

    @property
    def area_origin(self):
        return self._observe()

    @property
    def area_x(self):
        return self._observe()[0]

    @property
    def area_y(self):
        return self._observe()[1]

    def _rd(self, method, params=None, sig=None):
        self.rd_calls.append((method, params, sig))


class TestAreaOriginIsAtomic(unittest.TestCase):
    """Issue #57: area_x and area_y are written on the D-Bus thread and read
    together on the socket thread, so "a reader can take a new `area_x` with a
    stale `area_y`" and the pointer is mis-shifted -- "input lands in the wrong
    place", and unlike #44's torn GEOM it does not self-correct on the next
    frame.

    The shift is contract, not implementation detail: runtime/README.md:59
    defines `M <x> <y>` as a pointer absolute move in *screen* px, and
    ROADMAP.md:255 -- "Pointer coordinates are shifted by the area origin
    (`area_x/area_y`) into the stream's frame". So the screen point (2020, 500)
    is (100, 300) in a stream whose area is anchored at (1920, 200), and
    (1380, 400) in one anchored at (640, 100). Those two are the only answers a
    correct reader can give while the layout flickers between exactly those two
    areas; (100, 400) -- x from the first area, y from the second -- is a point
    on neither, and is the pointer landing 100 px from where the operator
    clicked. Neither origin is (0, 0), so "shifted by one whole origin" is also
    not satisfiable by dropping the shift altogether.
    """

    DESKTOP_X, DESKTOP_Y = 2020.0, 500.0

    def test_pointer_is_shifted_by_one_published_origin_never_a_mix_of_two(self):
        s = FlickeringAreaSession()
        s.motion_abs(self.DESKTOP_X, self.DESKTOP_Y)

        self.assertEqual(len(s.rd_calls), 1, "motion_abs made no single RemoteDesktop call")
        method, params, sig = s.rd_calls[0]
        self.assertEqual(method, "NotifyPointerMotionAbsolute")
        self.assertEqual(params[0], s.stream_path)

        coherent = {(self.DESKTOP_X - ox, self.DESKTOP_Y - oy)
                    for ox, oy in FlickeringAreaSession.ORIGINS}
        self.assertIn(
            (params[1], params[2]),
            coherent,
            f"pointer sent to {(params[1], params[2])}, which is the point in "
            f"neither published area {FlickeringAreaSession.ORIGINS}: the "
            f"reader mixed {s.observations} observations of a changing origin",
        )


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


class TestSessionStopReleasesTheMutterSession(unittest.TestCase):
    """Issue #55, the half that survives a *process* restart.

    `systemctl --user restart dreamconnect-daemon` must leave the X screen at
    exactly the configured backstage resolution, which means the daemon has to
    release its RemoteDesktop session on the way out, not only when start() is
    re-entered in-process. Releasing it is one named thing — Session.stop() —
    so the exit path and the restart path cannot drift into two different
    "release the session" routines, which is how the exit path came to be an
    untested inline lambda.

    Contract being pinned (each clause is asserted below):
      * issues RD Stop on self.rd_path iff it is set;
      * logs and swallows a Stop that raises;
      * always clears rd_path / sc_path / stream_path / node_id;
      * idempotent — two calls produce one Stop;
      * never raises.
    """

    def _session(self, bus):
        # Backstage/virtual: the mode that makes Mutter conjure the monitor
        # whose leak the operator saw as a black second display.
        return d.Session(bus, None, None, virtual=(1280, 720))

    def test_stop_issues_one_stop_aimed_at_the_session_it_holds(self):
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        held = s.rd_path
        s.node_id = 42  # as PipeWireStreamAdded would have left it

        s.stop()

        self.assertEqual(bus.stops(), [held],
                         "stop() must Stop the RemoteDesktop session this daemon "
                         "holds (%s) — that Stop is the only thing that makes "
                         "Mutter drop the virtual monitor it conjured" % held)
        self.assertIsNone(s.rd_path, "and clears the session it no longer holds")
        self.assertIsNone(s.sc_path, "including the ScreenCast session")
        self.assertIsNone(s.stream_path, "and the stream")
        self.assertIsNone(s.node_id, "and the PipeWire node id")

    def test_stop_is_idempotent(self):
        # The exit path and a recovery can both reach stop() for the same
        # session; a second Stop is aimed at a session Mutter has already
        # destroyed, and the identifiers must not still name it.
        bus = FakeBus()
        s = self._session(bus)
        s.start()
        held = s.rd_path

        s.stop()
        s.stop()

        self.assertEqual(bus.stops(), [held],
                         "two stop() calls issue one Stop: the second has no "
                         "session to release")

    def test_stop_without_a_session_does_not_touch_the_bus(self):
        # The shape of the bug this slice exists to remove: the exit path
        # called Stop unconditionally, so a daemon that died before start()
        # ever succeeded aimed a Stop at a null path and failed silently.
        bus = FakeBus()
        s = self._session(bus)
        self.assertIsNone(s.rd_path, "precondition: no session has been created")

        s.stop()

        self.assertEqual(bus.calls, [],
                         "stop() with no session held makes no D-Bus call at all "
                         "— there is nothing to stop, and a Stop on a null path "
                         "is an error the caller cannot act on")

    def test_a_raising_stop_is_swallowed_and_the_session_still_released(self):
        # Mutter having already closed the session is the *commonest* reason we
        # are stopping, so a raising Stop is normal, not exceptional. It must
        # not escape into a shutdown sequence that still has to blank the
        # screen and drop the wake lock.
        bus = FakeBus(fail_on=("Stop",))
        s = self._session(bus)
        s.start()
        stopped = s.rd_path

        s.stop()  # must not raise

        self.assertIsNone(s.rd_path,
                          "a Stop that raises still clears the identifiers")
        bus.calls.clear()
        s.start()
        self.assertEqual(bus.stops(), [],
                         "so the next start has nothing to stop — aiming a later "
                         "Stop at %s would be aiming at a corpse" % stopped)


class _ExitingSession:
    """A session double shaped like the interface the exit path is specified
    against: set_blank(on), _release_wake_lock(), stop().

    Both real kinds answer exactly these three, which is why the exit path can
    be one routine rather than a branch on the mode: Session releases a Mutter
    session, and GreeterSession's set_blank/_release_wake_lock are deliberate
    no-ops (dreamconnect_greeter.py:524-528) while its stop() kills the Xvfb and
    the RDP client. `raising` names the steps that fail, because on the way out
    a failing step is ordinary — the bus may already be going away.
    """

    def __init__(self, raising=()):
        self.calls = []        # method names, in the order they were called
        self.blank_args = []   # what set_blank was asked for
        self._raising = set(raising)

    def _record(self, name):
        self.calls.append(name)
        if name in self._raising:
            raise RuntimeError("fake session: %s failed on the way out" % name)

    def set_blank(self, on):
        self.blank_args.append(on)
        self._record("set_blank")

    def _release_wake_lock(self):
        self._record("_release_wake_lock")

    def stop(self):
        self._record("stop")


class TestShutdownReleasesEverythingOnProcessExit(unittest.TestCase):
    """Issue #55's requirement: after `systemctl --user restart
    dreamconnect-daemon` the X screen must still be exactly the configured
    backstage resolution — so the *process* exit has to release the Mutter
    session, not only start() re-entered in-process.

    Contract being pinned (each clause is asserted below):
      * set_blank(False), then _release_wake_lock(), then stop();
      * each step guarded on its own, so a failing one cannot skip the rest;
      * never raises;
      * one routine for both modes — it needs only those three methods.

    Order is load-bearing in both directions. Unblank and drop the wake lock
    first, or a stop/restart while the panel is blanked leaves the box dark and
    awake with nobody left to restore it. Release the session last, because
    that is the step whose absence grows the X screen by one virtual monitor
    per restart.
    """

    def test_the_release_order_is_unblank_then_wake_lock_then_session(self):
        s = _ExitingSession()

        d.shutdown(s)

        self.assertEqual(s.calls, ["set_blank", "_release_wake_lock", "stop"],
                         "the local state the daemon imposed on the box is "
                         "undone before the session that carries it is released")
        self.assertEqual(s.blank_args, [False],
                         "and the blank is lifted, not re-applied on the way out")

    def test_a_failing_step_still_leaves_the_session_released(self):
        # The shape of the leak this slice exists to remove: guard the sequence
        # once instead of guarding each step, and the first failure — an
        # unblank against a bus that is already going away is a normal way to
        # exit — skips stop(), Mutter keeps the virtual monitor it conjured,
        # and the next start sits beside it. That is the 2560x720 screen.
        s = _ExitingSession(raising=("set_blank", "_release_wake_lock"))

        d.shutdown(s)  # must not raise

        self.assertEqual(s.calls, ["set_blank", "_release_wake_lock", "stop"],
                         "every step is attempted; an earlier failure must not "
                         "cost us the session release")

    def test_a_raising_stop_does_not_escape_the_exit_path(self):
        # Mutter having already closed the session is the commonest reason we
        # are here, so a raising Stop is normal. It must not turn a clean exit
        # into a traceback.
        s = _ExitingSession(raising=("stop",))

        d.shutdown(s)  # must not raise

        self.assertEqual(s.calls, ["set_blank", "_release_wake_lock", "stop"])

    def test_a_real_session_exits_with_one_stop_aimed_at_what_it_holds(self):
        # The same exit driven against a real backstage Session, so the claim
        # is about the Mutter traffic and not only about a double: exactly one
        # Stop, aimed at the RemoteDesktop session this daemon created, is what
        # makes Mutter drop the monitor before the replacement process starts.
        bus = FakeBus()
        s = d.Session(bus, None, None, virtual=(1280, 720))
        s.start()
        held = s.rd_path

        d.shutdown(s)

        self.assertEqual(bus.stops(), [held],
                         "process exit releases the session it holds (%s) exactly "
                         "once — no Stop, and the restart leaves a second virtual "
                         "monitor behind" % held)
        self.assertIsNone(s.rd_path, "and holds nothing afterwards")


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


class TestFrameBufferEnsure(unittest.TestCase):
    """FrameBuffer.ensure() opens the shm path with O_CREAT|O_RDWR (see
    dreamconnect_daemon.py ~line 95). O_CREAT is a no-op when the path
    already exists, so a file left over from a prior install -- now
    inaccessible because the daemon runs under a different uid (e.g. after
    the host-account migration) -- must not wedge ensure() with the same
    PermissionError forever (issue #27).
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="dreamconnect-test-")
        self.shm_path = os.path.join(self.tmpdir, "dreamconnect.frame")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_ensure_recovers_from_foreign_owned_existing_file(self):
        # Stand-in for "owned by a different uid": chmod 0o000 (can't chown
        # to another uid without root in a test) forces the same failure
        # os.open(O_RDWR|O_CREAT) hits against a pre-existing file this
        # process can no longer write to.
        with open(self.shm_path, "wb") as f:
            f.write(b"\x00" * d.HEADER_SIZE)
        os.chmod(self.shm_path, 0o000)

        fb = d.FrameBuffer(self.shm_path)
        fb.ensure(4, 2, 16)  # width=4 height=2 stride=16: arbitrary small frame

        # ensure() must leave the file owned/writable by this process again
        # (the 0600 contract already documented for a freshly created file,
        # dreamconnect_daemon.py lines 91-96) ...
        mode = stat.S_IMODE(os.stat(self.shm_path).st_mode)
        self.assertEqual(mode, 0o600)
        # ... holding the documented 64-byte header (the "<4sIIIII" layout
        # from the module's own header comment, lines 39-48, which
        # runtime/test_client.py independently parses off the real shm file).
        with open(self.shm_path, "rb") as f:
            header = f.read(d.HEADER_SIZE)
        magic, version, width, height, stride, fmt = struct.unpack_from(
            "<4sIIIII", header, 0)
        self.assertEqual(magic, d.MAGIC)
        self.assertEqual(version, 1)
        self.assertEqual(width, 4)
        self.assertEqual(height, 2)
        self.assertEqual(stride, 16)
        self.assertEqual(fmt, d.FORMAT_BGRX)


class TestFrameBufferEnsureStickyBitUnlink(unittest.TestCase):
    """dreamconnect_daemon.py ensure() (~lines 95-106) catches PermissionError
    around the initial os.open() and recovers by unlinking the leftover file,
    then retrying, once. /dev/shm has the sticky bit (mode 1777, see its own
    `stat`): under the sticky bit, unlink() requires the CALLER to own the
    target file, OR own the containing directory, OR be root -- merely
    having write access to the directory (what the sibling
    TestFrameBufferEnsure's chmod-0o000-in-a-plain-tempdir case exercises)
    is not sufficient. For a genuinely foreign-uid file (e.g. root-owned, as
    after a host-account migration -- the exact scenario issue #27
    describes), the recovery path's own os.unlink() call raises a SECOND
    PermissionError.

    Owner decision (issue #27 re-scope, after a breaker found this case):
    the daemon does NOT attempt privilege escalation (e.g. sudo) to handle
    it -- ensure() lets that second PermissionError propagate uncaught. The
    real fix belongs in install.sh instead, which already runs as root
    during the exact migration this occurs in and can unlink the stale file
    trivially before the daemon ever starts. This is a GUARD test: it
    documents that ensure() correctly refuses to paper over a case it
    cannot actually recover from, rather than hanging, swallowing the
    error, or failing some more confusing way.

    Reproduced with a synthetic directory (not /dev/shm itself, to avoid
    colliding with the live daemon's dreamconnect.frame) chmod+chowned to
    match /dev/shm's real mode and ownership (1777, root:root) -- confirmed
    by hand to fail identically to a real /dev/shm reproduction, since the
    sticky-bit unlink check is a generic VFS check (fs/namei.c may_delete),
    not tmpfs-specific. Note a same-uid-owned sticky tempdir would NOT
    reproduce this: under the sticky bit the DIRECTORY OWNER may unlink any
    file inside regardless of the file's own owner, so the directory itself
    must be foreign-owned too, exactly as /dev/shm (root:root) is.

    Needs passwordless sudo to create the foreign-owned directory/file;
    skipped where that is unavailable rather than failing for the wrong
    reason (SKILL.md "tests that can't run everywhere").
    """

    @classmethod
    def setUpClass(cls):
        r = subprocess.run(["sudo", "-n", "true"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode != 0:
            raise unittest.SkipTest(
                "requires passwordless sudo to create a foreign-uid file "
                "under a sticky-bit directory (issue #27 reproduction)")

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="dreamconnect-test-sticky-")
        os.chmod(self.tmpdir, 0o1777)  # matches /dev/shm's real mode
        subprocess.run(["sudo", "-n", "chown", "root:root", self.tmpdir],
                        check=True)  # matches /dev/shm's real ownership
        self.shm_path = os.path.join(self.tmpdir, "dreamconnect.frame")
        subprocess.run(["sudo", "-n", "touch", self.shm_path], check=True)
        subprocess.run(["sudo", "-n", "chown", "root:root", self.shm_path],
                        check=True)
        subprocess.run(["sudo", "-n", "chmod", "600", self.shm_path],
                        check=True)

    def tearDown(self):
        # If ensure() didn't complete (the point of this test before the
        # fix), tmpdir/shm_path are still root-owned; shutil.rmtree can't
        # remove those, so reclaim first.
        subprocess.run(
            ["sudo", "-n", "chown", "-R", f"{os.getuid()}:{os.getgid()}", self.tmpdir],
            check=False)
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_ensure_raises_permission_error_for_a_foreign_owned_file_under_sticky_bit_dir(self):
        # A file genuinely owned by a different uid, sitting under a
        # sticky-bit directory also owned by that uid, cannot be reclaimed
        # by an unprivileged process at all: os.unlink() itself raises EPERM
        # (fs/namei.c may_delete -- the caller must own the file, own the
        # directory, or be root). ensure() must let that PermissionError
        # propagate -- not hang, not swallow it, not fail some other more
        # confusing way -- so the caller (and ultimately install.sh,
        # upstream of the daemon ever starting) can see exactly what went
        # wrong.
        fb = d.FrameBuffer(self.shm_path)
        with self.assertRaises(PermissionError):
            fb.ensure(4, 2, 16)  # width=4 height=2 stride=16: arbitrary small frame

        # Not silently routed around some other way either: the file ensure()
        # could not reclaim is still exactly where it was -- still there,
        # still root-owned, mode unchanged -- not deleted by some fallback
        # that then failed differently, and not left half-modified.
        st = os.stat(self.shm_path)
        self.assertEqual(st.st_uid, 0)
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)


class _StopAccept(Exception):
    """Raised from the test socket's accept() to end ControlServer.run().

    run()'s tail is `while True: srv.accept()`, so the only way to drive the
    real method to completion synchronously -- no background thread to join,
    nothing left blocked in accept() after the test -- is to make the first
    accept() raise. run() wraps neither bind nor accept in try/except, so this
    propagates to the caller unchanged.
    """


class _BindWatchingSocket(socket.socket):
    """A real AF_UNIX socket that samples its own inode's mode mid-bind.

    The window under test (issue #45) exists only BETWEEN bind() and the
    following chmod, so it cannot be observed from outside: stat'ing the path
    after run() has settled reports 0600 whether or not the window was ever
    open, which is why this samples inside the bind call itself. The bind is
    the real one -- the mode recorded is what the kernel actually gave the
    inode, not a computed expectation.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.bind_time_mode = None
        self.listened = False

    def bind(self, address):
        super().bind(address)
        self.bind_time_mode = stat.S_IMODE(os.stat(address).st_mode)

    def listen(self, backlog=None):
        self.listened = True
        super().listen() if backlog is None else super().listen(backlog)

    def accept(self):
        raise _StopAccept


class _SocketModuleShim:
    """Stands in for the daemon's `socket` module, overriding only socket().

    Assigning over the stdlib module's own `socket` attribute would change it
    process-wide for the duration; delegating every other name to the real
    module keeps the substitution local to `dreamconnect_daemon.socket`.
    """

    def __init__(self, real, factory):
        self._real = real
        self.socket = factory

    def __getattr__(self, name):
        return getattr(self._real, name)


class TestControlSocketBindMode(unittest.TestCase):
    """The control socket must never be group- or world-connectable, not even
    for the instant between bind() and chmod (issue #45).

    Whoever can connect() to this socket can inject arbitrary input into the
    session -- the grammar at ControlServer.handle() takes M/B/W/K/KS with no
    authentication, because the 0600 mode IS the authentication. The shipped
    unit sets `UMask=0077` (systemd/dreamconnect-daemon.service:29) so the
    transient mode is 0700 there, but `dreamconnect_daemon.py:771-775` binds
    and only then chmods, so a daemon started by hand under the default umask
    022 publishes the socket at `0777 & ~umask` first. Issue #45, verbatim:
    "another local user could `connect()` in that sub-millisecond gap and
    inject input into the session", and the fix must hold "so the socket is
    never briefly world-connectable regardless of how the daemon is launched".

    Expected value is from that issue text plus the mode the code already
    commits to as its end state (0600, dreamconnect_daemon.py:773-775): no
    group and no other bits at any point -- `S_IMODE & 0o077 == 0`. It is not
    an assertion that any particular one of the issue's three candidate fixes
    was chosen; a umask around the bind, or a placeholder created 0600 first,
    both satisfy it.

    umask 0o022 is forced for the duration because it is the launch condition
    the issue names ("manual launch, default umask 022"); the gate's own umask
    is whatever the operator's shell had, which would make this pass or fail
    by accident. It is restored in a finally.
    """

    def setUp(self):
        # dir="/tmp" rather than the ambient TMPDIR: sun_path is 108 bytes and
        # a long TMPDIR (a CI scratch path, a worktree) would fail the bind
        # with "AF_UNIX path too long" -- a red for the wrong reason.
        self.tmpdir = tempfile.mkdtemp(prefix="dreamconnect-test-sock-", dir="/tmp")
        self.sock_path = os.path.join(self.tmpdir, "control.sock")
        self.made = []

        def factory(*args, **kwargs):
            s = _BindWatchingSocket(*args, **kwargs)
            self.made.append(s)
            return s

        self.real_socket_module = d.socket
        d.socket = _SocketModuleShim(socket, factory)
        self.server = d.ControlServer(self.sock_path, StubSession())

    def tearDown(self):
        d.socket = self.real_socket_module
        for s in self.made:
            s.close()
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _run_under_umask(self, umask):
        """Drive the real ControlServer.run() to its accept() and return the
        socket it bound."""
        entered = os.umask(umask)
        try:
            with self.assertRaises(_StopAccept):
                self.server.run()
            # Read-modify-write: os has no getumask, so the only way to see
            # what run() left behind is to set it again and read the old value.
            self.umask_after_run = os.umask(umask)
        finally:
            os.umask(entered)
        self.assertEqual(len(self.made), 1, "expected exactly one socket")
        return self.made[0]

    def test_socket_is_never_group_or_world_reachable_during_bind(self):
        srv = self._run_under_umask(0o022)
        self.assertIsNotNone(
            srv.bind_time_mode, "bind() was never called on the control socket")
        self.assertEqual(
            srv.bind_time_mode & 0o077, 0o000,
            f"control socket was mode {oct(srv.bind_time_mode)} in the window "
            f"between bind() and chmod -- another local user could connect() "
            f"there and inject input (issue #45)")

    def test_run_leaves_the_process_umask_as_it_found_it(self):
        # GUARD on the fix, not a red: os.umask is process-global and the
        # daemon creates other things (the shm frame, FrameBuffer._open_frame)
        # from other threads. A fix that narrows the umask and forgets to
        # restore it changes every later creation in the process.
        self._run_under_umask(0o022)
        self.assertEqual(self.umask_after_run, 0o022)

    def test_run_still_unlinks_a_stale_path_and_settles_at_0600(self):
        # GUARD on the fix: the end state documented at
        # dreamconnect_daemon.py:773-775 (0600, so the root SC JVM reaches it
        # by DAC override and nobody else does) and the stale-path unlink at
        # :769-770 both survive. A fix that binds an abstract socket, or one
        # that leaves the placeholder it created, fails here.
        with open(self.sock_path, "wb") as f:
            f.write(b"stale socket from a previous run")

        srv = self._run_under_umask(0o022)

        st = os.stat(self.sock_path)
        self.assertTrue(stat.S_ISSOCK(st.st_mode), "path is not a socket")
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
        self.assertTrue(srv.listened, "socket was never put in listening state")


if __name__ == "__main__":
    unittest.main()
