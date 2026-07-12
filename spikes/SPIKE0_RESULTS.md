# Spike 0 — Headless portal consent — **PASS** ✅ (go/no-go gate)

Date: 2026-07-12 · Host: `the-host` (Fedora 44, GNOME/mutter **50.2**, Wayland)

## Result

A persistent RemoteDesktop + ScreenCast session was created, started, and
driven **with no interactive "Allow" dialog**, by talking to the low-level
`org.gnome.Mutter.RemoteDesktop` / `org.gnome.Mutter.ScreenCast` D-Bus
interfaces directly — the same ones `gnome-remote-desktop` uses — instead of the
consent-gated `org.freedesktop.portal.*` layer.

| Check                        | Outcome |
|------------------------------|---------|
| Consent dialog               | **None** — direct Mutter API needs no portal Allow |
| Capture source (ScreenCast)  | **PipeWire node 66**, monitor `HDMI-2` (UGREEN dummy plug), 1920×1080@60 |
| Frames arrive (not black)    | **Yes** — captured a real 1920×1080 frame, luminance range 0–255, showing the live GNOME desktop (Firefox, top bar, notifications) |
| Input injection              | **Accepted** — `NotifyPointerMotionAbsolute(960,540)` returned OK |

This is the exact opposite of the X11-under-Wayland failure the project exists
to fix (black frames + dead XTEST input). The core mechanism is proven viable.

## Key facts learned (feed into the real runtime design)

1. **Two low-level interfaces, no portal.** `org.gnome.Mutter.RemoteDesktop`
   (`SupportedDeviceTypes = 7` → keyboard+pointer+touchscreen) and
   `org.gnome.Mutter.ScreenCast` (`Version 4`) are both exported by `gnome-shell`
   on the session bus and require no consent UI. This sidesteps the README's
   biggest risk (portal Allow click) entirely.

2. **Session lifetime is tied to the D-Bus connection.** Mutter destroys the
   session the instant the creating connection drops. The dreamconnect runtime
   **must hold one long-lived session-bus connection** for the whole session.

3. **Linkage + start ordering.** Link ScreenCast to RemoteDesktop by passing
   `remote-desktop-session-id` = the RD session's `SessionId` into
   `ScreenCast.CreateSession`. Then **start only the RemoteDesktop session** —
   it starts the linked ScreenCast session too. Calling `ScreenCast.Session.Start`
   directly on a linked session errors: *"Must be started from remote desktop
   session"*.

4. **PipeWire node id arrives via signal.** Subscribe to
   `org.gnome.Mutter.ScreenCast.Stream.PipeWireStreamAdded` on the stream object
   path; it delivers the node id (`u`) after Start. That node is the capture
   source for Spike 1.

5. **Capture source = the dummy plug.** Mutter reports the connector as `HDMI-2`
   (README said HDMI-A-2). It's the real desktop the operator shares.

## D-Bus call sequence (reference)

```
RD  = Mutter.RemoteDesktop.CreateSession()            -> /…/Session/uN
id  = Get(RD, "SessionId")
SC  = Mutter.ScreenCast.CreateSession({remote-desktop-session-id: id})
str = SC.Session.RecordMonitor("HDMI-2", {cursor-mode: 1})   -> stream obj path
      subscribe PipeWireStreamAdded on str
RD.Session.Start()          # starts SC too; node id delivered via signal
RD.Session.NotifyPointerMotionAbsolute(str, x, y)   # + Button/Axis/KeyboardKeycode
```

## Reproduce

```
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus python3 spikes/spike0_consent.py
```

## Note (unrelated, flagged during capture)

The captured frame showed a GNOME "**Low Disk Space** on Filesystem root — only
**218.8 MB remaining**" notification. Java/Maven builds for later spikes will
need free space; worth clearing before Spike 3.
