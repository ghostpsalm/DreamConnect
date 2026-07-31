# DreamConnect — design & internals

Deep technical rationale for how DreamConnect works. For a quick overview and
install instructions, see the [README](../README.md).

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
works natively — is unavailable on current GNOME: the X11 session was removed in
GNOME 49 (this was developed on GNOME/mutter **50**). `WaylandEnable=false` in
`/etc/gdm/custom.conf` is silently ignored because there is no GNOME Xorg session
to fall back to. That escape hatch is closed.

### Why not just use RDP?
`gnome-remote-desktop` (RDP) is Wayland-native and works (with a monitor / dummy
plug present). It is the right tool if all you need is remote *pixels*. It does
**not** give you the ScreenConnect ecosystem — the relay-brokered
"reach-from-anywhere, no-VPN, unattended fleet" model. DreamConnect keeps
ScreenConnect; it just fixes its eyes and hands.

## Design — Option B: hook AWT `Robot`, skip X11 entirely

Rather than emulate an X server (Option A — a special-purpose X server backed by
the portal; correct but weeks-to-months of work because AWT probes
RANDR/SHM/XDamage/XFixes/visuals on startup), DreamConnect **intercepts the
handful of `Robot` methods ScreenConnect actually calls** and reimplements them
against the Wayland side. ScreenConnect never knows it left X11.

The interception is elegant: `java.awt.Robot` delegates every operation to a
private `peer` (`java.awt.peer.RobotPeer`) built by the AWT toolkit — normally
the X11 one. The agent swaps that peer for its own, so one seam reroutes every
`Robot` method.

### Surface area intercepted

| AWT call                              | DreamConnect implementation                              |
|---------------------------------------|----------------------------------------------------------|
| `Robot.createScreenCapture(Rect)`     | Read the latest frame from the shared-memory buffer, crop to `Rect`, return `BufferedImage` |
| `Robot.getPixelColor(x,y)`            | Sample the cached frame                                  |
| `Robot.mouseMove(x,y)`                | `NotifyPointerMotionAbsolute`                            |
| `Robot.mousePress/Release(buttons)`   | `NotifyPointerButton`                                    |
| `Robot.mouseWheel(amt)`               | `NotifyPointerAxisDiscrete`                              |
| `Robot.keyPress/keyRelease(keycode)`  | `NotifyKeyboardKeysym` or `NotifyKeyboardKeycode` — see *Key routing* below |

#### Key routing

An AWT virtual keycode takes the **first** of these three that applies:

1. **Character key** (letters, digits, punctuation) → `NotifyKeyboardKeysym`
   with the base X11 keysym, so the guest's own layout picks the keycode.
2. **Physical/functional key** (modifiers, whitespace/control, navigation,
   function row, numpad, locks) → `NotifyKeyboardKeycode`, from the AWT vk →
   evdev keycode map.
3. **Anything else** → dropped silently, with no line put on the control socket.

There used to be a fourth step — a best-effort keysym for an unmapped vk that
happened to land in printable ASCII — but #36 deleted it: it existed to catch
raw ints ScreenConnect never actually sends, and the one named vk it was
silently papering over (VK_SEPARATOR) got a real table entry instead of a
guess. Order no longer matters between the two remaining branches either: the
keysym and evdev tables are guaranteed disjoint (AwtEvdevTablesDisjoint), so
for any given vk at most one of them ever answers.

##### The 86-vk drop contract

Before #36, 86 of AWT's 189 named `VK_*` constants matched neither table and
fell through to the (now-deleted) fallback — an accident of two disjoint maps,
not a decision. #36 turned that into a stated contract, one vk-class at a
time:

**Mapped instead of dropped (17):**
- `VK_F13`–`VK_F24` — real hardware keys on extended function rows, evdev
  `KEY_F13`–`KEY_F24` exist and mean the same thing.
- `VK_HELP` — evdev `KEY_HELP` exists.
- `VK_KP_UP`/`DOWN`/`LEFT`/`RIGHT` — the same physical key as
  `VK_UP`/`DOWN`/`LEFT`/`RIGHT` with Num Lock off; share their evdev codes.

**Still dropped, now by contract rather than accident (69):**
- Clipboard/edit/action keys (12) — `VK_ACCEPT`, `VK_AGAIN`, `VK_CANCEL`,
  `VK_CLEAR`, `VK_COMPOSE`, `VK_COPY`, `VK_CUT`, `VK_FIND`, `VK_PASTE`,
  `VK_PROPS`, `VK_STOP`, `VK_UNDO` — modelled on Sun/Solaris keyboards' action
  row, not a standard PC key position. A few (`KEY_COPY`, `KEY_PASTE`,
  `KEY_CUT`, `KEY_UNDO`, `KEY_AGAIN`, `KEY_FIND`, `KEY_PROPS`, `KEY_STOP`,
  `KEY_CANCEL`, `KEY_COMPOSE`) do exist as evdev "Application Control" codes
  for dedicated multimedia-keyboard buttons, but that names a different
  physical key from the Ctrl+C-style shortcut Robot models here — mapping
  them is deliberately out of scope for #36 rather than declared unmappable.
- `VK_DEAD_*` (16) — dead-key *composition outcomes* from an IME, not
  physical keys Robot should ever receive from ScreenConnect.
- The IME/input-method cluster (20) — `VK_ALL_CANDIDATES`, `VK_ALPHANUMERIC`,
  `VK_CODE_INPUT`, `VK_CONVERT`, `VK_FINAL`, `VK_FULL_WIDTH`, `VK_HALF_WIDTH`,
  `VK_HIRAGANA`, `VK_INPUT_METHOD_ON_OFF`, `VK_JAPANESE_HIRAGANA`,
  `VK_JAPANESE_KATAKANA`, `VK_JAPANESE_ROMAN`, `VK_KANA`, `VK_KANA_LOCK`,
  `VK_KANJI`, `VK_KATAKANA`, `VK_MODECHANGE`, `VK_NONCONVERT`,
  `VK_PREVIOUS_CANDIDATE`, `VK_ROMAN_CHARACTERS` — evdev does define matching
  codes (`KEY_HANJA`, `KEY_KATAKANA`, `KEY_HENKAN`, …) but only meaningful
  inside a CJK IME session, which ScreenConnect's Robot path never drives.
- Shifted-symbol vks (19) — `VK_AMPERSAND`, `VK_ASTERISK`, `VK_AT`,
  `VK_BRACELEFT`, `VK_BRACERIGHT`, `VK_CIRCUMFLEX`, `VK_COLON`, `VK_DOLLAR`,
  `VK_EURO_SIGN`, `VK_EXCLAMATION_MARK`, `VK_GREATER`,
  `VK_INVERTED_EXCLAMATION_MARK`, `VK_LEFT_PARENTHESIS`, `VK_LESS`,
  `VK_NUMBER_SIGN`, `VK_PLUS`, `VK_QUOTEDBL`, `VK_RIGHT_PARENTHESIS`,
  `VK_UNDERSCORE` — already reachable: the character they represent goes
  through the keysym table when AWT sends the base key plus Shift, so
  mapping the named vk itself would be redundant. Two of these
  (`VK_DOLLAR`, `VK_EURO_SIGN`) do have a same-named evdev code
  (`KEY_DOLLAR`, `KEY_EURO`), but that names a dedicated hardware
  currency key some international keyboards have, not the Shift+digit
  combination AWT's Robot models here — mapping it would send the wrong
  physical key.
- `VK_UNDEFINED` — the sentinel value 0, not a real keypress.
- `VK_BEGIN` — no evdev or X11 equivalent.

`VK_SEPARATOR`'s own layout-independence gap (evdev 121 binds nothing on
`us`/`pc` layouts) is tracked separately in #40.

### Injection mechanism
The client runs from a systemd unit we control (`connectwisecontrol-<id>.service`),
so we own its environment. The agent is injected without touching the
ConnectWise install:

```
Environment=JAVA_TOOL_OPTIONS=-javaagent:/opt/dreamconnect/dreamconnect-agent.jar
```

The premain uses ByteBuddy to instrument `java.awt.Robot.init` and swap the peer.
Because `java.awt.Robot` is a platform class and `java.awt.peer.RobotPeer` is a
non-exported package, the agent injects its peer into the bootstrap classloader
and opens `java.desktop`'s `java.awt.peer`/`sun.awt` packages via
`Instrumentation.redefineModule` at premain (JAVA_TOOL_OPTIONS can't carry
`--add-exports`).

### Two-process architecture

DreamConnect is split into a daemon and an agent — deliberately, not JNI inside
the client JVM:

```
  Real Wayland GNOME session (the actual desktop)
        │  capture                              ▲  input
        ▼                                       │
  org.gnome.Mutter.ScreenCast (PipeWire)        │ org.gnome.Mutter.RemoteDesktop
        │                                       │
        ▼                                       │
  ┌──────────────────── DreamConnect daemon (runtime/) ─────────────┐
  │  PipeWire consumer → /dev/shm frame buffer   input → Notify*     │
  └──────────▲ shm (capture) ──────────── socket (input) ▲──────────┘
             │                                            │
        DreamConnect agent (agent/, in the client JVM)    │
             │  swaps java.awt.Robot's peer               │
        java.awt.Robot.createScreenCapture / mouseMove / keyPress …
             │
        ScreenConnect.Client.jar (unmodified)
             │  outbound TLS
             ▼
        the ScreenConnect relay  →  operator's browser
```

- **Daemon** (`runtime/dreamconnect_daemon.py`, runs as the desktop user): holds
  the persistent Mutter session, captures PipeWire into a shared-memory frame
  buffer, and injects input received over a Unix socket. A separate process
  because the Mutter session is bound to its D-Bus connection lifetime, because
  keeping libpipewire/GStreamer out of the client JVM means a capture crash can't
  take down the support session, and because it survives ScreenConnect updates.
- **Agent** (`agent/`, runs inside the client's root JVM): swaps the `Robot`
  peer; reads frames from the shm buffer and forwards input over the socket.

The transports (shm seqlock frame layout + the socket line protocol) are
documented in [`runtime/README.md`](../runtime/README.md); the agent internals
in [`agent/README.md`](../agent/README.md).

## The consent breakthrough

The portal (`xdg-desktop-portal`) `RemoteDesktop`/`ScreenCast` interfaces
normally require an interactive "Allow" click per session — fatal for an
unattended agent, and originally the project's single biggest risk. DreamConnect
sidesteps it entirely by driving the **low-level `org.gnome.Mutter.RemoteDesktop`
and `org.gnome.Mutter.ScreenCast`** D-Bus interfaces directly — the same ones
`gnome-remote-desktop` uses — which require **no consent UI at all**. See
[`../spikes/SPIKE0_RESULTS.md`](../spikes/SPIKE0_RESULTS.md) for the proof and the
exact call sequence.

## Build history (spikes)

Built in dependency order, each proven before the next:

- **Spike 0 — consent:** persistent headless RemoteDesktop + ScreenCast session
  with no dialog; frames arrive, input accepted. (The go/no-go gate.)
- **Spike 1 — capture:** PipeWire → shared-memory frame → Java `BufferedImage`
  matching the real desktop.
- **Spike 2 — input:** AWT vk/button → evdev map, forwarded to Mutter's
  `Notify*`; `Robot.mouseMove` moves the real cursor.
- **Spike 3 — agent:** ByteBuddy javaagent swaps the `Robot` peer; verified end
  to end against a real `Robot`.
- **Integrate:** systemd user service for the daemon + drop-in that injects
  `JAVA_TOOL_OPTIONS`; verified against a live operator session.

## Security model

- **Transports are owner-only (`0600`).** The shared-memory frame buffer and the
  control socket are created mode `0600`, owned by the desktop user. The only
  intended consumer is the **root** ScreenConnect JVM, which reads them via DAC
  override — so `0600` loses no functionality while preventing other local users
  from scraping the screen (the frame lives in world-traversable `/dev/shm`) or
  injecting input.
- **The deployed agent is a root-trust boundary.** The agent runs inside the
  root ScreenConnect JVM, so **write access to `/opt/dreamconnect/dreamconnect-agent.jar`
  (or the daemon script) is equivalent to root code execution.** `install.sh`
  deploys them `root:root`, non-writable by others; keep them that way.
- **Least-privilege module opening.** The agent opens only `java.awt.peer` and
  `sun.awt`, and only to its own bootstrap module — not `ALL-UNNAMED`.
- **The daemon never touches ScreenConnect secrets.** It only relays frames and
  input; it does not read the client's launch parameters or relay keys, and the
  agent logs no ScreenConnect configuration.

## Non-goals
- Modifying the ConnectWise client binaries (injection is external, via env +
  javaagent only).
- Replacing RDP where plain remote pixels suffice.
- Bypassing Wayland security for anything other than this one sanctioned,
  operator-consented remote-support path.
