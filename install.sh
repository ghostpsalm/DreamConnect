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
#   DREAMCONNECT_SKIP_DEPS=1   don't touch the package manager (deps preinstalled)
#   DREAMCONNECT_AUTOLOGIN=1   configure GDM autologin so the bridge survives a
#                              reboot unattended (security trade-off — opt-in)
#
# Dependencies are installed via the detected package manager (apt/dnf/zypper/
# pacman); see docs/troubleshooting.md for the per-distro package list if your
# distro isn't covered or a name differs.
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

# --- GDM autologin (reboot survival) helpers --------------------------------
gdm_conf() {  # path to the GDM config, or empty if GDM isn't present
  local c
  for c in /etc/gdm/custom.conf /etc/gdm3/custom.conf; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
}

# Set AutomaticLoginEnable/AutomaticLogin under [daemon], preserving the rest of
# the file (comments included). Idempotent: strips any prior autologin keys in
# the section first. Backs up once to <conf>.dreamconnect.bak.
enable_autologin() {
  local conf="$1" user="$2" tmp
  [ -f "$conf.dreamconnect.bak" ] || cp -a "$conf" "$conf.dreamconnect.bak"
  tmp="$(mktemp)"
  awk -v user="$user" '
    BEGIN { in_daemon = 0; done = 0 }
    /^\[.*\]$/ {
      in_daemon = ($0 == "[daemon]"); print
      if (in_daemon) { print "AutomaticLoginEnable=true"; print "AutomaticLogin=" user; done = 1 }
      next
    }
    { if (in_daemon && $0 ~ /^[[:space:]]*#?[[:space:]]*AutomaticLogin(Enable)?[[:space:]]*=/) next; print }
    END { if (!done) { print ""; print "[daemon]"; print "AutomaticLoginEnable=true"; print "AutomaticLogin=" user } }
  ' "$conf" > "$tmp" && cat "$tmp" > "$conf"
  rm -f "$tmp"
}

# Undo: drop the autologin keys we set under [daemon]. Leaves the rest intact.
disable_autologin() {
  local conf="$1" tmp
  tmp="$(mktemp)"
  awk '
    /^\[.*\]$/ { in_daemon = ($0 == "[daemon]"); print; next }
    { if (in_daemon && $0 ~ /^[[:space:]]*AutomaticLogin(Enable)?[[:space:]]*=/) next; print }
  ' "$conf" > "$tmp" && cat "$tmp" > "$conf"
  rm -f "$tmp"
}

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
  # Revert autologin only if we set it up (our backup marker exists).
  local conf; conf="$(gdm_conf)"
  if [ -n "$conf" ] && [ -f "$conf.dreamconnect.bak" ]; then
    disable_autologin "$conf"
    echo ">> disabled the autologin we configured in $conf (backup: $conf.dreamconnect.bak)"
  fi
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

# --- dependencies (distro-agnostic, best-effort) ----------------------------
# The agent + daemon are distro-neutral, but they need: the X11 probe tools SC
# uses for geometry (xdpyinfo/xrandr/xwininfo), python3 + GObject introspection,
# the GStreamer PipeWire source + base plugins (pipewiresrc/videoconvert/appsink),
# wl-clipboard (the "insert clipboard text" paste fallback), and a JDK to build
# the agent. Names differ per distro; failures warn rather than abort so a box
# that already has them (or uses an unlisted PM) still installs.
detect_pm() {
  local pm
  for pm in apt-get dnf zypper pacman; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
  done
}
PM="$(detect_pm)"

pm_install() {  # best-effort; non-zero on failure
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)     dnf install -y "$@" ;;
    zypper)  zypper --non-interactive install "$@" ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" ;;
    *)       return 1 ;;
  esac
}

case "$PM" in
  dnf)     DEPS=(xdpyinfo xrandr xwininfo python3-gobject pipewire-gstreamer gstreamer1-plugins-base wl-clipboard); JDK_PKG=java-latest-openjdk-devel ;;
  apt-get) DEPS=(x11-utils x11-xserver-utils python3-gi gir1.2-gstreamer-1.0 gstreamer1.0-pipewire gstreamer1.0-plugins-base wl-clipboard); JDK_PKG=default-jdk ;;
  pacman)  DEPS=(xorg-xdpyinfo xorg-xrandr xorg-xwininfo python-gobject gst-plugin-pipewire gst-plugins-base wl-clipboard); JDK_PKG=jdk-openjdk ;;
  zypper)  DEPS=(xdpyinfo xrandr xwininfo python3-gobject gstreamer-plugins-pipewire gstreamer-plugins-base wl-clipboard); JDK_PKG=java-21-openjdk-devel ;;
  *)       DEPS=(); JDK_PKG="" ;;
esac

if [ "${DREAMCONNECT_SKIP_DEPS:-}" = "1" ]; then
  echo ">> skipping dependency install (DREAMCONNECT_SKIP_DEPS=1)"
elif [ -n "$PM" ]; then
  echo ">> installing dependencies via $PM"
  pm_install "${DEPS[@]}" >/dev/null 2>&1 \
    || echo "!! some dependencies failed via $PM; install manually: ${DEPS[*]}"
else
  echo "!! no supported package manager (apt/dnf/zypper/pacman) found."
  echo "   Ensure these are installed: xdpyinfo xrandr xwininfo, python3 + GObject"
  echo "   introspection, GStreamer PipeWire + base plugins, wl-clipboard, a JDK."
fi

# --- build the agent if not already built -----------------------------------
AGENT_JAR="$HERE/agent/target/dist/dreamconnect-agent.jar"
if [ ! -f "$AGENT_JAR" ]; then
  if ! command -v javac >/dev/null 2>&1; then
    echo ">> javac not found; installing a JDK (${JDK_PKG:-none})"
    [ -n "$JDK_PKG" ] && pm_install "$JDK_PKG" >/dev/null 2>&1 || true
    command -v javac >/dev/null 2>&1 \
      || die "javac is required to build the agent; install a JDK (17+) and re-run"
  fi
  echo ">> building agent"; bash "$HERE/agent/build.sh" >/dev/null
fi

# --- deploy files -----------------------------------------------------------
# Root-owned, not group/other-writable on purpose: anyone able to write the
# agent jar gets root code execution inside the ScreenConnect JVM, and anyone
# able to write the daemon script runs code in the desktop session. Keep these
# paths root:root and non-writable by others.
echo ">> deploying to $INSTALL_DIR"
install -d -o root -g root -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/runtime"
install -o root -g root -m 0755 "$HERE/runtime/dreamconnect_daemon.py" "$INSTALL_DIR/runtime/"
install -o root -g root -m 0644 "$AGENT_JAR" "$INSTALL_DIR/dreamconnect-agent.jar"

# --- host fix: broken-:1 display skip wrapper -------------------------------
# ScreenConnect detects screen geometry with xdpyinfo/xrandr/xwininfo (installed
# above). On hosts whose Xwayland :1 hangs X probes, that freezes the session
# periodically, so we shadow those tools with a wrapper that fails :1 probes
# instantly and passes everything else through. See host-fixes/ for the why.
echo ">> installing broken-display skip wrapper"
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

# --- reboot survival: display-manager autologin -----------------------------
# The daemon is WantedBy=graphical-session.target, which only fires once a
# graphical session logs in; the bridge can't drive the GDM greeter. So an
# unattended box must autologin at boot. That's a security trade-off (physical
# access -> an already-unlocked session), so we only configure it on explicit
# opt-in (DREAMCONNECT_AUTOLOGIN=1); otherwise we warn and point at the opt-in.
GDM_CONF="$(gdm_conf)"
if [ "${DREAMCONNECT_AUTOLOGIN:-}" = "1" ]; then
  if [ -n "$GDM_CONF" ]; then
    echo ">> enabling GDM autologin for $USER_NAME in $GDM_CONF (DREAMCONNECT_AUTOLOGIN=1)"
    enable_autologin "$GDM_CONF" "$USER_NAME"
    echo "   SECURITY: this box now boots straight into $USER_NAME's session, no login prompt."
    echo "   backup: $GDM_CONF.dreamconnect.bak · reboot to verify unattended survival."
    if grep -qiE '^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*false' "$GDM_CONF"; then
      echo "   NOTE: WaylandEnable=false is set — the bridge needs a *Wayland* session."
      echo "   Make sure $USER_NAME's default session is GNOME on Wayland, not Xorg."
    fi
  else
    echo "!! DREAMCONNECT_AUTOLOGIN=1 but no GDM found (/etc/gdm{,3}/custom.conf)."
    echo "   DreamConnect targets GNOME/GDM; enable autologin for $USER_NAME on your"
    echo "   display manager by hand to survive reboots."
  fi
elif [ -n "$GDM_CONF" ] \
     && grep -qiE '^[[:space:]]*AutomaticLoginEnable[[:space:]]*=[[:space:]]*true' "$GDM_CONF"; then
  echo ">> autologin already enabled in $GDM_CONF — the bridge will survive a reboot."
else
  echo "!! WARNING: autologin is not enabled — the bridge will NOT survive a reboot."
  echo "   It needs a graphical Wayland session at boot but can't drive the greeter."
  echo "   Re-run with DREAMCONNECT_AUTOLOGIN=1 to configure GDM autologin for $USER_NAME"
  echo "   (security trade-off: physical access -> an unlocked session), or set it up manually."
fi

echo ">> done. Check:  ${RUN_USER[*]} systemctl --user status dreamconnect-daemon"
