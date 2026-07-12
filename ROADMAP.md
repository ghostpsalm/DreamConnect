# DreamConnect Roadmap

DreamConnect makes the unmodified **ConnectWise ScreenConnect** Linux client work
under **Wayland GNOME** by swapping the AWT `Robot` peer onto the sanctioned
Wayland portals (see [`README.md`](README.md)). This file tracks what's shipped
and what's planned.

---

## v1.0 — current (shipped)

The core bridge, deployed and verified against a live operator session through
the real ScreenConnect client.

### Features
- **Headless capture + input, no consent dialog** — drives the low-level
  `org.gnome.Mutter.{RemoteDesktop,ScreenCast}` D-Bus API directly, so no
  interactive "Allow" is ever required (Spike 0).
- **Live screen capture** — a PipeWire ScreenCast of the shared monitor is
  written to a shared-memory frame buffer and returned as the result of
  `Robot.createScreenCapture` / `getPixelColor`. Real desktop, not black.
- **Mouse + keyboard control** — `Robot` mouse move / press / release / wheel and
  key press / release are forwarded to Mutter's `Notify*` methods, with an
  AWT-virtual-key → evdev translation table. Scroll direction is correct.
- **Low-latency input** — input is fire-and-forget end to end (no per-event ack),
  so control stays responsive under a stream of mouse events.
- **External, update-resilient injection** — a ByteBuddy javaagent loaded via
  `JAVA_TOOL_OPTIONS` swaps the `Robot` peer; no ScreenConnect binary is
  modified. A separate runtime daemon holds the Wayland session so a capture
  crash can't take down the support session.
- **One-command install** — `install.sh` auto-detects the desktop user, the
  ScreenConnect unit, and the capture monitor, deploys everything, and wires up
  both systemd services. `--uninstall` reverses it.
- **Clipboard** — copy/paste works via ScreenConnect's clipboard sharing.

### Known limitations (tracked below)
- "Insert clipboard text" does not work → [F1](#f1--insert-clipboard-text).
- Keymap assumes a US-ish physical layout; non-US layouts, dead keys, and some
  keypad keys may be imperfect → [H1](#h1--keymap-fidelity).
- Single monitor only; multi-monitor is untested → [H2](#h2--multi-monitor).
- Requires a host workaround for a broken Xwayland `:1` display → [B1](#b1--broken-xwayland-1-display).

---

## Backlog

### Features

#### F1 — Insert clipboard text
**Status:** planned · **Priority:** medium

ScreenConnect's "Insert clipboard text" (type the operator's clipboard as
keystrokes on the remote) does nothing under the bridge. It bypasses
`java.awt.Robot` entirely and calls the **native** method
`com.screenconnect.LinuxNative.sendStringAsKeystrokes` (in `libscnative`), so the
agent's peer swap never sees it, and the native path does not function under
Wayland.

*Workaround today:* share clipboards and paste manually — works fine.

*Approach options to evaluate:*
1. Intercept `LinuxNative.sendStringAsKeystrokes` and re-implement it in the
   agent as a sequence of key events routed through the daemon (same idea as the
   Robot peer, but the target is a native JNI method — use
   `Instrumentation.setNativeMethodPrefix` or hook the Java caller instead of the
   native method itself).
2. Find whether the client has a Robot-based fallback for typing and force it
   (e.g. flip a `canSendStringAsKeystrokes` gate to false) so the text is typed
   via `Robot.keyPress`/`keyRelease`, which already works through the peer.
   Cheaper if such a fallback exists; needs bytecode spelunking to confirm.

#### F2 — Backstage terminal as a login option
**Status:** idea · **Priority:** medium

Offer ScreenConnect **Backstage**-style access (a command shell + file transfer
without joining the graphical desktop) as a first-class option, so an operator
can get a terminal even when the graphical session isn't available, or for quick
headless admin without spinning up the full capture/input bridge.

*Open questions to scope:*
- How ScreenConnect's Backstage mode is triggered/served on the Linux client,
  and whether it works today independent of the AWT `Robot` path (Backstage may
  not need the display bridge at all).
- Whether it should be a login/session option surfaced by DreamConnect or simply
  documented as already-working ScreenConnect behavior.

### Bugfixes & investigations

#### B1 — Broken Xwayland `:1` display
**Status:** worked around, root cause open · **Priority:** medium

This host has a second Xwayland display `:1` whose socket accepts X connections
but never completes the handshake. ScreenConnect's own display detection
(`getDisplayInfos`) probes every display it finds and hangs on `:1`, which froze
the session periodically and blocked startup. v1.0 ships a wrapper
(`host-fixes/xprobe-skip-broken-display.sh`) that makes `:1` probes fail
instantly while `:0` works normally.

*Open question — is this a ConnectWise trait or unique to this device?* Two
separable parts to pin down:
- **The hang-on-probe behavior is ScreenConnect's**: its display probe has no
  per-command timeout, so *any* unresponsive X display will freeze it. That is
  reproducible in principle on any host with a stuck display.
- **The broken `:1` itself** may be specific to this box's GNOME/Xwayland (or
  `gnome-remote-desktop`) configuration. Current lean: the same Xwayland process
  serves both `:0` and `:1`, so `:1` is likely a secondary/virtual display that
  was set up but is not driven.

*To investigate:* reproduce on a clean Fedora GNOME/Wayland VM (does a `:1`
appear at all? does it hang?); check whether `gnome-remote-desktop`'s
headless/virtual-monitor sessions create it; and confirm whether removing the
dummy-plug/RDP configuration makes `:1` go away. Outcome decides whether the
wrapper is a permanent shim or a one-host quirk.

### Hardening

#### H1 — Keymap fidelity
AWT virtual-key → evdev mapping currently assumes a US-ish physical layout.
Cover non-US layouts, dead keys, keypad edge cases, and modifier combinations;
consider using Mutter's `NotifyKeyboardKeysym` / `CurrentKeymap` for
layout-independent injection where appropriate.

#### H2 — Multi-monitor
Capture and coordinate mapping are validated for a single monitor. Support
multiple monitors / logical-monitor layouts and correct absolute-coordinate
mapping across them.

#### H3 — Wheel units & momentum
Confirm scroll step units/granularity match operator expectations across apps
(direction is already correct); consider high-resolution / smooth-scroll axis
events.

#### H4 — Reconnect & resilience
Exercise daemon restart, Mutter session `Closed` recovery, and ScreenConnect
update survival end to end; make sure the agent re-attaches cleanly after a
daemon bounce.

---

## Version history
- **v1.0** (2026-07-13) — first working release: headless capture + input,
  low-latency control, systemd install, `:1` host workaround.
