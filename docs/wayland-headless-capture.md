# Wayland headless capture — removing the dummy plug and autologin

**Status: an external finding, verified elsewhere, not yet implemented here.** Nothing in this
repository does what this document describes. It is written so the work can be picked up without
re-deriving it.

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

`runtime/dreamconnect_daemon.py:345` calls `RecordMonitor`, which takes a connector name and therefore
requires a connector to exist. The same `ScreenCast.Session` object exposes:

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

## Still open

- **KDE/KWin and wlroots have no equivalent verified path.** GNOME-only. `ext-image-copy-capture-v1` is
  a third code path, and whether Mutter/KWin expose it to unprivileged clients or gate it behind portal
  consent is **unverified**.
- `gnome-remote-desktop-handover.service` and `-headless.service` ship as packaged system units, so the
  GDM handover mechanism is real. Whether a third party may drive it is unestablished — but this finding
  means it is **not needed** for ordinary unattended access.
- Whether the existing area/coordinate maths in `dreamconnect_daemon.py` (the `RecordMonitor`
  `area_x`/`area_y` handling around line 428) needs adjusting for a virtual output has not been checked.
