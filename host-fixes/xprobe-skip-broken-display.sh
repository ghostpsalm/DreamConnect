#!/bin/sh
# dreamconnect host fix — never let a hung X display block ScreenConnect.
#
# ScreenConnect's startup and *periodic* display detection (ClientService ->
# getDisplayInfos) probes every X display it can find a cookie for, using
# `xdpyinfo || xwininfo || xdotool || xrandr || xrdb -query` with NO timeout of
# its own. Every gnome-shell publishes a second X socket for GNOME_SETUP_DISPLAY
# which accepts connections and never completes the handshake, so a probe of it
# blocks forever — and with it SC's main thread, which then never reaches the
# relay (the client stays offline) and later freezes the live session on every
# re-probe.
#
# This wrapper is installed to /usr/local/bin as xdpyinfo/xrandr/xwininfo/xrdb
# (ahead of /usr/bin in the service PATH) and bounds every probe.
#
# It deliberately keys on BEHAVIOUR, not on a display number. An earlier version
# hardcoded ":1" — the dead socket on a box parked in a user session. In
# backstage mode the GDM greeter runs permanently and *its* dead socket is
# ":1025", so the hardcoded skip missed it and SC hung exactly as before. The
# number depends on what else is running and cannot be predicted.
#
# A display that times out is remembered briefly, because SC re-probes every few
# seconds and paying the timeout each round would still stall detection. The
# memo lives under the runtime dir (cleared at boot) and expires after 5 minutes
# so a display that comes back is picked up again.
#
# Remove the /usr/local/bin symlinks to revert.

tool=$(basename "$0")
timeout_s="${DREAMCONNECT_XPROBE_TIMEOUT:-3}"

# A fixed search list, deliberately not $PATH: this runs as root inside
# ScreenConnect's service environment, and resolving through PATH would let a
# writable directory earlier in it decide what root executes. /usr/sbin is in the
# list because that is where xdotool lives on Fedora — assuming /usr/bin made the
# wrapper exec a path that does not exist.
real_dirs="/usr/bin /usr/sbin /bin /sbin"
real=""
for d in $real_dirs; do
  if [ -x "$d/$tool" ]; then real="$d/$tool"; break; fi
done
# Tool genuinely absent: report "nothing found" so SC's chain moves on.
[ -n "$real" ] || exit 1

# No `timeout` binary: nothing useful to add, so stay out of the way entirely.
command -v timeout >/dev/null 2>&1 || exec "$real" "$@"

# One memo file per display. Squash anything that isn't a safe filename
# character so a hostile DISPLAY can't escape the directory.
key=$(printf '%s' "${DISPLAY:-none}" | tr -c 'A-Za-z0-9._-' '_')
memo_dir="${XDG_RUNTIME_DIR:-/run}/dreamconnect-xprobe"
memo="$memo_dir/$key"

if [ -e "$memo" ]; then
  # Still fresh (younger than 5 minutes): skip instantly.
  if [ -z "$(find "$memo" -mmin +5 2>/dev/null)" ]; then
    exit 1
  fi
  rm -f "$memo" 2>/dev/null
fi

timeout -s KILL "$timeout_s" "$real" "$@"
rc=$?

# 124 = timeout fired, 137 = SIGKILL after it. Either way the display never
# answered: report "nothing found" and remember it.
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  # 0700 root-owned: the memo suppresses display detection, so it must not be
  # writable by other local users. A failure to create it is not fatal — the
  # timeout above is what actually protects SC.
  (umask 077; mkdir -p "$memo_dir" 2>/dev/null) && : > "$memo" 2>/dev/null
  exit 1
fi

exit "$rc"
