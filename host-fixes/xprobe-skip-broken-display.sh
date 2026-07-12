#!/bin/sh
# dreamconnect host fix — skip a broken Xwayland display in X probes.
#
# On this host, GNOME's Xwayland exposes a second display (:1) whose socket
# accepts X connections but never completes the handshake, so any X client that
# probes :1 hangs forever. ScreenConnect's startup and *periodic* display
# detection (ClientService -> getDisplayInfos) probes every display it finds
# with xdpyinfo/xwininfo/xrandr/xrdb; when it hits :1 it blocks, which freezes
# the whole remote session for ~20-30s at a time on a repeating cycle.
#
# Installed to /usr/local/bin as xdpyinfo/xrandr/xwininfo/xrdb (which is ahead
# of /usr/bin in the service PATH). For DISPLAY=:1 it exits immediately with a
# non-zero status (as if the probe found nothing); for every other display it
# execs the real tool from /usr/bin unchanged. Net effect: :0 is detected
# normally, :1 is skipped instantly, detection never blocks.
#
# This is a targeted workaround for a pre-existing GNOME/Xwayland quirk, not a
# dreamconnect component — remove the symlinks to revert.
tool=$(basename "$0")
case "$DISPLAY" in
  :1|:1.*) exit 1 ;;
esac
exec "/usr/bin/$tool" "$@"
