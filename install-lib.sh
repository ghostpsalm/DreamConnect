#!/usr/bin/env bash
#
# dreamconnect installer library: function definitions only.
#
# Sourced by install.sh (and by test_install.sh). Deliberately free of
# side effects — no `set`, no top-level statements — so it can be sourced
# before any environment is set up, and unit-tested without root.

die() { echo "error: $*" >&2; exit 1; }

# Run a command, or announce it when DC_DRY_RUN=1. Lets the destructive
# steps be exercised by the tests without touching the real system.
run() {
  if [ "${DC_DRY_RUN:-}" = "1" ]; then echo "DRY: $*"; else "$@"; fi
}

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

# Type (wayland/x11) of the desktop user's active graphical session.
user_session_type() {
  local sid uid name type active
  while read -r sid uid name _; do
    [ "$name" = "$USER_NAME" ] || continue
    type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
    active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)
    if { [ "$type" = "wayland" ] || [ "$type" = "x11" ]; } && [ "$active" = "yes" ]; then
      echo "$type"; return
    fi
  done < <(loginctl list-sessions --no-legend)
}

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

# --- package manager --------------------------------------------------------
detect_pm() {
  local pm
  for pm in apt-get dnf zypper pacman; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
  done
}

pm_install() {  # best-effort; non-zero on failure
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)     dnf install -y "$@" ;;
    zypper)  zypper --non-interactive install "$@" ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" ;;
    *)       return 1 ;;
  esac
}

# --- host identity ----------------------------------------------------------
# Is this a bare account name, and nothing else? A pure predicate: no output, no
# filesystem, no passwd lookup. A whitelist on purpose — a blacklist of "/" and
# ".." would still let through the next character nobody thought of.
#
# The shape is the portable-username one useradd(8) advises: a letter or
# underscore, then letters, digits, underscore or hyphen, at most 32 characters.
# Two concrete failures it closes, both found by a pass over slices 3-6a:
# an all-numeric name, because `getent passwd 1000` resolves by UID and would
# bind the whole install to whoever owns that uid; and a name carrying "/" or
# ".", because "./user" normalises to the same path as "user" and so walks
# straight past the reserved-name guards below, which compare the string.
valid_account_name() {  # name
  local name="${1:-}"
  [ -n "$name" ] || return 1
  [ "${#name}" -le 32 ] || return 1
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || return 1
  return 0
}

# Resolve the account the daemon runs as into one line: NAME UID HOME SOCKET.
# With no account requested (arg1 empty), the detected desktop user (arg2) stays
# the identity, which is today's behaviour. The uid is never guessed: an account
# that isn't in the passwd source is a hard error, because a fabricated uid would
# point the root JVM at a socket path nothing will ever bind.
#
# DC_PASSWD_DB, if set, is read as a passwd(5) file instead of getent passwd, so
# the tests can resolve accounts this machine does not have.
resolve_host_identity() {
  local name="${1:-}" entry uid home
  [ -n "$name" ] || name="${2:-}"
  [ -n "$name" ] || { echo "error: resolve_host_identity: no account and no fallback user" >&2; return 1; }
  if [ -n "${DC_PASSWD_DB:-}" ]; then
    entry="$(awk -F: -v n="$name" '$1 == n { print; exit }' "$DC_PASSWD_DB")"
  else
    entry="$(getent passwd "$name" || true)"
  fi
  [ -n "$entry" ] || { echo "error: no such account: $name" >&2; return 1; }
  uid="$(echo "$entry" | cut -d: -f3)"
  home="$(echo "$entry" | cut -d: -f6)"
  echo "$name $uid $home /run/user/$uid/dreamconnect.sock"
}

# One passwd(5) entry, matched on the whole name, printed verbatim (empty when
# there is no such account). Same convention resolve_host_identity uses:
# DC_PASSWD_DB, if set, is read as a passwd file instead of getent passwd.
passwd_entry() {
  local name="$1"
  if [ -n "${DC_PASSWD_DB:-}" ]; then
    awk -F: -v n="$name" '$1 == n { print; exit }' "$DC_PASSWD_DB"
  else
    getent passwd "$name" || true
  fi
}

# --- install state ----------------------------------------------------------
# What the installer actually did, so --uninstall reverts exactly that and no
# more. DC_STATE_FILE, if set, replaces the real path, so the tests can drive
# the state file and the removal gate without writing to /etc.
install_state_file() { echo "${DC_STATE_FILE:-/etc/dreamconnect/install.state}"; }

# Record the host identity, whether we created the account, and whether we set
# autologin. A full overwrite every time, never an append: two HOST_ACCOUNT
# lines would leave the reader picking one of them arbitrarily.
write_install_state() {  # name uid created_account autologin_set
  local f
  f="$(install_state_file)"
  mkdir -p "$(dirname "$f")"
  {
    echo "HOST_ACCOUNT=$1"
    echo "HOST_UID=$2"
    echo "CREATED_ACCOUNT=$3"
    echo "AUTOLOGIN_SET=$4"
  } > "$f"
}

# Set HOST_ACCOUNT/HOST_UID/CREATED_ACCOUNT/AUTOLOGIN_SET in the caller's scope.
# Parsed key by key and never sourced: this file decides whether userdel runs,
# and `. install.state` on a tampered or half-written file would execute
# whatever it contains. All four are reset on every call, so an absent or
# partial file cannot leave a previous read's account name behind for the gate.
read_install_state() {
  local f line key value
  f="$(install_state_file)"
  HOST_ACCOUNT=""; HOST_UID=""; CREATED_ACCOUNT=0; AUTOLOGIN_SET=0
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      HOST_ACCOUNT)    HOST_ACCOUNT="$value" ;;
      HOST_UID)        HOST_UID="$value" ;;
      CREATED_ACCOUNT) CREATED_ACCOUNT="$value" ;;
      AUTOLOGIN_SET)   AUTOLOGIN_SET="$value" ;;
    esac
  done < "$f"
}

# The rail that decides whether --uninstall may delete a Linux account. Exit 0
# only when all seven conditions hold; every refusal names the rail on stderr.
# Deliberately stricter than a uid>=1000 heuristic: it demands our GECOS marker
# AND our own state record, because the failure mode here is `userdel -r` on a
# human's home directory. The caller passes the account to protect in; this
# function detects nothing by itself.
host_account_removable() {  # name protected_user
  local name="${1:-}" protected="${2:-}" entry uid home gecos
  local marker="DreamConnect display host"
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT AUTOLOGIN_SET

  [ -n "$name" ] || { echo "refusing account removal: no account name given" >&2; return 1; }

  # Defence in depth: the other six rails can all be satisfied by a malformed
  # name — a passwd source really can hold an entry called "1000" or ".." — and
  # this gate is the last thing standing between a tampered install.state and
  # `userdel -r`.
  valid_account_name "$name" || {
    echo "refusing to remove $name: not a valid account name" >&2; return 1; }

  entry="$(passwd_entry "$name")"
  [ -n "$entry" ] || {
    echo "refusing to remove $name: no such account in the passwd source" >&2; return 1; }
  uid="$(echo "$entry" | cut -d: -f3)"
  gecos="$(echo "$entry" | cut -d: -f5)"
  home="$(echo "$entry" | cut -d: -f6)"

  [ "$uid" != "0" ] || { echo "refusing to remove $name: uid 0" >&2; return 1; }

  case "$home" in
    /|/home|/root) echo "refusing to remove $name: home directory is $home" >&2; return 1 ;;
  esac

  [ "$name" != "$protected" ] || {
    echo "refusing to remove $name: it is the desktop user" >&2; return 1; }

  if [ -n "${SUDO_USER:-}" ] && [ "$name" = "$SUDO_USER" ]; then
    echo "refusing to remove $name: it is the account that invoked sudo" >&2; return 1
  fi

  read_install_state
  [ "$HOST_ACCOUNT" = "$name" ] || {
    echo "refusing to remove $name: install state records host account '$HOST_ACCOUNT'" >&2; return 1; }
  [ "$CREATED_ACCOUNT" = "1" ] || {
    echo "refusing to remove $name: install state says the installer did not create it" >&2; return 1; }

  [ "$gecos" = "$marker" ] || {
    echo "refusing to remove $name: GECOS is not exactly '$marker'" >&2; return 1; }

  return 0
}

# --- the display-host account -----------------------------------------------
# Create the account when it is absent, and assert the greeter-hiding marker
# either way. An account that already exists is left alone — no useradd, no
# usermod: it may be a human's, and re-running install.sh must not disable their
# password or restamp their GECOS.
#
# Every write goes through run(), so DC_DRY_RUN=1 really does mean nothing on
# this machine changed. DC_ACCOUNTSSERVICE_DIR, if set, replaces the real
# /var/lib/AccountsService/users, so the tests can drive this without root.
#
# ACCOUNT_WAS_CREATED is set in the caller's scope on BOTH paths — the same
# convention read_install_state uses, and for the same reason: it becomes
# write_install_state's CREATED_ACCOUNT, which is rail 5 of the userdel gate, so
# a value left over from a previous call would decide the wrong thing.
ensure_host_account() {  # name
  local name="${1:-}" dir tmp conf

  # The create half runs useradd on this name, and the marker half pastes it into
  # a directory path, so "../victim" both makes an account nobody asked for and
  # installs over a file outside DC_ACCOUNTSSERVICE_DIR. Refuse before either —
  # the same guard remove_accountsservice_marker applies on the way back out.
  valid_account_name "$name" || {
    echo "error: refusing to create display-host account '$name': not a valid account name" >&2
    return 1; }

  dir="${DC_ACCOUNTSSERVICE_DIR:-/var/lib/AccountsService/users}"

  if [ -z "$(passwd_entry "$name")" ]; then
    # The comment is one argument: split, the GECOS becomes "DreamConnect" and
    # host_account_removable() would refuse to remove the account we created.
    run useradd --system --create-home --comment "DreamConnect display host" "$name"
    # -p '*' rather than passwd -l: non-interactive, no tty, and '*' means no
    # password can ever match rather than "! in front of whatever was there".
    run usermod -p '*' "$name"
    ACCOUNT_WAS_CREATED=1
  else
    ACCOUNT_WAS_CREATED=0
  fi

  # An account that already existed may already have an AccountsService file —
  # a human's Session/XSession/Language/Icon. The overwrite below is unavoidable
  # (SystemAccount=true is what hides the account), destroying it is not. Backed
  # up once, the same way and with the same suffix enable_autologin backs up the
  # GDM config: the .bak must hold what the account looked like before
  # dreamconnect ever touched it, so a re-run must never copy our own marker
  # over it.
  conf="$dir/$name"
  if [ -f "$conf" ] && [ ! -f "$conf.dreamconnect.bak" ]; then
    run cp -a "$conf" "$conf.dreamconnect.bak"
  fi

  # SystemAccount=true is what keeps the account out of the GDM user list.
  # Staged in a temp file so the write itself goes through run() too, and
  # installed as a full overwrite: a re-run leaves byte-identical content, never
  # a second [User] section for AccountsService to pick between.
  tmp="$(mktemp)"
  printf '[User]\nSystemAccount=true\n' > "$tmp"
  run install -D -m 0644 "$tmp" "$dir/$name"
  rm -f "$tmp"
}

# Undo: the AccountsService side of ensure_host_account, and nothing else.
# A backup means the account had a file before we clobbered it, and --uninstall
# owes it back rather than deleting it; no backup means we wrote the file from
# scratch and removing it leaves the box as it was. Neither present is the
# never-configured box, and a silent success.
remove_accountsservice_marker() {  # name
  local name="${1:-}" conf

  # conf below is built by pasting $name into a directory path, so "../victim"
  # reaches straight out of the AccountsService directory and the mv -f or rm -f
  # then overwrites or deletes a file that is none of this installer's business.
  # Same reasoning as remove_no_idle_lock, and sharper for the same reason: from
  # --uninstall this name comes off a state FILE. Refuse before either branch.
  valid_account_name "$name" || {
    echo "error: refusing to remove AccountsService marker for '$name': not a valid account name" >&2
    return 1; }

  conf="${DC_ACCOUNTSSERVICE_DIR:-/var/lib/AccountsService/users}/$name"

  if [ -f "$conf.dreamconnect.bak" ]; then
    run mv -f "$conf.dreamconnect.bak" "$conf"
  elif [ -f "$conf" ]; then
    run rm -f "$conf"
  fi
}

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

# --- no idle lock for the display-host account -------------------------------
# Locking a session makes Mutter close the active RemoteDesktop/ScreenCast
# session and refuse to recreate one while locked, so an unattended account that
# idle-locks makes itself unreachable. This gives the account its own dconf
# system db (never a shared one), points its session at that db, and skips the
# first-boot wizard nobody is present to click through.
#
# DC_DCONF_DIR, if set, replaces the real /etc/dconf, so the tests can drive
# this without root. Only `dconf update` goes through run(): the four file
# writes land in paths the caller already chose, and a dry run that skipped them
# would leave nothing to inspect.
configure_no_idle_lock() {  # name home
  local name="$1" home="$2" dir p

  # Blast radius. "user" is dconf's own default profile and "local" its
  # conventional system db: writing either would disable lock and idle for every
  # user on the box. Refuse before anything at all is created.
  case "$name" in
    user|local)
      echo "error: refusing to write dconf profile '$name': reserved name" >&2
      return 1 ;;
  esac

  # And the other half of that guard: the paths below are built by pasting
  # $name into them, so "./user" reaches exactly the files the case above
  # protects. A function this destructive validates its own argument rather than
  # trusting whatever install.sh checked at the entry point.
  valid_account_name "$name" || {
    echo "error: refusing to write dconf profile '$name': not a valid account name" >&2
    return 1; }

  dir="${DC_DCONF_DIR:-/etc/dconf}"
  mkdir -p "$dir/profile" "$dir/db/$name.d"

  # These two /etc/dconf files may already belong to the box: DREAMCONNECT_HOST_
  # ACCOUNT can name an account whose name was already used for a hand-rolled
  # profile or a policy db. Overwriting is unavoidable — the db is what disables
  # the idle lock — destroying is not. Each is backed up once, with the same
  # suffix and the same once-only rule as the two home files below, and
  # independently: a box may have one without the other.
  #
  # The keyfile's backup goes BESIDE <name>.d rather than inside it. dconf
  # compiles every regular file in a <name>.d directory as a keyfile fragment,
  # with no extension filtering, so a backup left in there would be compiled by
  # `dconf update` into live configuration — the very settings this function is
  # here to override. A backup that introduces a new bug is not a backup.
  if [ -f "$dir/profile/$name" ] && [ ! -f "$dir/profile/$name.dreamconnect.bak" ]; then
    cp -a "$dir/profile/$name" "$dir/profile/$name.dreamconnect.bak"
  fi
  if [ -f "$dir/db/$name.d/00-display-host" ] \
     && [ ! -f "$dir/db/$name.d.dreamconnect.bak" ]; then
    cp -a "$dir/db/$name.d/00-display-host" "$dir/db/$name.d.dreamconnect.bak"
  fi

  # user-db:user keeps the account's own dconf writes readable; system-db:<name>
  # is what makes the keyfile below apply. A full overwrite, like every other
  # file this installer owns.
  printf 'user-db:user\nsystem-db:%s\n' "$name" > "$dir/profile/$name"

  # lock-delay and idle-delay are "type u" in the installed GNOME schemas, hence
  # uint32; the sleep-inactive-*-type enums are strings. Suspending would be the
  # same unreachability the lock keys are here to prevent.
  cat > "$dir/db/$name.d/00-display-host" <<'EOF'
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
lock-delay=uint32 0

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
EOF

  # Without DCONF_PROFILE in the session's environment dconf loads its default
  # profile and the db above is inert.
  #
  # <home> may belong to a human whose session already has a DCONF_PROFILE
  # drop-in, or who has been through the first-boot wizard. Overwriting is
  # unavoidable, destroying is not: each file is backed up once to
  # <path>.dreamconnect.bak, the same way and with the same suffix
  # ensure_host_account backs up the AccountsService file, so a re-run never
  # copies our own content over the original. The two are independent files and
  # get independent backups. Not behind run(), like the writes they precede.
  mkdir -p "$home/.config/environment.d"
  for p in "$home/.config/environment.d/dconf-profile.conf" \
           "$home/.config/gnome-initial-setup-done"; do
    if [ -f "$p" ] && [ ! -f "$p.dreamconnect.bak" ]; then
      cp -a "$p" "$p.dreamconnect.bak"
    fi
  done
  printf 'DCONF_PROFILE=%s\n' "$name" > "$home/.config/environment.d/dconf-profile.conf"
  printf 'yes\n' > "$home/.config/gnome-initial-setup-done"

  # Same `chown "<name>:" <path>` form install.sh already uses after installing
  # the user unit into a home directory as root. Best effort: nothing here
  # enforces that ensure_host_account ran first, and losing the configuration
  # over an ownership fixup would trade a working unattended session for a
  # cosmetic detail. The /etc/dconf files are left root-owned.
  for p in "$home/.config" "$home/.config/environment.d" \
           "$home/.config/environment.d/dconf-profile.conf" \
           "$home/.config/gnome-initial-setup-done"; do
    chown "$name:" "$p" || echo "warning: could not chown $p to $name" >&2
  done

  run dconf update
}

# Undo: everything configure_no_idle_lock wrote, and nothing else. --uninstall
# also runs on boxes where the opt-in was never used, so every removal tolerates
# an absent file. The environment.d directory itself is never deleted — it may
# hold drop-ins that are none of our business — but the <name>.d db directory is,
# once our keyfile is out of it and it is empty.
remove_no_idle_lock() {  # name home
  local name="$1" home="$2" dir p

  # The removal side of configure_no_idle_lock's blast-radius guard, and the
  # sharper half of it: from --uninstall this name comes off a state FILE, so a
  # tampered or truncated install.state saying HOST_ACCOUNT=user would delete
  # dconf's own default profile, and HOST_ACCOUNT=local the shared system db.
  case "$name" in
    user|local)
      echo "error: refusing to remove dconf profile '$name': reserved name" >&2
      return 1 ;;
  esac

  # Same reasoning as the write side, and sharper again: "./user" would delete
  # the very files the case above protects, and ".." makes `rm -f
  # "$dir/profile/.."` fail and wedge the uninstall before it ever reaches
  # account deletion. Refuse before any rm, rmdir or dconf update.
  valid_account_name "$name" || {
    echo "error: refusing to remove dconf profile '$name': not a valid account name" >&2
    return 1; }

  dir="${DC_DCONF_DIR:-/etc/dconf}"

  # The two /etc/dconf files, each on its own and the same three ways round as
  # remove_accountsservice_marker: a backup means the box had that file before
  # configure_no_idle_lock clobbered it and --uninstall owes it back; no backup
  # means we wrote it and removing it leaves /etc/dconf as it was; neither is the
  # never-configured box, and `rm -f` is already silent about it.
  if [ -f "$dir/profile/$name.dreamconnect.bak" ]; then
    mv -f "$dir/profile/$name.dreamconnect.bak" "$dir/profile/$name"
  else
    rm -f "$dir/profile/$name"
  fi

  # The keyfile's backup lives outside <name>.d, so restoring it is a move back
  # IN — and it has to happen while that directory is still there, or the mv
  # would create a plain FILE named <name>.d where a directory belongs. Hence
  # before the rmdir, and with a mkdir -p for the box whose db directory went
  # missing between install and uninstall. A restored keyfile leaves the
  # directory non-empty, so the rmdir below then fails harmlessly and the box
  # keeps its db; a keyfile that was ours leaves it empty and it goes, as today.
  if [ -f "$dir/db/$name.d.dreamconnect.bak" ]; then
    mkdir -p "$dir/db/$name.d"
    mv -f "$dir/db/$name.d.dreamconnect.bak" "$dir/db/$name.d/00-display-host"
  else
    rm -f "$dir/db/$name.d/00-display-host"
  fi
  rmdir "$dir/db/$name.d" 2>/dev/null || true

  # The two files inside <home>, each on its own: a backup means the account had
  # that file before configure_no_idle_lock clobbered it and --uninstall owes it
  # back; no backup means we wrote it from scratch and removing it leaves the
  # home as it was; neither is the never-configured box. Same three ways round as
  # remove_accountsservice_marker.
  for p in "$home/.config/environment.d/dconf-profile.conf" \
           "$home/.config/gnome-initial-setup-done"; do
    if [ -f "$p.dreamconnect.bak" ]; then
      mv -f "$p.dreamconnect.bak" "$p"
    elif [ -f "$p" ]; then
      rm -f "$p"
    fi
  done

  run dconf update
}

# --- removing the display-host account ---------------------------------------
# The only place in this installer that runs `userdel -r`, so it never decides
# for itself: host_account_removable() is asked first, and a refusal means
# nothing destructive is attempted at all — not even a loginctl call.
#
# Order matters. Linger has to go before the user is terminated, or systemd
# brings the account's manager straight back up; the user has to be terminated
# before userdel, or a still-running session holds its files open.
uninstall_host_account() {  # name protected_user
  local name="$1" protected="${2:-}"

  host_account_removable "$name" "$protected" || return 1

  # disable-linger legitimately fails when linger was never enabled — a fresh
  # install that stopped part-way, or a box where the opt-in was never used.
  # Refusing to delete the account over it would leak exactly the account this
  # function exists to remove.
  run loginctl disable-linger "$name" || true
  # terminate-user legitimately fails when the account has no session — the
  # normal case on a box rebooted since install, and no reason to abandon the
  # deletion.
  run loginctl terminate-user "$name" || true
  # userdel IS the deletion: its status is ours, so a failed removal is never
  # reported to the caller as a completed one. No `return 0` after it.
  run userdel -r "$name"
}
