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

Expected in v1.0. That feature uses ScreenConnect's native
`LinuxNative.sendStringAsKeystrokes` (in `libscnative`), which bypasses
`java.awt.Robot` — so the agent's peer never sees it — and doesn't function under
Wayland. **Workaround:** enable clipboard sharing and paste manually (Ctrl+V),
which works. Tracked as ROADMAP item **F1**.

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
