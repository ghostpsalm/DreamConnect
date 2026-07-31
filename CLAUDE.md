# DreamConnect

Transparently runs the **unmodified** ScreenConnect Linux client on Wayland/GNOME. A Java javaagent
reroutes ScreenConnect's AWT `Robot` calls (screen capture + input) onto a Python daemon that drives
Wayland's Mutter RemoteDesktop + PipeWire ScreenCast. ScreenConnect never learns it left X11 — that is
the whole point.

## Architecture

Two processes, split by privilege:

- **Agent** (`agent/`, Java, ByteBuddy) — injected into ScreenConnect's JVM via `JAVA_TOOL_OPTIONS`, so
  it runs **as root** (ScreenConnect runs as root). It replaces the AWT `RobotPeer`, so every
  capture/input call ScreenConnect makes is serviced from the daemon. `agent/boot/` is the bootstrap
  peer + IPC clients; `agent/src/` is the ByteBuddy advice; `agent/test/` is `BootTests`.
- **Daemon** (`runtime/dreamconnect_daemon.py`, Python) — runs in the **user's graphical session** as a
  systemd user unit (`WantedBy=graphical-session.target`). Talks D-Bus to Mutter, captures via PipeWire.

IPC between them (both `0600`, owner-only — the root JVM reads them via DAC override, so no other local
user can scrape the screen or inject input):

- **Frame buffer** — `/dev/shm/dreamconnect.frame`, a seqlock-guarded BGRx buffer the agent mmaps.
- **Control socket** — `/run/user/<uid>/dreamconnect.sock`, a line protocol (`M x y`, `B btn state`,
  `K evdev state`, `KS keysym state`, `W axis amt`, `PING`, …).

## Gate

`./run-tests.sh` (also reachable as `scripts/gate.sh`) — runs the Java `BootTests`, the Python daemon
parser tests, and the installer shell tests (`test_install.sh`). **Green before every commit.** No
external test frameworks; needs a JDK (17+), `python3` with PyGObject + GStreamer introspection, and
bash. CI runs the same gate on every PR (`.github/workflows/ci.yml`).

## Conventions

- **Commits**: imperative subject with an area prefix — `Installer: …`, `H1: …`, `Roadmap: …`. One
  logical change each. **Never** add a `Co-Authored-By: Claude` or any AI-generated trailer.
- **This repo is PUBLIC.** Keep it sanitized: no hardcoded personal names, hostnames, or single-box
  specifics. Runtime labels that read the live system (e.g. the logged-in username shown in the session
  list) are fine — that is data, not a hardcoded fact.
- **`install.sh` is idempotent**, and its `--uninstall` must fully reverse whatever an install did.
  What was actually done is recorded in `/etc/dreamconnect/install.state` so uninstall reverts exactly
  that and no more. Shared helpers live in `install-lib.sh`, unit-tested via `test_install.sh`.
- **Version bumps are deployment decisions** — the owner decides; the installer self-updates, so a bump
  is a release. Current version and history live in `ROADMAP.md`.

## Risk profile

- The agent runs **as root inside ScreenConnect's JVM** — the highest-consequence surface in the repo.
  The installer runs `useradd` / autologin / `dconf` as root. Treat anything that builds a shell command
  or a filesystem path from install-time input as a potential injection/traversal site, and keep the shm
  + socket owner-only.
- **Wayland constraints that shape the design — established, do not re-litigate:** the GDM greeter and
  the GNOME lock screen both *inhibit* Mutter's capture/input APIs, so "remotely reachable" requires an
  *unlocked* session. Hence the display-host account + autologin (`DREAMCONNECT_HOST_ACCOUNT`). Capturing
  the physical login/lock screen is not possible on GNOME/Wayland.

## Layout

`agent/` Java agent · `runtime/` Python daemon + tests · `install.sh` + `install-lib.sh` +
`test_install.sh` · `systemd/` units + agent drop-in · `host-fixes/` broken-Xwayland-probe shim ·
`docs/` · `spikes/` throwaway experiments · `ROADMAP.md` feature list + version history · `factory/`
production-line records.
