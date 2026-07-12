#!/usr/bin/env bash
#
# dreamconnect installer. Wires up the two halves of the bridge:
#   * a user systemd service running the runtime daemon (Wayland capture/input);
#   * a systemd drop-in on the ScreenConnect client unit that injects the agent
#     via JAVA_TOOL_OPTIONS.
#
# Run as root (it writes /opt and /etc/systemd/system):   sudo ./install.sh
# Uninstall:                                              sudo ./install.sh --uninstall
#
# Overrides via environment:
#   DREAMCONNECT_USER=<name>   desktop user (default: auto-detected graphical session)
#   MONITOR=<connector>        capture source (default: auto-detected / HDMI-2)
#   INSTALL_DIR=<path>         default /opt/dreamconnect
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/dreamconnect}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-install}"

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

# --- detect the desktop user + uid ------------------------------------------
detect_user() {
  if [ -n "${DREAMCONNECT_USER:-}" ]; then echo "$DREAMCONNECT_USER"; return; fi
  local sid uid name type active
  while read -r sid uid name _; do
    type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
    active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)
    if { [ "$type" = "wayland" ] || [ "$type" = "x11" ]; } && [ "$active" = "yes" ]; then
      echo "$name"; return
    fi
  done < <(loginctl list-sessions --no-legend)
  die "could not detect a graphical session user; set DREAMCONNECT_USER="
}

USER_NAME="$(detect_user)"
USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
RUN_USER=(sudo -u "$USER_NAME" env "XDG_RUNTIME_DIR=/run/user/$USER_UID" \
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus")

# --- find the ScreenConnect unit --------------------------------------------
SC_UNIT="$(systemctl list-unit-files --no-legend 'connectwisecontrol-*.service' 2>/dev/null \
           | awk '{print $1}' | head -1)"

uninstall() {
  echo ">> uninstalling"
  "${RUN_USER[@]}" systemctl --user disable --now dreamconnect-daemon.service 2>/dev/null || true
  rm -f "$USER_HOME/.config/systemd/user/dreamconnect-daemon.service"
  "${RUN_USER[@]}" systemctl --user daemon-reload 2>/dev/null || true
  if [ -n "$SC_UNIT" ]; then
    rm -f "/etc/systemd/system/$SC_UNIT.d/dreamconnect.conf"
    rmdir "/etc/systemd/system/$SC_UNIT.d" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart "$SC_UNIT" || true
  fi
  for t in xdpyinfo xrandr xwininfo xrdb; do
    [ -L "/usr/local/bin/$t" ] && rm -f "/usr/local/bin/$t"
  done
  rm -f /usr/local/bin/.dc-xprobe-wrapper
  echo ">> removed service wiring + probe wrappers (left $INSTALL_DIR in place)"
  exit 0
}
[ "$ACTION" = "--uninstall" ] && uninstall

# --- detect the capture monitor ---------------------------------------------
detect_monitor() {
  if [ -n "${MONITOR:-}" ]; then echo "$MONITOR"; return; fi
  "${RUN_USER[@]}" python3 - <<'PY' 2>/dev/null || echo "HDMI-2"
from gi.repository import Gio, GLib
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
r = bus.call_sync('org.gnome.Mutter.DisplayConfig','/org/gnome/Mutter/DisplayConfig',
    'org.gnome.Mutter.DisplayConfig','GetCurrentState',None,None,Gio.DBusCallFlags.NONE,-1,None)
_, monitors, *_ = r.unpack()
print(monitors[0][0][0])  # first monitor's connector name
PY
}
MONITOR="$(detect_monitor)"

echo ">> desktop user : $USER_NAME (uid $USER_UID)"
echo ">> SC unit      : ${SC_UNIT:-<none found>}"
echo ">> capture mon  : $MONITOR"
echo ">> install dir  : $INSTALL_DIR"

# --- build the agent if not already built -----------------------------------
AGENT_JAR="$HERE/agent/target/dist/dreamconnect-agent.jar"
[ -f "$AGENT_JAR" ] || { echo ">> building agent"; bash "$HERE/agent/build.sh" >/dev/null; }

# --- deploy files -----------------------------------------------------------
echo ">> deploying to $INSTALL_DIR"
install -d "$INSTALL_DIR/runtime"
install -m 0755 "$HERE/runtime/dreamconnect_daemon.py" "$INSTALL_DIR/runtime/"
install -m 0644 "$AGENT_JAR" "$INSTALL_DIR/dreamconnect-agent.jar"

# --- host fix: display-detection tools + broken-:1 skip wrapper --------------
# ScreenConnect detects screen geometry with xdpyinfo/xrandr/xwininfo; without
# them it reports "no display information". And this host's Xwayland :1 hangs
# X probes, freezing the session periodically. See host-fixes/ for the why.
echo ">> installing display-probe tools + broken-display skip wrapper"
if command -v dnf >/dev/null 2>&1; then
  dnf install -y xdpyinfo xrandr xwininfo >/dev/null 2>&1 || \
    echo "!! could not install xdpyinfo/xrandr/xwininfo; install them manually"
fi
install -m 0755 "$HERE/host-fixes/xprobe-skip-broken-display.sh" \
  /usr/local/bin/.dc-xprobe-wrapper
for t in xdpyinfo xrandr xwininfo xrdb; do ln -sf .dc-xprobe-wrapper "/usr/local/bin/$t"; done

# --- user daemon service ----------------------------------------------------
echo ">> installing user service"
install -d -o "$USER_NAME" "$USER_HOME/.config/systemd/user"
sed -e "s#@INSTALL_DIR@#$INSTALL_DIR#g" -e "s#@MONITOR@#$MONITOR#g" \
    "$HERE/systemd/dreamconnect-daemon.service" \
    > "$USER_HOME/.config/systemd/user/dreamconnect-daemon.service"
chown "$USER_NAME:" "$USER_HOME/.config/systemd/user/dreamconnect-daemon.service"
loginctl enable-linger "$USER_NAME"
"${RUN_USER[@]}" systemctl --user daemon-reload
"${RUN_USER[@]}" systemctl --user enable --now dreamconnect-daemon.service

# --- ScreenConnect drop-in --------------------------------------------------
if [ -n "$SC_UNIT" ]; then
  echo ">> installing agent drop-in on $SC_UNIT"
  install -d "/etc/systemd/system/$SC_UNIT.d"
  sed -e "s#@INSTALL_DIR@#$INSTALL_DIR#g" -e "s#@UID@#$USER_UID#g" \
      "$HERE/systemd/dreamconnect-agent.conf" \
      > "/etc/systemd/system/$SC_UNIT.d/dreamconnect.conf"
  systemctl daemon-reload
  systemctl restart "$SC_UNIT"
else
  echo "!! no connectwisecontrol-*.service found; skipping agent injection."
  echo "   Set JAVA_TOOL_OPTIONS manually per systemd/dreamconnect-agent.conf."
fi

# --- reboot-survival check: the graphical session must autostart ------------
# The daemon is WantedBy=graphical-session.target, which only fires when a
# graphical session logs in. Without GDM autologin, a reboot leaves the login
# screen up and the bridge down until someone logs in at the console.
if ! grep -qiE '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*true' \
       /etc/gdm/custom.conf 2>/dev/null; then
  echo "!! WARNING: GDM autologin is not enabled — the bridge will NOT survive a reboot."
  echo "   The daemon needs a graphical Wayland session at boot. To run unattended,"
  echo "   enable autologin for $USER_NAME in /etc/gdm/custom.conf:"
  echo "       [daemon]"
  echo "       AutomaticLoginEnable=true"
  echo "       AutomaticLogin=$USER_NAME"
  echo "   (then reboot to verify)."
fi

echo ">> done. Check:  ${RUN_USER[*]} systemctl --user status dreamconnect-daemon"
