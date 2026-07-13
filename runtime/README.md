# dreamconnect runtime daemon

`dreamconnect_daemon.py` is the long-lived process that owns the Wayland side of
the bridge. It runs as the **desktop user** (so it owns the user session bus),
while the ScreenConnect client — and the Java agent injected into it — runs as
root and reaches the daemon through the two transports below (root bypasses the
file permissions on both).

## What it does

1. Opens a persistent headless **Mutter RemoteDesktop + ScreenCast** session via
   the low-level `org.gnome.Mutter.*` D-Bus API — no portal consent dialog
   (proven in `../spikes/SPIKE0_RESULTS.md`). The session is bound to this
   process's D-Bus connection, which is why a stable daemon must hold it; if
   Mutter closes the session, the daemon rebuilds it automatically.
2. Captures the shared monitor with a GStreamer `pipewiresrc → appsink` pipeline
   and writes each frame (BGRx) into a **shared-memory buffer** for pull-style
   reads by the agent's `Robot.createScreenCapture` hook.
3. Serves a **Unix-socket control channel** for input injection and geometry
   queries, forwarding to Mutter's `Notify*` methods.
4. Holds a **wake lock** while any client is connected — a GNOME SessionManager
   idle+suspend inhibit — so the desktop doesn't blank, auto-lock, or suspend
   during a support session (remote input alone doesn't reset GNOME's idle
   timer). Acquired on the first connection, released when the last drops.

## Transports

### Shared-memory frame buffer — default `/dev/shm/dreamconnect.frame`
64-byte little-endian header then BGRx pixels. A **seqlock** (`seq_begin` /
`seq_end`) lets a lock-free reader detect and retry torn frames:

| offset | type | field |
|-------:|------|-------|
| 0  | `4s` | magic `DCF1` |
| 4  | `I`  | version (1) |
| 8  | `I`  | width |
| 12 | `I`  | height |
| 16 | `I`  | stride (bytes/row) |
| 20 | `I`  | format (0 = BGRx) |
| 24 | `Q`  | seq_begin (writer bumps before copy) |
| 32 | `Q`  | seq_end (writer sets == seq_begin after copy) |
| 64 | …    | pixel data |

Reader: read `seq_end`, copy pixels, read `seq_begin`; if they match (and are
non-zero) the frame is intact, else retry.

### Control socket — default `$XDG_RUNTIME_DIR/dreamconnect.sock`
Line-based ASCII, one reply line per command:

| command | meaning | reply |
|---------|---------|-------|
| `PING` | liveness | `PONG` |
| `GEOM` | stream size | `<w> <h>` |
| `NODE` | PipeWire node id | `<id>` |
| `M <x> <y>` | pointer absolute move (screen px) | `OK` |
| `B <evdev_button> <state>` | pointer button (state 1/0) | `OK` |
| `W <axis> <steps>` | wheel (axis 0=vert 1=horiz) | `OK` |
| `K <evdev_keycode> <state>` | key by evdev keycode | `OK` |
| `KS <keysym> <state>` | key by keysym (fallback) | `OK` |

Coordinates and button/key codes are already in Wayland/evdev terms — the Java
agent does the AWT→evdev translation (see `../keymap/`) before sending.

## Run

```sh
python3 dreamconnect_daemon.py --monitor HDMI-2
# options: --shm PATH  --socket PATH
```
Requires `python3-gobject`, `gstreamer1-plugin-pipewire`, a running Wayland
GNOME session, and a capture source (a real or dummy-plug monitor).

`test_client.py` exercises every command and dumps a captured frame — use it to
validate a running daemon.

## Dependencies (Fedora)
```sh
sudo dnf install python3-gobject gstreamer1 gstreamer1-plugins-base \
                 gstreamer1-plugin-pipewire python3-pillow
```
