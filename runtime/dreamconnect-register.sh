#!/usr/bin/env bash
#
# dreamconnect-register.sh — publish one session to the agent's registry.
#
# The agent (root, inside ScreenConnect's JVM) attaches each SC child to the
# daemon serving that child's own display, and will only consider sessions root
# has registered at /run/dreamconnect/sessions/<uid>. Registration is therefore
# a property of a session being UP, not of an install having happened: /run is
# tmpfs, so an entry written at install time is gone after a reboot, and a
# backstage session that is running but unregistered gets refused rather than
# shown (the agent will not fall back onto a display the registry gives to
# somebody else).
#
# Driven by dreamconnect-register@<uid>.service, whose ExecStart/ExecStop make
# the entry's lifetime the unit's. Run directly for a one-off:
#
#   dreamconnect-register.sh register   <uid> [registry_dir] [envfile] [timeout]
#   dreamconnect-register.sh deregister <uid> [registry_dir]
#
# Root only: the registry must be root-owned or the agent ignores it entirely.
#
# Functions above a main guard, so the suite can source this and call them.

INSTALL_DIR="${INSTALL_DIR:-/opt/dreamconnect}"
DC_STATE_FILE_DEFAULT="/etc/dreamconnect/install.state"
DC_REGISTRY_DIR_DEFAULT="/run/dreamconnect/sessions"
DC_REGISTER_TIMEOUT_DEFAULT=60

# The registry writers live in install-lib.sh. Checkout path second so this
# works from the repo as well as from an install; silent and non-fatal here,
# because sourcing must have no side effects — a caller that needs the writers
# finds out when it calls one.
_dcr_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _dcr_lib in "$INSTALL_DIR/install-lib.sh" "$_dcr_here/../install-lib.sh"; do
  if [ -r "$_dcr_lib" ]; then . "$_dcr_lib"; break; fi
done
unset _dcr_lib
: # keep the sourcing status clean under `set -e`

# register_label <account> -> the name this session shows in the picker.
# The installed backstage account is the one the operator must be able to tell
# apart; everybody else is named after themselves.
register_label() {
  local account="$1" host
  [ -n "$account" ] || return 1
  # read_install_state rather than a second parser: a private one disagreed with
  # it on a duplicated key (first match vs last), which labelled a human's
  # session as the unattended one — the operator told the opposite of the truth.
  read_install_state
  host="$HOST_ACCOUNT"
  [ -n "$host" ] || return 1
  if [ "$account" = "$host" ]; then printf '%s\n' '[Backstage]'
  else printf '%s\n' "$account"; fi
}

# account_for_uid <uid> -> login name. DC_PASSWD_DB, if set, is read as a
# passwd(5) file instead of the real one, so this is testable without accounts.
account_for_uid() {
  local uid="$1" name
  is_uid "$uid" || return 1
  if [ -n "${DC_PASSWD_DB:-}" ]; then
    name="$(awk -F: -v u="$uid" '$3 == u { print $1; exit }' "$DC_PASSWD_DB")"
  else
    name="$(getent passwd "$uid" | cut -d: -f1)"
  fi
  [ -n "$name" ] || return 1
  printf '%s\n' "$name"
}

# register_session <uid> [registry_dir] [envfile] [timeout]
#
# Waits, bounded, for the session to publish its display — the shell's Xwayland
# decides that number and it does not exist before the session is up — then
# writes the entry. Refuses rather than registering a session it cannot fully
# describe: an entry the agent trusts but that serves nothing makes it refuse
# that display, which is worse than never having registered at all.
register_session() {
  local uid="$1" dir="${2:-$DC_REGISTRY_DIR_DEFAULT}" env="${3:-}"
  local timeout="${4:-$DC_REGISTER_TIMEOUT_DEFAULT}"
  local account label display i
  is_uid "$uid" || return 1
  [ -n "$env" ] || env="/run/user/$uid/dreamconnect-display.env"
  account="$(account_for_uid "$uid")" || return 1
  label="$(register_label "$account")" || return 1

  display=""
  for ((i = 0; i < timeout; i++)); do
    display="$(session_display "$env" 2>/dev/null || true)"
    [ -n "$display" ] && break
    sleep 1
  done
  [ -n "$display" ] || return 1

  write_registry_entry "$dir" "$uid" "$account" "$display" \
    "/dev/shm/dreamconnect.frame.$uid" "/run/user/$uid/dreamconnect.sock" "$label"
}

# deregister_session <uid> [registry_dir] — idempotent. Removing the entry is
# what keeps a dead session from blacking out its own display.
deregister_session() {
  local uid="$1" dir="${2:-$DC_REGISTRY_DIR_DEFAULT}"
  remove_registry_entry "$dir" "$uid"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _cmd="${1:-}"; shift || true
  case "$_cmd" in
    register)   register_session "$@" ;;
    deregister) deregister_session "$@" ;;
    *) echo "usage: $0 register|deregister <uid> [registry_dir]" >&2; exit 2 ;;
  esac
fi
