# dreamconnect

A shim that makes the **ConnectWise ScreenConnect** Linux client work under
**Wayland** — without waiting on ConnectWise to ship native support, and without
abandoning the ScreenConnect ecosystem (relay-from-anywhere access, unattended
sessions, the existing `screenconnect.com` estate).

Host of record: a headless GNOME/Wayland workstation (Fedora 44, GNOME/mutter 50, Wayland).

---

## Why this exists

The ScreenConnect Linux client is a **Java** application
(`ScreenConnect.Client.jar` + `ScreenConnect.Core.jar`; the bundled `.so` files
are only webp/zstd codecs). It performs **all** screen capture and input
injection through **Java AWT `Robot`**, which the JRE implements over **X11**
(`sun.awt.X11` XToolkit): `XGetImage`/MIT-SHM for capture, **XTEST** for input.

Under Wayland this breaks, by design:

- The client connects to **rootless Xwayland**. `Robot.createScreenCapture()`
  grabs the X11 **root window**, but Wayland compositors do **not** composite
  native Wayland surfaces into that root — so capture returns **black**.
- **XTEST** input injected into Xwayland does **not** reach native Wayland
  surfaces — so clicks/keys go nowhere.

This is the Wayland security model (X clients must not screenshot or drive other
apps), not a bug. The sanctioned way to capture/inject on Wayland is
`xdg-desktop-portal` + **PipeWire** (ScreenCast) and **RemoteDesktop** (input via
libEI).

### Why not just force an Xorg session?
The classic ScreenConnect-on-Linux fix — run GNOME on Xorg, where AWT Robot
works natively — is **unavailable here**. GNOME removed the X11 session in
GNOME 49; this box runs GNOME/mutter **50**. `WaylandEnable=false` is already set
in `/etc/gdm/custom.conf` and is silently ignored because there is no GNOME Xorg
session to fall back to. That escape hatch is closed.

### Why not just use RDP?
`gnome-remote-desktop` (RDP) is Wayland-native and works (with a monitor / dummy
plug present). It is the right tool if all you need is remote *pixels*. It does
**not** give you the ScreenConnect ecosystem — the relay-brokered
"reach-from-anywhere, no-VPN, unattended fleet" model that the rest of the estate
is built around. **dreamconnect keeps ScreenConnect; it just fixes its eyes and
hands.**

---

## Design — Option B: hook AWT `Robot`, skip X11 entirely

Rather than emulate an X server (Option A — writing a special-purpose X server
backed by the portal; correct but weeks-to-months of work because AWT probes
RANDR/SHM/XDamage/XFixes/visuals on startup), **intercept the handful of `Robot`
methods ScreenConnect actually calls** and reimplement them against the Wayland
portals. ScreenConnect never knows it left X11.

### Surface area to intercept
ScreenConnect's capture/input reduces to a small set of AWT calls:

| AWT call                              | dreamconnect implementation                              |
|---------------------------------------|----------------------------------------------------------|
| `Robot.createScreenCapture(Rect)`     | Pull latest frame from a **PipeWire ScreenCast** stream, crop to `Rect`, return `BufferedImage` |
| `Robot.getPixelColor(x,y)`            | Sample the cached frame                                  |
| `Robot.mouseMove(x,y)`                | `portal.RemoteDesktop.NotifyPointerMotionAbsolute`       |
| `Robot.mousePress/Release(buttons)`   | `NotifyPointerButton`                                    |
| `Robot.mouseWheel(amt)`               | `NotifyPointerAxis`                                       |
| `Robot.keyPress/keyRelease(keycode)`  | `NotifyKeyboardKeycode` (AWT vk → evdev keycode map)     |
| `GraphicsEnvironment` / screen size   | Report the ScreenCast stream geometry                    |

### Injection mechanism
The client runs from a **systemd unit we control**
(`connectwisecontrol-<id>.service`), so we own its environment. Inject a Java
agent without touching the ConnectWise install:

```
Environment=JAVA_TOOL_OPTIONS=-javaagent:/opt/dreamconnect/dreamconnect-agent.jar
```

The agent uses bytecode instrumentation (ByteBuddy/ASM) to replace the bodies of
the `Robot`/`GraphicsEnvironment` methods above with calls into the
dreamconnect runtime.

### Architecture

```
  Real Wayland GNOME session (ptyxis tabs, the actual desktop)
        │  capture                              ▲  input
        ▼                                       │
  xdg-desktop-portal ─ ScreenCast (PipeWire)    │ RemoteDesktop (libEI)
        │                                       │
        ▼                                       │
  ┌───────────────────── dreamconnect runtime ──────────────────┐
  │  PipeWire consumer → frame cache      evdev/portal injector  │
  └───────────────▲─────────────────────────────▲───────────────┘
                  │ javaagent hooks              │
        java.awt.Robot.createScreenCapture / mouseMove / keyPress …
                  │
        ScreenConnect.Client.jar (unmodified)
                  │  outbound TLS
                  ▼
        instance-*.relay.screenconnect.com  →  operator's browser
```

Net effect: ScreenConnect sees a normal X11-ish `Robot` that happens to be
wired to the real Wayland session through the sanctioned portal path.

---

## The hard parts (read before committing effort)

1. **Portal consent.** `portal.RemoteDesktop` / `ScreenCast` normally require an
   interactive "Allow" click per session — hostile to an unattended headless
   agent. Options, roughly in order of effort:
   - Reuse the **gnome-remote-desktop system daemon**'s already-granted
     RemoteDesktop session instead of opening our own (investigate its D-Bus
     surface / whether a session handle can be shared).
   - Persist the portal permission grant (portal `remember` where supported).
   - Worst case: a headless auto-approve backend for `xdg-desktop-portal-gnome`
     (fragile, updates-sensitive).
   This is the single biggest risk and should be spiked **first**.

2. **A capture source must exist.** ScreenCast of the *existing* session needs a
   monitor → the **HDMI dummy plug** (already fitted, connector `HDMI-2`). The
   headless virtual-monitor mode spawns a *new* session (no ptyxis tabs), so the
   dummy plug is the right source for sharing the real desktop.

3. **Keymap fidelity.** AWT virtual keycodes → evdev keycodes is not 1:1
   (modifiers, layout, keypad). Needs a tested mapping table.

4. **Frame pacing / latency.** PipeWire is push (damage-driven); `Robot`
   capture is pull (synchronous). Maintain a latest-frame cache the hook reads
   instantly; don't block the client thread on a frame.

5. **Maintenance.** This bridge tracks GNOME/portal/JRE internals and will need
   care across updates. Budget for it.

---

## Build plan (spikes, in dependency order)

- [x] **Spike 0 — consent:** persistent headless `RemoteDesktop` + `ScreenCast`
      session with no consent dialog; frames arrive, input accepted. Done via
      the low-level `org.gnome.Mutter.*` API (`spikes/SPIKE0_RESULTS.md`).
- [x] **Spike 1 — capture:** PipeWire → shared-memory frame → Java `BufferedImage`;
      pixels match the real desktop. Runtime writes the frame; the agent's peer
      turns it into the `Robot.createScreenCapture` result.
- [x] **Spike 2 — input:** AWT vk/button → evdev map (`agent/.../AwtEvdev.java`),
      forwarded to Mutter's `Notify*`; `Robot.mouseMove` moves the real cursor.
- [x] **Spike 3 — agent:** ByteBuddy javaagent swaps the `Robot` peer; verified
      end to end against a real `Robot` under the agent.
- [x] **Integrate:** systemd user service for the daemon + drop-in that injects
      `JAVA_TOOL_OPTIONS` into the ScreenConnect unit (`install.sh`). *Live
      relay connection is the remaining manual verification.*
- [ ] **Harden:** keymap edge cases, multi-monitor, wheel direction/units,
      reconnect, update-survival.

---

## Install

```sh
sudo ./install.sh            # detects the desktop user, SC unit, and monitor;
                             # builds the agent, deploys to /opt/dreamconnect,
                             # starts the daemon, injects the agent into SC.
sudo ./install.sh --uninstall
```
Then connect to the machine from the ScreenConnect relay as usual — you now get
the real Wayland desktop, and your mouse/keyboard drive it. See each component's
README for details and manual validation.

## Repo layout

```
dreamconnect/
├── README.md              ← this file
├── install.sh             ← detects host specifics and wires up both halves
├── agent/                 ← Java agent: swaps java.awt.Robot's peer (ByteBuddy)
│   ├── src/               ← premain + Robot.init advice
│   └── boot/              ← bootstrap peer, daemon client, frame reader, keymap
├── runtime/               ← Python daemon: Mutter session + PipeWire capture + input
├── systemd/               ← daemon user service + SC agent-injection drop-in
└── spikes/                ← proofs for the go/no-go gates
```

## Status
**Working end to end.** An operator connecting from the ScreenConnect relay
sees the live Wayland desktop and drives it with mouse + keyboard, through the
unmodified client. All spikes pass; the daemon + agent are deployed via
`install.sh`.

- Spike 0 (consent): PASS — headless `org.gnome.Mutter.{RemoteDesktop,ScreenCast}`,
  no dialog (`spikes/SPIKE0_RESULTS.md`).
- Runtime daemon (`runtime/`): persistent session + PipeWire→shm capture + input.
- Java agent (`agent/`): swaps `java.awt.Robot`'s peer; verified serving a real
  operator session (capture non-black, mouse/keyboard live).

Planned work (Insert-clipboard-text, Backstage terminal, keymap/multi-monitor
hardening, and the `:1` root-cause investigation) is tracked in
[`ROADMAP.md`](ROADMAP.md). Current release: **v1.0**.

A plain `gnome-remote-desktop` (RDP) path remains as a fallback.

## Troubleshooting host quirks

This host has a broken GNOME **Xwayland `:1`** display whose socket accepts X
connections but never completes the handshake. ScreenConnect's own display
detection (`getDisplayInfos`) probes every display it finds with
`xdpyinfo`/`xrandr`/`xwininfo`/`xrdb` and **hangs on `:1`**, which:
- at startup, blocks the client from connecting → **agent offline on the portal**;
- periodically at runtime, freezes the session for ~20–30 s on a repeating cycle.

This is a pre-existing Xwayland quirk, unrelated to the agent (it hangs
identically with the daemon stopped, and no Java is in that path). `install.sh`
works around it by installing the probe tools and a `host-fixes/` wrapper that
makes `:1` probes fail instantly while `:0` works normally. If the client ever
hangs offline after a restart before the wrapper is in place, recover with
`sudo pkill -9 xrdb`.

## Non-goals
- Modifying the ConnectWise client binaries (injection is external, via env +
  javaagent only).
- Replacing RDP where plain remote pixels suffice.
- Bypassing Wayland security for anything other than this one sanctioned,
  operator-consented remote-support path.
