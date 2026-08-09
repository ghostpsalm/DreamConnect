# Wayland headless capture — removing the dummy plug and autologin

**Status: IMPLEMENTED and live-verified on this host (2026-08-09).** Shipped as backstage mode —
`DREAMCONNECT_BACKSTAGE=1`. Both findings below were re-run here from a cold start, with the box
parked at the GDM greeter and nobody logged in, before any code was written:

| Check | Result on Fedora 44 / GNOME 50.2 / mutter 50.1 |
|---|---|
| `gnome-shell --headless` under linger, no seat | Mutter on the user bus in **2s** |
| `RecordVirtual` with no monitor attached | stream up, `GetCurrentState` = **0 monitors / 0 logical** |
| Frame | 1920×1080 BGRx, non-blank; `1280x720` and `1600x900` also honoured |
| Input | `NotifyPointerMotionAbsolute` + `NotifyKeyboardKeysym` accepted |
| That shell's Xwayland `:0` | reports a real **1920×1080** (0×0 before `RecordVirtual`) |
| Java AWT **as root** against it | `isHeadless=false`, `screenSize=1920x1080`, `Robot` constructs, `mouseMove` works |
| Deployed end to end | daemon streams backstage frames into shm; SC's root JVM loads the agent, holds the shm open, and reaches the relay |

What shipped: `--virtual WxH` on the daemon, `systemd/dreamconnect-backstage.service`,
`runtime/dreamconnect-backstage-env.sh`, and the installer wiring. What did **not** change: the
greeter is still unreachable, and backstage is a private session, not the console user's desktop.

**Provenance.** Proven on 2026-08-08 in the SpiritBox RMM project as its spike #96
(`ghostpsalm/SpiritBox-RMM`, issue #96), while surveying Linux capture paths for a remote-control
subsystem. The runnable proof is `spikes/spike96-recordvirtual.py` in that repository, with results in
`spikes/SPIKE96_RESULTS.md`. This document is a summary of that work for the purpose of implementing it
here; where the two disagree, the spike results are authoritative because they were run.

## What it removes

Two documented requirements of the current design, both of which this repository names openly:

1. **A capture source: "a real monitor or an **HDMI dummy plug**"** (`README.md`).
2. **Autologin for unattended/reboot survival** (`README.md`), opt-in via `DREAMCONNECT_AUTOLOGIN=1`
   and correctly described there as a security trade-off.

Neither is necessary. Shipping dummy plugs to a fleet is not a product, and a fleet of machines booting
to unlocked desktops is a security position that is hard to defend to a customer.

## What DreamConnect already got right, and why it is the foundation

The hard part is already solved here. DreamConnect drives `org.gnome.Mutter.ScreenCast` /
`org.gnome.Mutter.RemoteDesktop` **directly**, not through `xdg-desktop-portal` — which is what makes
capture possible with **no consent dialog at all**. Every portal-based approach hits a prompt that no
unattended session can answer.

That decision is not what this document changes, and it should not be revisited. The finding below
reaches the *same* no-consent interface; it does not trade the dummy plug for a portal prompt.

## Finding 1 — `RecordVirtual` replaces the dummy plug outright

`runtime/dreamconnect_daemon.py` called only `RecordMonitor`, which takes a connector name and
therefore requires a connector to exist. The same `ScreenCast.Session` object exposes:

```
RecordVirtual(a{sv} properties) -> o stream_path
```

No connector argument. Mutter conjures the monitor itself. Verified with
`GetCurrentState` reporting **0 monitors and 0 logical monitors** — no panel, no dummy plug, and the
shell was started *without* `--virtual-monitor`, so no pre-configured virtual output either.

Capture came back on a PipeWire node at **1920×1080, full luminance range 0–255**, and
`NotifyPointerMotionAbsolute(960,540)` was accepted, so input injection works against the virtual
output too.

**One implementation trap, already hit once.** The first attempt returned a **1×1** frame. That was the
consumer not requesting a size, not a capture failure — the pipeline must ask. Requesting `1920x1080`
returned exactly that, and `1280x720` likewise. This is strictly better than `RecordMonitor`, where you
inherit whatever panel happens to be attached: here **the operator chooses the session resolution**.

## Finding 2 — `enable-linger` replaces autologin, and you already do it

A GNOME shell can be started headless by an ordinary user over SSH with **no seat, no login and no
graphical session**:

```
gnome-shell --headless --wayland-display=sp96
```

This survives with nobody logged in because `loginctl show-user … Linger` is `yes` — the systemd **user
manager persists when no session exists**. So `loginctl enable-linger` is the real deployment
prerequisite, and it is a far smaller ask than autologin: no unlocked desktop, no GDM configuration, no
security trade-off to explain.

**This repository already enables linger.** `install-lib.sh:545` documents its asynchronous start-up
behaviour, and the uninstall path reverses it at `install-lib.sh:865`. The prerequisite is therefore
already installed, already reversible, and already tested — which makes this a substantially cheaper
change than it first appears. The autologin machinery (`DREAMCONNECT_AUTOLOGIN`, the GDM configuration,
and the warnings around it) becomes removable rather than something new having to be added.

## The honest caveat — these are two modes, not one

A spawned headless shell is a **separate session**. It is not the console user's desktop.

- **Unattended** — spawn or attach to a headless shell. Works with nobody logged in. You get a *fresh*
  desktop, not the user's running applications. For unattended administration this is arguably better:
  it is isolated, and it cannot shoulder-surf a logged-in user.
- **Attended** — attach to the user's real session, which exists precisely because they are sitting at
  it.

**"See what the user sees" is the attended path and always requires a live user session.** This finding
does not remove that requirement, and any implementation that presents the headless session as the
user's desktop will be wrong in a way users notice immediately.

## What was actually tested

| | |
|---|---|
| Host | Fedora 44 |
| Compositor | GNOME Shell **50.2** / mutter **50.1**, Wayland |
| `RemoteDesktop.Version` | 1 |
| `ScreenCast.Version` | 4 |
| `RemoteDesktop.SupportedDeviceTypes` | 7 (keyboard + pointer + touchscreen) |

Nothing here has been tested against an older mutter, and `RecordVirtual`'s availability across the
versions this installer supports is **unverified** — worth checking before it becomes the only path.

## Reproduce

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
setsid gnome-shell --headless --wayland-display=sp96 >/tmp/sp96.log 2>&1 &
python3 spike96-recordvirtual.py     # from ghostpsalm/SpiritBox-RMM, spikes/
```

## What implementing it turned up

Three things the spike could not have shown, all found while wiring it in:

1. **`graphical-session.target` is never reached** by a spawned headless shell (checked live). The
   daemon's `WantedBy=graphical-session.target` would therefore never fire, so in backstage mode it
   hangs off `dreamconnect-backstage.service` instead.
2. **SC needs to be told where the display is.** The shell's display number and mutter's xauth path
   (`.mutter-Xwaylandauth.XXXXXX`) are both unpredictable, so neither can be hardcoded in a drop-in.
   `runtime/dreamconnect-backstage-env.sh` snapshots them out of the systemd user environment into
   an `EnvironmentFile` the SC drop-in reads.
3. **The `:1` probe hang is not about `:1`.** Every gnome-shell publishes a `GNOME_SETUP_DISPLAY`
   socket that Xwayland accepts and never serves. Backstage keeps the GDM greeter running
   permanently, and the greeter's dead socket is **`:1025`** — so the old wrapper, which hardcoded
   `:1`, missed it and SC hung offline exactly as before. The wrapper now bounds every probe with a
   timeout and memoises non-answering displays; it keys on behaviour, never on a number.

## Still open

- **KDE/KWin and wlroots have no equivalent verified path.** GNOME-only. `ext-image-copy-capture-v1` is
  a third code path, and whether Mutter/KWin expose it to unprivileged clients or gate it behind portal
  consent is **unverified**.
- `gnome-remote-desktop-handover.service` and `-headless.service` ship as packaged system units, so the
  GDM handover mechanism is real. Whether a third party may drive it is unestablished — but this finding
  means it is **not needed** for ordinary unattended access.
- ~~Whether the existing area/coordinate maths needs adjusting for a virtual output.~~ **Resolved:** a
  `RecordVirtual` output is origin-anchored, so `area_x`/`area_y` stay 0 and the pointer shift is a
  no-op, exactly as on the `RecordMonitor` path.
- **Resolution cannot be changed on a live stream.** Renegotiating the consumer's caps mid-stream
  stalls it (tested: no further frames). Changing the backstage resolution means tearing the
  ScreenCast stream down and recreating it, which today means restarting the daemon. ScreenConnect
  has no guest-resolution command to hook either — `SelectQuality`/`ZoomToScale` are operator-side
  only — so this is install-time configuration (`DREAMCONNECT_BACKSTAGE_RES`) for now.
- **Presenting backstage in SC's own session picker is not built.** `SelectLogonSession` already
  reaches the guest and `Bridge.relabelLogonSessions` already rewrites its entries, so injecting a
  "Backstage" entry is the natural seam — but where SC's Linux client *acts* on the selection is
  undecompiled and unverified.
- **Whether the headless shell idle-locks is untested.** If it does, it self-destructs the same way a
  locked session does (Mutter closes the RemoteDesktop session and refuses to recreate it), so the
  same `configure_no_idle_lock` treatment the display-host account gets is probably needed.
- **Both modes at once is untested.** If a human logs in on a box running backstage *in their own
  account*, two shells export `DISPLAY`/`XAUTHORITY` into the same user environment and the env-file
  snapshot could pick the wrong one. `DREAMCONNECT_BACKSTAGE=1` + `DREAMCONNECT_HOST_ACCOUNT=<name>`
  avoids the overlap entirely — separate account, separate user manager, separate environment — and
  is the recommended deployment.
- **Running backstage as root is a dead end, tested 2026-08-09.** `gnome-shell --headless` does start
  under a root user manager and `RecordVirtual` returns a stream, but `RemoteDesktop.Start` fails with
  `Couldn't connect pipewire context`: PipeWire is a per-user service and root has no PipeWire stack.
  Standing one up would mean running an entire GNOME desktop plus PipeWire and WirePlumber as root for
  no security gain, since ScreenConnect is already root. A dedicated unprivileged account is strictly
  better.
