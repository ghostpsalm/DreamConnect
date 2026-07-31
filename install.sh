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
#   DREAMCONNECT_HOST_ACCOUNT=<name>
#                              run the bridge in a dedicated display-host account
#                              instead of the human's session: creates the account
#                              if absent, hides it from the greeter, disables
#                              idle/lock for it, and always configures GDM
#                              autologin for it (so DREAMCONNECT_AUTOLOGIN is not
#                              consulted — host-account mode implies autologin,
#                              and requires GDM). Opt-in; unset means the
#                              detected desktop user, exactly as before. One host
#                              account per box: once one is installed, a re-run
#                              naming a DIFFERENT account is refused — run
#                              --uninstall first to switch.
#
# Dependencies are installed via the detected package manager (apt/dnf/zypper/
# pacman); see docs/troubleshooting.md for the per-distro package list if your
# distro isn't covered or a name differs.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/dreamconnect}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION="${1:-install}"

# Function definitions live in the library so they can be unit-tested without
# root; everything below is the install sequence itself.
source "$HERE/install-lib.sh"

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

# The human's own graphical session — always detected, even when a display-host
# account also exists. It's the fallback identity when DREAMCONNECT_HOST_ACCOUNT
# is unset (today's behaviour, unchanged below), and it's the account
# host_account_removable refuses to ever delete.
#
# Tolerated empty rather than fatal: a display-host box is managed over SC's root
# channel or SSH with nobody logged in locally, so "no graphical session at all"
# is a normal state for it. The paths that genuinely need a session still refuse
# without one — see uninstall()'s classic-mode branch.
PROTECTED_USER="$(detect_user 2>/dev/null)" || PROTECTED_USER=""

# --- find the ScreenConnect unit --------------------------------------------
# `|| true` because systemctl exits non-zero when its pattern matches nothing,
# and under `set -o pipefail` that would abort the whole script on a box with no
# ScreenConnect client installed — including an --uninstall that still has an
# account to clean up. The empty case is handled everywhere SC_UNIT is used.
SC_UNIT="$(systemctl list-unit-files --no-legend 'connectwisecontrol-*.service' 2>/dev/null \
           | awk '{print $1}' | head -1 || true)"

uninstall() {
  echo ">> uninstalling"
  # Safe defaults when there is no state file — i.e. DREAMCONNECT_HOST_ACCOUNT
  # was never used, and everything below reverts the desktop user's install.
  read_install_state

  local target_name target_uid target_home
  if [ -n "$HOST_ACCOUNT" ]; then
    target_name="$HOST_ACCOUNT"
    target_uid="$HOST_UID"
    target_home="$(passwd_entry "$target_name" | cut -d: -f6)"
  else
    # Classic mode has no state file, so the detected session is the only thing
    # that says whose install to revert — here it really is required.
    [ -n "$PROTECTED_USER" ] || die "could not detect a graphical session user; set DREAMCONNECT_USER= (or use DREAMCONNECT_HOST_ACCOUNT for unattended installs)"
    target_name="$PROTECTED_USER"
    target_uid="$(id -u "$target_name")"
    target_home="$(getent passwd "$target_name" | cut -d: -f6)"
  fi
  local target_run_user=(sudo -u "$target_name" env "XDG_RUNTIME_DIR=/run/user/$target_uid" \
                          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$target_uid/bus")

  "${target_run_user[@]}" systemctl --user disable --now dreamconnect-daemon.service 2>/dev/null || true
  # $target_home is passwd field 6 verbatim, and an account deleted by hand
  # before --uninstall leaves it empty — which points this rm at root's own
  # /.config/systemd/user. `rm -f` is silent about that today, but silence is an
  # accident, not a guard. Skipped rather than fatal, for the same reason
  # remove_no_idle_lock's failure is non-fatal below: everything after this line
  # (the SC drop-in, the dconf revert, the account, the state file) is exactly
  # what a box whose account is already gone still needs reverted.
  if valid_home_dir "$target_home"; then
    rm -f "$target_home/.config/systemd/user/dreamconnect-daemon.service"
  else
    echo "!! skipping the daemon unit removal for $target_name: unusable home directory '$target_home' — continuing"
  fi
  "${target_run_user[@]}" systemctl --user daemon-reload 2>/dev/null || true
  # Here, with the other calls into the account's live user manager, and not down
  # in the HOST_ACCOUNT block below: the `loginctl disable-linger` further down is
  # the only thing stopping user@<uid>.service on a reused account (CREATED_ACCOUNT=0,
  # so uninstall_host_account's terminate-user never runs), and systemd takes
  # /run/user/<uid> down with it — after that there is no manager left to unset
  # DCONF_PROFILE in. Still the reverse of the install order: clear DCONF_PROFILE
  # from the live manager first, then remove_no_idle_lock deletes the profile it
  # names, so the manager never spends the uninstall pointing at an absent profile
  # (dconf's null configuration).
  #
  # Never fatal, for the same reason as its neighbours below: a refusal here (a
  # reserved name in a tampered state file, or a manager that is simply not
  # running) must not stop the account deletion, which is the whole point.
  if [ -n "$HOST_ACCOUNT" ]; then
    unpush_dconf_environment "$HOST_ACCOUNT" "$target_uid" 2>/dev/null \
      || echo "!! could not clear DCONF_PROFILE from $HOST_ACCOUNT's user manager — continuing"
  fi
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
  # `|| true` because gdm_conf exits non-zero when there is no GDM, and set -e
  # would abort the rest of the cleanup below over a display manager we never
  # touched. The empty case is already handled on the next line.
  local conf; conf="$(gdm_conf || true)"
  # Branched, and never fatal for the same reason as its neighbours: a failed
  # strip must not stop the account deletion below. On success the backup is
  # gone with it, so only the failure branch can point at one.
  if [ -n "$conf" ] && [ -f "$conf.dreamconnect.bak" ]; then
    if disable_autologin "$conf"; then
      echo ">> disabled the autologin we configured in $conf"
    else
      echo "!! could not disable the autologin we configured in $conf — it may still log in automatically; the pre-install config is at $conf.dreamconnect.bak"
    fi
  fi
  # Undo the linger install always enables — previously never reverted here,
  # a pre-existing gap (see ROADMAP.md H6).
  loginctl disable-linger "$target_name" 2>/dev/null || true

  if [ -n "$HOST_ACCOUNT" ]; then
    # Never fatal: a refusal here (a reserved name in a tampered state file)
    # must not stop the account deletion below, which is the whole point.
    # DCONF_PROFILE was already cleared from the live manager above, so this
    # deletes a profile nothing is pointing at any more.
    remove_no_idle_lock "$HOST_ACCOUNT" "$target_home" \
      || echo "!! could not fully revert idle-lock config for $HOST_ACCOUNT — continuing"
    # ensure_host_account backs up a pre-existing marker before overwriting it
    # (a pre-existing account may not be ours), or writes one fresh if there
    # wasn't one — this restores the original in the first case, and removes
    # what we created in the second, so a pre-existing account isn't left
    # hidden from GDM after we're uninstalled.
    # Not fatal either, and for the same reason as the line above: under set -e a
    # refusal would abort the uninstall before the account deletion below.
    remove_accountsservice_marker "$HOST_ACCOUNT" \
      || echo "!! could not revert the AccountsService marker for $HOST_ACCOUNT — continuing"
    local account_removed=1
    if [ "$CREATED_ACCOUNT" = "1" ]; then
      # On an autologinned box the only active session IS the host account's, so
      # detect_user returns it and rail 3 would refuse to remove the very account
      # this feature exists to remove. Protecting an account from itself is
      # meaningless; the other five rails (uid≠0, safe home, not $SUDO_USER,
      # state agreement, exact GECOS marker) still prove it's ours.
      local protect_arg="$PROTECTED_USER"
      [ "$protect_arg" != "$HOST_ACCOUNT" ] || protect_arg=""
      if uninstall_host_account "$HOST_ACCOUNT" "$protect_arg"; then
        echo ">> removed display-host account $HOST_ACCOUNT"
      else
        echo "!! could not remove display-host account $HOST_ACCOUNT — left in place, check manually"
        account_removed=0
      fi
    fi
    # The state file is the only thing that says this account is ours: rails 5/6
    # read it. Deleting it after a failed removal (userdel exits 8 while the
    # session is still winding down, say) would leave the account permanently
    # unremovable by this tool, so keep it and let a re-run retry.
    if [ "$account_removed" = "1" ]; then
      rm -f "$(install_state_file)"
    else
      echo "!! state preserved at $(install_state_file) so a future --uninstall can retry account removal"
    fi
  fi

  echo ">> removed service wiring + probe wrappers (left $INSTALL_DIR in place)"
  exit 0
}
[ "$ACTION" = "--uninstall" ] && uninstall

# --- detect the capture monitor ---------------------------------------------
# Always probed through the human's own active session: the probe is a D-Bus
# call into Mutter, and the display-host account resolved below has no session
# of its own at install time, so probing as it would silently fall back to the
# hardcoded default. RUN_USER is reassigned to the resolved identity right after.
#
# Empty when there is no session to probe through at all — bootstrapping a
# display-host account on a headless box over SSH. `id -u ""` would fail and
# set -e would abort the install right here, so build the prefix only when there
# is a user for it; detect_monitor's own fallback then yields the default.
if [ -n "$PROTECTED_USER" ]; then
  RUN_USER=(sudo -u "$PROTECTED_USER" env "XDG_RUNTIME_DIR=/run/user/$(id -u "$PROTECTED_USER")" \
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u "$PROTECTED_USER")/bus")
else
  RUN_USER=()
fi
MONITOR="$(detect_monitor)"

# --- resolve the identity the daemon/autologin/socket will run under --------
# "user" and "local" are dconf's own default profile and its shared system db;
# configure_no_idle_lock refuses them, and it only runs long after the account
# exists. "root" is not a dconf name at all — it is simply the account every
# other rail here exists to protect; host_account_installable refuses it too,
# but only through the generic "already installed" die below, which is a lie on
# a fresh box. Refuse all three here instead, before anything at all is created,
# so a reserved name can never leave an account behind that the later failure
# never recorded.
case "${DREAMCONNECT_HOST_ACCOUNT:-}" in
  root|user|local)
    die "DREAMCONNECT_HOST_ACCOUNT=$DREAMCONNECT_HOST_ACCOUNT is a reserved name (root/user/local); choose a different account name" ;;
esac
# And the shape of the name itself, at the entry point, before ensure_host_account
# or resolve_host_identity ever sees it: `getent passwd 1000` resolves by UID, so
# an all-numeric name would silently bind the whole install to whoever owns that
# uid, and a name carrying "/" or "." walks past the string comparison above.
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ] && ! valid_account_name "$DREAMCONNECT_HOST_ACCOUNT"; then
  die "DREAMCONNECT_HOST_ACCOUNT=$DREAMCONNECT_HOST_ACCOUNT is not a valid account name (must start with a letter or underscore, contain only letters/digits/underscore/hyphen, and be at most 32 characters)"
fi
# One display-host account per box: a re-run naming a different account than
# install.state records is refused (its predecessor's dconf profile, linger and
# AccountsService marker would become unreachable by --uninstall), and a re-run
# naming none at all continues under the recorded one. Asked here, before
# ensure_host_account can create anything and long before write_install_state
# overwrites the single slot — and the answer is what the rest of the run uses.
DREAMCONNECT_HOST_ACCOUNT="$(host_account_installable "${DREAMCONNECT_HOST_ACCOUNT:-}")" \
  || die "this box already has a display-host account installed; run $0 --uninstall first
   (if install.state itself records an invalid or reserved account name, --uninstall
   will refuse it too; delete $(install_state_file) by hand to recover)"
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
  # Host-account mode needs GDM to ever autologin — fail before touching the
  # system rather than leaving a created-but-useless account behind. `|| true`
  # because gdm_conf exits non-zero when there is no GDM, and set -e would
  # otherwise abort here without saying why.
  GDM_CONF="$(gdm_conf || true)"
  [ -n "$GDM_CONF" ] || die "DREAMCONNECT_HOST_ACCOUNT=$DREAMCONNECT_HOST_ACCOUNT set but no GDM found (/etc/gdm{,3}/custom.conf); DreamConnect's display-host account currently targets GNOME/GDM only."
  ensure_host_account "$DREAMCONNECT_HOST_ACCOUNT"
  HOST_WAS_CREATED="$ACCOUNT_WAS_CREATED"
fi
IDENTITY="$(resolve_host_identity "${DREAMCONNECT_HOST_ACCOUNT:-}" "$PROTECTED_USER")" \
  || die "could not resolve the identity to install the daemon under"
read -r USER_NAME USER_UID USER_HOME _ <<<"$IDENTITY"
# resolve_host_identity copies passwd field 6 out verbatim, and every later use
# of $USER_HOME is a root write pasted into it: the `install -d`, the daemon unit
# and its chown, and configure_no_idle_lock's two home files. An empty or
# malformed field aims all of them at root's own /.config. Refused here, before
# the first of them runs: this is the install side, with an operator present, and
# files laid down under a bad home are artefacts --uninstall can never find again.
valid_home_dir "$USER_HOME" \
  || die "the account $USER_NAME has an unusable home directory ('$USER_HOME'); fix its passwd entry and re-run"
RUN_USER=(sudo -u "$USER_NAME" env "XDG_RUNTIME_DIR=/run/user/$USER_UID" \
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus")

# The account now exists, so record it before anything else can fail: every
# later step (deps, build, deploy, linger, the daemon unit, autologin) is a
# chance to abort, and --uninstall can only revert what this file names.
# AUTOLOGIN_SET is 1 because host-account mode always configures it below.
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
  write_install_state "$USER_NAME" "$USER_UID" "$HOST_WAS_CREATED" 1
fi

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
# `|| true` because detect_pm returns non-zero when none of apt/dnf/zypper/pacman
# is present, and a bare assignment from a command substitution propagates that
# under set -e — aborting the install before the "no supported package manager"
# warning below ever runs.
PM="$(detect_pm || true)"

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
# enable-linger starts user@$USER_UID.service in the background; the systemctl
# --user calls below need its bus to exist first (issue #24).
wait_for_user_bus "$USER_UID" \
  || die "the user bus for $USER_NAME (uid $USER_UID) never came up after 'loginctl enable-linger'; check 'systemctl status user@$USER_UID.service'"
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

# --- display-host extras: idle/lock -----------------------------------------
# The install-state record was written earlier, right after the account was
# resolved, so a failure here is still reverted by --uninstall.
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
  echo ">> disabling idle/lock for $USER_NAME (locking or idle-suspend kills the remote session — see ROADMAP.md H6)"
  configure_no_idle_lock "$USER_NAME" "$USER_HOME"
  # The drop-in above only reaches `systemd --user` at manager start, and the
  # manager has been running since enable-linger, so push DCONF_PROFILE into the
  # live one too (issue #26). Non-fatal: this is the redundant half — the
  # environment.d drop-in is on disk either way — so a manager that refuses
  # set-environment must warn, not abort an otherwise-complete install.
  push_dconf_environment "$USER_NAME" "$USER_UID" \
    || echo "!! could not push DCONF_PROFILE into $USER_NAME's running user manager — the environment.d drop-in is still in place and applies at the next manager start, so reboot to pick up the idle/lock settings"
fi

# --- reboot survival: display-manager autologin -----------------------------
# The daemon is WantedBy=graphical-session.target, which only fires once a
# graphical session logs in; the bridge can't drive the GDM greeter. So an
# unattended box must autologin at boot. That's a security trade-off (physical
# access -> an already-unlocked session), so we only configure it on explicit
# opt-in (DREAMCONNECT_AUTOLOGIN=1); otherwise we warn and point at the opt-in.
# Host-account mode is unattended by construction, so it always configures
# autologin (for the display-host account, never the human's) — DREAMCONNECT_AUTOLOGIN
# isn't consulted, and the GDM check above already refused if there's no GDM.
# `|| true` because gdm_conf exits non-zero when there is no GDM, and set -e
# would abort here — silently, after everything else has already installed, and
# without ever reaching the "no GDM found" warnings below.
GDM_CONF="$(gdm_conf || true)"
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
  echo ">> enabling GDM autologin for the display-host account $USER_NAME in $GDM_CONF"
  enable_autologin "$GDM_CONF" "$USER_NAME"
  echo "   backup: $GDM_CONF.dreamconnect.bak · reboot to verify unattended survival."
elif [ "${DREAMCONNECT_AUTOLOGIN:-}" = "1" ]; then
  if [ -n "$GDM_CONF" ]; then
    echo ">> enabling GDM autologin for $USER_NAME in $GDM_CONF (DREAMCONNECT_AUTOLOGIN=1)"
    # Non-fatal here, unlike the host-account call above: this is the very last
    # step and the daemon is already installed, so a refused name (root, or one
    # carrying a backslash) must not abort an otherwise-complete install.
    if enable_autologin "$GDM_CONF" "$USER_NAME"; then
      echo "   SECURITY: this box now boots straight into $USER_NAME's session, no login prompt."
      echo "   backup: $GDM_CONF.dreamconnect.bak · reboot to verify unattended survival."
    else
      # Nothing was written, so neither the security warning nor the backup path
      # below would be true — the refusal is the whole of the output.
      echo "!! could not enable autologin for $USER_NAME — the daemon install itself succeeded; check the account name and re-run, or configure autologin manually"
    fi
    # WaylandEnable=false only matters if it's actually forcing Xorg. Modern GDM
    # (50+) ignores it and the session is Wayland anyway, so only warn when this
    # user's current session is NOT Wayland — otherwise it's demonstrably inert.
    if grep -qiE '^[[:space:]]*WaylandEnable[[:space:]]*=[[:space:]]*false' "$GDM_CONF" \
       && [ "$(user_session_type)" != "wayland" ]; then
      echo "   NOTE: WaylandEnable=false is set and this session isn't Wayland —"
      echo "   ensure $USER_NAME's autologin session is GNOME on Wayland, not Xorg,"
      echo "   or the bridge won't work at boot."
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
