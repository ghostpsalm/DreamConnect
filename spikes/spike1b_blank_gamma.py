#!/usr/bin/env python3
"""Zero the CRTC gamma to black the physical scanout, and measure whether the
operator's capture stays live (pre-gamma => feasible) and whether it HOLDS
through injected input. Restores gamma in a finally at the end."""
import os
import socket
import struct
import time
from gi.repository import Gio, GLib

BUS = Gio.bus_get_sync(Gio.BusType.SESSION, None)
DEST = "org.gnome.Mutter.DisplayConfig"
PATH = "/org/gnome/Mutter/DisplayConfig"
SHM = "/dev/shm/dreamconnect.frame"
HEADER = 64


def call(m, p): return BUS.call_sync(DEST, PATH, DEST, m, p, None,
                                     Gio.DBusCallFlags.NONE, -1, None)


def active_crtc():
    serial, crtcs, *_ = call("GetResources", None).unpack()
    cid = next(cr[0] for cr in crtcs if cr[6] not in (-1, 4294967295))
    return serial, cid


def set_gamma(cid, r, g, b):
    s, _ = active_crtc()
    call("SetCrtcGamma", GLib.Variant("(uuaqaqaq)", (s, cid, r, g, b)))


def opview():
    with open(SHM, "rb") as f:
        h = f.read(HEADER)
        w, ht, st = struct.unpack_from("<III", h, 8)
        seq = struct.unpack_from("<Q", h, 32)[0]
        f.seek(HEADER + st * (ht // 2))
        buf = f.read(min(300000, st * (ht // 4)))
    mean = sum(buf) / len(buf)
    return f"seq={seq} mean={mean:.0f} {'BLACK' if mean < 2 else 'content'}"


c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], "dreamconnect.sock"))
c.sendall(b"PING\n"); c.recv(16)
time.sleep(2.0)  # let gwatch snapshot gamma first

serial, cid = active_crtc()
r, g, b = call("GetCrtcGamma", GLib.Variant("(uu)", (serial, cid))).unpack()
r, g, b = list(r), list(g), list(b)
zeros = [0] * len(r)
print(f"baseline  | operator-view: {opview()}")

try:
    set_gamma(cid, zeros, zeros, zeros)   # black the physical scanout
    print(">> gamma zeroed (physical scanout should be black)")
    time.sleep(0.8)
    print(f"blanked   | operator-view: {opview()}")
    for i in range(6):
        c.sendall(f"M {400+i*40} {300+i*25}\n".encode())
        time.sleep(0.4)
        print(f"  +motion {i} | operator-view: {opview()}")
except Exception as e:
    print("!! gamma test error:", e)
finally:
    for attempt in range(5):
        try:
            set_gamma(cid, r, g, b)
            print(">> gamma restored")
            break
        except Exception as e:
            print(f"restore retry {attempt}: {e}"); time.sleep(0.5)
    print(f"restored  | operator-view: {opview()}")
    c.close()
