# DreamConnect — troubleshooting

## Agent shows offline on the portal, or the session freezes periodically

**Symptom:** after (re)starting the ScreenConnect client, the agent shows
**offline**; or, once connected, control freezes for ~20–30 s on a repeating
cycle.

**Cause:** a broken GNOME **Xwayland `:1`** display. On some hosts the Xwayland
that serves `:0` also exposes a second display `:1` whose socket accepts X
connections but never completes the handshake. ScreenConnect's own display
detection (`ClientService` → `getDisplayInfos`) probes every display it finds
with `xdpyinfo`/`xrandr`/`xwininfo`/`xrdb`, has no per-probe timeout, and so
**hangs forever on `:1`** — blocking the relay connection at startup and freezing
the session thread when detection re-runs.

This is a pre-existing Xwayland quirk, **not** the agent: `xrdb :1` hangs
identically with the DreamConnect daemon stopped, and no Java is in that shell
probe path. See ROADMAP item **B1** for the open question of whether this is
inherent ScreenConnect behavior or specific to a given host.

**Fix (applied by `install.sh`):** install the probe tools and a wrapper
(`host-fixes/xprobe-skip-broken-display.sh`) into `/usr/local/bin` — ahead of
`/usr/bin` in the service PATH — that makes `DISPLAY=:1` probes fail instantly
while `:0` works normally. Detection then completes in milliseconds and never
blocks.

**Emergency recovery** (if the client hangs offline before the wrapper is in
place):

```sh
sudo pkill -9 xrdb
```

The client's display probe then gets EOF and proceeds to connect within seconds.

## "Insert clipboard text" does nothing

Works as of **v1.2** (ROADMAP **F1**): the agent hooks the console-only native
path and routes the text to the daemon, which types it via Mutter — keymappable
characters directly, and anything else (non-US/Unicode) via a `wl-copy` + Ctrl+V
paste fallback. If it does nothing:

- Confirm **`wl-clipboard`** is installed (the paste fallback needs `wl-copy`).
- Check the client log for `clipboard keystrokes forwarded (<n> chars)` and the
  daemon log for `pasted <n> chars` / typed output.

## Dependencies (per distro)

`install.sh` installs these via the detected package manager. If your distro or a
package name isn't covered, install the equivalents by hand and re-run with
`DREAMCONNECT_SKIP_DEPS=1`:

| Need | Fedora (`dnf`) | Debian/Ubuntu (`apt`) | Arch (`pacman`) | openSUSE (`zypper`) |
|---|---|---|---|---|
| X11 probe tools | `xdpyinfo xrandr xwininfo` | `x11-utils x11-xserver-utils` | `xorg-xdpyinfo xorg-xrandr xorg-xwininfo` | `xdpyinfo xrandr xwininfo` |
| Python + GObject | `python3-gobject` | `python3-gi gir1.2-gstreamer-1.0` | `python-gobject` | `python3-gobject` |
| GStreamer PipeWire + base | `pipewire-gstreamer gstreamer1-plugins-base` | `gstreamer1.0-pipewire gstreamer1.0-plugins-base` | `gst-plugin-pipewire gst-plugins-base` | `gstreamer-plugins-pipewire gstreamer-plugins-base` |
| Clipboard paste fallback | `wl-clipboard` | `wl-clipboard` | `wl-clipboard` | `wl-clipboard` |
| JDK (to build the agent) | `java-latest-openjdk-devel` | `default-jdk` | `jdk-openjdk` | `java-21-openjdk-devel` |

Non-Fedora names are best-effort — corrections welcome. Only `dnf`/Fedora is
tested end to end today.

## Checking status

```sh
# daemon (runs as the desktop user)
sudo -u <user> XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user status dreamconnect-daemon

# is the agent loaded in the client JVM?
sudo grep -a dreamconnect-agent /var/log/connectwisecontrol-*

# is the daemon capturing + reachable?  (run as the desktop user)
python3 /opt/dreamconnect/runtime/test_client.py     # if the source is present
```

A healthy attach logs, in the ScreenConnect client log:

```
[dreamconnect-agent] installed; Robot peer will be swapped on next Robot()
[dreamconnect-agent] attached to daemon; geometry 1920 1080; replacing X11 Robot peer
```
