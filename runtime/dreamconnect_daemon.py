#!/usr/bin/env python3
"""dreamconnect runtime daemon.

Holds a persistent headless Mutter RemoteDesktop + ScreenCast session (proven in
Spike 0 — no portal consent dialog), captures the shared monitor via PipeWire,
and exposes two things the in-JVM Java agent consumes:

  * a shared-memory frame buffer (/dev/shm/dreamconnect.frame) holding the latest
    desktop frame as BGRx, updated push-style from PipeWire, read pull-style by
    the agent's Robot.createScreenCapture hook (a seqlock guards torn reads);
  * a Unix-socket control channel for input injection + geometry queries, which
    the daemon forwards to Mutter's RemoteDesktop Notify* methods.

Runs as the desktop user (uid 1000) so it owns the user session bus. The SC JVM
runs as root and reads the socket + shm directly (root bypasses perms).

Why a separate daemon instead of JNI inside SC's JVM: the Mutter session is bound
to the D-Bus *connection* lifetime, so it must be held by a stable long-lived
process; and keeping libpipewire/GStreamer out of the client JVM means a capture
crash can't take down the remote-support session. It also survives SC updates.
"""
import argparse
import base64
import getpass
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst  # noqa: E402

# ---- shared-memory frame layout -------------------------------------------
# 64-byte header (little-endian) followed by BGRx pixel data.
#   0  4s  magic  "DCF1"
#   4  I   version (1)
#   8  I   width
#   12 I   height
#   16 I   stride (bytes per row)
#   20 I   format (0 = BGRx, 8 bits/channel)
#   24 Q   seq_begin  (seqlock: writer bumps before copy)
#   32 Q   seq_end    (seqlock: writer sets == seq_begin after copy)
#   40..63 reserved
HEADER_SIZE = 64
MAGIC = b"DCF1"
FORMAT_BGRX = 0

# ---- evdev button codes (Linux input-event-codes) --------------------------
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112

RD_DEST = "org.gnome.Mutter.RemoteDesktop"
RD_PATH = "/org/gnome/Mutter/RemoteDesktop"
RD_IFACE = "org.gnome.Mutter.RemoteDesktop"
RD_SESSION_IFACE = "org.gnome.Mutter.RemoteDesktop.Session"
SC_DEST = "org.gnome.Mutter.ScreenCast"
SC_PATH = "/org/gnome/Mutter/ScreenCast"
SC_IFACE = "org.gnome.Mutter.ScreenCast"
SC_SESSION_IFACE = "org.gnome.Mutter.ScreenCast.Session"
SC_STREAM_IFACE = "org.gnome.Mutter.ScreenCast.Stream"


# Upper bound on a --virtual resolution. Mutter will happily create an enormous
# virtual monitor, and every frame is copied into shm at width*height*4 bytes,
# so a typo (192000x1080) must be refused rather than allocated.
MAX_DIMENSION = 16384


def log(*a):
    print("[dreamconnect]", *a, file=sys.stderr, flush=True)


def _now_ms():
    return int(time.monotonic() * 1000)


def parse_resolution(text):
    """'1920x1080' -> (1920, 1080). Raises ValueError on anything else."""
    parts = str(text).strip().lower().split("x")
    if len(parts) != 2:
        raise ValueError(f"expected WxH, got {text!r}")
    try:
        w, h = int(parts[0]), int(parts[1])
    except ValueError:
        raise ValueError(f"expected WxH with integer dimensions, got {text!r}") from None
    if w < 1 or h < 1:
        raise ValueError(f"resolution must be positive, got {text!r}")
    if w > MAX_DIMENSION or h > MAX_DIMENSION:
        raise ValueError(f"resolution exceeds {MAX_DIMENSION}px per side: {text!r}")
    return w, h


class FrameBuffer:
    """A /dev/shm file the agent mmaps. Single writer (PipeWire thread)."""

    def __init__(self, path):
        self.path = path
        self.fd = None
        self.mm = None
        self.width = self.height = self.stride = 0
        self.seq = 0

    def _open_frame(self):
        """Open the shm frame read-write, reclaiming a stale one if needed.

        A frame left behind by a previous install under a *different* account —
        the usual cause being a switch to a display-host account — is owned by
        that account and mode 0600, so every open fails with EACCES. Without
        this the daemon logs the same PermissionError forever and the operator
        sees a desktop frozen on the last frame the old install wrote (#27).

        Note /dev/shm is sticky, so unlinking only succeeds for a frame this
        account owns (or when running as root). When it doesn't, say who owns
        the path rather than retrying silently.
        """
        try:
            return os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        except PermissionError:
            pass
        try:
            owner = os.stat(self.path).st_uid
        except OSError:
            owner = -1
        try:
            os.unlink(self.path)
        except OSError as e:
            raise OSError(
                f"cannot use the shared-memory frame {self.path}: it is owned by "
                f"uid {owner}, this process is uid {os.getuid()}, and it could not "
                f"be removed ({e}). Delete it and restart the daemon."
            ) from None
        log(f"reclaimed stale frame {self.path} (was owned by uid {owner})")
        return os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)

    def ensure(self, width, height, stride):
        if (width, height, stride) == (self.width, self.height, self.stride) and self.mm:
            return
        import mmap
        size = HEADER_SIZE + stride * height
        # Recreate at the right size.
        if self.mm:
            self.mm.close()
        if self.fd is not None:
            os.close(self.fd)
        # 0600: the only intended reader is the root ScreenConnect JVM, which
        # bypasses DAC — so owner-only keeps other local users from scraping the
        # screen out of /dev/shm (which is world-traversable). fchmod overrides
        # any inherited umask.
        self.fd = self._open_frame()
        os.fchmod(self.fd, 0o600)
        os.ftruncate(self.fd, size)
        self.mm = mmap.mmap(self.fd, size)
        self.width, self.height, self.stride = width, height, stride
        struct.pack_into("<4sIIIII", self.mm, 0, MAGIC, 1, width, height, stride, FORMAT_BGRX)
        log(f"frame buffer {width}x{height} stride={stride} ({size} bytes) at {self.path}")

    def write(self, data, width, height, stride):
        self.ensure(width, height, stride)
        self.seq += 1
        # seqlock: bump begin, copy, set end. Reader retries while begin != end.
        struct.pack_into("<Q", self.mm, 24, self.seq)
        self.mm[HEADER_SIZE:HEADER_SIZE + len(data)] = data
        struct.pack_into("<Q", self.mm, 32, self.seq)


class Session:
    """Persistent Mutter RemoteDesktop + linked ScreenCast session."""

    def __init__(self, bus, monitor, frame, all_monitors=False, virtual=None,
                 stall_timeout_ms=4000):
        self.bus = bus
        self.monitor = monitor
        # Frames can stop arriving while the RemoteDesktop session stays alive
        # (Mutter pausing the screencast, a PipeWire node vanishing with no
        # GStreamer error) — input keeps working but the desktop is frozen. The
        # pipeline uses keepalive-time=1000, so a healthy stream emits >=1 fps
        # even on a static screen; this many ms with no frame while a client is
        # attached therefore means stalled, not idle, and triggers a rebuild.
        self.stall_timeout_ms = stall_timeout_ms
        self._last_frame_ms = 0  # 0 = pipeline not started yet; seeded on start
        self.all_monitors = all_monitors  # capture the whole logical desktop
        # (w, h) to capture a Mutter-conjured virtual monitor via RecordVirtual
        # instead of a physical connector — the backstage/headless mode, which
        # needs no monitor, no dummy plug and no login. None = physical capture.
        self.virtual = virtual
        self.area_x = 0  # origin of the captured area in desktop coords (RecordArea)
        self.area_y = 0
        self.frame = frame
        self.rd_path = None
        self.sc_path = None
        self.stream_path = None
        self.node_id = None
        self.width = self.height = 0
        self.pipeline = None
        self._sub_ids = []          # D-Bus signal subscriptions, cleared on restart
        self._restarting = False    # guards against overlapping session restarts
        self.active_clients = 0  # socket connections; gates idle frame copies
        self._lock = threading.Lock()
        self._client_lock = threading.Lock()
        self._inhibit_cookie = None  # GNOME SessionManager wake-lock cookie
        self._blank_lock = threading.Lock()
        self._saved_gamma = None  # {crtc_id: (r,g,b)} while the monitor is blanked

    # ---- stall detection ---------------------------------------------------
    def note_frame(self, now_ms):
        """Record that a frame (or a keepalive repeat) reached the appsink."""
        self._last_frame_ms = now_ms

    def is_stalled(self, now_ms):
        """True when a client is attached but no frame has arrived within the
        timeout. Pure and side-effect-free so it can be unit-tested; the live
        watchdog supplies a monotonic clock. Never fires before the first frame
        is seeded (last_frame_ms 0), so a starting pipeline gets its grace."""
        if self.active_clients <= 0 or self._last_frame_ms == 0:
            return False
        return (now_ms - self._last_frame_ms) > self.stall_timeout_ms

    # ---- client accounting + wake lock -------------------------------------
    def client_connected(self):
        with self._client_lock:
            self.active_clients += 1

    def client_disconnected(self):
        with self._client_lock:
            self.active_clients -= 1
            if self.active_clients <= 0:
                self.active_clients = 0
                # Safety: if a session drops without releasing, don't leak the
                # inhibit and leave the box permanently awake, or leave the
                # monitor blanked (gamma zeroed) with no operator attached.
                self._release_wake_lock()
                self.set_blank(False)

    def set_wake_lock(self, on):
        """Driven by ScreenConnect's AcquireWakeLock/release command (via the
        agent hook on OSToolkit.acquireWakeLock/releaseWakeLock), not by mere
        connection presence — so it respects the operator's explicit action."""
        with self._client_lock:
            if on:
                self._acquire_wake_lock()
            else:
                self._release_wake_lock()

    def _acquire_wake_lock(self):
        # Remote input doesn't reset GNOME's idle timer, so without this the
        # session would blank + auto-lock mid-support-session. Inhibit idle (8)
        # and suspend (4) via GNOME SessionManager for the duration of the
        # connection. Best-effort: capture works regardless if this fails.
        if self._inhibit_cookie is not None:
            return
        try:
            res = self.bus.call_sync(
                "org.gnome.SessionManager", "/org/gnome/SessionManager",
                "org.gnome.SessionManager", "Inhibit",
                GLib.Variant("(susu)", ("dreamconnect", 0, "remote support session active", 12)),
                GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, -1, None)
            self._inhibit_cookie = res.unpack()[0]
            log(f"wake lock acquired (idle+suspend inhibited), cookie={self._inhibit_cookie}")
        except Exception as e:  # noqa: BLE001
            log(f"wake lock inhibit failed (session may still blank/lock): {e}")

    def _release_wake_lock(self):
        if self._inhibit_cookie is None:
            return
        try:
            self.bus.call_sync(
                "org.gnome.SessionManager", "/org/gnome/SessionManager",
                "org.gnome.SessionManager", "Uninhibit",
                GLib.Variant("(u)", (self._inhibit_cookie,)), None,
                Gio.DBusCallFlags.NONE, -1, None)
            log("wake lock released")
        except Exception as e:  # noqa: BLE001
            log(f"wake lock uninhibit failed: {e}")
        self._inhibit_cookie = None

    # ---- monitor blanking (BlankGuestMonitor) ------------------------------
    def _dc(self, method, params=None):
        """Call org.gnome.Mutter.DisplayConfig."""
        return self.bus.call_sync(
            "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig", method, params, None,
            Gio.DBusCallFlags.NONE, -1, None)

    def set_blank(self, on):
        """Driven by ScreenConnect's BlankGuestMonitor command (agent hook on
        ClientOSToolkit.blankMonitorsOrWallpapers). Blanks the *physical* panel
        by zeroing each active CRTC's gamma ramp. The ScreenCast captures the
        composited framebuffer (pre-gamma), so the operator keeps seeing the real
        desktop while a local bystander sees black. Unlike DPMS, gamma is CRTC
        state, not a wake-able power mode, so the blank holds through operator
        input. Best-effort; never raises into the control loop."""
        with self._blank_lock:
            if on:
                self._blank_on()
            else:
                self._blank_off()

    def _blank_on(self):
        if self._saved_gamma is not None:
            return  # already blanked
        saved = {}  # crtc_id -> original (r,g,b); populated as we blank each
        try:
            serial, crtcs = self._dc("GetResources").unpack()[:2]
            for cr in crtcs:
                cid, cur_mode = cr[0], cr[6]
                if cur_mode < 0:
                    continue  # inactive CRTC
                r, g, b = self._dc(
                    "GetCrtcGamma", GLib.Variant("(uu)", (serial, cid))).unpack()
                saved[cid] = (list(r), list(g), list(b))
                z = [0] * len(r)
                s = self._dc("GetResources").unpack()[0]  # fresh serial per set
                self._dc("SetCrtcGamma",
                         GLib.Variant("(uuaqaqaq)", (s, cid, z, z, z)))
            if saved:
                self._saved_gamma = saved
                log(f"monitor blanked (zeroed gamma on {len(saved)} crtc(s))")
            else:
                log("blank requested but no active CRTC found")
        except Exception as e:  # noqa: BLE001
            log(f"blank failed: {e}")
            # roll back any CRTCs we already zeroed before the failure
            self._saved_gamma = saved or None
            self._blank_off()

    def _blank_off(self):
        if self._saved_gamma is None:
            return
        for cid, (r, g, b) in self._saved_gamma.items():
            try:
                s = self._dc("GetResources").unpack()[0]
                self._dc("SetCrtcGamma",
                         GLib.Variant("(uuaqaqaq)", (s, cid, r, g, b)))
            except Exception as e:  # noqa: BLE001
                log(f"unblank crtc {cid} failed: {e}")
        log("monitor unblanked (gamma restored)")
        self._saved_gamma = None

    def _rd(self, method, params=None, sig=None):
        v = GLib.Variant(sig, params) if sig else None
        return self.bus.call_sync(RD_DEST, self.rd_path, RD_SESSION_IFACE, method,
                                  v, None, Gio.DBusCallFlags.NONE, -1, None)

    def _desktop_area(self):
        """Bounding box of all logical monitors as (x, y, w, h, count), in
        desktop/logical coordinates — or None if it can't be determined."""
        try:
            r = self.bus.call_sync(
                "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None, None,
                Gio.DBusCallFlags.NONE, -1, None)
            _serial, monitors, logical, _props = r.unpack()
            if not logical:
                return None

            def mode_dims(conn):
                for (mc, *_r), modes, _mp in monitors:
                    if mc == conn:
                        for md in modes:
                            if md[6].get("is-current"):
                                return md[1], md[2]
                return None

            minx = miny = 1 << 30
            maxx = maxy = -(1 << 30)
            for (x, y, scale, transform, _primary, mons, _lp) in logical:
                dims = mode_dims(mons[0][0])
                if not dims:
                    continue
                w = int(round(dims[0] / scale))
                h = int(round(dims[1] / scale))
                if transform in (1, 3):  # 90/270 rotation swaps w/h
                    w, h = h, w
                minx, miny = min(minx, x), min(miny, y)
                maxx, maxy = max(maxx, x + w), max(maxy, y + h)
            if maxx <= minx or maxy <= miny:
                return None
            return (minx, miny, maxx - minx, maxy - miny, len(logical))
        except Exception as e:  # noqa: BLE001
            log(f"desktop-area query failed: {e}")
            return None

    def start(self):
        # Drop any subscriptions from a previous session — start() is re-entered
        # on recovery, and the old rd_path/stream_path are gone, so leaving them
        # subscribed would leak and (worse) let a future Closed/message fire the
        # handlers multiple times, cascading restarts. Two kinds live here: plain
        # D-Bus subscription ids, and ("gst", bus, handler_id) tuples for the
        # GStreamer bus watch, which is torn down differently.
        for sid in self._sub_ids:
            try:
                if isinstance(sid, tuple) and sid[0] == "gst":
                    _, gbus, hid = sid
                    gbus.disconnect(hid)
                    gbus.remove_signal_watch()
                else:
                    self.bus.signal_unsubscribe(sid)
            except Exception:  # noqa: BLE001
                pass
        self._sub_ids = []

        # Stop the session this daemon already holds before creating its
        # replacement. Mutter conjures a virtual monitor per RecordVirtual
        # session and drops it only when that session ends, so skipping this
        # leaks one monitor per restart: the X screen grows, gnome-shell puts
        # its top bar on a monitor we do not capture, and the operator sees a
        # black half-screen next to a desktop with no top bar. Observed live
        # after 25 restarts — a 2560x720 screen for a 1280x720 session (#55).
        #
        # Failure is tolerated on purpose: the commonest reason we are here is
        # that Mutter already closed the session, and refusing to recover from
        # that would trade a leaked monitor for a dead bridge. The identifiers
        # are cleared either way, so a later stop can never aim at a corpse.
        if self.rd_path:
            try:
                self._rd("Stop")
            except Exception as e:  # noqa: BLE001
                log(f"previous session would not stop ({e}); continuing")
            self.rd_path = None
            self.sc_path = None
            self.stream_path = None
            self.node_id = None

        self.rd_path = self.bus.call_sync(
            RD_DEST, RD_PATH, RD_IFACE, "CreateSession", None, None,
            Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
        sess_id = self.bus.call_sync(
            RD_DEST, self.rd_path, "org.freedesktop.DBus.Properties", "Get",
            GLib.Variant("(ss)", (RD_SESSION_IFACE, "SessionId")), None,
            Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
        log(f"RemoteDesktop session {self.rd_path} id={sess_id}")

        self.sc_path = self.bus.call_sync(
            SC_DEST, SC_PATH, SC_IFACE, "CreateSession",
            GLib.Variant("(a{sv})", ({"remote-desktop-session-id": GLib.Variant("s", sess_id)},)),
            None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]

        # Backstage/headless: RecordVirtual takes no connector — Mutter conjures
        # the monitor, so this works with GetCurrentState reporting zero monitors
        # (no panel, no dummy plug). The output is origin-anchored, so area_x/y
        # stay 0 and the pointer maths below is a no-op, same as RecordMonitor.
        props = {"cursor-mode": GLib.Variant("u", 1)}
        if self.virtual:
            self.area_x = self.area_y = 0
            self.stream_path = self.bus.call_sync(
                SC_DEST, self.sc_path, SC_SESSION_IFACE, "RecordVirtual",
                GLib.Variant("(a{sv})", (props,)),
                None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
            log(f"ScreenCast session {self.sc_path} stream {self.stream_path} "
                f"virtual {self.virtual[0]}x{self.virtual[1]}")
            self._subscribe_and_start()
            return

        # Multi-monitor: capture the whole logical desktop (RecordArea over the
        # bounding box) when forced, or auto when more than one logical monitor
        # is present. Otherwise keep the proven single-monitor RecordMonitor.
        area = self._desktop_area()
        if area and (self.all_monitors or area[4] > 1):
            x, y, w, h, n = area
            self.area_x, self.area_y = x, y
            self.stream_path = self.bus.call_sync(
                SC_DEST, self.sc_path, SC_SESSION_IFACE, "RecordArea",
                GLib.Variant("(iiiia{sv})", (x, y, w, h, props)),
                None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
            log(f"ScreenCast session {self.sc_path} stream {self.stream_path} "
                f"area ({x},{y}) {w}x{h} spanning {n} monitor(s)")
        else:
            self.area_x = self.area_y = 0
            self.stream_path = self.bus.call_sync(
                SC_DEST, self.sc_path, SC_SESSION_IFACE, "RecordMonitor",
                GLib.Variant("(sa{sv})", (self.monitor, props)),
                None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
            log(f"ScreenCast session {self.sc_path} stream {self.stream_path} monitor={self.monitor}")

        self._subscribe_and_start()

    def _subscribe_and_start(self):
        """Common tail of every capture mode: subscribe to the stream/session
        signals and start the RD session."""
        self._sub_ids.append(self.bus.signal_subscribe(
            SC_DEST, SC_STREAM_IFACE, "PipeWireStreamAdded", self.stream_path, None,
            Gio.DBusSignalFlags.NONE, self._on_stream_added))
        self._sub_ids.append(self.bus.signal_subscribe(
            RD_DEST, RD_SESSION_IFACE, "Closed", self.rd_path, None,
            Gio.DBusSignalFlags.NONE, self._on_closed))

        # Start the RD session; the linked ScreenCast session starts with it.
        self._rd("Start")
        log("session started (awaiting PipeWireStreamAdded)")

    def _on_closed(self, *_):
        log("!! Mutter session closed; restarting in 1s")
        self._recover()

    def _restart(self):
        try:
            self.start()
            self._restarting = False
        except Exception as e:  # noqa: BLE001
            log(f"restart failed: {e}; retrying in 2s")
            GLib.timeout_add_seconds(2, self._restart)
        return False

    def _on_stream_added(self, conn, sender, path, iface, signal, params):
        self.node_id = params.unpack()[0]
        log(f"PipeWireStreamAdded node={self.node_id}; starting capture pipeline")
        self._start_pipeline()

    # ---- PipeWire capture via GStreamer appsink ----------------------------
    def _pipeline_desc(self):
        # A RecordVirtual stream has no intrinsic size — the virtual monitor is
        # sized by what the consumer asks for, and asking for nothing negotiates
        # a 1x1 frame (verified against mutter 50.1). So the requested size IS
        # the session resolution and must be pinned here. The physical paths
        # (RecordMonitor/RecordArea) must NOT pin one: there the size comes from
        # the monitor, and forcing a different one would scale every frame.
        caps = "video/x-raw,format=BGRx"
        if self.virtual:
            caps += f",width={self.virtual[0]},height={self.virtual[1]}"
        return (
            f"pipewiresrc path={self.node_id} do-timestamp=true keepalive-time=1000 ! "
            f"videoconvert ! {caps} ! "
            "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )

    def _start_pipeline(self):
        self.pipeline = Gst.parse_launch(self._pipeline_desc())
        sink = self.pipeline.get_by_name("sink")
        sink.connect("new-sample", self._on_sample)
        # Seed the stall clock: the watchdog must give a just-started pipeline
        # the full timeout to produce its first frame rather than firing at once.
        self.note_frame(_now_ms())
        # Watch the GStreamer bus: a pipewiresrc that errors or EOSes (the node
        # went away) would otherwise leave the pipeline dead and unnoticed. The
        # silent-stall case — frames simply stop with no message — is caught by
        # the frame watchdog instead.
        gbus = self.pipeline.get_bus()
        gbus.add_signal_watch()
        self._sub_ids.append(("gst", gbus, gbus.connect("message", self._on_gst_message)))
        self.pipeline.set_state(Gst.State.PLAYING)

    def _on_gst_message(self, _bus, msg):
        t = msg.type
        if t == Gst.MessageType.ERROR:
            err, _dbg = msg.parse_error()
            log(f"!! GStreamer pipeline error: {err.message}; recovering")
            self._recover()
        elif t == Gst.MessageType.EOS:
            log("!! GStreamer pipeline EOS (capture node gone); recovering")
            self._recover()

    def _watchdog(self):
        """Periodic: rebuild the session if a client is attached but frames have
        stopped. Returns True to stay scheduled."""
        try:
            if self.is_stalled(_now_ms()) and not self._restarting:
                stalled_ms = _now_ms() - self._last_frame_ms
                log(f"!! capture stalled ({stalled_ms} ms, no frame with a client "
                    f"attached); recovering")
                self._recover()
        except Exception as e:  # noqa: BLE001
            log(f"watchdog error: {e}")
        return True

    def _recover(self):
        """Shared restart path for a Mutter session close, a GStreamer
        error/EOS, or a detected stall. Guarded so overlapping triggers schedule
        exactly one restart."""
        if self._restarting:
            return
        self._restarting = True
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        GLib.timeout_add_seconds(1, self._restart)

    def _on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if not sample:
            return Gst.FlowReturn.OK
        # A frame reached us (real damage, or a keepalive repeat). Record it for
        # the watchdog before the client gate, so liveness reflects the actual
        # PipeWire stream, not whether anyone is currently reading.
        self.note_frame(_now_ms())
        # No agent attached: drain the sample (drop=true handles the queue) but
        # skip the ~8 MB map+copy into shm — nothing is reading it.
        if self.active_clients == 0:
            return Gst.FlowReturn.OK
        buf = sample.get_buffer()
        caps = sample.get_caps().get_structure(0)
        w = caps.get_value("width")
        h = caps.get_value("height")
        ok, mapinfo = buf.map(Gst.MapFlags.READ)
        if ok:
            stride = mapinfo.size // h  # BGRx => normally w*4, but honour actual
            try:
                self.frame.write(mapinfo.data, w, h, stride)
            finally:
                buf.unmap(mapinfo)
            if (w, h) != (self.width, self.height):
                self.width, self.height = w, h
                log(f"stream geometry {w}x{h}")
        return Gst.FlowReturn.OK

    # ---- input injection (called from the socket thread) -------------------
    def motion_abs(self, x, y):
        # Coordinates are relative to the captured stream. For RecordArea the
        # stream origin is the area's top-left (area_x/area_y), so shift the
        # desktop coordinate SC gives us into the stream's frame; for
        # RecordMonitor area_x/area_y are 0 and this is a no-op.
        with self._lock:
            self._rd("NotifyPointerMotionAbsolute",
                     (self.stream_path, x - self.area_x, y - self.area_y), "(sdd)")

    def button(self, evdev_button, state):
        with self._lock:
            self._rd("NotifyPointerButton", (evdev_button, state), "(ib)")

    def axis_discrete(self, axis, steps):
        with self._lock:
            self._rd("NotifyPointerAxisDiscrete", (axis, steps), "(ui)")

    def key_code(self, evdev_keycode, state):
        with self._lock:
            self._rd("NotifyKeyboardKeycode", (evdev_keycode, state), "(ub)")

    def key_sym(self, keysym, state):
        with self._lock:
            self._rd("NotifyKeyboardKeysym", (keysym, state), "(ub)")

    # ---- clipboard-text typing (ScreenConnect SendClipboardKeystrokes) ------
    @staticmethod
    def _keymappable(c):
        # Printable ASCII (+ newline/tab) — the keys the layout can produce.
        return c in "\n\t" or 0x20 <= ord(c) < 0x7f

    def type_string(self, text):
        """Type a string on the remote. Keymappable text goes via keysym
        injection (works even in paste-blocked fields, which is the point of
        'insert clipboard text'); text containing characters Mutter's keysym
        injection can't reach (non-ASCII/Unicode) falls back to a clipboard
        paste."""
        if not text:
            return
        if all(self._keymappable(c) for c in text):
            for c in text:
                ks = 0xff0d if c == "\n" else 0xff09 if c == "\t" else ord(c)
                self.key_sym(ks, True)
                self.key_sym(ks, False)
                time.sleep(0.005)  # pacing so fast keysyms aren't dropped
            log(f"typed {len(text)} chars via keysym")
        else:
            self._paste_text(text)

    def _paste_text(self, text):
        env = dict(os.environ,
                   WAYLAND_DISPLAY=os.environ.get("WAYLAND_DISPLAY", "wayland-0"))
        try:
            subprocess.run(["wl-copy"], input=text.encode(), env=env,
                           timeout=3, check=True)
        except Exception as e:  # noqa: BLE001
            log(f"wl-copy failed; cannot paste non-ASCII text: {e}")
            return
        # Ctrl+V via evdev keycodes (LEFTCTRL=29, V=47).
        for kc, st in ((29, True), (47, True), (47, False), (29, False)):
            self.key_code(kc, st)
        log(f"pasted {len(text)} chars via clipboard (contained non-keymappable chars)")


def _unset_if_blank(value):
    """A blank string is an absent value, not a value. Shared by the display
    and label paths so both treat a unit's unexpanded variable the same way."""
    return value.strip() if value and value.strip() else None


def resolve_display(arg, env):
    """The X display this daemon's session owns, or None if we can't tell.

    The --display arg wins: backstage units know their display and pass it in,
    and the shell they start from may carry a $DISPLAY of its own. A classic
    daemon under graphical-session.target has no arg and inherits $DISPLAY.

    Blank is unset, not a display: a systemd unit expanding a variable that was
    never set ships a blank argument, and whitespace must never reach the
    agent's picker as if it named a session.
    """
    return _unset_if_blank(arg) or _unset_if_blank(env.get("DISPLAY")) or None


class ControlServer(threading.Thread):
    """Line-based Unix socket protocol. See handle() for the grammar."""

    daemon = True

    def __init__(self, sock_path, session, display=None, label=None):
        super().__init__()
        self.sock_path = sock_path
        self.session = session
        self.display = display
        self.label = label

    def run(self):
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        # 0600, not 0666: the root SC JVM connects via DAC override. Don't rely
        # solely on the 0700 XDG_RUNTIME_DIR parent to gate access.
        os.chmod(self.sock_path, 0o600)
        srv.listen(8)
        log(f"control socket at {self.sock_path}")
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self._client, args=(conn,), daemon=True).start()

    def _client(self, conn):
        self.session.client_connected()
        try:
            with conn, conn.makefile("rwb", buffering=0) as f:
                for raw in f:
                    try:
                        reply = self.handle(raw.decode("ascii", "replace").strip())
                    except Exception as e:  # noqa: BLE001
                        reply = f"ERR {e}"
                    if reply is not None:
                        f.write((reply + "\n").encode("ascii"))
        finally:
            self.session.client_disconnected()

    def handle(self, line):
        if not line:
            return None
        parts = line.split()
        cmd, args = parts[0].upper(), parts[1:]
        s = self.session
        # Input commands are fire-and-forget: they return None (no reply) so the
        # agent's hot input path never waits for an ack. Errors are logged, not
        # returned, to keep the reply stream aligned with control commands only.
        try:
            if cmd == "M":  # M x y  (absolute, in screen pixels)
                s.motion_abs(float(args[0]), float(args[1]))
                return None
            if cmd == "B":  # B evdev_button state
                s.button(int(args[0]), args[1] == "1")
                return None
            if cmd == "W":  # W axis steps  (axis 0=vertical 1=horizontal)
                s.axis_discrete(int(args[0]), int(args[1]))
                return None
            if cmd == "K":  # K evdev_keycode state
                s.key_code(int(args[0]), args[1] == "1")
                return None
            if cmd == "KS":  # KS keysym state
                s.key_sym(int(args[0]), args[1] == "1")
                return None
            if cmd == "WAKELOCK":  # WAKELOCK 1|0 (operator AcquireWakeLock command)
                s.set_wake_lock(args[0] == "1")
                return None
            if cmd == "BLANK":  # BLANK 1|0 (operator BlankGuestMonitor command)
                s.set_blank(args[0] == "1")
                return None
            if cmd == "TYPE":  # TYPE <base64-utf8> (SendClipboardKeystrokes)
                s.type_string(base64.b64decode(args[0]).decode("utf-8", "replace"))
                return None
        except Exception as e:  # noqa: BLE001
            log(f"input error on '{line}': {e}")
            return None
        # Request/reply control commands (low frequency).
        if cmd == "PING":
            return "PONG"
        if cmd == "GEOM":
            return f"{s.width} {s.height}"
        if cmd == "NODE":
            return str(s.node_id)
        if cmd == "WHO":
            # The picker entry for this session. Defaults to the desktop user's
            # login name: the daemon runs as that user; the agent (root, inside
            # ScreenConnect's JVM) can't derive it, so it asks us — it uses this
            # to relabel the logon session in the operator's session picker with
            # a friendlier name. --label overrides it verbatim (backstage);
            # a blank label is unset, so the login name still answers.
            return _unset_if_blank(self.label) or getpass.getuser()
        if cmd == "DUPES":
            # Users holding more than one graphical session, so the operator can
            # see a double login rather than discover it later. Reported only:
            # we never end a session we did not create. Modes that cannot tell
            # (the Mutter path) answer empty rather than ERR, so the agent can
            # ask unconditionally.
            finder = getattr(s, "duplicate_sessions", None)
            if not finder:
                return ""
            return " ".join(f"{user}:{','.join(ids)}" for user, ids in finder())
        if cmd == "DISPLAY":
            # Which X display this session owns, so the agent can match a picker
            # entry to the right daemon instead of assuming the JVM's $DISPLAY.
            # A blank display is UNKNOWN, never whitespace on the wire.
            return _unset_if_blank(self.display) or "UNKNOWN"
        return f"ERR unknown cmd {cmd}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monitor", default="HDMI-2")
    ap.add_argument("--all-monitors", action="store_true",
                    help="capture the whole logical desktop (RecordArea) instead "
                         "of a single monitor; auto-enabled when >1 monitor")
    ap.add_argument("--virtual", metavar="WxH",
                    help="backstage mode: capture a Mutter-conjured virtual "
                         "monitor (RecordVirtual) at this resolution instead of a "
                         "physical connector. Needs no monitor, no dummy plug and "
                         "no login; overrides --monitor/--all-monitors.")
    ap.add_argument("--greeter", action="store_true",
                    help="greeter mode: serve the GDM login screen by acting as "
                         "an RDP client of the local gnome-remote-desktop system "
                         "(Remote Login) service, so an operator can log the box "
                         "in. Needs no Mutter session of its own and overrides "
                         "--monitor/--all-monitors/--virtual.")
    ap.add_argument("--rdp-host", default="127.0.0.1",
                    help="greeter mode: remote-login host (default: loopback; "
                         "there is no reason to point this off-box)")
    ap.add_argument("--rdp-port", type=int, default=3389,
                    help="greeter mode: remote-login port")
    ap.add_argument("--rdp-user", default="dreamconnect",
                    help="greeter mode: remote-login transport username")
    ap.add_argument("--rdp-password-file",
                    help="greeter mode: file holding the remote-login transport "
                         "password. A file, not an argument, so the credential "
                         "never appears in argv or /proc.")
    ap.add_argument("--greeter-display", default=":89",
                    help="greeter mode: private X display the RDP client draws on")
    ap.add_argument("--greeter-size", default="1920x1080",
                    help="greeter mode: resolution to request from the login view")
    ap.add_argument("--shm", default="/dev/shm/dreamconnect.frame")
    ap.add_argument("--stall-timeout-ms", type=int, default=4000,
                    help="rebuild the capture session if a client is attached but "
                         "no frame arrives within this many ms (0 disables the "
                         "watchdog). keepalive-time keeps a healthy stream >=1 fps, "
                         "so this only fires on a real stall, not an idle screen.")
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    ap.add_argument("--socket", default=os.path.join(runtime_dir, "dreamconnect.sock"))
    ap.add_argument("--display", help="X display this session owns (default: $DISPLAY)")
    ap.add_argument("--label", help="picker entry name (default: the login name)")
    args = ap.parse_args()

    virtual = None
    if args.virtual:
        try:
            virtual = parse_resolution(args.virtual)
        except ValueError as e:
            ap.error(str(e))

    greeter_size = None
    if args.greeter:
        try:
            greeter_size = parse_resolution(args.greeter_size)
        except ValueError as e:
            ap.error(str(e))
        if not args.rdp_password_file:
            ap.error("--greeter needs --rdp-password-file")

    Gst.init(None)
    frame = FrameBuffer(args.shm)
    if args.greeter:
        # Greeter mode owns no Mutter session, so it needs no session bus — it
        # is an RDP client of the local remote-login service. Importing here
        # keeps python-xlib off the dependency path for the normal modes.
        from dreamconnect_greeter import GreeterSession
        width, height = greeter_size
        session = GreeterSession(frame, width=width, height=height,
                                 display=args.greeter_display,
                                 rdp_host=args.rdp_host, rdp_port=args.rdp_port,
                                 rdp_user=args.rdp_user,
                                 password_file=args.rdp_password_file,
                                 stall_timeout_ms=args.stall_timeout_ms)
    else:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        session = Session(bus, args.monitor, frame, all_monitors=args.all_monitors,
                          virtual=virtual, stall_timeout_ms=args.stall_timeout_ms)
    session.start()
    # Greeter mode answers the picker with its own private display, not the
    # daemon's inherited $DISPLAY: the agent matches a picker entry to a daemon
    # by display, and this session's pixels live on the Xvfb, not wherever the
    # unit happened to start.
    picker_display = (args.greeter_display if args.greeter
                      else resolve_display(args.display, os.environ))
    ControlServer(args.socket, session, display=picker_display,
                  label=args.label).start()

    # Poll for a stalled capture pipeline a few times per timeout window. Disabled
    # when the timeout is 0.
    if args.stall_timeout_ms > 0:
        interval = max(1, args.stall_timeout_ms // 2000)
        GLib.timeout_add_seconds(interval, session._watchdog)

    loop = GLib.MainLoop()

    def _stop(*_):
        log("shutting down")
        loop.quit()
        return GLib.SOURCE_REMOVE

    # systemd stops us with SIGTERM (not KeyboardInterrupt), so handle both —
    # otherwise a stop/restart while the monitor is blanked would leave the
    # panel dark (gamma still zeroed).
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, _stop)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, _stop)
    try:
        loop.run()
    finally:
        # Restore any local blank + wake lock before releasing the session, so
        # we never leave the box blanked/awake after the daemon exits. Greeter
        # mode releases an Xvfb and an RDP client instead of a Mutter session;
        # leaving either behind would hold the private display against the next
        # start.
        release = session.stop if args.greeter else (lambda: session._rd("Stop"))
        for cleanup in (lambda: session.set_blank(False),
                        session._release_wake_lock,
                        release):
            try:
                cleanup()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    main()
