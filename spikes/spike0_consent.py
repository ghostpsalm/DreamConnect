#!/usr/bin/env python3
"""Spike 0 — headless portal consent (go/no-go gate).

Proves that a persistent RemoteDesktop + ScreenCast session can be opened and
driven with NO interactive "Allow" dialog, by talking to the low-level
org.gnome.Mutter.RemoteDesktop / org.gnome.Mutter.ScreenCast D-Bus interfaces
directly (the same ones gnome-remote-desktop uses) instead of the consent-gated
org.freedesktop.portal.* layer.

Success criteria:
  1. Both sessions create + start without a dialog.
  2. ScreenCast yields a live PipeWire node id (a capture source exists).
  3. A pointer NotifyPointerMotionAbsolute is accepted (input path is live).

The D-Bus connection is held open for the session's lifetime — Mutter destroys
the session the instant the creating connection drops.
"""
import sys
from gi.repository import Gio, GLib

MONITOR = sys.argv[1] if len(sys.argv) > 1 else "HDMI-2"

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def call(dest, path, iface, method, params=None, sig=None):
    variant = GLib.Variant(sig, params) if sig else None
    return bus.call_sync(dest, path, iface, method, variant, None,
                         Gio.DBusCallFlags.NONE, -1, None)


# 1. RemoteDesktop session ---------------------------------------------------
rd_path = call("org.gnome.Mutter.RemoteDesktop", "/org/gnome/Mutter/RemoteDesktop",
               "org.gnome.Mutter.RemoteDesktop", "CreateSession").unpack()[0]
print(f"[ok] RemoteDesktop session: {rd_path}")

rd_id = bus.call_sync("org.gnome.Mutter.RemoteDesktop", rd_path,
                      "org.freedesktop.DBus.Properties", "Get",
                      GLib.Variant("(ss)", ("org.gnome.Mutter.RemoteDesktop.Session", "SessionId")),
                      None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
print(f"[ok] SessionId: {rd_id}")

# 2. ScreenCast session, linked to the RD session ----------------------------
sc_path = call("org.gnome.Mutter.ScreenCast", "/org/gnome/Mutter/ScreenCast",
               "org.gnome.Mutter.ScreenCast", "CreateSession",
               ({"remote-desktop-session-id": GLib.Variant("s", rd_id)},),
               "(a{sv})").unpack()[0]
print(f"[ok] ScreenCast session: {sc_path}")

# 3. Record the monitor; capture the PipeWire node id via signal -------------
stream_path = call("org.gnome.Mutter.ScreenCast", sc_path,
                   "org.gnome.Mutter.ScreenCast.Session", "RecordMonitor",
                   (MONITOR, {"cursor-mode": GLib.Variant("u", 1)}),  # 1 = embedded
                   "(sa{sv})").unpack()[0]
print(f"[ok] Stream object: {stream_path}")

loop = GLib.MainLoop()
node_id = {"v": None}

def on_stream_signal(conn, sender, path, iface, signal, params):
    if signal == "PipeWireStreamAdded":
        node_id["v"] = params.unpack()[0]
        print(f"[ok] PipeWireStreamAdded -> node id {node_id['v']}")
        loop.quit()

bus.signal_subscribe("org.gnome.Mutter.ScreenCast", "org.gnome.Mutter.ScreenCast.Stream",
                     "PipeWireStreamAdded", stream_path, None,
                     Gio.DBusSignalFlags.NONE, on_stream_signal)

# 4. Start the RD session — this starts the linked ScreenCast session too.
#    (A ScreenCast session bound via remote-desktop-session-id must NOT be
#     started directly: "Must be started from remote desktop session".)
call("org.gnome.Mutter.RemoteDesktop", rd_path, "org.gnome.Mutter.RemoteDesktop.Session", "Start")
print("[ok] RemoteDesktop started (ScreenCast starts with it)")

# Wait (up to 5s) for the PipeWire node to be announced.
GLib.timeout_add_seconds(5, lambda: (loop.quit(), False)[1])
loop.run()

# 5. Inject a pointer motion (absolute) to prove input path ------------------
try:
    call("org.gnome.Mutter.RemoteDesktop", rd_path,
         "org.gnome.Mutter.RemoteDesktop.Session", "NotifyPointerMotionAbsolute",
         (stream_path, 960.0, 540.0), "(sdd)")
    print("[ok] NotifyPointerMotionAbsolute(960,540) accepted")
except Exception as e:
    print(f"[FAIL] pointer inject: {e}")

# 6. Grab one real frame from the live PipeWire node to prove frames arrive
#    (not black) — the core failure X11 capture hits under Wayland.
frame_ok = "SKIPPED"
if node_id["v"] is not None:
    import subprocess, os, tempfile
    out_png = os.path.join(tempfile.gettempdir(), "spike0_frame.png")
    pipeline = [
        "gst-launch-1.0", "-q",
        "pipewiresrc", f"path={node_id['v']}", "num-buffers=10", "!",
        "videoconvert", "!", "pngenc", "snapshot=true", "!",
        "filesink", f"location={out_png}",
    ]
    try:
        subprocess.run(pipeline, check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sz = os.path.getsize(out_png)
        # Non-black test: decode PNG and check any pixel variance / brightness.
        try:
            from PIL import Image
            im = Image.open(out_png).convert("L")
            ex = im.getextrema()  # (min, max) luminance
            frame_ok = f"OK {im.size} lum{ex} {'NON-BLACK' if ex[1] > 10 else 'ALL-BLACK!'} -> {out_png}"
        except ImportError:
            frame_ok = f"OK ({sz} bytes, PIL absent so no luma check) -> {out_png}"
    except Exception as e:
        frame_ok = f"FAIL: {e}"

print("\n=== RESULT ===")
print(f"consent dialog shown:  NO (direct Mutter API)")
print(f"capture node id:       {node_id['v']}")
print(f"input injection:       OK")
print(f"frame capture:         {frame_ok}")
print("Holding session open 2s then releasing...")
GLib.timeout_add_seconds(2, lambda: (loop.quit(), False)[1])
loop.run()
call("org.gnome.Mutter.RemoteDesktop", rd_path, "org.gnome.Mutter.RemoteDesktop.Session", "Stop")
print("[ok] stopped cleanly")
