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

## How it works (in one paragraph)

A [`javaagent`](agent/) injected via `JAVA_TOOL_OPTIONS` swaps `java.awt.Robot`'s
internal peer, so every capture/input call is served from the Wayland side by a
[runtime daemon](runtime/): capture comes from a PipeWire ScreenCast written to a
shared-memory frame buffer, and input goes out through Mutter's RemoteDesktop
API. Crucially, it drives the low-level `org.gnome.Mutter.*` D-Bus interfaces
directly, so there is **no per-session "Allow" consent dialog** — it works fully
headless/unattended. Full details in [`docs/design.md`](docs/design.md).

## Requirements

- A GNOME **Wayland** session that stays logged in (autologin), with a capture
  source present — a real monitor or an **HDMI dummy plug**.
- The **ScreenConnect Linux client** already installed and enrolled
  (`connectwisecontrol-*.service`).
- A **JDK** (built/tested on JDK 25), `python3` with GObject + GStreamer PipeWire,
  and `systemd`. On Fedora the installer pulls the few missing bits automatically.

## Install

One line (fetches the latest release and installs):

```sh
curl -fsSL https://github.com/ghostpsalm/DreamConnect/releases/latest/download/dreamconnect-install.sh | sudo bash
```

The installer auto-detects the desktop user, the ScreenConnect unit, and the
capture monitor; builds the agent; deploys to `/opt/dreamconnect`; starts the
runtime daemon; and injects the agent into the ScreenConnect service.

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
usual. You'll see the live Wayland desktop and can drive it with mouse and
keyboard. Copy/paste works via clipboard sharing.

## Uninstall

```sh
sudo ./install.sh --uninstall     # from a source checkout
```

## Limitations

- **"Insert clipboard text"** doesn't work (it uses a native code path that
  bypasses `Robot`); share clipboards and paste manually instead.
- Keymap assumes a US-ish physical layout; single-monitor only.
- Some hosts need a workaround for a broken Xwayland `:1` display (the installer
  applies it) — see [Troubleshooting](docs/troubleshooting.md).

These and planned work (clipboard typing, Backstage terminal, hardening) are
tracked in [`ROADMAP.md`](ROADMAP.md).

## Documentation

- [`docs/design.md`](docs/design.md) — how and why it works, architecture, internals
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — offline/freeze fixes, status checks
- [`ROADMAP.md`](ROADMAP.md) — releases and planned features
- Component docs: [`agent/`](agent/README.md), [`runtime/`](runtime/README.md)

## License

[MIT](LICENSE).
