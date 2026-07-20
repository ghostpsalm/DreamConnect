# DreamConnect Roadmap

DreamConnect makes the unmodified **ConnectWise ScreenConnect** Linux client work
under **Wayland GNOME** by swapping the AWT `Robot` peer onto the sanctioned
Wayland portals (see [`README.md`](README.md)). This file tracks what's shipped
and what's planned.

---

## Shipped (current — v1.2)

The core bridge plus the operator-command set, deployed and verified against a
live operator session through the real ScreenConnect client.

### Core (v1.0)
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

### Operator commands (v1.2)
See [`docs/screenconnect-commands.md`](docs/screenconnect-commands.md) for the
full per-command coverage.
- **Insert clipboard text** ([F1](#f1--insert-clipboard-text)) — types the
  operator's clipboard on the remote, incl. non-US/Unicode via a paste fallback.
- **Wake lock** ([F3](#f3--wake-lock--stay-awake-idle--lock-inhibitor)) — the
  operator AcquireWakeLock command inhibits idle-blank/auto-lock for the session.
- **Blank guest monitor** — darkens the physical panel for local privacy while
  the operator keeps seeing the desktop, via CRTC gamma (holds through input).
- **Logon-session rename** — the picker shows the logged-in user's name, not `:0`.
- **Verified working as-is** — block guest input, screenshots, Open URL, reboot,
  run tool, and file transfer.

### Known limitations (tracked below)
- **GNOME/Mutter only** — no KDE/wlroots yet → [V2-2](#v2-2--wayland-everywhere-other-compositors).
- **Fedora-tested**; installer supports apt/dnf/zypper/pacman but only Fedora is
  verified end to end → [H5](#h5--distro-agnostic-install).
- **Must be logged in**; the installer can enable autologin (opt-in) for reboot
  survival → [H6](#h6--reboot-survival--autologin).
- Keymap assumes a US-ish physical layout; non-US layouts, dead keys, and some
  keypad keys may be imperfect → [H1](#h1--keymap-fidelity).
- Single monitor only; multi-monitor is untested → [H2](#h2--multi-monitor).
- Requires a host workaround for a broken Xwayland `:1` display → [B1](#b1--broken-xwayland-1-display).

---

## Backlog

### Features

#### F1 — Insert clipboard text
**Status:** ✅ DONE (v1.2) · **Priority:** medium

**Implemented 2026-07-13.** SC's `SendClipboardKeystrokes` is handled by
`OSToolkit$LinuxPackageToolkit.sendStringAsKeystrokes`, which is **console-only**
(guards on `getCurrentTerminalName`, then calls the native) — a silent no-op on
the Wayland desktop. The agent hooks that method (skips it) and forwards the text
to the daemon's new `TYPE` command: keymappable text is typed via
`NotifyKeyboardKeysym` (works even in paste-blocked fields); text with characters
keysym injection can't reach falls back to `wl-copy` + Ctrl+V. **Both paths
verified live** through the operator's actual "insert clipboard text" command
(ASCII via keysym; a 472- and 275-char Unicode payload via the paste fallback).
`canSendStringAsKeystrokes` is forced true so the command is offered. Original
notes below.

---

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
**Status:** ❌ won't do (spiked 2026-07-13) · **Priority:** —

**Not pursuing.** ScreenConnect has no native backstage terminal on the Linux
client, so building one would mean re-creating a whole out-of-band channel SC
itself doesn't provide — and a root shell is already available today (see below).

**Spike result (jar decompile, 2026-07-13):**
- **No interactive backstage on the Linux client.** SC's "Logon Session" concept
  is implemented on Linux as a **display picker**, not a shell:
  `ClientOSToolkit$LinuxClientToolkit.getAvailableLogonSessionInfosAsClientService()`
  just walks `getDisplayInfos()` and emits one `Messages$LogonSessionInfo2` per
  display/framebuffer (tagging the active console `USER_LOGON_SESSION`). The
  `BACKSTAGE_LOGON_SESSION` capability flags exist in the shared protocol, but the
  Linux graphical client never implements a text-console backstage. So the
  dashboard showing nothing backstage-like is a **client-implementation limit,
  not an account/role entitlement** — no config flip surfaces it.
- **A root shell already exists — SC's Commands feature.** This device runs as a
  persistent **Access agent, as root**, and the Commands tab / command bar runs
  every line via `Extensions.runCommandMessage` → `OSToolkit$UnixToolkit`, i.e.
  `["/bin/sh", "-c", <text>]` **as root** (`getDefaultInterpreterPath()` → `/bin/sh`).
  It works today with **zero DreamConnect code**, in-window, independent of the
  capture/input bridge — but it is **one-shot** commands with returned output, not
  an interactive PTY.

**Why we're not building an interactive terminal:** the only SC-served surface
that's both in-window *and* headless is the Commands tab, which is one-shot by
protocol — we can't inject a new "console" panel into the operator's web UI (it's
server-rendered; the client speaks a fixed message protocol). So an interactive
terminal could only be either (a) a **terminal app on the shared desktop** —
in-window but needs the graphical session up (just use the existing bridge), or
(b) an **out-of-band `ttyd`/tmux over a port** — headless but reached *outside*
the SC window, a new network + auth surface. Neither is "SC backstage," and the
Commands tab covers the root-shell need. Revisit only if a concrete need for a
persistent headless PTY appears; it'd be option (b) as a deliberate feature.

#### F3 — Wake lock / stay-awake (idle & lock inhibitor)
**Status:** ✅ DONE (v1.2) · **Priority:** medium

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

Full per-command coverage lives in
[`docs/screenconnect-commands.md`](docs/screenconnect-commands.md) (of 58 enum
values, ~35 are host-side UI; only a handful act on the guest). Open items:

- **`BlankGuestMonitor`** — ✅ done via **CRTC gamma zeroing** (the ScreenCast is
  pre-gamma, so the operator keeps seeing the desktop while the physical panel
  goes black; holds through input, unlike DPMS). See
  [`spikes/SPIKE1_RESULTS.md`](spikes/SPIKE1_RESULTS.md). On-device physical-dark
  confirmation pending.
- **`SendSystemKeyCode`** — ❌ not worth it (fixed Ctrl-Alt-Del; a GNOME no-op).
- **Spot-check as-root commands** — `Reboot`, file transfer, `RunTool`,
  screenshots, `OpenUrl` (likely already work; verify, don't build).
- **Through-the-lock-screen** — needs a separate path (capture shows the shield).
- **Multi-monitor** — see [H2](#h2--multi-monitor).

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
**Status:** ✅ DONE (core) · **Priority:** medium

Character keys (letters, digits, punctuation) now inject as a **base X11 keysym**
via Mutter's `NotifyKeyboardKeysym`, which resolves the keycode on the *guest's*
layout — so the right character lands on US, QWERTZ, AZERTY, etc. Modifiers and
functional keys (F-row, nav, numpad, locks) stay evdev (position-based, correct
on every layout); an operator-held Shift/Ctrl/Alt injected as an evdev modifier
combines correctly with the keysym. **Empirically verified** with a focused
key-logger: on German, evdev-21 gave `z` (the QWERTZ swap bug) while keysym `y`
gave `y`; on US, `a`/`A`/`@`/`5`/`;`/Ctrl+C all correct via the new path.

Remaining edge cases (lower priority): shifted *symbols* still assume the guest
shares the operator's layout for that key (base-keysym + evdev-Shift → guest's
shift level); dead keys / compose and AltGr-layer symbols aren't specially
handled.

#### H2 — Multi-monitor
**Status:** ✅ DONE (single-monitor path verified; spanning needs multi-mon HW) · **Priority:** medium

The daemon now captures the **whole logical desktop** via `RecordArea` over the
bounding box of all logical monitors — auto-enabled when more than one monitor is
present (or forced with `--all-monitors`), falling back to the proven
single-monitor `RecordMonitor` otherwise. Pointer coordinates are shifted by the
area origin (`area_x/area_y`) into the stream's frame; for a single monitor / an
origin-anchored layout that's a no-op. The bounding box honours per-monitor scale
and 90/270 rotation. **Verified** on this single-monitor box that `RecordArea`
over `(0,0) 1920×1080` captures live at the right geometry, identical to
`RecordMonitor` (so no regression, and the area path + coordinate math are sound);
true multi-monitor *spanning* is architecturally in place but needs a
multi-monitor host to confirm end to end.

Open follow-ups: HiDPI mixed-scale layouts (RecordArea captures at logical res);
interaction with SC's own `SelectMonitor` command (today we present one combined
desktop rather than switchable per-monitor streams).

#### H3 — Wheel units & momentum
**Status:** scoped · **Priority:** low

**Current path:** `RobotPeer.mouseWheel(wheelAmt)` → `W 0 <wheelAmt>` →
`NotifyPointerAxisDiscrete(axis=0, steps=wheelAmt)`. One AWT notch = one discrete
step; direction is correct and it works. It's the traditional *notch* model — no
smooth/pixel scrolling, and horizontal isn't wired (AWT `mouseWheel` is
vertical-only).

**Mutter offers two axis calls:** `NotifyPointerAxisDiscrete(u axis, i steps)`
(what we use) and `NotifyPointerAxis(d dx, d dy, u flags)` — continuous,
high-resolution/smooth scrolling with a kinetic-`finish` flag.

**Plan (if operators report notchy/uneven scrolling — otherwise leave as-is):**
1. Add a continuous path via `NotifyPointerAxis` with a configurable
   pixels-per-notch factor (default tuned to GNOME's ~ per-notch step), keeping
   `NotifyPointerAxisDiscrete` as a fallback/option.
2. Emit a kinetic `finish` on the last event of a scroll burst for natural
   momentum stop.
3. Cross-app feel test (browser, terminal, editor, file manager) — the whole risk
   here is subjective tuning, not mechanism.
· **Effort: S–M.** · **Risk: low mechanically; needs operator feel-testing.**
The main open question is whether the notch model is actually a problem in
practice; capture a real complaint before investing.

#### H4 — Reconnect & resilience
**Status:** ✅ DONE · **Priority:** medium

Verified end to end: a daemon bounce recovers (capture resumes, a client
reconnects to live frames); the shm inode is stable across restart so the agent's
long-lived mmap survives, and the socket is rebound so `DaemonClient.ensure()`
reconnects on the next command; the unit is `Restart=always` with
`StartLimitIntervalSec=0` for crash recovery. Fixed a real bug in the Mutter
`Closed` recovery path: `start()` re-subscribed the D-Bus signals on every
restart without dropping the old ones (leak → duplicate `_on_closed` → cascading
restarts); now subscriptions are tracked/unsubscribed and a `_restarting` guard
makes one close schedule exactly one restart. SC update survival rides the
`JAVA_TOOL_OPTIONS` drop-in, which persists across client package updates.

#### H5 — Distro-agnostic install
**Status:** ✅ DONE (Fedora tested; others best-effort) · **Priority:** medium

`install.sh` now detects the package manager (apt/dnf/zypper/pacman) and installs
the full runtime dep set — X11 probe tools, python3 + GObject, GStreamer PipeWire
+ base plugins, wl-clipboard — plus a JDK fallback when `javac` is missing for the
source build. Best-effort: failures warn with the manual package list rather than
aborting; `DREAMCONNECT_SKIP_DEPS=1` opts out. Per-distro package names are
documented in [`docs/troubleshooting.md`](docs/troubleshooting.md). Only Fedora is
tested end to end; other distros' names are best-effort.

#### H6 — Reboot survival / autologin
**Status:** ✅ DONE · **Priority:** medium

`install.sh` configures GDM autologin on explicit opt-in
(`DREAMCONNECT_AUTOLOGIN=1`) — a section-aware, idempotent edit of
`/etc/gdm{,3}/custom.conf` that preserves the rest of the file, backs it up, and
is reverted on `--uninstall`. Without the opt-in it warns and points at it. Warns
if `WaylandEnable=false` (the bridge needs a Wayland session at boot). Reboot
survival itself is the operator's on-device verification. See F3 (wake lock) for
the idle/lock case.

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
- **v1.3** (2026-07-19) — hardening: distro-agnostic dependency install
  (apt/dnf/zypper/pacman) (H5), opt-in GDM autologin for reboot survival (H6),
  and reconnect/resilience fixes — session-restart subscription leak + restart
  guard, verified daemon-bounce recovery (H4).
- **v1.2** (2026-07-15) — operator commands: insert clipboard text (F1), wake
  lock (F3), blank guest monitor (CRTC gamma), logon-session rename; spot-checked
  screenshot/OpenUrl/reboot/run-tool/file-transfer as working. Closed backstage
  (F2) and Ctrl-Alt-Del as not-applicable on Linux.
- **v1.1** (2026-07-13) — public release polish: MIT license, release-ready
  README, curl|bash network installer, docs split out.
- **v1.0** (2026-07-13) — first working release: headless capture + input,
  low-latency control, systemd install, `:1` host workaround.
