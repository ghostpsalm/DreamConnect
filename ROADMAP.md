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
- **GNOME/Mutter only** — no KDE/wlroots yet → [V2-2](#v2-2--wayland-everywhere-other-compositors).
- **Fedora-tested**; installer is Fedora-shaped → [H5](#h5--distro-agnostic-install).
- **Must be logged in**; no login through the greeter after reboot without
  autologin → [H6](#h6--reboot-survival--autologin).
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

**Feasibility (probed 2026-07-13):** `libscnative`'s `sendStringAsKeystrokes`
links no X/uinput libs and sits next to the console-framebuffer exports — it
looks **console-oriented** (raw VT), which is why it never reaches the Wayland
desktop. Best path: intercept that one native method (`setNativeMethodPrefix`)
and reroute to a new daemon "type string" command built on Mutter's
`NotifyKeyboardKeysym` — which types **arbitrary Unicode, layout-independent**,
sidestepping the US-keymap limit entirely. Approach 2's caller wasn't obvious via
`javap` (likely obfuscated), so approach 1 is preferred.
· **Time: ~2–4 days (M).** · **Likelihood: ~70% (medium-high).** Risk is in the
native-method interception mechanics and keysym timing, not the typing itself.

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

**Feasibility (probed 2026-07-13):** the client advertises the capability flags
`BACKSTAGE_LOGON_SESSION` / `CAN_ENABLE_BACKSTAGE_LOGON_SESSION`, and the native
lib exposes console-framebuffer + console-keystroke primitives — so SC's Linux
"backstage" looks like a **raw text-console (VT)** session, not graphical. That's
actually a plus: it would work independent of the desktop (even at the login
screen). `tmux` is already installed, so wrapping a persistent, reattachable
shell on that VT is trivial **once the SC side is proven**. The whole risk is
whether SC's Linux backstage actually functions (it may be Windows-centric or
stubbed) — if it's a no-op on Linux, this becomes "build a whole out-of-band
channel," which is a much larger effort. **Needs a spike to enable + test SC
backstage first.**
· **Time: ~1 day to spike; ~3–6 days if SC backstage works, much more if not.**
· **Likelihood: ~45% (low-medium)** — gated almost entirely on the SC-side unknown.

#### F3 — Wake lock / stay-awake (idle & lock inhibitor)
**Status:** ✅ DONE (in `main`, unreleased) · **Priority:** medium

**Implemented 2026-07-13.** Driven by the operator's actual **AcquireWakeLock**
command — the agent hooks `com.screenconnect.OSToolkit.acquireWakeLock` /
`releaseWakeLock` (a Linux no-op; only macOS/Windows implement it) and forces
`canAcquireWakeLock()` → true so ScreenConnect offers the command. The hook
tells the daemon (`WAKELOCK 1|0`) to grab/drop a GNOME SessionManager idle+suspend
inhibit — verified `InhibitedActions` 0 → 12 → 0. So it respects the operator's
explicit action rather than firing for any open session; the daemon also releases
on last-client-disconnect as a safety net. Original notes below.

---

During a session the desktop can idle-blank or auto-lock, turning the operator's
view into a blank/lock screen and breaking input focus. Take an inhibitor while
an operator is connected and release it on disconnect. The daemon already knows
when a client is attached (the `active_clients` counter from P-04), so it has the
right signal to grab/drop the inhibitor.

*Mechanism:* a D-Bus inhibitor — `org.freedesktop.login1.Manager.Inhibit`
(idle/sleep), and/or the GNOME session / `org.freedesktop.ScreenSaver` inhibit
for blanking. Language-agnostic (a D-Bus call), so **not** a Rust-specific win.
*Open question:* whether capture/input should also keep working while the session
is *locked* — that's a separate path (see F4).

**Feasibility (probed 2026-07-13):** all the interfaces are present on the box —
`org.gnome.SessionManager` (idle inhibit), `org.freedesktop.ScreenSaver`, and
system `org.freedesktop.login1`. The daemon already tracks `active_clients`, so
it grabs an inhibit on 0→1 and drops it on →0. Cleanest quick win here.
· **Time: ~0.5–1 day (S).** · **Likelihood: ~90% (high).** Minor tuning: pick the
inhibit flag(s) that stop the *lock*, not just blanking.

#### F4 — Other candidate features (unverified under the bridge)
**Status:** potential · **Priority:** low–medium

ScreenConnect capabilities that may or may not work through the Robot-peer
bridge and are worth checking or building:
- **Insert clipboard text** — tracked separately as [F1](#f1--insert-clipboard-text).
- **Through-the-lock-screen** capture/control — today capture would just show the
  GNOME screen shield; driving a locked session likely needs a separate path.
- **SAS / Ctrl-Alt-Del** injection — the secure-attention sequence; may require
  direct evdev/`uinput` injection rather than Mutter's RemoteDesktop API.
- **Local privacy** — blank the local monitor and/or lock the local
  keyboard/mouse for the duration of a session.
- **Multi-monitor** — see [H2](#h2--multi-monitor).

The lower-level ones (SAS via `uinput`, direct device control) are where a Rust
daemon could genuinely help (see [V2-1](#v2-1--rust-daemon-rewrite)); the rest
(inhibitors, clipboard) are plumbing any language handles.

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

#### H5 — Distro-agnostic install
**Status:** planned · **Priority:** medium

`install.sh` is Fedora-shaped: `dnf` for the probe tools, and GDM assumptions in
the autologin warning. The agent + daemon are distro-neutral. Detect the package
manager (apt/dnf/pacman/zypper) and install deps accordingly, generalise the
display-manager/autologin guidance, and document the manual steps per distro.
The `:1` probe wrapper and systemd wiring are already portable.

#### H6 — Reboot survival / autologin
**Status:** planned · **Priority:** medium

The bridge needs a logged-in graphical session; it can't drive the GDM greeter,
so a reboot without autologin leaves it unreachable (v1.x prints a warning only).
Offer to configure display-manager autologin during install (with explicit
consent, given the security trade-off), and verify reboot survival end to end.
See also F3 (wake lock) for the idle/lock case.

---

## Larger bets (v2)

#### V2-1 — Rust daemon rewrite
**Status:** discussion · **Priority:** low (revisit if the drivers below appear)

Rewrite the Python runtime daemon in Rust. Framed as an **architecture** change,
not a performance fix: the hot path is already a native `memcpy` plus
GStreamer/PipeWire in C, and the GIL isn't a factor here, so a like-for-like
port buys essentially nothing in speed. The real motivations are:

- **Robustness / safety** — compile-time guarantees on the shared-memory layout,
  the seqlock, and protocol parsing (exactly the fiddly, offset-based code where
  Rust's types shine), and a single self-contained binary instead of a
  `python3-gobject` + GStreamer + PipeWire binding stack to install.
- **Fewer moving parts** — potentially consume **PipeWire directly**
  (`pipewire-rs`) and drop GStreamer, opening a path to zero-copy DMABUF capture
  and tighter buffer/latency control.
- **Enables lower-level features** — direct evdev/`uinput` input (SAS keys and
  other items in [F4](#f4--other-candidate-features-unverified-under-the-bridge))
  and finer device control that are awkward through Mutter's D-Bus API.

*Trade-offs:* more code than today (PyGObject maps the C API 1:1, which is why
the daemon is ~340 terse lines); `pipewire-rs` / `zbus` are less mature than
PyGObject; and it still dynamically links the same native libraries. Do it as a
deliberate v2 pass **if/when** we want the dependency reduction, zero-copy
capture, or `uinput`-level features — not as a "scripting is slow" fix. The
**agent stays Java** regardless — it lives inside ScreenConnect's JVM.

#### V2-2 — Wayland everywhere (other compositors)
**Status:** discussion · **Priority:** medium (most-requested direction)

Today the daemon acquires its capture/input session via GNOME's
`org.gnome.Mutter.{RemoteDesktop,ScreenCast}` D-Bus API — which is why it's
**GNOME/Mutter only**. Supporting **KDE/KWin** and **wlroots** (Sway, Hyprland,
…) means acquiring the session through the compositor-neutral
`xdg-desktop-portal` `RemoteDesktop` + `ScreenCast` interfaces instead.

The rest of DreamConnect is already portable: the agent's `Robot`-peer swap is
compositor-agnostic, and the shm/socket transports don't care. Only the daemon's
session-acquisition layer is GNOME-specific, so this is a **pluggable backend**
(Mutter today; portal-based backends for KDE/wlroots).

*The hard part is consent.* The portal path normally shows an interactive
"Allow" prompt per session — the exact thing the Mutter backend sidesteps. Each
compositor handles unattended/persistent grants differently (restore tokens,
KDE's remote-desktop config, wlroots portal backends), so this needs a per-
compositor spike on headless consent before it's genuinely unattended. Structure
the daemon around a backend interface first, then add backends one compositor at
a time.

---

## Version history
- **v1.0** (2026-07-13) — first working release: headless capture + input,
  low-latency control, systemd install, `:1` host workaround.
