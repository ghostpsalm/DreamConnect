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
#   DREAMCONNECT_HOST_ACCOUNT_SUDO=1
#                              give the display-host account passwordless sudo,
#                              so an operator can administer the box from the
#                              backstage desktop. NOPASSWD is not a choice: the
#                              account has no password. Opt-in and reversible;
#                              only meaningful with DREAMCONNECT_HOST_ACCOUNT.
#   DREAMCONNECT_FPS=<n>        session fps ceiling (backstage default 60; 0 = SC's
#                              stock 20). Lifts SC's fixed 50ms frame interval. The agent
#                              always logs the achieved fps either way.
#   DREAMCONNECT_BACKSTAGE=1   backstage mode: run the bridge against a headless
#                              `gnome-shell --headless` started by the lingering
#                              user manager, capturing a Mutter virtual monitor.
#                              Needs no monitor, no HDMI dummy plug, no login and
#                              no autologin — the box is reachable from boot with
#                              the greeter still up. The operator gets a private
#                              admin desktop, NOT the console user's session.
#   DREAMCONNECT_BACKSTAGE_RES=<WxH>
#                              backstage screen size (default 1280x720). This is
#                              the real resolution: a virtual monitor has no
#                              intrinsic size, so whatever is asked for is what
#                              the operator sees.
#   DREAMCONNECT_HOST_ACCOUNT=<name>
#                              run the bridge in a dedicated display-host account
#                              instead of the human's session: creates the account
#                              if absent, hides it from the greeter, disables
#                              idle/lock for it, and runs the bridge there. The
#                              account never logs in, so this implies (and turns
#                              on) DREAMCONNECT_BACKSTAGE=1. Opt-in; unset means
#                              the detected desktop user. One host account per
#                              box: once one is installed, a re-run naming a
#                              DIFFERENT account is refused — run --uninstall
#                              first to switch.
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
  # Backstage installs only: stopping the shell unit tears down the headless
  # session itself. Unconditional and quiet, exactly like the daemon line above —
  # a classic install simply has no such unit.
  "${target_run_user[@]}" systemctl --user disable --now dreamconnect-backstage.service 2>/dev/null || true
  # Drop the shm frame with the daemon that owned it. Leaving it behind is not
  # just an 8 MB leak: /dev/shm is sticky, so a later install under a different
  # account cannot unlink it and every write fails with EACCES (#27). Both the
  # uid-scoped path and the legacy unscoped one.
  rm -f "/dev/shm/dreamconnect.frame.$target_uid" /dev/shm/dreamconnect.frame
  # $target_home is passwd field 6 verbatim, and an account deleted by hand
  # before --uninstall leaves it empty — which points this rm at root's own
  # /.config/systemd/user. `rm -f` is silent about that today, but silence is an
  # accident, not a guard. Skipped rather than fatal, for the same reason
  # remove_no_idle_lock's failure is non-fatal below: everything after this line
  # (the SC drop-in, the dconf revert, the account, the state file) is exactly
  # what a box whose account is already gone still needs reverted.
  if valid_home_dir "$target_home"; then
    rm -f "$target_home/.config/systemd/user/dreamconnect-daemon.service" \
          "$target_home/.config/systemd/user/dreamconnect-backstage.service"
  else
    echo "!! skipping the daemon unit removal for $target_name: unusable home directory '$target_home' — continuing"
  fi
  "${target_run_user[@]}" systemctl --user daemon-reload 2>/dev/null || true
  if [ -n "$SC_UNIT" ]; then
    rm -f "/etc/systemd/system/$SC_UNIT.d/dreamconnect.conf"
    rmdir "/etc/systemd/system/$SC_UNIT.d" 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart "$SC_UNIT" || true
  fi
  for t in xdpyinfo xrandr xwininfo xrdb xdotool; do
    [ -L "/usr/local/bin/$t" ] && rm -f "/usr/local/bin/$t"
  done
  rm -f /usr/local/bin/.dc-xprobe-wrapper
  # Undo the linger install always enables — previously never reverted here,
  # a pre-existing gap (see ROADMAP.md H6).
  loginctl disable-linger "$target_name" 2>/dev/null || true

  if [ -n "$HOST_ACCOUNT" ]; then
    # Never fatal: a refusal here (a reserved name in a tampered state file)
    # must not stop the account deletion below, which is the whole point.
    remove_no_idle_lock "$HOST_ACCOUNT" "$target_home" \
      || echo "!! could not fully revert idle-lock config for $HOST_ACCOUNT — continuing"
    # Unconditional: install.state does not record whether sudo was granted, and
    # leaving a passwordless root rule behind for a deleted account is the worst
    # thing this uninstall could do.
    revoke_host_account_sudo "$HOST_ACCOUNT" \
      || echo "!! could not remove the sudo rule for $HOST_ACCOUNT — check /etc/sudoers.d/dreamconnect-$HOST_ACCOUNT by hand"
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
      # If the host account ever does hold the active session, detect_user
      # returns it and rail 3 would refuse to remove the very account this
      # feature exists to remove. Protecting an account from itself is
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
# --- backstage mode ---------------------------------------------------------
# Backstage runs the bridge against `gnome-shell --headless` under the lingering
# user manager: no monitor, no dummy plug, no login, no autologin. Resolved here,
# before anything is created, because it changes which unit the daemon hangs off
# and removes the GDM requirement below.
BACKSTAGE=0
BACKSTAGE_RES=""
# A named Wayland display keeps the backstage shell distinct from any real
# session the human may later log into on the same box.
BACKSTAGE_WAYLAND_DISPLAY="dreamconnect"
if [ "${DREAMCONNECT_BACKSTAGE:-}" = "1" ]; then
  BACKSTAGE=1
  BACKSTAGE_RES="$(backstage_resolution "${DREAMCONNECT_BACKSTAGE_RES:-}")" \
    || die "fix DREAMCONNECT_BACKSTAGE_RES and re-run"
  backstage_supported \
    || die "DREAMCONNECT_BACKSTAGE=1 but gnome-shell is not installed; backstage runs 'gnome-shell --headless' and cannot work without it"
  # The backstage shell runs in the HOME of whatever account it is installed
  # under, so pointing it at a human's account hands every operator that
  # person's files — and their app state, which is visible the moment the
  # desktop restores a session. A dedicated account is the isolated form.
  if [ -z "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
    echo "!! WARNING: backstage without DREAMCONNECT_HOST_ACCOUNT runs the headless desktop"
    echo "   in a human user's HOME — operators get that user's files and app state."
    echo "   For anything but a test box, isolate it:"
    echo "     DREAMCONNECT_BACKSTAGE=1 DREAMCONNECT_HOST_ACCOUNT=screenconnect ./install.sh"
  fi
fi

# A backstage session has no connector to name — Mutter conjures the monitor —
# and probing for one on a box with no session would just log a fallback.
if [ "$BACKSTAGE" -eq 1 ]; then
  MONITOR=""
else
  MONITOR="$(detect_monitor)"
fi

# --- resolve the identity the daemon and socket will run under --------------
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
# A display-host account never logs in, and autologin — the thing that used to
# log it in — is gone. Backstage is now the only way it can run a session at all,
# so the account implies it rather than requiring the operator to ask for both.
# Resolved here, after host_account_installable, so a bare re-run on a box that
# already records an account still gets backstage.
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ] && [ "$BACKSTAGE" -eq 0 ]; then
  echo ">> DREAMCONNECT_HOST_ACCOUNT implies backstage — the account never logs in"
  BACKSTAGE=1
  BACKSTAGE_RES="$(backstage_resolution "${DREAMCONNECT_BACKSTAGE_RES:-}")" \
    || die "fix DREAMCONNECT_BACKSTAGE_RES and re-run"
  backstage_supported \
    || die "a display-host account needs backstage, which runs 'gnome-shell --headless', but gnome-shell is not installed"
  MONITOR=""
fi
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
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
# later step (deps, build, deploy, linger, the daemon unit) is a chance to abort,
# and --uninstall can only revert what this file names.
if [ -n "${DREAMCONNECT_HOST_ACCOUNT:-}" ]; then
  write_install_state "$USER_NAME" "$USER_UID" "$HOST_WAS_CREATED"
fi

echo ">> desktop user : $USER_NAME (uid $USER_UID)"
echo ">> SC unit      : ${SC_UNIT:-<none found>}"
if [ "$BACKSTAGE" -eq 1 ]; then
  echo ">> capture      : backstage virtual monitor $BACKSTAGE_RES (no physical connector)"
else
  echo ">> capture mon  : $MONITOR"
fi
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

# Backstage pre-pins an admin toolset in the dash; install what the box lacks so
# those launchers work. Best-effort and Fedora-named (dnf) — on another distro
# the missing ones simply stay unpinned. Only the GUIs GNOME does not ship by
# default; the two custom terminal launchers need nothing extra.
BACKSTAGE_TOOLS=()
if [ "$BACKSTAGE" -eq 1 ] && [ "$PM" = "dnf" ]; then
  BACKSTAGE_TOOLS=(nautilus ptyxis gnome-disk-utility dconf-editor gnome-logs
                   gnome-system-monitor firewall-config gnome-text-editor)
fi

if [ "${DREAMCONNECT_SKIP_DEPS:-}" = "1" ]; then
  echo ">> skipping dependency install (DREAMCONNECT_SKIP_DEPS=1)"
elif [ -n "$PM" ]; then
  echo ">> installing dependencies via $PM"
  pm_install "${DEPS[@]}" >/dev/null 2>&1 \
    || echo "!! some dependencies failed via $PM; install manually: ${DEPS[*]}"
  if [ "${#BACKSTAGE_TOOLS[@]}" -gt 0 ]; then
    echo ">> installing the backstage admin toolset via $PM"
    pm_install "${BACKSTAGE_TOOLS[@]}" >/dev/null 2>&1 \
      || echo "!! some backstage tools failed via $PM; the dash will just skip the missing ones"
  fi
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
install -o root -g root -m 0755 "$HERE/runtime/dreamconnect-backstage-env.sh" "$INSTALL_DIR/runtime/"
install -o root -g root -m 0644 "$AGENT_JAR" "$INSTALL_DIR/dreamconnect-agent.jar"

# --- host fix: broken-:1 display skip wrapper -------------------------------
# ScreenConnect detects screen geometry with xdpyinfo/xrandr/xwininfo (installed
# above). On hosts whose Xwayland :1 hangs X probes, that freezes the session
# periodically, so we shadow those tools with a wrapper that fails :1 probes
# instantly and passes everything else through. See host-fixes/ for the why.
echo ">> installing broken-display skip wrapper"
install -m 0755 "$HERE/host-fixes/xprobe-skip-broken-display.sh" \
  /usr/local/bin/.dc-xprobe-wrapper
for t in xdpyinfo xrandr xwininfo xrdb xdotool; do ln -sf .dc-xprobe-wrapper "/usr/local/bin/$t"; done

# --- user daemon service ----------------------------------------------------
# One unit template serves both modes; what differs is the session the daemon
# hangs off and how it is told to capture.
#   classic   — a real logged-in session:   graphical-session.target, --monitor
#   backstage — our own headless shell:     dreamconnect-backstage.service, --virtual
# graphical-session.target is never reached by a spawned headless shell, so the
# backstage daemon must depend on the shell unit itself.
if [ "$BACKSTAGE" -eq 1 ]; then
  SESSION_UNIT="dreamconnect-backstage.service"
  DAEMON_ARGS="--virtual $BACKSTAGE_RES"
else
  SESSION_UNIT="graphical-session.target"
  DAEMON_ARGS="--monitor $MONITOR"
fi

# The frame is scoped by uid: /dev/shm is sticky, so a frame left behind by an
# install under a different account cannot be unlinked by this one — every write
# fails with EACCES and the operator sees a frozen desktop (#27). Hit for real
# when a box is switched to a display-host account.
SHM_PATH="/dev/shm/dreamconnect.frame.$USER_UID"
# Drop the legacy unscoped frame from a pre-uid-scoping install, so it doesn't
# sit in /dev/shm forever owned by whoever ran that install.
rm -f /dev/shm/dreamconnect.frame

echo ">> installing user service"
install -d -o "$USER_NAME" "$USER_HOME/.config/systemd/user"
sed -e "s#@INSTALL_DIR@#$INSTALL_DIR#g" \
    -e "s#@SESSION_UNIT@#$SESSION_UNIT#g" \
    -e "s#@SHM_PATH@#$SHM_PATH#g" \
    -e "s#@DAEMON_ARGS@#$DAEMON_ARGS#g" \
    "$HERE/systemd/dreamconnect-daemon.service" \
    > "$USER_HOME/.config/systemd/user/dreamconnect-daemon.service"
chown "$USER_NAME:" "$USER_HOME/.config/systemd/user/dreamconnect-daemon.service"

if [ "$BACKSTAGE" -eq 1 ]; then
  echo ">> installing backstage session unit (headless gnome-shell, ${BACKSTAGE_RES})"
  sed -e "s#@INSTALL_DIR@#$INSTALL_DIR#g" \
      -e "s#@WAYLAND_DISPLAY@#$BACKSTAGE_WAYLAND_DISPLAY#g" \
      "$HERE/systemd/dreamconnect-backstage.service" \
      > "$USER_HOME/.config/systemd/user/dreamconnect-backstage.service"
  chown "$USER_NAME:" "$USER_HOME/.config/systemd/user/dreamconnect-backstage.service"
fi

loginctl enable-linger "$USER_NAME"
# enable-linger starts user@$USER_UID.service in the background; the systemctl
# --user calls below need its bus to exist first (issue #24).
wait_for_user_bus "$USER_UID" \
  || die "the user bus for $USER_NAME (uid $USER_UID) never came up after 'loginctl enable-linger'; check 'systemctl status user@$USER_UID.service'"
"${RUN_USER[@]}" systemctl --user daemon-reload
# `enable --now` does nothing to an already-running unit, so a re-run would leave
# the previous ExecStart live — the new unit file on disk, the old daemon in
# memory. Enable for boot, then restart to actually apply this run's changes.
if [ "$BACKSTAGE" -eq 1 ]; then
  # The daemon is WantedBy the backstage unit, so starting the shell pulls the
  # daemon up with it — and does so again at every boot, with nobody logged in.
  "${RUN_USER[@]}" systemctl --user enable dreamconnect-daemon.service
  "${RUN_USER[@]}" systemctl --user enable dreamconnect-backstage.service
  "${RUN_USER[@]}" systemctl --user restart dreamconnect-backstage.service
else
  "${RUN_USER[@]}" systemctl --user enable dreamconnect-daemon.service
  "${RUN_USER[@]}" systemctl --user restart dreamconnect-daemon.service
fi

# --- ScreenConnect drop-in --------------------------------------------------
# Backstage sessions are named "[Backstage]" in the operator's picker (and the
# agent then hides every other display, so it is the only, first entry); a
# classic install keeps SC's own labelling.
if [ "$BACKSTAGE" -eq 1 ]; then
  # label: name the picker entry. logonttl: a backstage display never changes, so
  # cache SC's periodic display probe for 5 min instead of re-running its slow
  # runuser/xauth shell every ~6 s (which stalls input each time).
  AGENT_EXTRA=",label=[Backstage],logonttl=300"
else
  AGENT_EXTRA=""
fi
# Capture-loop tuning: lift ScreenConnect's fixed 50 ms / 20 fps frame-interval
# ceiling (see spikes/SPIKE_ENCODER_KNOBS.md). Measured on a 6-core box at 720p:
# 20.0 fps stock -> 62 fps at maxfps=60, for ~2% guest CPU. Backstage runs on
# dedicated hardware, so it defaults to 60 (a 60 Hz display shows no more anyway);
# a classic install stays stock so a human's machine is never pushed harder
# without asking. DREAMCONNECT_FPS overrides either way; 0 = stock (disable).
: "${DREAMCONNECT_FPS:=$([ "$BACKSTAGE" -eq 1 ] && echo 60 || echo 0)}"
case "$DREAMCONNECT_FPS" in
  ''|*[!0-9]*) die "DREAMCONNECT_FPS must be a non-negative integer, got '$DREAMCONNECT_FPS'" ;;
esac
if [ "$DREAMCONNECT_FPS" -gt 0 ]; then
  AGENT_EXTRA="$AGENT_EXTRA,maxfps=$DREAMCONNECT_FPS"
  echo ">> capture tuning: maxfps=$DREAMCONNECT_FPS (lifts SC's stock 20 fps ceiling)"
fi
if [ -n "$SC_UNIT" ]; then
  echo ">> installing agent drop-in on $SC_UNIT"
  install -d "/etc/systemd/system/$SC_UNIT.d"
  sed -e "s#@INSTALL_DIR@#$INSTALL_DIR#g" -e "s#@UID@#$USER_UID#g" \
      -e "s#@SHM_PATH@#$SHM_PATH#g" -e "s#@AGENT_EXTRA@#$AGENT_EXTRA#g" \
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
  if [ "${DREAMCONNECT_HOST_ACCOUNT_SUDO:-}" = "1" ]; then
    echo ">> granting passwordless sudo to $USER_NAME (DREAMCONNECT_HOST_ACCOUNT_SUDO=1)"
    if grant_host_account_sudo "$USER_NAME"; then
      echo "   SECURITY: anything running in the backstage desktop can become root without a password."
      echo "   ScreenConnect already has a root channel, so this adds a second path, not a first one."
    else
      # Not fatal: everything else is installed and working, and a box whose
      # backstage desktop merely lacks sudo is still a usable bridge.
      echo "!! could not grant sudo to $USER_NAME — the rest of the install succeeded; see the error above"
    fi
  fi
fi

# --- reboot survival ---------------------------------------------------------
# Backstage is how an unattended box survives a reboot: the lingering user
# manager brings the headless session (and the daemon with it) up at boot, with
# nobody logged in and the greeter untouched.
#
# GDM autologin used to be the answer here. It existed only to manufacture a
# graphical session so the bridge had something to attach to — never to make the
# login screen viewable, which Mutter forbids outright. Backstage creates that
# session directly, so the workaround, its GDM edit and its unlocked console are
# all gone. See git history if it ever needs resurrecting.
if [ "$BACKSTAGE" -eq 1 ]; then
  echo ">> backstage: the bridge comes up at boot from the lingering user manager."
  echo "   the greeter stays up and no session is ever auto-unlocked."
  echo
  echo "   NOTE: the backstage desktop is a PRIVATE session, not the console user's."
  echo "   To see what a logged-in user sees, install without DREAMCONNECT_BACKSTAGE=1"
  echo "   and have the user log in."
else
  echo "!! attended install: the bridge follows $USER_NAME's graphical session, so it"
  echo "   only runs while they are logged in and will NOT survive a reboot on its own."
  echo "   Re-run with DREAMCONNECT_BACKSTAGE=1 for an unattended box."
fi
