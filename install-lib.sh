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
  local sid uid name type active class
  while read -r sid uid name _; do
    class=$(loginctl show-session "$sid" -p Class --value 2>/dev/null || true)
    # The GDM greeter is a real, active, Wayland session (uid 60578, gnome-shell
    # --mode=gdm), so "active and graphical" matches it. It is never the desktop
    # user: returning it would install the daemon into the display manager's
    # account, and make an uninstall silently revert nothing. Backstage boxes sit
    # at the greeter permanently, so this is the normal state there, not an edge
    # case. Class is logind's own answer to "what kind of session is this".
    case "$class" in
      greeter|lock-screen) continue ;;
    esac
    type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
    active=$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)
    if { [ "$type" = "wayland" ] || [ "$type" = "x11" ]; } && [ "$active" = "yes" ]; then
      echo "$name"; return
    fi
  done < <(loginctl list-sessions --no-legend)
  die "could not detect a graphical session user; set DREAMCONNECT_USER="
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
# The lookup goes through passwd_entry, which is the one place that knows how to
# tell an absent account from a lookup that failed (and which honours
# DC_PASSWD_DB, so the tests can resolve accounts this machine does not have).
resolve_host_identity() {
  local name="${1:-}" entry uid home rc=0
  [ -n "$name" ] || name="${2:-}"
  [ -n "$name" ] || { echo "error: resolve_host_identity: no account and no fallback user" >&2; return 1; }
  # `|| rc=$?` and not a bare assignment: install.sh runs this library under
  # `set -euo pipefail`, where a non-zero command substitution in an assignment
  # kills the caller outright — same exit status as a refusal, but without the
  # message that says which account and why.
  entry="$(passwd_entry "$name")" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "error: no such account: $name" >&2; return 1 ;;
    # A failed lookup is not an absence, and the uid is exactly what must not be
    # guessed here: a fabricated one points the root JVM at a socket path nothing
    # will ever bind.
    *) echo "error: cannot resolve account $name: the passwd lookup failed" >&2; return 1 ;;
  esac
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

# One passwd(5) entry, matched on the whole name, printed verbatim, and a status
# that says which of three things happened:
#
#   0  found — the entry is on stdout
#   1  absent — the passwd source answered and there is no such account; empty
#      stdout and nothing on stderr, because absence is an answer, not an error
#   2  the lookup itself FAILED — a broken NSS module, a down LDAP/SSSD backend,
#      no getent at all; empty stdout and a stderr line naming the account
#
# The third status is issue #30. This function used to answer with stdout alone,
# so "not there" and "could not tell" were the same empty string and every caller
# read both as absence: uninstall_host_account reported a live account as already
# gone and install.sh then deleted install.state, and ensure_host_account ran
# useradd over an account that may well already exist.
#
# getent's exit 2 is the ambiguity itself — it is both its documented "key not
# found" and what a backend that answered nothing returns — so it is classified
# by a second lookup of a key every usable passwd source must hold. root
# answering means the source is alive and this account really is gone; root not
# answering means nothing was established. The probe is deliberately NOT `getent
# -s files`, and deliberately not a read of /etc/passwd: the display-host account
# can be one the installer adopted rather than created (CREATED_ACCOUNT=0) and so
# can live in LDAP or SSSD, and corroborating against the local file would report
# it absent while userdel still refuses to remove it — issue #30 inverted.
#
# Residual hole, not closable through getent: SSSD down while `files` is healthy
# leaves the root probe answering, so an LDAP host account still classifies as
# absent. Narrowing it needs a per-source answer getent does not expose, and the
# only local alternative is the /etc/passwd read ruled out above.
#
# DC_PASSWD_DB, if set, is read as a passwd file instead of getent passwd (a test
# fixture only, never a production path) and answers on the same three-way scale.
passwd_entry() {
  local name="$1" entry rc=0
  if [ -n "${DC_PASSWD_DB:-}" ]; then
    # Readability is checked ahead of awk rather than read off its status: awk's
    # own fatal message names the FILE, and a caller refusing a removal has to be
    # able to say which account's lookup it was that failed.
    [ -r "$DC_PASSWD_DB" ] || {
      echo "error: passwd lookup for $name failed: cannot read $DC_PASSWD_DB" >&2; return 2; }
    entry="$(awk -F: -v n="$name" '$1 == n { print; exit }' "$DC_PASSWD_DB")" || {
      echo "error: passwd lookup for $name failed: could not read $DC_PASSWD_DB" >&2; return 2; }
    [ -n "$entry" ] || return 1
    printf '%s\n' "$entry"
    return 0
  fi
  # getent's stderr is left alone: on a genuinely degraded box its one line names
  # the backend that failed, which is the whole diagnosis. The probe's is not —
  # it is an internal classification step, and its noise would read as a second,
  # unrelated failure.
  entry="$(getent passwd "$name")" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$entry" ]; then
    printf '%s\n' "$entry"
    return 0
  fi
  # Only exit 2 can mean absence. Every other status (1, 3, 126/127, a signal)
  # and a success with no output are states getent does not use for a key it
  # looked up and did not find, so none of them establish that the account is
  # gone.
  if [ "$rc" -eq 2 ] && getent passwd root >/dev/null 2>&1; then
    return 1
  fi
  echo "error: passwd lookup for $name failed: the passwd source did not answer" >&2
  return 2
}

# --- install state ----------------------------------------------------------
# What the installer actually did, so --uninstall reverts exactly that and no
# more. DC_STATE_FILE, if set, replaces the real path, so the tests can drive
# the state file and the removal gate without writing to /etc.
install_state_file() { echo "${DC_STATE_FILE:-/etc/dreamconnect/install.state}"; }

# write_install_state stages its write as install.state.XXXXXX beside the real
# file, then mv's it into place (below). A crash/power-loss/SIGKILL/SIGXFSZ
# between mktemp and mv leaves that named temp file behind, and nothing else
# ever names it again to clean it up: a later write mints a fresh random
# suffix, and read_install_state only ever opens the literal install.state
# path (#34). Harmless clutter — never read by name — but it accumulates
# under the state directory across repeated interrupted runs, so both
# write_install_state and uninstall() sweep it: the glob is anchored to
# install_state_file()'s own path with mktemp's fixed 6-`?` suffix, so it can
# never match the real file (which has no suffix) or anything unrelated.
sweep_stale_install_state_tmp() {
  local f dir stale
  f="$(install_state_file)"
  dir="$(dirname "$f")"
  [ -d "$dir" ] || return 0
  for stale in "$f".??????; do
    [ -e "$stale" ] || continue
    rm -f "$stale"
  done
}

# Record the host identity and whether we created the account. A full overwrite
# every time, never an append: two HOST_ACCOUNT lines would leave the reader
# picking one of them arbitrarily.
write_install_state() {  # name uid created_account
  local f dir tmp created="$3"
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT
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
  sweep_stale_install_state_tmp
  tmp="$(mktemp "$dir/install.state.XXXXXX")"
  {
    echo "HOST_ACCOUNT=$1"
    echo "HOST_UID=$2"
    echo "CREATED_ACCOUNT=$created"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}

# Set HOST_ACCOUNT/HOST_UID/CREATED_ACCOUNT in the caller's scope. Parsed key by
# key and never sourced: this file decides whether userdel runs, and
# `. install.state` on a tampered or half-written file would execute whatever it
# contains. All three are reset on every call, so an absent or partial file
# cannot leave a previous read's account name behind for the gate. Unknown keys
# are ignored, which is what lets a state file written before autologin was
# removed (it carried AUTOLOGIN_SET) still parse.
read_install_state() {
  local f line key value
  f="$(install_state_file)"
  HOST_ACCOUNT=""; HOST_UID=""; CREATED_ACCOUNT=0
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; value="${line#*=}"
    # A state file written or edited on Windows carries CR, and a hand-edited one
    # carries whatever spacing the operator typed — which would ride along into
    # an account name, a uid, and the picker label derived from it. Both ends of
    # BOTH halves are trimmed: padding on the key ("HOST_ACCOUNT = dchost")
    # matches no case arm below, so the whole record would read as "nothing
    # recorded" and host_account_installable would take the fresh-box branch on a
    # box that already has a host account.
    #
    # [:space:] covers CR, so this subsumes the old `%$'\r'` strip. It is done
    # with the ends-only expansions rather than `tr -d '[:space:]'` because inner
    # whitespace is data, not padding: a recorded "dc host" must stay distinct
    # from "dchost" for the refusal message to be worth reading. A value that is
    # only whitespace trims to empty, which every consumer already treats as
    # unset — the right reading, since " " is not an account.
    key="${key#"${key%%[![:space:]]*}"}";       key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      HOST_ACCOUNT)    HOST_ACCOUNT="$value" ;;
      HOST_UID)        HOST_UID="$value" ;;
      CREATED_ACCOUNT) CREATED_ACCOUNT="$value" ;;
    esac
  done < "$f"
}

# --- the installer lock -------------------------------------------------------
# One display-host account per box is decided by READING install.state and then
# WRITING it, with `useradd` in between (install.sh: host_account_installable ->
# ensure_host_account -> write_install_state). Nothing serialises that span, so
# two concurrent installs naming different accounts both read "nothing recorded",
# both pass the one-account guard, both create an account, and the last writer
# takes the single slot — leaving the loser's account on the box with no record
# naming it, which is exactly the shape no later --uninstall can reach (#32).
#
# Beside install.state rather than under /run or /tmp: the tests' existing
# DC_STATE_FILE override moves the lock with the file it guards, with no second
# environment variable to forget, and uninstall()'s own `rm -rf /run/dreamconnect`
# can then never unlink a lock a concurrent run is holding.
install_lock_file() { echo "$(dirname "$(install_state_file)")/install.lock"; }

# Take the installer lock for the rest of this process, or refuse. $1 names the
# operation, and appears in the refusal.
#
# Never blocks. install.sh demands root, so a second concurrent run is an
# operator mistake rather than a queue; waiting would hang a root session with no
# output, behind a timeout nobody has chosen.
#
# `exec {fd}>` plus `flock -n <fd>` rather than `flock <file> <command>`: the lock
# must span a sequence of statements in THIS shell, and the command form could
# only manage that by re-entering the whole installer as a child. A `mkdir` or
# `O_EXCL` lock file was rejected for the opposite reason — the kernel drops an
# flock when the holder dies, so a killed or crashed install leaves nothing stale
# behind for the next operator to clear by hand.
#
# The descriptor is NOT close-on-exec (bash's {var}> redirections are inherited
# across exec, verified on bash 5.3), so a process started inside the critical
# section keeps the lock alive for as long as it lives. Both call sites hold the
# lock only across short-lived children — useradd, getent, systemctl clients —
# and nothing that daemonises; keep it that way when either span moves.
acquire_install_lock() {  # what
  local what="${1:-operation}" lock dir

  # Already ours. flock conflicts between open file DESCRIPTIONS, including two
  # in the same process, so a second acquire would open a second description,
  # fail against our own lock and report a concurrent run that does not exist.
  # Keyed on the variable and not on a pid because a subshell inherits the
  # descriptor, and so genuinely does inherit the lock along with it.
  #
  # The claim is CHECKED, not believed, and the variable is outside the `DC_*`
  # fixture-override namespace. `DC_INSTALL_LOCK_FD=9 ./install.sh` used to make
  # this return 0 having taken no lock at all: an environment variable could
  # switch off the safety rail this whole slice exists to be. Sourcing this file
  # must stay free of side effects, so the inherited value is not scrubbed at
  # load — instead the descriptor it names has to really be open, in this
  # process, on this lock file, before the lock is treated as held.
  if [ -n "${_dc_install_lock_fd:-}" ] \
     && [ -e "/proc/$$/fd/${_dc_install_lock_fd}" ] \
     && [ "/proc/$$/fd/${_dc_install_lock_fd}" -ef "$(install_lock_file)" ]; then
    return 0
  fi
  _dc_install_lock_fd=""

  command -v flock >/dev/null 2>&1 || {
    echo "error: cannot serialise the $what: flock is not installed (it ships in util-linux)" >&2
    echo "       refusing rather than running unlocked — a concurrent run would strand an account that no --uninstall could then find" >&2
    return 1; }

  lock="$(install_lock_file)"
  dir="$(dirname "$lock")"
  mkdir -p "$dir" || {
    echo "error: cannot serialise the $what: could not create $dir to hold the lock file" >&2
    return 1; }

  # A failed open leaves the variable unset (bash assigns it only on success) and
  # returns 1 rather than killing the shell, so there is no stale descriptor
  # number for release_install_lock to close by mistake.
  exec {_dc_install_lock_fd}>"$lock" || {
    echo "error: cannot serialise the $what: could not open the lock file $lock" >&2
    return 1; }

  flock -n "$_dc_install_lock_fd" || {
    exec {_dc_install_lock_fd}>&-
    _dc_install_lock_fd=""
    echo "error: refusing to $what: another dreamconnect install or uninstall is already running on this box and holds the lock $lock" >&2
    echo "       nothing has been changed; wait for that run to finish, then re-run" >&2
    return 1; }

  return 0
}

# Drop the lock by closing the descriptor that holds it — the kernel releases an
# flock with the last close of its open file description. Silent and exit 0 when
# nothing is held, so a path that refuses before acquiring can still call it.
release_install_lock() {
  [ -n "${_dc_install_lock_fd:-}" ] || return 0
  exec {_dc_install_lock_fd}>&-
  _dc_install_lock_fd=""
}

# The rail that decides whether --uninstall may delete a Linux account. Exit 0
# only when all seven conditions hold; every refusal names the rail on stderr.
# Deliberately stricter than a uid>=1000 heuristic: it demands our GECOS marker
# AND our own state record, because the failure mode here is `userdel -r` on a
# human's home directory. The caller passes the account to protect in; this
# function detects nothing by itself.
host_account_removable() {  # name protected_user
  local name="${1:-}" protected="${2:-}" entry uid home gecos rc=0
  local marker="DreamConnect display host"
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT

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

  # Guarded for the reason resolve_host_identity spells out: this library runs
  # under `set -euo pipefail`, and a rail that dies instead of refusing gives its
  # caller the same status with none of the words.
  entry="$(passwd_entry "$name")" || rc=$?
  case "$rc" in
    0) ;;
    1) echo "refusing to remove $name: no such account in the passwd source" >&2; return 1 ;;
    # Distinct from absence on purpose. Every rail below reads a field of $entry,
    # and there is no entry: a lookup that failed has not established that this
    # account is gone, and `userdel -r` is not a thing to attempt on a guess.
    *) echo "refusing to remove $name: the passwd lookup failed, so whether it exists is unknown" >&2
       return 1 ;;
  esac
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
  # Both names through %q, for the reason spelled out at the installable
  # mismatch below: this is the other refusal that juxtaposes two names, and a
  # recorded one that differs only by inner whitespace reads as the given one.
  [ "$HOST_ACCOUNT" = "$name" ] || {
    printf "refusing to remove %q: install state records host account '%q'\n" \
      "$name" "$HOST_ACCOUNT" >&2; return 1; }
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
  # profile. root is not a dconf name, it is the account every
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

  # The one message that prints two names side by side, and read_install_state
  # only trims the ENDS of a recorded value — inner whitespace is data and
  # survives on purpose. So a hand-edited or Windows-edited state file can make
  # this refusal name "dchost" and "dc host", which a terminal renders as the
  # same string, and the operator cannot tell a mistyped account from a padded
  # state file. %q makes the difference visible ("dc\ host"). ${var@Q} was ruled
  # out: it only quotes ('dc host'), which the literal quotes here already did,
  # so it reveals nothing. A name without whitespace passes through %q
  # unchanged, so the ordinary refusal reads exactly as it did.
  [ "$requested" = "$HOST_ACCOUNT" ] || {
    printf "error: refusing to install under '%q': install state records display-host account '%q'; run ./install.sh --uninstall first\n" \
      "$requested" "$HOST_ACCOUNT" >&2
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
  local name="${1:-}" dir tmp conf rc=0

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

  # A lookup that FAILED is not "no such account", and the difference decides
  # whether useradd runs: on a box whose NSS or SSSD is down, creating over an
  # account that may already be there is a create attempt against someone else's
  # identity, and the usermod that follows would disable a password that is not
  # ours. Nothing is written until the source has actually answered.
  passwd_entry "$name" >/dev/null || rc=$?
  [ "$rc" -ne 2 ] || {
    echo "error: refusing to create display-host account '$name': the passwd lookup failed, so it may already exist" >&2
    return 1; }

  if [ "$rc" -eq 1 ]; then
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
  # up once, with the .dreamconnect.bak suffix the installer uses everywhere: the
  # .bak must hold what the account looked like before dreamconnect ever touched
  # it, so a re-run must never copy our own marker over it.
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
# connect. A refusal is not an error here, only "not up yet".
#
# The status is python3's, passed through untouched, and the caller reads all
# three cases: 0 connected · 1 refused · anything else the probe never ran (no
# python3, or one that cannot start). Do not collapse those into a boolean —
# DREAMCONNECT_SKIP_DEPS=1 and an unrecognised package manager both leave a host
# without python3, and the third case is the only thing that distinguishes it
# from a bus that is genuinely slow to appear.
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
  local bus deadline probe

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
    if [ -S "$bus" ]; then
      # `probe=0; ... || probe=$?`, not `bus_socket_is_live; probe=$?`: install.sh
      # runs under `set -e`, where the unguarded call aborts the whole install on
      # the refusal that just means "not up yet", before $? can be read at all.
      probe=0; bus_socket_is_live "$bus" || probe=$?
      case "$probe" in
        0) return 0 ;;
        1) ;;  # connect refused: the user manager is still starting, keep polling
        # Anything else is the probe failing to RUN — 127 when python3 is absent
        # from PATH or the interpreter itself cannot load, 126 when it is there
        # but not executable. Waiting cannot fix that, and the timeout message
        # below would blame user@<uid>.service for a bus that may be listening
        # perfectly well, so stop here and say what actually broke. Split on the
        # STATUS rather than a `command -v python3` pre-check: a python3 that is
        # on PATH and exits 127 for its own reasons is the same dead end, and a
        # presence check waves it through into the full timeout.
        *) echo "error: cannot verify the user bus of uid $uid ($bus): the python3" \
                "connect probe exited $probe without running. Install python3, or" \
                "re-run without DREAMCONNECT_SKIP_DEPS=1 so it gets installed;" \
                "the bus itself was not tested." >&2
           return 1 ;;
      esac
    fi
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

# --- backstage (headless) session --------------------------------------------
# Backstage runs the bridge against a gnome-shell started with --headless, so no
# monitor, no dummy plug and no login are needed. The resolution is not a
# preference there: a RecordVirtual stream has no intrinsic size, so whatever is
# requested here IS the session's screen size, and an unvalidated value reaches
# Mutter and the shm frame allocator directly. Echoes the normalised WxH.
backstage_resolution() {  # [value] -> WxH on stdout, non-zero if unusable
  local value lower w h
  value="${1:-}"
  # 1280x720 by default: a virtual monitor has no native size, so the resolution
  # is purely a bandwidth/latency knob, and a headless admin desktop does not
  # need 1080p — 720p is ~2.6x fewer pixels for ScreenConnect to encode and ship
  # each frame, the difference between a responsive session and a sticky one.
  # Not lower: below 720p GNOME's overview stops scaling the dash and window
  # thumbnails down cleanly, so they overlap and the dash becomes hard to click.
  # Override with DREAMCONNECT_BACKSTAGE_RES for a larger workspace.
  [ -n "$value" ] || value="1280x720"
  lower="${value//X/x}"
  case "$lower" in
    *[!0-9x]*)
      echo "error: DREAMCONNECT_BACKSTAGE_RES must be WxH (e.g. 1920x1080), got '$value'" >&2
      return 1 ;;
  esac
  w="${lower%%x*}"; h="${lower##*x}"
  # Round-tripping the split back to the input is what pins "exactly one 'x'":
  # it rejects '1920' (no separator), '1920x1080x1', 'x1080' and '1920x' alike.
  if [ -z "$w" ] || [ -z "$h" ] || [ "${w}x${h}" != "$lower" ]; then
    echo "error: DREAMCONNECT_BACKSTAGE_RES must be WxH (e.g. 1920x1080), got '$value'" >&2
    return 1
  fi
  # Strip leading zeros so 08 isn't read as octal by the arithmetic below.
  w=$((10#$w)); h=$((10#$h))
  if [ "$w" -lt 1 ] || [ "$h" -lt 1 ]; then
    echo "error: backstage resolution must be positive, got '$value'" >&2
    return 1
  fi
  # Same 16384 ceiling the daemon enforces (MAX_DIMENSION): every frame is
  # copied into shm at w*h*4 bytes, so a typo must not be allocated.
  if [ "$w" -gt 16384 ] || [ "$h" -gt 16384 ]; then
    echo "error: backstage resolution exceeds 16384px per side: '$value'" >&2
    return 1
  fi
  echo "${w}x${h}"
}

# Refuse backstage on a box with no gnome-shell: the unit would crash-loop
# forever and the failure would only show up as "no capture" much later.
backstage_supported() {  # -> 0 if a headless gnome-shell can be started
  command -v gnome-shell >/dev/null 2>&1
}

# --- sudo for the display-host account ---------------------------------------
# Opt-in (DREAMCONNECT_HOST_ACCOUNT_SUDO=1). The account is created with password
# '*', so a rule without NOPASSWD is inert: sudo would prompt into a session with
# no tty and there is no password that could ever satisfy it.
#
# Nothing is installed until visudo has validated it. A drop-in that fails to
# parse makes sudo refuse to run *for every user on the box* — locking the owner
# out of their own machine is a far worse outcome than the grant failing.
sudoers_file() {  # name -> path, non-zero if the name is unusable
  local name="${1:-}" dir
  # The name is pasted into a path here and into a sudo rule below, so both the
  # traversal and the rule-injection risks are refused at the same gate.
  valid_account_name "$name" || {
    echo "error: refusing a sudo rule for '$name': not a valid account name" >&2
    return 1; }
  dir="${DC_SUDOERS_DIR:-/etc/sudoers.d}"
  # sudo silently ignores drop-ins whose name contains a dot; valid_account_name
  # already excludes dots, and the prefix adds none.
  echo "$dir/dreamconnect-$name"
}

grant_host_account_sudo() {  # name
  local name="${1:-}" file tmp main
  file="$(sudoers_file "$name")" || return 1
  main="${DC_SUDOERS_MAIN:-/etc/sudoers}"

  # A drop-in in a directory sudo never reads is worse than no drop-in: it looks
  # configured and does nothing. Warn rather than refuse — the directive spelling
  # varies (#includedir / @includedir) and a missing one may be deliberate.
  if [ -f "$main" ] && ! grep -qE '^[[:space:]]*[#@]includedir[[:space:]]' "$main"; then
    echo "!! $main has no '#includedir' directive for sudoers.d — the rule below will be inert until one is added" >&2
  fi

  tmp="$(mktemp)" || return 1
  printf '# Installed by dreamconnect. Removed by install.sh --uninstall.\n' > "$tmp"
  printf '# NOPASSWD is required: this account has no password (usermod -p "*").\n' >> "$tmp"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$name" >> "$tmp"

  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "error: refusing to install a sudo rule for '$name': visudo rejected it" >&2
    return 1
  fi

  # 0440 is what sudo requires; it refuses drop-ins that others can write.
  # Ownership follows the installing process, which is root — install.sh refuses
  # to run as anything else — so no explicit -o/-g is needed, and leaving them
  # off keeps this callable (and testable) without root.
  run install -m 0440 "$tmp" "$file"
  rm -f "$tmp"
}

revoke_host_account_sudo() {  # name
  local file
  file="$(sudoers_file "$1")" || return 1
  # Absent is success: uninstall calls this unconditionally, since the install
  # state file does not record whether sudo was ever granted.
  run rm -f "$file"
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
  # The desktop half of the keyfile pre-pins the dash with a Windows-style admin
  # toolset for an operator arriving over ScreenConnect, in a fixed order (see
  # the launcher list below for the Windows-tool -> Linux-app mapping). This is
  # stock GNOME otherwise — no window-list/taskbar extension — so the dash shows
  # in the Activities overview exactly as vanilla GNOME does. Missing apps are
  # silently skipped by the shell, so pinning one a minimal box lacks is harmless.
  # These are defaults, not locks: the account can still change them.
  #
  # Animations are OFF: over a remote session every animated frame (an overview
  # transition is ~0.3 s of full-screen change at the session frame rate) is
  # captured, encoded and shipped for zero information, and it is exactly what
  # makes the app switcher "chug" on a CPU-contended box. Measured: disabling
  # them roughly halves the shell + capture CPU during an app switch and makes
  # the transition instant. Eye-candy is a poor trade on a headless admin desktop.
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

[org/gnome/desktop/interface]
enable-animations=false

[org/gnome/shell]
favorite-apps=['org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'org.gnome.DiskUtility.desktop', 'ca.desrt.dconf-editor.desktop', 'org.gnome.Logs.desktop', 'dreamconnect-services.desktop', 'org.gnome.SystemMonitor.desktop', 'dreamconnect-sysinfo.desktop', 'firewall-config.desktop', 'org.gnome.TextEditor.desktop']
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

  # Two admin tools the dash pins that GNOME ships no GUI for: a services list
  # and a system-information dump. They open in the session's terminal
  # (Terminal=true, so no terminal binary is hardcoded) and drop to a shell so
  # the operator can act on what they see. Written into the account's own
  # applications dir, so they are removed with the home directory on uninstall.
  mkdir -p "$home/.local/share/applications"
  cat > "$home/.local/share/applications/dreamconnect-services.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=System Services
Comment=systemd service units (Windows "Services" equivalent)
Icon=applications-system
Exec=sh -c 'systemctl list-units --type=service --all --no-pager; echo; exec ${SHELL:-bash}'
Terminal=true
Categories=System;
EOF
  cat > "$home/.local/share/applications/dreamconnect-sysinfo.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=System Information
Comment=Host, CPU, memory and disk summary (Windows "System Information" equivalent)
Icon=computer
Exec=sh -c 'hostnamectl; echo; lscpu | head -n 25; echo; free -h; echo; df -h -x tmpfs -x devtmpfs; echo; exec ${SHELL:-bash}'
Terminal=true
Categories=System;
EOF

  # Same `chown "<name>:" <path>` form install.sh already uses after installing
  # the user unit into a home directory as root. Best effort: nothing here
  # enforces that ensure_host_account ran first, and losing the configuration
  # over an ownership fixup would trade a working unattended session for a
  # cosmetic detail. The /etc/dconf files are left root-owned.
  for p in "$home/.config" "$home/.config/environment.d" \
           "$home/.config/environment.d/dconf-profile.conf" \
           "$home/.config/gnome-initial-setup-done" \
           "$home/.local" "$home/.local/share" "$home/.local/share/applications" \
           "$home/.local/share/applications/dreamconnect-services.desktop" \
           "$home/.local/share/applications/dreamconnect-sysinfo.desktop"; do
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
    # Our own dash launchers — never a pre-existing file, so always just removed.
    # Matters for an adopted account (userdel -r never runs on it); for an account
    # we created they go with the home anyway.
    rm -f "$home/.local/share/applications/dreamconnect-services.desktop" \
          "$home/.local/share/applications/dreamconnect-sysinfo.desktop"
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
  local name="$1" protected="${2:-}" uid="${3:-}" rc=0

  # The account issue #21 is about: removed outside this tool before --uninstall
  # ever ran. host_account_removable would refuse it — correctly, for a caller
  # that does not already know — and the refusal would keep install.state alive
  # naming an account no retry can ever delete, which host_account_installable
  # then reads as "one host account already exists" forever. Nothing to remove IS
  # removed, so this caller answers it here: exit 0, having run none of the three
  # commands below, all of which are meaningless on an account that is not there.
  # A name that is EMPTY is not this case — it names no account to be absent —
  # and falls through to the refusal it has always had.
  #
  # The STATUS decides it, never the emptiness of stdout. This short-circuit used
  # to read `[ -z "$(passwd_entry "$name")" ]`, and a command substitution throws
  # the status away: "no such account" and "the lookup could not be performed"
  # arrive as the same empty string, so a box with a broken NSS module or a down
  # LDAP/SSSD backend took the exit-0 path for an account that is still there
  # (issue #30). install.sh clears install.state only on our 0, so that answer
  # orphaned a live account — linger and markers still set — with no record left
  # to retry the removal from.
  if [ -n "$name" ]; then
    passwd_entry "$name" >/dev/null || rc=$?
    case "$rc" in
      1)
        echo "note: display-host account '$name' is already gone from the passwd source; nothing to remove" >&2
        return 0 ;;
      # Not a refusal by host_account_removable's rails and not an absence: the
      # question was never answered. Nothing destructive is attempted, and the
      # non-zero status is what keeps install.state alive for a retry once the
      # passwd source is healthy again. passwd_entry has already named the
      # account and the failure on stderr; this line says what it cost.
      2)
        echo "refusing to remove '$name': the passwd lookup failed, so whether the account is still there was never established; leaving the install state in place to retry" >&2
        return 1 ;;
    esac
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

# --- session registry writers -------------------------------------------------
#
# The agent reads /run/dreamconnect/sessions/<uid> to learn which sessions exist
# and how to reach each one (docs/specs/multi-session-picker.md, Solution 1).
# It is deliberately strict about what it will trust, and these writers exist to
# satisfy that exactly:
#
#   * the filename must be the bare uid — anything else (a .tmp or .bak left
#     beside it) is not an entry, and two entries for one display refuse it;
#   * neither the directory nor the file may be group- or other-writable, since
#     whoever can rewrite an entry can name any session;
#   * `key=value` per line with no escape syntax — so a value carrying a newline
#     could smuggle a second key, and is refused rather than escaped.
#
# Root ownership is inherited rather than asserted: only root runs these, and
# the test suite never does. That half is verified by review and a live run.

# A uid is digits and nothing else. This is also what stops
# `remove_registry_entry` being handed `../victim` and deleting, as root,
# outside the registry.
is_uid() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# render_registry_entry uid user display shm socket [label] -> entry text
# Refuses — non-zero, nothing on stdout — rather than emit an entry the reader
# would reject, or one carrying a value nobody meant to write.
render_registry_entry() {
  local uid="$1" user="$2" display="$3" shm="$4" socket="$5" label="${6:-}" v
  is_uid "$uid" || return 1
  for v in "$user" "$display" "$shm" "$socket"; do
    [ -n "$v" ] || return 1
    case "$v" in *$'\n'*) return 1 ;; esac
  done
  case "$label" in *$'\n'*) return 1 ;; esac
  printf 'uid=%s\nuser=%s\ndisplay=%s\nshm=%s\nsocket=%s\n' \
    "$uid" "$user" "$display" "$shm" "$socket"
  # Omitted entirely rather than written blank: the reader reads a blank value
  # as missing, and an unnamed session is fine where a rejected one is not.
  [ -n "$label" ] && printf 'label=%s\n' "$label"
  return 0
}

# write_registry_entry dir uid user display shm socket [label]
# Stage then rename, so a reader never sees a half-written entry. Modes are set
# explicitly because the reader refuses anything group- or other-writable and an
# inherited umask must not get a say in that.
write_registry_entry() {
  local dir="$1"; shift
  local uid="$1" body tmp
  is_uid "$uid" || return 1
  body="$(render_registry_entry "$@")" || return 1
  install -d -m 0755 "$dir" || return 1
  tmp="$dir/.$uid.tmp.$$"
  printf '%s\n' "$body" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dir/$uid" || { rm -f "$tmp"; return 1; }
}

# remove_registry_entry dir uid — idempotent: a session already gone is the
# state we wanted. Leaves the directory and every other entry untouched.
remove_registry_entry() {
  local dir="$1" uid="$2"
  is_uid "$uid" || return 1
  rm -f "$dir/$uid"
}

# session_display envfile -> the X display that session published
# Reads what dreamconnect-backstage-env.sh writes for a session (`DISPLAY=…`
# then `XAUTHORITY=…`). Anchored, so an `XDISPLAY=` line is not a DISPLAY.
session_display() {
  local f="$1" v
  [ -f "$f" ] || return 1
  v="$(sed -n 's/^DISPLAY=//p' "$f" | head -n 1)"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}
# --- stale shm frame (issue #27) ---------------------------------------------
# /dev/shm carries the sticky bit (1777), so unlinking a file there requires
# owning the file, owning the directory, or being root — no other DAC path
# exists (fs/namei.c may_delete). A prior install identity (e.g. a migration
# from a per-user install to a DREAMCONNECT_HOST_ACCOUNT one, issue #35) can
# leave the frame file owned by a uid the daemon never runs as, and an
# unprivileged daemon then can never clear it itself; the owner decided the
# daemon must not attempt privilege escalation for this at runtime. install.sh
# already runs as root (line 44), so it reclaims the file here, before the
# daemon's systemd unit (re)starts, but only when it's owned by some other
# uid -- a file already owned by target_uid is live and must be left alone.
reclaim_stale_shm_frame() {  # path target_uid
  local path="$1" target_uid="$2"
  [ -e "$path" ] || return 0
  [ "$(stat -c '%u' "$path")" != "$target_uid" ] && run rm -f "$path"
  return 0
}
