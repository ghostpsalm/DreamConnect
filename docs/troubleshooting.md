# DreamConnect — troubleshooting

## Agent shows offline on the portal, or the session freezes periodically

**Symptom:** after (re)starting the ScreenConnect client, the agent shows
**offline**; or, once connected, control freezes for ~20–30 s on a repeating
cycle.

**Cause:** an X display that accepts connections and never completes the
handshake. Every `gnome-shell` publishes a second X socket for
`GNOME_SETUP_DISPLAY` alongside the one it actually serves; Xwayland listens on
both, but only the first answers. ScreenConnect's own display detection
(`ClientService` → `getDisplayInfos`) probes every display it finds a cookie for
with `xdpyinfo`/`xrandr`/`xwininfo`/`xrdb`, has no per-probe timeout, and so
**hangs forever** on that socket — blocking the relay connection at startup and
freezing the session thread when detection re-runs.

**The display number is not fixed.** A shell serving `:0` publishes the dead
socket as `:1`; the GDM greeter serving `:1024` publishes `:1025`. Backstage mode
keeps the greeter running permanently, so its dead socket is present the whole
time — verified on Fedora 44 / GNOME 50.2, where `xdpyinfo :1024` answers and
`xdpyinfo :1025` never returns.

This is a pre-existing Xwayland quirk, **not** the agent: the probe hangs
identically with the DreamConnect daemon stopped, and no Java is in that shell
probe path. See ROADMAP item **B1** for the open question of whether this is
inherent ScreenConnect behavior or specific to a given host.

**Fix (applied by `install.sh`):** install the probe tools and a wrapper
(`host-fixes/xprobe-skip-broken-display.sh`) into `/usr/local/bin` — ahead of
`/usr/bin` in the service PATH — that bounds every probe with `timeout` and
remembers, for five minutes, any display that failed to answer. The wrapper keys
on behaviour, never on a display number: an earlier version hardcoded `:1` and
therefore missed the greeter's `:1025` entirely. Detection then completes in
milliseconds and never blocks.

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

**`flock` (util-linux) is a hard prerequisite, not a best-effort one.** It is
what serialises the one-display-host-account-per-box decision against a second
concurrent run, so `install.sh` and `install.sh --uninstall` refuse to start at
all when it is missing rather than proceed unlocked. Every supported distro ships
it in the base system; if `flock --version` fails, install `util-linux`.

## "another dreamconnect install or uninstall is running"

`install.sh` holds a lock (`/etc/dreamconnect/install.lock`, beside
`install.state`) across the whole account decision — the guard read, the
`useradd`, and the state write — and `--uninstall` holds the same one across the
account removal. A second run refuses immediately rather than waiting: it has
created nothing, removed nothing, and left `install.state` untouched, so simply
re-run it once the first has finished. The kernel drops the lock when the holder
exits, including on a crash or a kill, so there is never a stale lock to clear by
hand.

## Upgraded box still logs in automatically / `custom.conf.dreamconnect.bak` left behind

Only a box first installed **before** GDM autologin was removed from DreamConnect
(see the README) can show this. That installer set GDM to log the desktop user in
automatically at boot. Before its first edit it copied the GDM config to
`custom.conf.dreamconnect.bak`. Today's installer has no autologin code at all,
so `--uninstall` reverts neither change. This box therefore still boots straight
to an unlocked desktop. **That is the part worth fixing.** The leftover `.bak`
file is only clutter.

This cleanup is manual by decision (issue #22), not an `--uninstall` step. The
steps below follow from what the old installer wrote. They have not been run on a
real upgraded box.

1. Find the config. The old installer used the first of these two files that
   existed:

   ```sh
   ls -l /etc/gdm/custom.conf* /etc/gdm3/custom.conf* 2>/dev/null
   ```

   Fedora uses `/etc/gdm`; Debian and Ubuntu use `/etc/gdm3`. Name the one that
   holds `custom.conf.dreamconnect.bak`, because the later steps use it:

   ```sh
   conf=/etc/gdm/custom.conf    # or /etc/gdm3/custom.conf
   ```

2. In that file's `[daemon]` section, delete only the two lines the installer
   added: `AutomaticLoginEnable=true` and `AutomaticLogin=<user>`. Leave every
   other line alone.

3. Check the backup for autologin settings of its own:

   ```sh
   grep -n 'AutomaticLogin' "$conf.dreamconnect.bak"
   ```

   A plain, uncommented `AutomaticLogin*` line in its `[daemon]` section is a
   setting this box had *before* DreamConnect was installed. If you want it
   back, copy that line back into `[daemon]`. Lines that start with `#` are
   GDM's stock comments, and putting them back is optional.

4. Delete the backup:

   ```sh
   sudo rm "$conf.dreamconnect.bak"
   ```

**Do not restore the `.bak` over `custom.conf` wholesale.** The backup is a copy
of the config from the day of the *first* install. Copying it back would also undo
every change made to the live config since then for other reasons.

The change takes effect at the next GDM start, which is the next reboot.

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
