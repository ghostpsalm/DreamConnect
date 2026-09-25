#!/usr/bin/env python3
"""Spike 2 — does a virtual monitor outlive the peer that created it? (#67)

#55 closed every virtual-monitor leak this daemon can reach in code: start()
stops the session it is replacing, and main()'s finally stops the session on
SIGTERM/SIGINT. A SIGKILL, a crash or an OOM reaches none of that — the process
runs nothing — so whether the monitor survives depends entirely on Mutter:

    does Mutter drop a RecordVirtual monitor when the creating D-Bus peer
    disconnects without stopping its session?

If it does, SIGKILL is already safe and #67 closes on evidence. If it does not,
every crash adds a monitor and the operator gets the #55 symptom back: an X
screen wider than the session, a top bar on the half we do not capture.

Two pieces of evidence already point at "dropped" and neither is proof.
spike0's header records that Mutter destroys the session the instant the
creating connection drops, but that was observed on a clean exit, not a kill.
#55's live box logged `Added virtual monitor` 25 times while the X screen was
2560 wide — 2 monitors, so 23 had been reclaimed somehow, but by what is not
established. This is the purpose-built check.

## Method

The parent reads Mutter's monitor list, starts a CHILD in its own process (so
it holds its own D-Bus connection), waits for the child to report a live
RecordVirtual stream, re-reads the list to confirm the monitor actually
appeared, SIGKILLs the child, waits for Mutter to settle, and reads the list a
third time.

    VERDICT: dropped   — the monitor is gone after the kill. SIGKILL is safe.
    VERDICT: retained  — the monitor outlived its peer. A crash leaks one.

## Running it

Run as the session's own user, on the box whose Mutter is in question — a
backstage session is the case that matters, since that is where the leak bites.

    python3 spikes/spike2_virtual_monitor_lifetime.py

**Do not run it while an operator is attached.** It briefly adds a monitor,
which resizes the X screen and moves windows about.

Paste the block it prints into spikes/SPIKE2_RESULTS.md.
"""
import os
import select
import signal
import subprocess
import sys
import time

from gi.repository import Gio, GLib

DC_DEST = "org.gnome.Mutter.DisplayConfig"
DC_PATH = "/org/gnome/Mutter/DisplayConfig"
RD_DEST = "org.gnome.Mutter.RemoteDesktop"
RD_PATH = "/org/gnome/Mutter/RemoteDesktop"
RD_SESSION_IFACE = "org.gnome.Mutter.RemoteDesktop.Session"
SC_DEST = "org.gnome.Mutter.ScreenCast"
SC_PATH = "/org/gnome/Mutter/ScreenCast"
SC_SESSION_IFACE = "org.gnome.Mutter.ScreenCast.Session"

# How long to give Mutter to notice the peer is gone and tear its session down.
# Generous on purpose: reporting "retained" because we looked too early would be
# the one wrong answer that costs someone a day.
SETTLE_SECONDS = 5
# How long to wait for the child to establish its session before giving up.
CHILD_READY_TIMEOUT = 20


def bus():
    return Gio.bus_get_sync(Gio.BusType.SESSION, None)


def monitors(b):
    """Connector names Mutter currently reports, in order."""
    r = b.call_sync(DC_DEST, DC_PATH, DC_DEST, "GetCurrentState", None, None,
                    Gio.DBusCallFlags.NONE, -1, None)
    _serial, mons, _logical, _props = r.unpack()
    return [m[0][0] for m in mons]


def child():
    """Hold a RecordVirtual session open until killed. Own process, own D-Bus
    connection — that connection dropping is the whole subject of the spike."""
    b = bus()
    rd_path = b.call_sync(RD_DEST, RD_PATH, RD_DEST, "CreateSession", None, None,
                          Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
    sess_id = b.call_sync(
        RD_DEST, rd_path, "org.freedesktop.DBus.Properties", "Get",
        GLib.Variant("(ss)", (RD_SESSION_IFACE, "SessionId")), None,
        Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
    sc_path = b.call_sync(
        SC_DEST, SC_PATH, "org.gnome.Mutter.ScreenCast", "CreateSession",
        GLib.Variant("(a{sv})", ({"remote-desktop-session-id":
                                  GLib.Variant("s", sess_id)},)),
        None, Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
    b.call_sync(SC_DEST, sc_path, SC_SESSION_IFACE, "RecordVirtual",
                GLib.Variant("(a{sv})", ({"cursor-mode": GLib.Variant("u", 1)},)),
                None, Gio.DBusCallFlags.NONE, -1, None)
    b.call_sync(RD_DEST, rd_path, RD_SESSION_IFACE, "Start", None, None,
                Gio.DBusCallFlags.NONE, -1, None)
    print("READY", flush=True)
    # No main loop needed: nothing here consumes signals. The session lives as
    # long as this process holds the connection, which is exactly the point.
    GLib.MainLoop().run()


def parent():
    b = bus()
    before = monitors(b)
    print(f"[ok] before:  {len(before)} monitor(s): {before or '(none)'}")

    proc = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--child"],
                            stdout=subprocess.PIPE, text=True, bufsize=1)
    # select() rather than a bare readline(): a child whose CreateSession never
    # returns (the interesting failure, not a theoretical one — that is what a
    # box with no Mutter session does) would block readline forever and make
    # CHILD_READY_TIMEOUT a decoration.
    deadline = time.monotonic() + CHILD_READY_TIMEOUT
    ready = False
    while time.monotonic() < deadline:
        r, _, _ = select.select([proc.stdout], [], [],
                                max(0.1, deadline - time.monotonic()))
        if not r:
            break
        line = proc.stdout.readline()
        if not line:
            break
        if line.strip() == "READY":
            ready = True
            break
    if not ready:
        proc.kill()
        sys.exit("[fail] the child never established a RecordVirtual session; "
                 "nothing to measure. Is this a GNOME/Mutter session?")

    time.sleep(1)  # let Mutter apply the new layout before reading it
    during = monitors(b)
    print(f"[ok] during:  {len(during)} monitor(s): {during or '(none)'}")
    if len(during) <= len(before):
        proc.kill()
        sys.exit(f"[fail] RecordVirtual added no monitor ({before} -> {during}), "
                 "so killing the child proves nothing about reclaiming one. "
                 "Inconclusive — do NOT record a verdict from this run.")
    conjured = [c for c in during if c not in before]

    os.kill(proc.pid, signal.SIGKILL)  # not terminate(): SIGTERM is the case #55 already covers
    proc.wait()
    print(f"[ok] child {proc.pid} SIGKILLed (no Stop, no clean disconnect)")
    time.sleep(SETTLE_SECONDS)

    after = monitors(b)
    print(f"[ok] after:   {len(after)} monitor(s): {after or '(none)'}")
    survivors = [c for c in conjured if c in after]
    verdict = "retained" if survivors else "dropped"

    print()
    print(f"VERDICT: {verdict}")
    print()
    print("--- paste into spikes/SPIKE2_RESULTS.md ---")
    print(f"Date: {time.strftime('%Y-%m-%d')} · Host: {os.uname().nodename} "
          f"({os.uname().release})")
    print(f"before:  {before or '(none)'}")
    print(f"during:  {during or '(none)'}  (conjured: {conjured})")
    print(f"after:   {after or '(none)'}")
    print(f"VERDICT: {verdict}"
          + ("  — a SIGKILLed daemon leaks its virtual monitor; #67 needs a "
             "remedy, not just a detector." if survivors else
             "  — Mutter reclaims the monitor on peer disconnect; SIGKILL is "
             "safe and #67 closes on this evidence."))
    print("--- end ---")
    return 0 if verdict == "dropped" else 1


if __name__ == "__main__":
    if "--child" in sys.argv[1:]:
        child()
    else:
        sys.exit(parent())
