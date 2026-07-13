#!/usr/bin/env python3
"""Spike 1 — can we blank the physical monitor while capture keeps working?

BlankGuestMonitor is a hard no-op on the Linux ScreenConnect client. To make it
useful we'd need to darken the physical panel *while the operator still sees the
real desktop* through our PipeWire capture. This probes the cleanest available
mechanism on GNOME/Mutter — org.gnome.Mutter.DisplayConfig.PowerSaveMode (DPMS)
— and measures, from the shared-memory capture buffer, whether frames keep
flowing with real content once the panel is powered off.

Verdict logic:
  - baseline:  seq advancing + non-black  => capture live
  - blanked:   seq advancing + non-black  => FEASIBLE (operator keeps seeing)
               seq frozen OR black         => NOT FEASIBLE (operator loses view)

Always restores PowerSaveMode in a finally. Blanks for ~2.5s only.
"""
import os
import socket
import struct
import subprocess
import sys
import time

SHM = "/dev/shm/dreamconnect.frame"
SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()),
                    "dreamconnect.sock")
HEADER = 64
DBUS = ("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
        "org.gnome.Mutter.DisplayConfig", "PowerSaveMode")


def sample():
    """Return (seq_end, mean_byte, nonzero_frac) from the current frame."""
    with open(SHM, "rb") as f:
        head = f.read(HEADER)
        magic, ver, w, h, stride, fmt = struct.unpack_from("<4sIIIII", head, 0)
        seq_end = struct.unpack_from("<Q", head, 32)[0]
        # read a mid-screen strip so we're not fooled by a black taskbar edge
        mid = HEADER + stride * (h // 2)
        f.seek(mid)
        buf = f.read(min(400_000, stride * (h // 4)))
    if not buf:
        return seq_end, 0.0, 0.0
    total = sum(buf)
    nz = sum(1 for b in buf if b) / len(buf)
    return seq_end, total / len(buf), nz


def observe(label, secs=1.6):
    seqs, means = [], []
    t0 = time.time()
    while time.time() - t0 < secs:
        s, m, nz = sample()
        seqs.append(s)
        means.append((m, nz))
        time.sleep(0.2)
    advancing = seqs[-1] > seqs[0]
    mean = sum(m for m, _ in means) / len(means)
    nz = sum(n for _, n in means) / len(means)
    black = mean < 2.0 and nz < 0.02
    print(f"  {label:9s} seq {seqs[0]}->{seqs[-1]} "
          f"({'advancing' if advancing else 'FROZEN'})  "
          f"mean={mean:5.1f} nonzero={nz*100:4.1f}%  "
          f"=> {'BLACK' if black else 'content'}")
    return advancing, black


def get_power():
    out = subprocess.check_output(
        ["busctl", "--user", "get-property", *DBUS], text=True).strip()
    return int(out.split()[-1])  # "i 0" -> 0


def set_power(v):
    subprocess.check_call(["busctl", "--user", "set-property", *DBUS, "i", str(v)])


def main():
    if not os.path.exists(SHM):
        sys.exit("no shm frame; is the daemon running?")
    # hold a daemon connection so active_clients>0 and capture copies frames
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.connect(SOCK)
    c.sendall(b"PING\n")
    c.recv(64)
    time.sleep(0.5)

    saved = get_power()
    print(f"PowerSaveMode baseline = {saved}")
    print("== baseline (panel on) ==")
    b_adv, b_black = observe("baseline")
    if not b_adv or b_black:
        print("!! capture not live/non-black at baseline — reconnect an operator "
              "session first; aborting before blanking.")
        c.close()
        return

    try:
        print("== blanking: PowerSaveMode=3 (OFF) for ~2.5s ==")
        set_power(3)
        time.sleep(0.6)  # let it take effect
        k_adv, k_black = observe("blanked")
    finally:
        set_power(saved)
        print(f"restored PowerSaveMode = {saved}")
    c.close()

    print("\n=== VERDICT ===")
    if k_adv and not k_black:
        print("FEASIBLE: panel powered off but capture kept delivering real "
              "frames — operator would still see the desktop.")
    elif k_black:
        print("NOT FEASIBLE via DPMS: capture went BLACK when the panel powered "
              "off — operator loses the view too.")
    else:
        print("NOT FEASIBLE via DPMS: capture FROZE when the panel powered off "
              "(stale last frame) — operator sees a frozen image.")


if __name__ == "__main__":
    main()
