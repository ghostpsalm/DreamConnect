# DreamConnect

**Make the ConnectWise ScreenConnect Linux client work under Wayland GNOME.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ghostpsalm/DreamConnect)](https://github.com/ghostpsalm/DreamConnect/releases)

ScreenConnect's Linux client does all screen capture and input through Java AWT
`Robot`, which the JRE implements over X11. On a modern Wayland GNOME desktop
(no X11 session since GNOME 49) that means **black screens and dead
mouse/keyboard** — by Wayland's security design, not a bug.

DreamConnect is a small Java agent + helper daemon that transparently reroutes
those `Robot` calls onto Wayland's own capture/input APIs (PipeWire ScreenCast +
Mutter RemoteDesktop). The ScreenConnect client is **not modified** — it keeps
working exactly as before, including through client updates, because it's
ultimately just a Java shim we intercept. You keep the whole ScreenConnect
ecosystem (relay-brokered, no-VPN, unattended access); it just gets its eyes and
hands back.

> DreamConnect is an independent, unofficial project. "ConnectWise" and
> "ScreenConnect" are trademarks of their respective owners.

### Scope & maturity — read this first

DreamConnect is a young project, proven end-to-end on a **Fedora + GNOME/Wayland**
box. Today it targets exactly that:

- **GNOME/Mutter only.** The headless, no-consent path uses GNOME's
  `org.gnome.Mutter.*` D-Bus API. **KDE/KWin and wlroots (Sway, etc.) are not
  supported yet.**
- **Fedora-tested.** The installer installs dependencies via the detected package
  manager (`apt`/`dnf`/`zypper`/`pacman`) and assumes GDM for the autologin
  guidance. The agent + daemon aren't distro-specific, but only Fedora is verified
  end to end — other distros are best-effort (package names may need tweaks; see
  [per-distro packages](docs/troubleshooting.md)).
- **The machine must be logged in.** It attaches to an existing graphical
  session and can't drive the login greeter — so **you can't log in through
  ScreenConnect after a reboot unless autologin is enabled** (the installer
  warns you).

Broadening to other compositors and distros is explicitly on the
[roadmap](ROADMAP.md). See [Limitations](#limitations) for the full list.

## How it works (in one paragraph)

A [`javaagent`](agent/) injected via `JAVA_TOOL_OPTIONS` swaps `java.awt.Robot`'s
internal peer, so every capture/input call is served from the Wayland side by a
[runtime daemon](runtime/): capture comes from a PipeWire ScreenCast written to a
shared-memory frame buffer, and input goes out through Mutter's RemoteDesktop
API. Crucially, it drives the low-level `org.gnome.Mutter.*` D-Bus interfaces
directly, so there is **no per-session "Allow" consent dialog** — it works fully
headless/unattended. Full details in [`docs/design.md`](docs/design.md).

## Requirements

- **GNOME on Wayland** (uses GNOME's Mutter D-Bus interfaces — see
  [Scope](#scope--maturity--read-this-first)), with a session that stays logged
  in — **autologin** for unattended/reboot survival.
- A capture source: a real monitor or an **HDMI dummy plug**.
- The **ScreenConnect Linux client** already installed and enrolled
  (`connectwisecontrol-*.service`).
- `systemd`, a **JDK** (built/tested on JDK 25), and `python3` with GObject +
  GStreamer PipeWire.
- **Tested on Fedora.** The installer pulls dependencies via the detected package
  manager (`apt`/`dnf`/`zypper`/`pacman`) — see
  [per-distro packages](docs/troubleshooting.md). Only Fedora is verified end to
  end; other distros are best-effort.

## Install

One line (fetches the latest release and installs):

```sh
curl -fsSL https://github.com/ghostpsalm/DreamConnect/releases/latest/download/dreamconnect-install.sh | sudo bash
```

The installer auto-detects the desktop user, the ScreenConnect unit, and the
capture monitor; builds the agent; deploys to `/opt/dreamconnect`; starts the
runtime daemon; and injects the agent into the ScreenConnect service.

> **This runs code as root.** Piping to `sudo bash` trusts GitHub + TLS with no
> further integrity check. If you'd rather read it first:
> ```sh
> curl -fsSLO https://github.com/ghostpsalm/DreamConnect/releases/latest/download/dreamconnect-install.sh
> less dreamconnect-install.sh          # review
> sudo bash dreamconnect-install.sh
> ```

<details>
<summary>From a source checkout instead</summary>

```sh
git clone https://github.com/ghostpsalm/DreamConnect
cd DreamConnect
sudo ./install.sh
```
Overrides: `DREAMCONNECT_USER=<name>`, `MONITOR=<connector>`, `INSTALL_DIR=<path>`.
</details>

## Use

After installing, connect to the machine from your ScreenConnect relay/portal as
usual — you'll see the live Wayland desktop and can drive it with low-latency
mouse and keyboard (correct scroll direction included).

Operator commands that work through the bridge:

- **Screen capture + mouse/keyboard control** — the real desktop, not black.
- **Copy/paste** (clipboard sharing) and **Insert clipboard text** — types the
  operator's clipboard on the remote, including non-US/Unicode text (via a
  clipboard-paste fallback).
- **Wake lock** — keeps the session from idle-blanking or auto-locking mid-session.
- **Blank guest monitor** — darkens the physical panel for local privacy while
  you keep seeing the desktop (via CRTC gamma, so it holds through input).
- **Block guest input**, **screenshots**, **Open URL**, **Reboot**, **Run tool**,
  and **file transfer** all work as usual.
- The session/display picker shows the **logged-in user's name** instead of `:0`.

## Uninstall

```sh
sudo ./install.sh --uninstall     # from a source checkout
```

## Limitations

Environment (see [Scope](#scope--maturity--read-this-first)):
- **GNOME/Mutter only** — no KDE/KWin or wlroots (Sway, …) support yet. Those
  need the generic `xdg-desktop-portal` path, where avoiding the per-session
  "Allow" consent prompt is a separate problem. *(Roadmap.)*
- **Fedora-tested; the installer is Fedora-shaped** (`dnf`, GDM). The core is
  distro-agnostic; other distros need manual dependency install + autologin
  setup for now. *(Roadmap.)*
- **Must be logged in** — can't drive the GDM login greeter, so no logging in
  through ScreenConnect after a reboot without **autologin**.

Features:
- **Single monitor** only, and the keymap assumes a **US-ish physical layout**.
- Some hosts need a workaround for a broken Xwayland `:1` display (the installer
  applies it) — see [Troubleshooting](docs/troubleshooting.md).

Broader compositor/distro support and further hardening are tracked in
[`ROADMAP.md`](ROADMAP.md). It's early; issues and PRs (especially other
compositors/distros) are welcome.

## Documentation

- [`docs/design.md`](docs/design.md) — how and why it works, architecture, internals
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — offline/freeze fixes, status checks
- [`ROADMAP.md`](ROADMAP.md) — releases and planned features
- Component docs: [`agent/`](agent/README.md), [`runtime/`](runtime/README.md)

## License

[MIT](LICENSE).
