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

  # Deliberately NOT the two rails the account-creating functions here use. In
  # classic mode this name is the machine's existing desktop user, resolved out
  # of the passwd source and never created by us: on an AD-joined box it is
  # routinely `john.doe`, it can run past 32 characters, and `user`/`local` are
  # dconf PROFILE reservations that mean nothing to a file classic mode never
  # touches. Rejecting those would abort the install after everything else has
  # already run. What is left is root — the one account this must never log in
  # automatically — and the two ways a name pasted verbatim into the [daemon]
  # section below can corrupt the file rather than merely name the wrong
  # account: empty, or carrying a newline/CR that splits AutomaticLogin= into a
  # second key. A backslash goes the same way one step later: `awk -v` processes
  # C escapes in the value, so `DOMAIN\nick` — the winbind domain separator, two
  # ordinary characters no newline rail can see — becomes a real newline inside
  # awk. Refused before the backup, so a refusal leaves no .bak either.
  case "$user" in
    root)
      echo "error: refusing to set GDM autologin for 'root'" >&2
      return 1 ;;
    "")
      echo "error: refusing to set GDM autologin: empty account name" >&2
      return 1 ;;
    *$'\n'*|*$'\r'*)
      echo "error: refusing to set GDM autologin: account name contains a newline" >&2
      return 1 ;;
    *\\*)
      echo "error: refusing to set GDM autologin: account name contains a backslash" >&2
      return 1 ;;
  esac

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

# Undo: put back whatever autologin the backup's [daemon] section held, in place
# of the keys we set there. Leaves the rest intact — a surgical strip and
# reinsert rather than a wholesale restore from our backup, because custom.conf
# is shared with the admin and unrelated edits made since install must survive
# the revert.
#
# Reinsert, not simply strip, because enable_autologin's own strip drops ANY
# AutomaticLogin* key in [daemon] before writing ours: on a box where the admin
# had already configured autologin for one of their accounts, stripping ours out
# to nothing loses theirs, and the backup we delete below is the last copy of it.
#
# Returns the status of the strip itself (the awk pass and its write-back), not
# of the scratch-file cleanup, so a caller can tell a reverted config from an
# untouched one. On success the backup enable_autologin took has no further use
# and is removed, so nothing of ours is left beside custom.conf; on failure the
# keys are still live and that backup is the operator's only copy of the
# pre-install config, so it stays (issue #22).
disable_autologin() {
  local conf="$1" bak="$1.dreamconnect.bak" tmp rc=0 bak_exists=0
  [ -e "$bak" ] && bak_exists=1
  tmp="$(mktemp)"
  # awk opens the backup itself rather than taking its lines through -v, which
  # would run C escape expansion over content we do not control. The lines it
  # collects are the same set enable_autologin's strip ate — live or commented —
  # and they go back verbatim, at the head of [daemon] where GDM reads them. A
  # backup whose [daemon] section had none (or no backup at all) restores none,
  # which is the strip this function has always done.
  #
  # getline answers -1 for both "no such file" and "there is a file but it could
  # not be read", and those two are opposites here: the first is the ordinary
  # no-backup case above, the second means the only copy of the pre-install
  # autologin is sitting there unread. So the shell's own existence check
  # separates them, and a read failure over a backup that DOES exist fails
  # closed — exit non-zero before the write-back, leaving the live keys and the
  # backup exactly where they are, the same way a failed strip does (issue #22).
  awk -v bak="$bak" -v bak_exists="$bak_exists" '
    BEGIN {
      n = 0
      while ((r = (getline line < bak)) > 0) {
        if (line ~ /^\[.*\]$/) { in_bak_daemon = (line == "[daemon]"); continue }
        if (in_bak_daemon && line ~ /^[[:space:]]*#?[[:space:]]*AutomaticLogin(Enable)?[[:space:]]*=/) saved[++n] = line
      }
      close(bak)
      if (r < 0 && bak_exists == "1") {
        print "error: cannot read " bak > "/dev/stderr"
        failed = 1
        exit 1
      }
    }
    /^\[.*\]$/ {
      in_daemon = ($0 == "[daemon]"); print
      if (in_daemon) { for (i = 1; i <= n; i++) print saved[i]; done = 1 }
      next
    }
    # The same pattern the collect pass above matches, `#?` included: a commented
    # hint this function itself restored on an earlier call has to be recognised
    # as ours to strip, or the fresh collection reprints it beside the old copy
    # and every repeated revert grows [daemon] by one more.
    { if (in_daemon && $0 ~ /^[[:space:]]*#?[[:space:]]*AutomaticLogin(Enable)?[[:space:]]*=/) next; print }
    END { if (!failed && !done && n) { print ""; print "[daemon]"; for (i = 1; i <= n; i++) print saved[i] } }
  ' "$conf" > "$tmp" && cat "$tmp" > "$conf" || rc=$?
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return "$rc"
  # The revert has happened by here, so a backup we cannot unlink is not a
  # failure of it: the cleanup's status stays out of the return value.
  rm -f "$bak"
  return 0
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
  # [A-Za-z] is a locale-dependent RANGE, not an ASCII set: under an en_US.utf8
  # LC_CTYPE this box accepts "é" as a letter and under C it does not, so the
  # same name would be valid or invalid depending on the operator's environment.
  # LC_ALL is one of the variables bash re-reads on assignment, `local` included,
  # and it is restored when the function returns — so the match below is ASCII
  # whatever the caller's locale, and nothing else in the run is affected.
  local LC_ALL=C
  local name="${1:-}"
  [ -n "$name" ] || return 1
  [ "${#name}" -le 32 ] || return 1
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || return 1
  return 0
}

# Is this a home directory it is safe to paste into `rm -f "$home/.config/..."`,
# `install -d "$home/..."` and `chown <name>: "$home/.config"` as root? A pure
# predicate beside valid_account_name, and the same kind: no output, no
# filesystem, no passwd lookup. A blacklist rather than a whitelist because
# unlike a username a home directory is a path, and the legitimate ones range
# from /var/lib/dreamconnect-host to a human's /home/john.doe.
#
# Each rail is one call site's failure. Empty is the literal trigger: an account
# deleted by hand makes `passwd_entry | cut -d: -f6` yield "", and every path
# above collapses onto root's own /.config/... . Relative is corrupt passwd data
# that would resolve against root's CWD — the checkout install.sh was run from.
# And "/", "/home" and "/root" are the set host_account_removable was refusing
# as a home directory before this predicate existed; that rail now calls here,
# so the two cannot drift apart.
valid_home_dir() {  # path
  local home="${1:-}" p
  [ -n "$home" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  # The reserved three are a PATH, not a spelling. A trailing slash, a run of
  # slashes and a "." component are all no-ops on the resolved path — POSIX
  # 4.13 — so /root/, //root, /root/. and /./root all name /root, and a literal
  # compare against the four ways a passwd file or an operator writes it misses
  # every one. Normalised with parameter expansion alone: no realpath, no
  # readlink, no stat, because this stays a pure predicate over a path that need
  # not exist yet.
  p="$home/"                                                      # bracket the tail
  while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done   # collapse slash runs
  while [ "$p" != "${p//\/.\//\/}" ]; do p="${p//\/.\//\/}"; done # drop "." components
  [ "$p" = "/" ] || p="${p%/}"                                    # strip the trailing slash
  case "$p" in /|/home|/root) return 1 ;; esac
  # A ".." COMPONENT, not the substring: bracketing the path in slashes makes
  # every component delimited, so /var/lib/x/.. is caught while the ordinary
  # directory name /var/lib/dc..host stays valid. Against the RAW path, and
  # deliberately not normalised away above: a home that traverses is unsafe
  # whatever it resolves to, so /root/../etc is a refusal here rather than an
  # accepted /etc.
  case "/$home/" in */../*) return 1 ;; esac
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
  # The home is validated HERE, while it is still a variable. Once it is pasted
  # into the line below its boundaries are gone: an empty field 6 leaves a double
  # space, the caller's `read -r name uid home _` collapses it, and the socket
  # path lands in the home. So a caller gets a complete identity or nothing (a
  # home containing whitespace still shifts the caller's read — known gap, out
  # of scope for this fix).
  valid_home_dir "$home" || {
    echo "error: account $name: unusable home directory: '$home'" >&2; return 1; }
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
  local f dir tmp created="$3"
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT AUTOLOGIN_SET
  # CREATED_ACCOUNT is sticky once true, per account name: a bare re-run finds
  # the account already there, recomputes 0, and would otherwise erase the fact
  # that we created it — permanently disarming host_account_removable's rail 5,
  # so --uninstall could never remove it again. A record naming a DIFFERENT
  # account carries nothing over, and only this flag is sticky: the rest is
  # always this run's arguments.
  read_install_state
  if [ "$HOST_ACCOUNT" = "$1" ] && [ "$CREATED_ACCOUNT" = "1" ]; then
    created=1
  fi
  f="$(install_state_file)"
  dir="$(dirname "$f")"
  mkdir -p "$dir"
  # Staged beside the target and renamed over it, never `> "$f"` directly: a
  # redirect truncates first, so a write cut short (ENOSPC, power loss, a kill)
  # would leave an empty file, which read_install_state reports as "nothing
  # recorded" and --uninstall then declines to remove the account we created.
  # The temp file shares the directory so the mv is a rename(2) on one
  # filesystem, i.e. atomic: readers see the old content or the new, never half.
  tmp="$(mktemp "$dir/install.state.XXXXXX")"
  {
    echo "HOST_ACCOUNT=$1"
    echo "HOST_UID=$2"
    echo "CREATED_ACCOUNT=$created"
    echo "AUTOLOGIN_SET=$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
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

  # A name rail, not a uid rail. The uid-0 and /root-home checks below refuse the
  # genuine root entry, but a passwd source is DATA: an entry named "root" with a
  # non-zero uid, a home outside /root, our GECOS marker and a matching state
  # record satisfies every one of them, and `userdel -r root` follows.
  case "$name" in
    root|user|local)
      echo "refusing to remove $name: reserved account name (root/user/local)" >&2; return 1 ;;
  esac

  entry="$(passwd_entry "$name")"
  [ -n "$entry" ] || {
    echo "refusing to remove $name: no such account in the passwd source" >&2; return 1; }
  uid="$(echo "$entry" | cut -d: -f3)"
  gecos="$(echo "$entry" | cut -d: -f5)"
  home="$(echo "$entry" | cut -d: -f6)"

  [ "$uid" != "0" ] || { echo "refusing to remove $name: uid 0" >&2; return 1; }

  # The same predicate the write side uses, not a second copy of its literals:
  # this rail refused "/", "/home" and "/root" spelled exactly, and `userdel -r`
  # is the one caller for which /root/, //root and /./root are just as fatal.
  # valid_home_dir's other rails only strengthen it — an empty or relative field
  # 6 is corrupt passwd data, and `userdel -r` on it is not an improvement.
  valid_home_dir "$home" || {
    echo "refusing to remove $name: home directory is $home" >&2; return 1; }

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

# One display-host account per box. install.state has a single slot, and
# --uninstall can only revert the dconf profile/db, linger and AccountsService
# marker of the account that slot names — so a second run under a different
# account would strand the first one's artefacts for good. Answers, for one run:
# may it proceed, and under which account.
#
# Same convention resolve_host_identity uses — the resolution on stdout, the
# complaint on stderr, non-zero only on a refusal — because install.sh has no
# harness of its own. Nothing is ever written here: a refusal has to leave
# install.state naming the account --uninstall still has to reach.
host_account_installable() {  # requested_or_empty
  local requested="${1:-}"
  local HOST_ACCOUNT

  # install.sh refuses these at its entry point too, but that script has no
  # harness of its own and the fresh-box path below otherwise echoes the
  # REQUESTED name straight back unvalidated — so a reserved name survives the
  # whole resolution and reaches useradd, an AccountsService path, a dconf
  # profile and GDM autologin. root is not a dconf name, it is the account every
  # other rail in this file exists to protect.
  case "$requested" in
    root|user|local)
      echo "error: refusing to install under requested display-host account '$requested': reserved name (root/user/local)" >&2
      return 1 ;;
  esac

  read_install_state

  # Fresh box (or an install that never used a host account): anything goes,
  # including the empty request that means "run as the desktop user".
  [ -n "$HOST_ACCOUNT" ] || { echo "$requested"; return 0; }

  # Both adoption paths below hand the RECORDED name back for the whole run to
  # use — install.sh reassigns DREAMCONNECT_HOST_ACCOUNT from this stdout, long
  # after its own entry-point guards ran against the original env var. So the
  # name off the state file gets those same two guards here, the same way
  # host_account_removable re-validates the record before `userdel -r`: a
  # tampered or legacy install.state otherwise reaches useradd, an
  # AccountsService path and a dconf profile unchecked. Reserved first, then the
  # shape, the order install.sh and configure_no_idle_lock already use.
  if [ -z "$requested" ] || [ "$requested" = "$HOST_ACCOUNT" ]; then
    case "$HOST_ACCOUNT" in
      root|user|local)
        echo "error: refusing to continue under recorded display-host account '$HOST_ACCOUNT': reserved name (root/user/local)" >&2
        return 1 ;;
    esac
    valid_account_name "$HOST_ACCOUNT" || {
      echo "error: refusing to continue under recorded display-host account '$HOST_ACCOUNT': not a valid account name" >&2
      return 1; }
  fi

  # A bare re-run must keep working, and must keep working against the account
  # already installed — silently falling back to the desktop user would strand
  # the very same artefacts.
  if [ -z "$requested" ]; then
    echo "warning: install state records display-host account '$HOST_ACCOUNT'; continuing under it" >&2
    echo "$HOST_ACCOUNT"
    return 0
  fi

  [ "$requested" = "$HOST_ACCOUNT" ] || {
    echo "error: refusing to install under '$requested': install state records display-host account '$HOST_ACCOUNT'; run ./install.sh --uninstall first" >&2
    return 1; }

  echo "$requested"
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

  # root is in every passwd source, so the create half is skipped and the marker
  # half stamps SystemAccount=true onto .../AccountsService/users/root, hiding
  # root from the greeter; user and local reach this function long before
  # configure_no_idle_lock's own guard would see them, with the account already
  # created by then. Reserved first, then the shape, the order install.sh and
  # configure_no_idle_lock already use.
  case "$name" in
    root|user|local)
      echo "error: refusing to create display-host account '$name': reserved name (root/user/local)" >&2
      return 1 ;;
  esac

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

  # The removal side of ensure_host_account's reserved-name guard, and sharper
  # for the usual reason: from --uninstall this name comes off a state FILE, so
  # HOST_ACCOUNT=root makes the restore branch overwrite root's own
  # AccountsService file and the remove branch delete it.
  case "$name" in
    root|user|local)
      echo "error: refusing to remove AccountsService marker for '$name': reserved name (root/user/local)" >&2
      return 1 ;;
  esac

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

# --- the user bus -----------------------------------------------------------
# `loginctl enable-linger` starts user@<uid>.service ASYNCHRONOUSLY, so the very
# next `systemctl --user` can run before /run/user/<uid>/bus exists and dies with
# "Failed to connect to user scope bus via local transport" — which install.sh's
# set -e turns into an aborted install on a first run. So wait for the socket.
#
# `-S`, not `-e`: what systemctl needs is something to connect to, and a leftover
# regular file at that path satisfies existence while still failing the connect.
#
# DC_RUNTIME_DIR_ROOT and DC_BUS_POLL_INTERVAL exist so the tests can drive this
# without root and without sitting out a real timeout.

# `-S` proves the path is a socket INODE, not that anyone is listening on it:
# AF_UNIX does not unlink the inode when the listener dies, so a crashed
# user@<uid>.service leaves a bus that passes `-S` forever and refuses every
# connect — precisely the failure this wait exists to prevent. So attempt a real
# connect. python3 is already installed by the time install.sh reaches the
# user-service section. A refusal is not an error here, only "not up yet".
bus_socket_is_live() {  # path
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except OSError:          # ConnectionRefusedError included: the bus is not up yet
    sys.exit(1)
finally:
    s.close()            # close, never unlink: the inode is not ours to remove
' "$1" 2>/dev/null
}

wait_for_user_bus() {  # uid [timeout_seconds]
  local uid="${1:-}" timeout="${2:-30}" interval="${DC_BUS_POLL_INTERVAL:-0.2}"
  local bus deadline

  # timeout_seconds is input, and a bad one must be refused in this function's
  # own voice rather than reaching the arithmetic below, where a non-numeric
  # value aborts the shell under `set -u` and an absurd one overflows the
  # millisecond deadline into an unbounded wait. The length check comes first
  # for the same reason: a digit string too long for 64 bits would wrap inside
  # the comparison meant to catch it. 86400s is a day — a per-boot startup race
  # that has not resolved by then is not going to.
  #
  # `0|[1-9][0-9]*`, not `[0-9]+`: `$(( ))` reads a leading zero as OCTAL, so
  # "08" aborts the whole expansion with "value too great for base" — an error
  # that is not a `return`, so the caller's `|| die` never runs and the install
  # walks on into the race this wait exists to prevent — while "010" is legal
  # octal and would quietly wait 8s. Both are ambiguous to whoever typed them,
  # so refuse rather than guess a base. Plain "0" stays valid: wait not at all.
  if ! [[ "$timeout" =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#timeout}" -gt 5 ] || [ "$timeout" -gt 86400 ]; then
    echo "error: wait_for_user_bus: timeout_seconds '$timeout' is not a whole" \
         "number of seconds in 0..86400" >&2
    return 1
  fi

  # A dry run never starts a user manager, so waiting for its bus could only
  # spend the whole timeout on its way to a failure that means nothing.
  [ "${DC_DRY_RUN:-}" = "1" ] && return 0

  bus="${DC_RUNTIME_DIR_ROOT:-/run/user}/$uid/bus"
  # Milliseconds, because the poll interval is a fraction of a second and a
  # whole-second deadline could expire a few ms after the wait began.
  deadline=$(( $(date +%s%3N) + timeout * 1000 ))
  while :; do
    [ -S "$bus" ] && bus_socket_is_live "$bus" && return 0
    [ "$(date +%s%3N)" -lt "$deadline" ] || break
    sleep "$interval"
  done
  echo "error: timed out after ${timeout}s waiting for the user bus of uid $uid ($bus);" \
       "is user@$uid.service running?" >&2
  return 1
}

# --- the user manager, on the way down ---------------------------------------
# The mirror of wait_for_user_bus, for --uninstall. `loginctl terminate-user` is
# ASYNCHRONOUS the same way enable-linger is: it signals systemd and returns
# while the account's processes and its user@<uid>.service are still exiting, so
# the `userdel -r` that follows can race a live process, fail with "user X is
# currently used by process N", and leave the account, its home and a stale
# compiled dconf db behind. So wait for the manager to actually be down.
#
# DC_MANAGER_POLL_INTERVAL (falling back to DC_BUS_POLL_INTERVAL) exists so the
# tests can drive this without sitting out a real timeout.
wait_for_user_manager_down() {  # uid [timeout_seconds]
  local uid="${1:-}" timeout="${2:-30}"
  local interval="${DC_MANAGER_POLL_INTERVAL:-${DC_BUS_POLL_INTERVAL:-0.2}}"
  local state deadline

  # A blank or non-numeric uid makes "user@$uid.service" a syntactically
  # invalid unit name. Real systemd prints NOTHING on stdout for that — unlike
  # a well-formed-but-nonexistent uid, which correctly reports "inactive" on
  # the first poll — so the `inactive|failed` case below never matches and the
  # poll burns the full timeout instead of failing fast. Refused here, in this
  # function's own voice, BEFORE the dry-run short-circuit: `--uninstall
  # --dry-run` against a corrupted install.state exists precisely so the
  # operator finds out before the real run, not after it has silently skipped
  # userdel.
  if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
    echo "error: wait_for_user_manager_down: uid '$uid' is not a numeric uid" >&2
    return 1
  fi

  # The same guard, for the same reasons, as wait_for_user_bus above: a bad
  # timeout_seconds is refused in this function's own voice BEFORE it can reach
  # the arithmetic, where a non-numeric value aborts the shell under `set -u`
  # (skipping the caller's `||` entirely), a leading zero is read as octal, and
  # an absurd value overflows the millisecond deadline into an unbounded wait.
  if ! [[ "$timeout" =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#timeout}" -gt 5 ] || [ "$timeout" -gt 86400 ]; then
    echo "error: wait_for_user_manager_down: timeout_seconds '$timeout' is not a whole" \
         "number of seconds in 0..86400" >&2
    return 1
  fi

  # A dry run terminates nobody, so the manager never goes anywhere and waiting
  # for it could only burn the whole timeout on its way to a meaningless failure.
  [ "${DC_DRY_RUN:-}" = "1" ] && return 0

  deadline=$(( $(date +%s%3N) + timeout * 1000 ))
  while :; do
    # The STATE STRING on stdout, never the exit status. `systemctl is-active`
    # answers "deactivating" — a unit part-way through stopping, MainPID still
    # alive, holding exactly the files userdel -r is about to remove — with the
    # SAME exit 3 as the genuinely stopped "inactive", and reports a unit that
    # does not exist at all as "inactive" with exit 4. Reading "any non-zero
    # exit" as down would therefore return the instant terminate-user began the
    # shutdown and reopen the race this wait exists to close.
    state="$(systemctl is-active "user@$uid.service" 2>/dev/null)" || true
    case "$state" in
      inactive|failed) return 0 ;;
    esac
    [ "$(date +%s%3N)" -lt "$deadline" ] || break
    sleep "$interval"
  done
  echo "error: timed out after ${timeout}s waiting for user@$uid.service to stop;" \
       "its last reported state was '$state'" >&2
  return 1
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
  # user on the box. "root" is the same rail by name rather than by file — the
  # home writes and the chown below land in /root. Refuse before anything at all
  # is created.
  case "$name" in
    root|user|local)
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

  # And <home>, which nothing upstream validates either: it is pasted into the
  # mkdir, the two writes and the chown below. This is the WRITE side, running
  # during install with an operator present, so it refuses outright rather than
  # skipping — files laid down under a bad home path are artefacts --uninstall
  # can never find again. Before anything at all is created.
  valid_home_dir "$home" || {
    echo "error: refusing to configure dconf profile '$name': unusable home directory '$home'" >&2
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

# The drop-in configure_no_idle_lock writes into <home>/.config/environment.d is
# only ever read by `systemd --user` AT MANAGER START, and install.sh starts that
# manager (`loginctl enable-linger`) before it writes the file — so on a fresh
# install the value is correct on disk and absent from the live session, which is
# issue #26. Push it into the already-running manager as well, from the account's
# own session, using the same sudo/env form install.sh builds RUN_USER from.
push_dconf_environment() {  # name uid
  local name="$1" uid="$2"

  # The same blast radius as configure_no_idle_lock, for the same reason and
  # before anything is invoked at all: DCONF_PROFILE=user points a live session
  # at dconf's own default profile, "local" at its conventional system db, and
  # "root" is the account every rail here exists to protect.
  case "$name" in
    root|user|local)
      echo "error: refusing to push DCONF_PROFILE='$name': reserved name" >&2
      return 1 ;;
  esac

  # And the other half of that guard: the name is pasted both into the variable
  # value and into the account sudo switches to, so "./user" reaches exactly what
  # the case above protects.
  valid_account_name "$name" || {
    echo "error: refusing to push DCONF_PROFILE='$name': not a valid account name" >&2
    return 1; }

  run sudo -u "$name" env "XDG_RUNTIME_DIR=/run/user/$uid" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
      systemctl --user set-environment "DCONF_PROFILE=$name"
}

# The inverse of the push, and the half --uninstall was missing: remove_no_idle_lock
# deletes /etc/dconf/profile/<name>, and for a reused pre-existing account the
# manager holding DCONF_PROFILE=<name> is never stopped (install.sh gates that on
# CREATED_ACCOUNT=1) — so it is left naming a profile that no longer exists, which
# drops dconf to its null configuration and costs that account every gsettings read
# and write until it logs out. Cleared from the live manager the same way it was
# pushed, from the account's own session.
unpush_dconf_environment() {  # name uid
  local name="$1" uid="$2"

  # Same guard as the push, and before anything is invoked: on this side the name
  # comes off install.state, a file, so a tampered record is what arrives here —
  # `sudo -u root systemctl --user ...` against root's own manager is exactly the
  # blast radius the reserved case exists to stop.
  case "$name" in
    root|user|local)
      echo "error: refusing to unset DCONF_PROFILE for '$name': reserved name" >&2
      return 1 ;;
  esac

  valid_account_name "$name" || {
    echo "error: refusing to unset DCONF_PROFILE for '$name': not a valid account name" >&2
    return 1; }

  # The BARE variable name, per systemctl(1): "If only a variable name is
  # specified, it will be removed regardless of its value." The value-qualified
  # form would leave the variable behind whenever the manager holds a
  # DCONF_PROFILE this run did not push, while the profile file is deleted
  # unconditionally either way.
  run sudo -u "$name" env "XDG_RUNTIME_DIR=/run/user/$uid" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
      systemctl --user unset-environment DCONF_PROFILE
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
  # dconf's own default profile, HOST_ACCOUNT=local the shared system db, and
  # HOST_ACCOUNT=root root's own profile and the files under /root.
  case "$name" in
    root|user|local)
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
  # dconf update compiles <name>.d/ into a binary db/<name> beside it, but never
  # deletes that binary once its source directory is gone — so an outright
  # removal above (the rmdir here actually succeeding) orphans it forever. Gated
  # on rmdir's own exit status, not merely "no backup was present": a restored
  # backup leaves the directory non-empty and the rmdir fails/never applies, and
  # a foreign fragment left behind by something else does too — both cases the
  # compiled db is still wanted and must be left alone.
  if rmdir "$dir/db/$name.d" 2>/dev/null; then
    rm -f "$dir/db/$name"
  fi

  # The two files inside <home>, each on its own: a backup means the account had
  # that file before configure_no_idle_lock clobbered it and --uninstall owes it
  # back; no backup means we wrote it from scratch and removing it leaves the
  # home as it was; neither is the never-configured box. Same three ways round as
  # remove_accountsservice_marker.
  #
  # Unless <home> is unusable — from --uninstall it comes off a state file, and
  # an account deleted by hand leaves passwd field 6 empty, which would point
  # both paths at root's own /.config. Only this half is skipped: the /etc/dconf
  # revert above is independent of <home> and is what --uninstall would otherwise
  # strand, so the function warns and still succeeds. There is nothing left in an
  # unusable home to have failed to revert.
  if valid_home_dir "$home"; then
    for p in "$home/.config/environment.d/dconf-profile.conf" \
             "$home/.config/gnome-initial-setup-done"; do
      if [ -f "$p.dreamconnect.bak" ]; then
        mv -f "$p.dreamconnect.bak" "$p"
      elif [ -f "$p" ]; then
        rm -f "$p"
      fi
    done
  else
    echo "warning: skipping the home half of the idle-lock revert for '$name': unusable home directory '$home'" >&2
  fi

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
uninstall_host_account() {  # name protected_user uid
  local name="$1" protected="${2:-}" uid="${3:-}"

  # The account issue #21 is about: removed outside this tool before --uninstall
  # ever ran. host_account_removable would refuse it — correctly, for a caller
  # that does not already know — and the refusal would keep install.state alive
  # naming an account no retry can ever delete, which host_account_installable
  # then reads as "one host account already exists" forever. Nothing to remove IS
  # removed, so this caller answers it here: exit 0, having run none of the three
  # commands below, all of which are meaningless on an account that is not there.
  # A name that is EMPTY is not this case — it names no account to be absent —
  # and falls through to the refusal it has always had.
  if [ -n "$name" ] && [ -z "$(passwd_entry "$name")" ]; then
    echo "note: display-host account '$name' is already gone from the passwd source; nothing to remove" >&2
    return 0
  fi

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
  # terminate-user is asynchronous: it signals systemd and returns while the
  # account's user@<uid>.service manager (and the processes it holds open) is
  # still on its way down. Racing userdel -r against that is issue #25 itself,
  # so wait for the manager to actually be down before attempting it. A
  # timeout here is NOT fatal to the caller in the die/exit sense — install.sh
  # runs under `set -euo pipefail` and still has state-file bookkeeping to do
  # after this call — but userdel IS the deletion, so a wedged manager must
  # skip it and report the failure through this function's own return, same
  # as any other failed removal.
  wait_for_user_manager_down "$uid" || return 1
  # userdel IS the deletion: its status is ours, so a failed removal is never
  # reported to the caller as a completed one. No `return 0` after it.
  run userdel -r "$name"
}
