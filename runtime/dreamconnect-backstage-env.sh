#!/usr/bin/env bash
#
# Publish the backstage shell's X display so the (root) ScreenConnect JVM can
# attach to it.
#
# gnome-shell exports DISPLAY and XAUTHORITY into the systemd *user* environment
# once its Xwayland is up. Both are unpredictable — the display number depends on
# what else is running, and mutter's xauth file carries a random suffix
# (.mutter-Xwaylandauth.XXXXXX) — so neither can be hardcoded in a drop-in.
# This snapshots them into an EnvironmentFile that the ScreenConnect drop-in
# reads, and is run as ExecStartPost of dreamconnect-backstage.service.
#
# Without it SC's JVM has no DISPLAY, AWT initialises headless, and the agent's
# Robot peer never gets constructed.
#
# The cookie is COPIED to a stable path rather than referenced where mutter put
# it. systemd reads an EnvironmentFile once, at unit start, so a long-running SC
# JVM keeps whatever XAUTHORITY it was started with — and mutter's filename
# changes on every backstage restart, which would leave SC pointing at a deleted
# file. A stable path with refreshed contents survives that, because X clients
# read the cookie file at connect time. (A changed display *number* still needs
# an SC restart; it is far rarer, as the shell reclaims the same free number.)
set -uo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OUT="$RUNTIME_DIR/dreamconnect-display.env"
STABLE_XAUTH="$RUNTIME_DIR/dreamconnect.Xauthority"
TIMEOUT="${DREAMCONNECT_DISPLAY_TIMEOUT:-60}"

# Read one variable out of the user manager's environment block. Values can't
# contain newlines, so a line-oriented read is exact.
show_env_value() {  # name
  systemctl --user show-environment 2>/dev/null \
    | sed -n "s/^$1=//p" | head -1
}

deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  display="$(show_env_value DISPLAY)"
  xauth="$(show_env_value XAUTHORITY)"
  if [ -n "$display" ] && [ -n "$xauth" ] && [ -r "$xauth" ]; then
    # 0600 throughout: an X cookie is a capability to drive the session. The only
    # intended reader is the root SC JVM, which bypasses DAC.
    umask 077
    cp -f "$xauth" "$STABLE_XAUTH.tmp" || {
      echo "[dreamconnect] could not copy $xauth to $STABLE_XAUTH" >&2
      exit 1
    }
    chmod 0600 "$STABLE_XAUTH.tmp"
    mv -f "$STABLE_XAUTH.tmp" "$STABLE_XAUTH"
    printf 'DISPLAY=%s\nXAUTHORITY=%s\n' "$display" "$STABLE_XAUTH" > "$OUT.tmp"
    mv -f "$OUT.tmp" "$OUT"
    echo "[dreamconnect] backstage display $display (cookie from $xauth) published to $OUT"
    exit 0
  fi
  sleep 1
done

echo "[dreamconnect] backstage shell never exported DISPLAY/XAUTHORITY within ${TIMEOUT}s;" \
     "ScreenConnect will have no display to attach to" >&2
exit 1
