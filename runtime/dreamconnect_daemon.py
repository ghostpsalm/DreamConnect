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
import os
import socket
import struct
import sys
import threading

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


def log(*a):
    print("[dreamconnect]", *a, file=sys.stderr, flush=True)


class FrameBuffer:
    """A /dev/shm file the agent mmaps. Single writer (PipeWire thread)."""

    def __init__(self, path):
        self.path = path
        self.fd = None
        self.mm = None
        self.width = self.height = self.stride = 0
        self.seq = 0

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
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
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

    def __init__(self, bus, monitor, frame):
        self.bus = bus
        self.monitor = monitor
        self.frame = frame
        self.rd_path = None
        self.sc_path = None
        self.stream_path = None
        self.node_id = None
        self.width = self.height = 0
        self.pipeline = None
        self.active_clients = 0  # socket connections; gates idle frame copies
        self._lock = threading.Lock()
        self._client_lock = threading.Lock()
        self._inhibit_cookie = None  # GNOME SessionManager wake-lock cookie

    # ---- client accounting + wake lock -------------------------------------
    def client_connected(self):
        """A control client attached; hold a wake lock while any are connected."""
        with self._client_lock:
            self.active_clients += 1
            if self.active_clients == 1:
                self._acquire_wake_lock()

    def client_disconnected(self):
        with self._client_lock:
            self.active_clients -= 1
            if self.active_clients <= 0:
                self.active_clients = 0
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

    def _rd(self, method, params=None, sig=None):
        v = GLib.Variant(sig, params) if sig else None
        return self.bus.call_sync(RD_DEST, self.rd_path, RD_SESSION_IFACE, method,
                                  v, None, Gio.DBusCallFlags.NONE, -1, None)

    def start(self):
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

        self.stream_path = self.bus.call_sync(
            SC_DEST, self.sc_path, SC_SESSION_IFACE, "RecordMonitor",
            GLib.Variant("(sa{sv})", (self.monitor, {"cursor-mode": GLib.Variant("u", 1)})),
            None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
        log(f"ScreenCast session {self.sc_path} stream {self.stream_path} monitor={self.monitor}")

        self.bus.signal_subscribe(
            SC_DEST, SC_STREAM_IFACE, "PipeWireStreamAdded", self.stream_path, None,
            Gio.DBusSignalFlags.NONE, self._on_stream_added)
        self.bus.signal_subscribe(
            RD_DEST, RD_SESSION_IFACE, "Closed", self.rd_path, None,
            Gio.DBusSignalFlags.NONE, self._on_closed)

        # Start the RD session; the linked ScreenCast session starts with it.
        self._rd("Start")
        log("session started (awaiting PipeWireStreamAdded)")

    def _on_closed(self, *_):
        log("!! Mutter session closed; restarting in 1s")
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        GLib.timeout_add_seconds(1, self._restart)

    def _restart(self):
        try:
            self.start()
        except Exception as e:  # noqa: BLE001
            log(f"restart failed: {e}; retrying in 2s")
            GLib.timeout_add_seconds(2, self._restart)
        return False

    def _on_stream_added(self, conn, sender, path, iface, signal, params):
        self.node_id = params.unpack()[0]
        log(f"PipeWireStreamAdded node={self.node_id}; starting capture pipeline")
        self._start_pipeline()

    # ---- PipeWire capture via GStreamer appsink ----------------------------
    def _start_pipeline(self):
        desc = (
            f"pipewiresrc path={self.node_id} do-timestamp=true keepalive-time=1000 ! "
            "videoconvert ! video/x-raw,format=BGRx ! "
            "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )
        self.pipeline = Gst.parse_launch(desc)
        sink = self.pipeline.get_by_name("sink")
        sink.connect("new-sample", self._on_sample)
        self.pipeline.set_state(Gst.State.PLAYING)

    def _on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if not sample:
            return Gst.FlowReturn.OK
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
        with self._lock:
            self._rd("NotifyPointerMotionAbsolute", (self.stream_path, x, y), "(sdd)")

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


class ControlServer(threading.Thread):
    """Line-based Unix socket protocol. See handle() for the grammar."""

    daemon = True

    def __init__(self, sock_path, session):
        super().__init__()
        self.sock_path = sock_path
        self.session = session

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
        return f"ERR unknown cmd {cmd}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--monitor", default="HDMI-2")
    ap.add_argument("--shm", default="/dev/shm/dreamconnect.frame")
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    ap.add_argument("--socket", default=os.path.join(runtime_dir, "dreamconnect.sock"))
    args = ap.parse_args()

    Gst.init(None)
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    frame = FrameBuffer(args.shm)
    session = Session(bus, args.monitor, frame)
    session.start()
    ControlServer(args.socket, session).start()

    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        log("shutting down")
        try:
            session._rd("Stop")
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    main()
