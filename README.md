# dreamconnect

A shim that makes the **ConnectWise ScreenConnect** Linux client work under
**Wayland** — without waiting on ConnectWise to ship native support, and without
abandoning the ScreenConnect ecosystem (relay-from-anywhere access, unattended
sessions, the existing `screenconnect.com` estate).

Host of record: `the-host` (Fedora 44, GNOME/mutter 50, Wayland).

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
Environment=JAVA_TOOL_OPTIONS=-javaagent:/home/user/dreamconnect/dist/dreamconnect-agent.jar
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
   monitor → the **HDMI dummy plug** (already fitted on `the-host`, HDMI-A-2). The
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

- [ ] **Spike 0 — consent:** open a persistent `portal.RemoteDesktop` +
      `ScreenCast` session headless from a systemd user service; prove input
      injection reaches a native Wayland app and frames arrive. *Go/no-go gate.*
- [ ] **Spike 1 — capture:** PipeWire consumer → `BufferedImage` at the plug's
      resolution; verify pixels match the real desktop.
- [ ] **Spike 2 — input:** AWT vk → evdev map; drive a Wayland app end-to-end.
- [ ] **Spike 3 — agent:** ByteBuddy javaagent that swaps the `Robot` methods in
      a toy JVM; confirm interception.
- [ ] **Integrate:** point the agent's hooks at the runtime; inject via
      `JAVA_TOOL_OPTIONS` into the ScreenConnect unit; connect from the relay.
- [ ] **Harden:** keymap edge cases, multi-monitor, reconnect, update-survival.

---

## Repo layout (planned)

```
dreamconnect/
├── README.md              ← this file
├── agent/                 ← Java agent (bytecode hooks into Robot/GraphicsEnvironment)
├── runtime/               ← PipeWire capture + portal RemoteDesktop injection (JNI/native)
├── keymap/                ← AWT vk ↔ evdev tables
├── systemd/               ← drop-in that injects JAVA_TOOL_OPTIONS into the SC unit
└── spikes/                ← throwaway proofs for the gates above
```

## Status
Design only. **Spike 0 (portal consent) is the go/no-go gate** — nothing else
matters until headless portal sessions are proven. See
`~/.claude` memory `scaim1-headless-rdp-dummyplug` for the RDP fallback that
already works if this proves not worth the effort.

## Non-goals
- Modifying the ConnectWise client binaries (injection is external, via env +
  javaagent only).
- Replacing RDP where plain remote pixels suffice.
- Bypassing Wayland security for anything other than this one sanctioned,
  operator-consented remote-support path.
