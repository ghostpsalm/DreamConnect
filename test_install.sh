#!/usr/bin/env bash
#
# Unit tests for the installer's shell library (install-lib.sh).
#
# install.sh itself cannot be unit-tested: it demands root and does top-level
# work (detect_user / id / getent) before anything is callable. install-lib.sh
# is the seam — it holds the *definitions* only, so sourcing it must be free of
# side effects, and every later slice (host-account create/delete, dconf
# idle-lock, autologin retarget) is exercised through it against tmp fixtures.
#
# Safety rail: this suite is never run as root. Slices 2+ drive useradd/userdel
# and dconf; a test that forgets a fixture override must not be able to reach
# the real system.
#
# Run:  bash test_install.sh      (also wired into ./run-tests.sh)
set -uo pipefail

[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/install-lib.sh"

# --- tiny assert harness -----------------------------------------------------
FAILURES=0
CURRENT="<none>"

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq() {  # actual expected label
  [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"
}

assert_contains() {  # haystack needle label
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: expected output to contain [$2], got [$1]" ;;
  esac
}

assert_not_contains() {  # haystack needle label
  case "$1" in
    *"$2"*) fail "$3: expected output NOT to contain [$2], got [$1]" ;;
  esac
}

assert_file_exists()  { [ -e "$1" ] || fail "$2: expected file to exist: $1"; }
assert_file_absent()  { [ -e "$1" ] && fail "$2: expected file NOT to exist: $1"; return 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- the seam ----------------------------------------------------------------
[ -f "$LIB" ] || { echo "FAIL: install-lib.sh not found at $LIB"; exit 1; }
# shellcheck source=install-lib.sh
. "$LIB"

# --- tests -------------------------------------------------------------------

# Sourcing the library must do nothing but define functions: no output, no
# non-zero exit. This is what makes it safe to source from a test (and from
# install.sh) before any environment is set up.
test_sourcing_is_side_effect_free() {
  local out rc
  out="$(bash -c 'set -euo pipefail; . "$1"' _ "$LIB" 2>&1)"; rc=$?
  assert_eq "$rc" "0" "sourcing install-lib.sh exits 0"
  assert_eq "$out" "" "sourcing install-lib.sh is silent"
}

# The functions install.sh defines today must all be available from the library
# after sourcing; these are the units slices 2-7 test against tmp fixtures.
test_library_defines_the_installer_functions() {
  local fn
  for fn in die detect_user user_session_type gdm_conf enable_autologin \
            disable_autologin detect_pm pm_install detect_monitor run; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

# Default (no DC_DRY_RUN): run executes the command for real.
test_run_executes_the_command_by_default() {
  local f out
  f="$TMP/really-created"
  out="$(unset DC_DRY_RUN; run touch "$f" 2>&1)"
  assert_file_exists "$f" "run without DC_DRY_RUN executes"
  assert_not_contains "$out" "DRY:" "run without DC_DRY_RUN does not announce a dry run"
}

# DC_DRY_RUN=1: run must not execute, and must say what it would have run.
test_run_suppresses_execution_when_dry() {
  local f out
  f="$TMP/never-created"
  out="$(DC_DRY_RUN=1 run touch "$f" 2>&1)"
  assert_file_absent "$f" "run with DC_DRY_RUN=1 does not execute"
  assert_contains "$out" "DRY:" "run with DC_DRY_RUN=1 announces the dry run"
  assert_contains "$out" "touch" "dry-run output names the command"
  assert_contains "$out" "$f" "dry-run output names the arguments"
}

# --- slice 2: resolve_host_identity ------------------------------------------
#
# Contract under test (issue #18 slice 1 "account name -> uid/home/socket,
# defaulting to today's detected user", checkpoint seams 3 and 5):
#
#   resolve_host_identity <account_or_empty> <fallback_user>
#
#   Prints ONE line to stdout with exactly four space-separated fields:
#       NAME UID HOME SOCKET
#   where SOCKET is always /run/user/<UID>/dreamconnect.sock — the formula that
#   systemd/dreamconnect-agent.conf's socket=/run/user/@UID@/dreamconnect.sock
#   and the daemon's $XDG_RUNTIME_DIR/dreamconnect.sock must agree on.
#
#   * arg1 empty/unset -> resolve arg2 instead (back-compat: unset opt-in
#     DREAMCONNECT_HOST_ACCOUNT keeps today's installing-user behaviour).
#   * arg1 non-empty   -> resolve arg1, not arg2.
#   * name not present in the passwd source -> exit non-zero, an informative
#     message naming the account on stderr, and nothing on stdout. It never
#     invents a uid (checkpoint: "never invents a uid" — a fabricated uid would
#     point the root JVM at a socket path nothing will ever bind).
#
# Lookup convention introduced here, which the implementation must follow:
#
#   DC_PASSWD_DB  set and non-empty -> read that file INSTEAD of getent passwd.
#                 It is passwd(5) format: colon-separated, one entry per line.
#                 The entry is the FIRST line whose field 1 equals the requested
#                 name exactly (not a prefix, not a substring); UID is field 3
#                 and HOME is field 6. e.g.
#                   awk -F: -v n="$name" '$1==n{print $3":"$6; exit}' "$DC_PASSWD_DB"
#                 unset/empty -> the real system: getent passwd "$name".
#
# The real-system (getent) path is deliberately not asserted here: it depends on
# accounts this sandbox/CI does not have. Only the fixture path is tested.

# A passwd(5) fixture. The first four entries are captured verbatim from a real
# /etc/passwd on the target-class box (GNOME/GDM, uid 1000 desktop user); the
# dreamconnect-host* entries are in the shape slice 4's ensure_host_account
# creates (system uid < 1000, GECOS marker "DreamConnect display host").
#
# dreamconnect-host2 is listed BEFORE dreamconnect-host on purpose: a lookup
# that prefix-matches (grep "^$name") instead of matching field 1 exactly would
# return the wrong entry and this fixture catches it.
make_passwd_db() {
  cat > "$TMP/passwd" <<'EOF'
root:x:0:0:Super User:/root:/bin/bash
gdm:x:42:42:GNOME Display Manager:/var/lib/gdm:/usr/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
dreamconnect-host2:x:986:986:DreamConnect display host:/var/lib/dreamconnect-host2:/bin/bash
dreamconnect-host:x:987:987:DreamConnect display host:/var/lib/dreamconnect-host:/bin/bash
EOF
  echo "$TMP/passwd"
}

# No host account requested (DREAMCONNECT_HOST_ACCOUNT unset) => today's
# behaviour: the installing/detected desktop user is the identity.
test_resolve_host_identity_defaults_to_fallback_user() {
  local db out rc
  db="$(make_passwd_db)"
  out="$(DC_PASSWD_DB="$db" resolve_host_identity "" kogies 2>&1)"; rc=$?
  assert_eq "$rc" "0" "resolve_host_identity with empty account exits 0"
  assert_eq "$out" "kogies 1000 /home/kogies /run/user/1000/dreamconnect.sock" \
    "empty account resolves the fallback user's NAME UID HOME SOCKET"
}

# A named account wins over the fallback, and is matched on the whole name.
test_resolve_host_identity_prefers_the_named_account() {
  local db out rc
  db="$(make_passwd_db)"
  out="$(DC_PASSWD_DB="$db" resolve_host_identity dreamconnect-host kogies 2>&1)"; rc=$?
  assert_eq "$rc" "0" "resolve_host_identity with a known account exits 0"
  assert_eq "$out" \
    "dreamconnect-host 987 /var/lib/dreamconnect-host /run/user/987/dreamconnect.sock" \
    "named account resolves its own NAME UID HOME SOCKET, exact-name match"
  assert_not_contains "$out" "kogies" "named account does not fall back to the desktop user"
}

# The socket path is the one value SC's root JVM and the daemon must agree on,
# so assert the formula directly for both identities the installer can produce.
test_resolve_host_identity_socket_is_run_user_uid_dreamconnect_sock() {
  local db sock
  db="$(make_passwd_db)"
  sock="$(DC_PASSWD_DB="$db" resolve_host_identity "" kogies 2>/dev/null | awk '{print $4}')"
  assert_eq "$sock" "/run/user/1000/dreamconnect.sock" "socket for uid 1000"
  sock="$(DC_PASSWD_DB="$db" resolve_host_identity dreamconnect-host2 kogies 2>/dev/null | awk '{print $4}')"
  assert_eq "$sock" "/run/user/986/dreamconnect.sock" "socket for a system uid < 1000"
}

# An account that does not exist yet (ensure_host_account has not run) must be
# a hard error, never a guessed uid.
test_resolve_host_identity_fails_when_the_account_is_absent() {
  local db out err rc
  db="$(make_passwd_db)"
  err="$TMP/resolve-absent.err"
  out="$(DC_PASSWD_DB="$db" resolve_host_identity dreamconnect-ghost kogies 2>"$err")"; rc=$?
  [ "$rc" -ne 0 ] || fail "absent account: expected non-zero exit, got $rc"
  assert_eq "$out" "" "absent account prints nothing to stdout"
  assert_contains "$(cat "$err")" "dreamconnect-ghost" "absent account names it on stderr"
}

# --- slice 3: install state + the uninstall safety gate ----------------------
#
# This slice is the rail that decides whether `--uninstall` is ever allowed to
# run `userdel -r`. Issue #18: "Creating a local account + autologin is
# high-risk: uninstall MUST delete the account and fully revert". The blast
# radius of a bug here is `userdel -r` on a human's home directory, so every
# refusal below gets its own test: each one keeps ALL other conditions valid and
# violates exactly one, and must still come back "not removable".
#
# Functions under test (contract, verbatim — the implementation follows this,
# not the reverse):
#
#   write_install_state <name> <uid> <created_account:0|1> <autologin_set:0|1>
#     Writes "$DC_STATE_FILE" (default /etc/dreamconnect/install.state when the
#     var is unset; these tests ALWAYS set it to a tmp path so nothing can touch
#     the real filesystem). Creates parent directories. Idempotent: a full
#     overwrite on every call, never an append. Sourceable KEY=VALUE lines:
#         HOST_ACCOUNT=<name>
#         HOST_UID=<uid>
#         CREATED_ACCOUNT=<0 or 1>
#         AUTOLOGIN_SET=<0 or 1>
#
#   read_install_state
#     No args. Sets FOUR variables in the CALLER's scope from "$DC_STATE_FILE":
#     HOST_ACCOUNT, HOST_UID, CREATED_ACCOUNT, AUTOLOGIN_SET. When the file does
#     not exist it must still set all four, to the safe defaults "", "", 0, 0 —
#     never leave a previous call's values sitting in the caller's shell.
#
#   host_account_removable <name> <protected_user>
#     Exit 0 ("removable") ONLY if ALL SIX hold; otherwise exit non-zero with a
#     line on stderr saying which rail refused:
#       1. <name> exists in the passwd source and its uid (field 3) is NOT 0.
#       2. Its home (field 6) is NOT exactly "/", "/home" or "/root".
#       3. <name> != <protected_user>  (the caller passes the detected desktop /
#          fallback user in; this function does not detect it itself).
#       4. <name> != "$SUDO_USER", when SUDO_USER is set and non-empty.
#       5. read_install_state (honouring DC_STATE_FILE) yields
#          HOST_ACCOUNT == <name> AND CREATED_ACCOUNT == 1.
#       6. Its GECOS (field 5) is EXACTLY "DreamConnect display host" — the
#          marker ensure_host_account stamps on accounts it creates. Exactly:
#          no trailing space, case-sensitive.
#     Deliberately stricter than a uid>=1000 heuristic: it demands OUR marker AND
#     OUR state record, at any uid.
#
# Passwd lookup: the same convention slice 2 introduced, not a second one —
# DC_PASSWD_DB set => read it as passwd(5) (colon-separated; field 1 name,
# field 3 uid, field 5 GECOS, field 6 home; first exact field-1 match wins);
# unset => getent passwd. Only the fixture path is asserted here.

# passwd(5) fixture for the removal rails. Every dc-* entry is a *decoy*: each
# one satisfies five of the six conditions and violates exactly one, so a rail
# that is missing from the implementation shows up as one specific failing test.
# Field layout is name:passwd:uid:gid:GECOS:home:shell — GECOS is field 5.
make_removal_passwd_db() {
  cat > "$TMP/passwd-removal" <<'EOF'
root:x:0:0:Super User:/root:/bin/bash
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
dreamconnect-host:x:987:987:DreamConnect display host:/var/lib/dreamconnect-host:/bin/bash
dc-uid0:x:0:0:DreamConnect display host:/var/lib/dc-uid0:/bin/bash
dc-home-slash:x:981:981:DreamConnect display host:/:/bin/bash
dc-home-home:x:982:982:DreamConnect display host:/home:/bin/bash
dc-home-root:x:983:983:DreamConnect display host:/root:/bin/bash
dc-gecos-empty:x:984:984::/var/lib/dc-gecos-empty:/bin/bash
dc-gecos-trailing:x:985:985:DreamConnect display host :/var/lib/dc-gecos-trailing:/bin/bash
dc-gecos-lower:x:986:986:dreamconnect display host:/var/lib/dc-gecos-lower:/bin/bash
dc-gecos-human:x:988:988:Roger Rickard:/var/lib/dc-gecos-human:/bin/bash
EOF
  echo "$TMP/passwd-removal"
}

# State fixtures are written BY HAND in the documented format, not via
# write_install_state, so a bug in the writer cannot mask a missing safety rail.
write_state_fixture() {  # path account uid created autologin
  mkdir -p "$(dirname "$1")"
  {
    echo "HOST_ACCOUNT=$2"
    echo "HOST_UID=$3"
    echo "CREATED_ACCOUNT=$4"
    echo "AUTOLOGIN_SET=$5"
  } > "$1"
}

# Call the gate in a subshell (it sets state globals; keep them out of the
# harness) and capture both the exit status and stderr.
REMOVE_RC=0
REMOVE_ERR=""
try_removable() {  # passwd_db state_file sudo_user name protected_user
  REMOVE_ERR="$(DC_PASSWD_DB="$1" DC_STATE_FILE="$2" SUDO_USER="$3" \
                host_account_removable "$4" "$5" 2>&1 >/dev/null)"
  REMOVE_RC=$?
  return 0
}

# "Refused" must mean the gate refused, not that anything at all went wrong: a
# missing function also exits non-zero with text on stderr, and a refusal test
# that accepts that asserts nothing.
assert_refused() {  # label
  declare -F host_account_removable >/dev/null || {
    fail "$1: host_account_removable() is not defined — refusal not demonstrated"; return 0; }
  [ "$REMOVE_RC" -ne 127 ] || { fail "$1: exit 127 (command not found), not a refusal"; return 0; }
  assert_not_contains "$REMOVE_ERR" "command not found" "$1: refusal came from the gate, not the shell"
  [ "$REMOVE_RC" -ne 0 ] || fail "$1: expected non-zero exit (NOT removable), got $REMOVE_RC"
  [ -n "$REMOVE_ERR" ] || fail "$1: expected a stderr line naming the rail that refused, got none"
}

test_library_defines_the_state_and_removal_functions() {
  local fn
  for fn in write_install_state read_install_state host_account_removable; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

# Parent directories may not exist yet (/etc/dreamconnect on a fresh box).
test_write_install_state_creates_parent_dirs_and_all_four_keys() {
  local body
  local DC_STATE_FILE="$TMP/state-fresh/dreamconnect/install.state"
  local state="$DC_STATE_FILE"
  write_install_state dreamconnect-host 987 1 1
  assert_file_exists "$state" "write_install_state creates the file and its parents"
  body="$(cat "$state" 2>/dev/null || true)"
  assert_contains "$body" "HOST_ACCOUNT=dreamconnect-host" "state file records HOST_ACCOUNT"
  assert_contains "$body" "HOST_UID=987"                   "state file records HOST_UID"
  assert_contains "$body" "CREATED_ACCOUNT=1"              "state file records CREATED_ACCOUNT"
  assert_contains "$body" "AUTOLOGIN_SET=1"                "state file records AUTOLOGIN_SET"
}

# Idempotent = full overwrite. An appending writer leaves two HOST_ACCOUNT lines
# and `. install.state` then silently picks the stale one first / last.
test_write_install_state_overwrites_rather_than_appends() {
  local lines accounts
  local DC_STATE_FILE="$TMP/state-idem/install.state"
  local state="$DC_STATE_FILE"
  write_install_state dreamconnect-host 987 1 1
  write_install_state dreamconnect-host2 986 0 0
  lines="$(wc -l < "$state" 2>/dev/null || echo 0)"
  assert_eq "${lines// /}" "4" "rewritten state file still has exactly 4 lines"
  accounts="$(grep -c '^HOST_ACCOUNT=' "$state" 2>/dev/null || echo 0)"
  assert_eq "$accounts" "1" "rewritten state file has exactly one HOST_ACCOUNT line"
  assert_contains "$(cat "$state" 2>/dev/null || true)" "HOST_ACCOUNT=dreamconnect-host2" \
    "the second write wins"
}

test_install_state_round_trips_all_four_values() {
  local DC_STATE_FILE="$TMP/state-roundtrip/install.state"
  local HOST_ACCOUNT="stale" HOST_UID="stale" CREATED_ACCOUNT="stale" AUTOLOGIN_SET="stale"
  write_install_state dreamconnect-host 987 1 0
  read_install_state
  assert_eq "$HOST_ACCOUNT"    "dreamconnect-host" "round-trip HOST_ACCOUNT"
  assert_eq "$HOST_UID"        "987"               "round-trip HOST_UID"
  assert_eq "$CREATED_ACCOUNT" "1"                 "round-trip CREATED_ACCOUNT"
  assert_eq "$AUTOLOGIN_SET"   "0"                 "round-trip AUTOLOGIN_SET"
}

# The stale-global bug class: a reader that only assigns when the file exists
# leaves the PREVIOUS account's name in HOST_ACCOUNT, and the gate would then
# green-light deleting it.
test_read_install_state_resets_to_safe_defaults_when_absent() {
  local DC_STATE_FILE="$TMP/state-stale/install.state"
  local HOST_ACCOUNT="" HOST_UID="" CREATED_ACCOUNT="" AUTOLOGIN_SET=""
  write_install_state dreamconnect-host 987 1 1
  read_install_state
  assert_eq "$HOST_ACCOUNT" "dreamconnect-host" "precondition: state was read"
  DC_STATE_FILE="$TMP/state-stale/no-such-file.state"
  read_install_state
  assert_eq "$HOST_ACCOUNT"    "" "absent state file resets HOST_ACCOUNT to empty"
  assert_eq "$HOST_UID"        "" "absent state file resets HOST_UID to empty"
  assert_eq "$CREATED_ACCOUNT" "0" "absent state file resets CREATED_ACCOUNT to 0"
  assert_eq "$AUTOLOGIN_SET"   "0" "absent state file resets AUTOLOGIN_SET to 0"
}

# All six rails satisfied: this is the only shape that may be deleted.
test_host_account_removable_accepts_the_account_we_created() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-ok/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  try_removable "$db" "$state" "" dreamconnect-host kogies
  assert_eq "$REMOVE_RC" "0" "account we created, marker + state agreeing: removable"
}

# Rail 1a: not in the passwd source at all.
test_host_account_removable_refuses_an_unknown_account() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-ghost/install.state"
  write_state_fixture "$state" dreamconnect-ghost 987 1 1
  try_removable "$db" "$state" "" dreamconnect-ghost kogies
  assert_refused "account absent from the passwd source"
}

# Rail 1b: uid 0, with the marker and the state record both "matching".
test_host_account_removable_refuses_uid_zero() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-uid0/install.state"
  write_state_fixture "$state" dc-uid0 0 1 1
  try_removable "$db" "$state" "" dc-uid0 kogies
  assert_refused "uid 0 account"
}

# Rail 2: `userdel -r` against these homes is the catastrophic case.
test_host_account_removable_refuses_dangerous_home_dirs() {
  local db state acct
  db="$(make_removal_passwd_db)"
  for acct in dc-home-slash dc-home-home dc-home-root; do
    state="$TMP/state-home-$acct/install.state"
    write_state_fixture "$state" "$acct" 981 1 1
    try_removable "$db" "$state" "" "$acct" kogies
    assert_refused "home directory rail ($acct)"
  done
}

# Rail 3: never the account the caller identified as the human's.
test_host_account_removable_refuses_the_protected_user() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-protected/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  try_removable "$db" "$state" "" dreamconnect-host dreamconnect-host
  assert_refused "name == protected_user"
}

# Rail 3, the other direction — a GUARD on existing behaviour, not a new feature.
#
# The contract (slice 3, above) is "3. <name> != <protected_user>", and the
# caller passes the protected user IN; this function detects nothing itself. So
# an EMPTY protected_user means "the caller has no user to protect", and the rail
# must then be a NO-OP, never a refusal: "$name" != "" is true for every real
# account name.
#
# Why that matters in the field, and why this is worth a test of its own. On a
# box rebooted into the display-host account — the feature's own steady state —
# that account holds the only active session, so install.sh's detect_user()
# returns it as "the desktop user" and PROTECTED_USER comes out equal to
# HOST_ACCOUNT. "Protect X from deleting X" is meaningless, so uninstall() passes
# "" here instead; if this rail ever treated "" as matching, --uninstall could
# never remove the very account it exists to remove, in precisely the primary
# real-world scenario. The other five rails (uid != 0, safe home, not $SUDO_USER,
# state agreement, exact GECOS marker) are what actually confirm the account is
# ours, and they are all still satisfied here.
test_host_account_removable_allows_an_empty_protected_user() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-no-protected/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  try_removable "$db" "$state" "" dreamconnect-host ""
  assert_eq "$REMOVE_RC" "0" \
    "empty protected_user disables rail 3 rather than refusing (stderr: $REMOVE_ERR)"
}

# Rail 4: never the account that invoked sudo to run the uninstall.
test_host_account_removable_refuses_sudo_user() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-sudo/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  try_removable "$db" "$state" dreamconnect-host dreamconnect-host kogies
  assert_refused "name == \$SUDO_USER"
}

# Rail 5a: an account with our marker that we did NOT create (pre-existing, or
# created by a different tool) is not ours to delete.
test_host_account_removable_refuses_when_state_says_not_created() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-not-created/install.state"
  write_state_fixture "$state" dreamconnect-host 987 0 1
  try_removable "$db" "$state" "" dreamconnect-host kogies
  assert_refused "CREATED_ACCOUNT=0"
}

# Rail 5b: no state file at all (nothing recorded => nothing to delete).
test_host_account_removable_refuses_when_state_file_is_absent() {
  local db
  db="$(make_removal_passwd_db)"
  try_removable "$db" "$TMP/state-missing/install.state" "" dreamconnect-host kogies
  assert_refused "state file absent"
}

# Rail 5c: state says we created X, someone is asking us to delete Y.
test_host_account_removable_refuses_when_state_names_another_account() {
  local db state
  db="$(make_removal_passwd_db)"; state="$TMP/state-other/install.state"
  write_state_fixture "$state" dreamconnect-host2 986 1 1
  try_removable "$db" "$state" "" dreamconnect-host kogies
  assert_refused "state HOST_ACCOUNT names a different account"
}

# Rail 6: GECOS must be EXACTLY "DreamConnect display host" — empty, trailing
# space, wrong case and a human's real name all refuse.
test_host_account_removable_refuses_a_wrong_gecos_marker() {
  local db state acct
  db="$(make_removal_passwd_db)"
  for acct in dc-gecos-empty dc-gecos-trailing dc-gecos-lower dc-gecos-human; do
    state="$TMP/state-gecos-$acct/install.state"
    write_state_fixture "$state" "$acct" 984 1 1
    try_removable "$db" "$state" "" "$acct" kogies
    assert_refused "GECOS marker rail ($acct)"
  done
}

# --- slice 4: ensure_host_account --------------------------------------------
#
# Issue #18, slice 2 of the CODE list: "ensure_host_account: create-if-absent +
# hide-from-greeter + no-sudo + disabled password, idempotent. Unit: tmp
# passwd/AccountsService dir." Owner-confirmed design in the same issue:
# "a dedicated hidden system-ish account (uid < 1000 or AccountsService
# SystemAccount=true, hidden from greeter user list, no sudo / minimal groups,
# password disabled)".
#
# CONTRACT UNDER TEST — the implementation follows this, not the reverse.
# These are the test-author's design decisions; the builder implements to match.
#
#   ensure_host_account <name>
#
#   Sources of truth it must use:
#     * existence  -> passwd_entry <name>, i.e. the slice-2 DC_PASSWD_DB
#                     convention (set => read that passwd(5) file instead of
#                     getent). No second lookup convention.
#     * the GECOS marker -> EXACTLY "DreamConnect display host". Not a new
#                     spelling: it is the string host_account_removable()
#                     already demands (slice 3, rail 6) before --uninstall may
#                     ever run userdel. A different byte here means the account
#                     can never be removed.
#     * the greeter-hiding file's directory -> $DC_ACCOUNTSSERVICE_DIR, a new
#                     env var, defaulting to the real /var/lib/AccountsService/users.
#                     The default is deliberately NOT asserted below: the tests
#                     always set it to a tmp fixture, because a test that forgot
#                     it must not be able to write to /var/lib.
#
#   A. Account ABSENT (passwd_entry empty) — emits, THROUGH run():
#        useradd --system --create-home --comment 'DreamConnect display host' \
#                [--shell <non-interactive>] <name>
#        - --system and --create-home and --comment are required.
#        - the marker is ONE argv element (asserted precisely, see "capture"
#          below): `--comment DreamConnect display host` unquoted would set the
#          GECOS to "DreamConnect" and the uninstall gate would then refuse to
#          remove the account we created — it would leak.
#        - argv must contain none of: -G, --groups, wheel, sudo, adm.
#      and then, as a SEPARATE run() call (password-disable mechanism chosen
#      here; the builder implements this one, not an alternative):
#        usermod -p '*' <name>
#      `-p '*'` rather than `passwd -l`: non-interactive, no tty, no "password
#      expiry" warnings, and '*' means "no password can ever match" rather than
#      "! prefix on whatever was there".
#
#   B. Account PRESENT — neither useradd NOR usermod runs. Idempotence is the
#      obvious reason for useradd; for usermod it is safety: if a human account
#      already holds this name, re-running install.sh must not disable their
#      password or restamp their GECOS. (An account we did not create keeps
#      whatever GECOS it has, and slice 3's gate then correctly refuses to
#      delete it on uninstall.)
#
#   C. BOTH paths — write $DC_ACCOUNTSSERVICE_DIR/<name> containing at minimum
#        [User]
#        SystemAccount=true
#      which is what hides the account from the GDM greeter's user list. Full
#      overwrite, never an append: re-running install.sh must leave byte-identical
#      content, not a second [User] section.
#
#   D. This write goes THROUGH run() as well — e.g. build the content in a
#      mktemp file and `run install -D -m 0644 "$tmp" "$dir/$name"`. Not
#      cosmetic: DC_DRY_RUN=1 must mean "nothing on this machine changed", and a
#      bare `> "$dir/$name"` redirect would silently punch through the dry run.
#      test_ensure_host_account_writes_nothing_when_dry is the assertion for it.
#      The emitted command must name the destination path, so a dry run is
#      auditable; which copy tool is used is left open.
#
#   E. ensure_host_account must not check for root itself (install.sh already
#      does), and must invoke useradd/usermod by BARE NAME so PATH-shimmed tests
#      can intercept them. It stays unit-testable as a non-root user.
#
#   CAPTURE TECHNIQUE (two, deliberately, because neither alone is enough):
#     1. DC_DRY_RUN=1 + run()'s `echo "DRY: $*"` — used for "which commands were
#        emitted, with which flags, and that they were gated by run() at all".
#        `$*` joins argv with spaces, so this view CANNOT see where one argument
#        ends and the next begins; nothing below asserts argument boundaries
#        from it.
#     2. A PATH shim directory whose useradd/usermod/passwd/userdel record
#        `printf '[%s]\n' "$@"` — one argv element per line, boundaries visible.
#        Used for the one assertion that needs them (the GECOS marker is a
#        single argument) and as the safety net for the two non-dry-run tests:
#        the shims exit 0 without touching the system, so the only real write in
#        this whole section is into the tmp AccountsService fixture dir.

# A passwd(5) fixture for a box where the host account does NOT exist yet: the
# same four real entries make_passwd_db captured, minus the dreamconnect-host*
# lines. This is the state install.sh meets on a first run.
make_fresh_passwd_db() {
  cat > "$TMP/passwd-fresh" <<'EOF'
root:x:0:0:Super User:/root:/bin/bash
gdm:x:42:42:GNOME Display Manager:/var/lib/gdm:/usr/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
EOF
  echo "$TMP/passwd-fresh"
}

# Recording stand-ins for the account tools, first on PATH. Each appends its own
# name and then ONE LINE PER ARGV ELEMENT, bracketed, so argument boundaries are
# observable — which run()'s "DRY: $*" view cannot show. They exit 0 and do
# nothing, so a non-dry-run test still cannot touch the real system.
make_cmd_shims() {  # dir -> echoes the call log path
  local d="$1" c
  mkdir -p "$d"
  for c in useradd usermod passwd userdel chfn; do
    cat > "$d/$c" <<EOF
#!/usr/bin/env bash
{ echo "== $c"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
exit 0
EOF
    chmod +x "$d/$c"
  done
  : > "$d/calls.log"
  echo "$d/calls.log"
}

ENSURE_OUT=""
ENSURE_RC=0

# Dry run: capture everything ensure_host_account said.
run_ensure_dry() {  # passwd_db accountsservice_dir name
  ENSURE_OUT="$(DC_DRY_RUN=1 DC_PASSWD_DB="$1" DC_ACCOUNTSSERVICE_DIR="$2" \
                ensure_host_account "$3" 2>&1)"
  ENSURE_RC=$?
  return 0
}

# Real run, but with the account tools shimmed away on PATH.
run_ensure_shimmed() {  # passwd_db accountsservice_dir shim_dir name
  ENSURE_OUT="$(DC_DRY_RUN= DC_PASSWD_DB="$1" DC_ACCOUNTSSERVICE_DIR="$2" \
                PATH="$3:$PATH" ensure_host_account "$4" 2>&1)"
  ENSURE_RC=$?
  return 0
}

dry_all() {  # every emitted command line, "DRY: " stripped
  printf '%s\n' "$ENSURE_OUT" | sed -n 's/^DRY: //p'
}

dry_lines_for() {  # cmd -> the emitted lines whose command word is (or ends in) cmd
  dry_all | awk -v c="$1" '{ n = split($1, p, "/"); if (p[n] == c) print }'
}

assert_line() {  # haystack exact_line label
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) ;;
    *) fail "$3: expected a line exactly [$2], got [$1]" ;;
  esac
}

# A missing function exits 127 having emitted nothing, which would make every
# "must NOT contain" / "must not have written" assertion below pass vacuously.
require_ensure_host_account() {  # label
  declare -F ensure_host_account >/dev/null && return 0
  fail "$1: ensure_host_account() is not defined"
  return 1
}

test_library_defines_ensure_host_account() {
  declare -F ensure_host_account >/dev/null || \
    fail "install-lib.sh defines ensure_host_account(): not defined"
}

# Contract A: a system account carrying the exact marker slice 3's removal gate
# demands. Flags only — argument boundaries are asserted separately, below.
test_ensure_host_account_creates_a_system_account_with_the_marker() {
  local db dir line
  require_ensure_host_account "create: system account" || return 0
  db="$(make_fresh_passwd_db)"; dir="$TMP/as-create"; mkdir -p "$dir"
  run_ensure_dry "$db" "$dir" dreamconnect-host
  line="$(dry_lines_for useradd)"
  [ -n "$line" ] || fail "absent account: expected a useradd command, emitted [$ENSURE_OUT]"
  assert_contains "$line" "--system"      "useradd creates a system account"
  assert_contains "$line" "--create-home" "useradd creates the home directory"
  assert_contains "$line" "--comment"     "useradd sets the GECOS comment"
  assert_contains "$line" "DreamConnect display host" \
    "useradd stamps the exact GECOS marker host_account_removable demands"
  assert_contains "$line" "dreamconnect-host" "useradd names the account"
}

# Contract A: "no sudo / minimal groups" (issue #18, agreed design). An absence
# check over the whole useradd argv.
test_ensure_host_account_grants_no_supplementary_groups() {
  local db dir line
  require_ensure_host_account "create: no groups" || return 0
  db="$(make_fresh_passwd_db)"; dir="$TMP/as-nogroups"; mkdir -p "$dir"
  run_ensure_dry "$db" "$dir" dreamconnect-host
  line="$(dry_lines_for useradd)"
  [ -n "$line" ] || fail "no-groups: expected a useradd command, emitted [$ENSURE_OUT]"
  assert_not_contains "$line" "-G"       "useradd passes no -G"
  assert_not_contains "$line" "--groups" "useradd passes no --groups"
  assert_not_contains "$line" "wheel"    "useradd puts the account in no wheel group"
  assert_not_contains "$line" "sudo"     "useradd puts the account in no sudo group"
  assert_not_contains "$line" "adm"      "useradd puts the account in no adm group"
}

# Contract A: the password is disabled by its own call, distinct from useradd.
test_ensure_host_account_disables_the_password() {
  local db dir line
  require_ensure_host_account "create: password disabled" || return 0
  db="$(make_fresh_passwd_db)"; dir="$TMP/as-passwd"; mkdir -p "$dir"
  run_ensure_dry "$db" "$dir" dreamconnect-host
  line="$(dry_lines_for usermod)"
  [ -n "$line" ] || fail "password: expected a usermod command, emitted [$ENSURE_OUT]"
  assert_contains "$line" "-p" "password is disabled via usermod -p"
  assert_contains "$line" "*"  "password is set to '*' (nothing can match it)"
  assert_contains "$line" "dreamconnect-host" "usermod names the account"
}

# Contract D: DC_DRY_RUN=1 means nothing on this machine changed — including the
# AccountsService file. If this fails, the file write bypassed run(), and any
# test that forgets DC_DRY_RUN=1 would provision an account for real.
test_ensure_host_account_writes_nothing_when_dry() {
  local db dir entries
  require_ensure_host_account "dry run writes nothing" || return 0
  db="$(make_fresh_passwd_db)"; dir="$TMP/as-dry"; mkdir -p "$dir"
  run_ensure_dry "$db" "$dir" dreamconnect-host
  entries="$(ls -A "$dir" | wc -l)"
  assert_eq "${entries// /}" "0" "DC_DRY_RUN=1 leaves the AccountsService dir empty"
  assert_file_absent "$dir/dreamconnect-host" "DC_DRY_RUN=1 writes no greeter-hiding file"
}

# Contract B + C: re-running install.sh against an existing account must not
# re-create it, must not touch its password, but must still assert the
# hidden-from-greeter marker.
test_ensure_host_account_skips_useradd_when_the_account_exists() {
  local db dir
  require_ensure_host_account "existing account" || return 0
  db="$(make_passwd_db)"; dir="$TMP/as-exists"; mkdir -p "$dir"
  run_ensure_dry "$db" "$dir" dreamconnect-host
  assert_eq "$(dry_lines_for useradd)" "" \
    "existing account: no useradd is emitted (idempotent)"
  assert_eq "$(dry_lines_for usermod)" "" \
    "existing account: its password is not re-disabled (it may be a human's)"
  assert_contains "$(dry_all)" "$dir/dreamconnect-host" \
    "existing account: the greeter-hiding file is still (re-)asserted"
}

# Contract C: the marker file's content, for real, in a fixture dir — and
# byte-identical on the second run. An appending writer gives two [User]
# sections and AccountsService then reads whichever it likes.
test_ensure_host_account_writes_the_hidden_marker_file_idempotently() {
  local db dir shims log f first count
  require_ensure_host_account "marker file" || return 0
  db="$(make_passwd_db)"; dir="$TMP/as-file"; mkdir -p "$dir"
  shims="$TMP/shims-file"; log="$(make_cmd_shims "$shims")"
  f="$dir/dreamconnect-host"; first="$TMP/as-file-first"

  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  assert_file_exists "$f" "greeter-hiding file is written for an existing account"
  assert_contains "$(cat "$f" 2>/dev/null || true)" "[User]" \
    "greeter-hiding file has a [User] section"
  assert_contains "$(cat "$f" 2>/dev/null || true)" "SystemAccount=true" \
    "greeter-hiding file sets SystemAccount=true"
  cp "$f" "$first" 2>/dev/null || true

  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  cmp -s "$first" "$f" || fail "second run rewrites the greeter-hiding file byte-identically"
  count="$(grep -c 'SystemAccount=true' "$f" 2>/dev/null || echo 0)"
  assert_eq "$count" "1" "SystemAccount=true appears exactly once after two runs"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "existing account: no account tool was invoked at all across two runs"
}

# Contract A, the one assertion run()'s "DRY: $*" view cannot make: the marker
# reaches useradd as a SINGLE argv element. Shimmed, so useradd never runs.
test_ensure_host_account_passes_the_marker_as_one_argument() {
  local db dir shims log calls
  require_ensure_host_account "marker is one argument" || return 0
  db="$(make_fresh_passwd_db)"; dir="$TMP/as-argv"; mkdir -p "$dir"
  shims="$TMP/shims-argv"; log="$(make_cmd_shims "$shims")"
  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  calls="$(cat "$log" 2>/dev/null || true)"
  assert_line "$calls" "== useradd" "useradd is invoked for an absent account"
  assert_line "$calls" "[--system]" "--system reaches useradd as its own argument"
  assert_line "$calls" "[--comment]" "--comment reaches useradd as its own argument"
  assert_line "$calls" "[DreamConnect display host]" \
    "the GECOS marker reaches useradd as ONE argument, unsplit"
  assert_line "$calls" "== usermod" "the password-disable call is made too"
}

# Contract F (coordinator decision): ensure_host_account reports whether THIS
# call created the account, because write_install_state's CREATED_ACCOUNT is
# rail 5 of the userdel gate — without it slice 3 can never say yes, and the
# account leaks on uninstall.
#
# It reports it the way read_install_state already reports its four values: by
# setting a variable in the CALLER's scope, not by echoing or by an exit status.
# Same convention, no new pattern:
#
#   ACCOUNT_WAS_CREATED = "1" if this call created the account,
#                         "0" if the account already existed.
#
# So: a plain assignment, NOT `local ACCOUNT_WAS_CREATED=` inside the function
# (that would hide it from the caller), and set on EVERY path — read_install_state
# resets all four unconditionally for exactly this reason. The two cases below
# run in one shell in sequence, seeded with a junk value and then leaving "1"
# behind, so a version that only assigns on the branch it takes fails here.
#
# Note the call is NOT wrapped in $(...) like the other tests: a command
# substitution is a subshell and the caller-scope variable would not survive it.
# Output goes to a file instead; the env overrides are locals, visible to the
# callee by bash's dynamic scoping and gone when this test returns.
test_ensure_host_account_reports_whether_it_created_the_account() {
  local fresh db dir
  local ACCOUNT_WAS_CREATED="junk"
  local DC_DRY_RUN=1 DC_PASSWD_DB DC_ACCOUNTSSERVICE_DIR
  require_ensure_host_account "ACCOUNT_WAS_CREATED" || return 0
  fresh="$(make_fresh_passwd_db)"; db="$(make_passwd_db)"
  dir="$TMP/as-created-flag"; mkdir -p "$dir"
  DC_ACCOUNTSSERVICE_DIR="$dir"

  DC_PASSWD_DB="$fresh"
  ensure_host_account dreamconnect-host >"$TMP/as-created-flag.out" 2>&1
  assert_eq "$ACCOUNT_WAS_CREATED" "1" \
    "absent account: ACCOUNT_WAS_CREATED=1 in the caller's scope"

  DC_PASSWD_DB="$db"
  ensure_host_account dreamconnect-host >>"$TMP/as-created-flag.out" 2>&1
  assert_eq "$ACCOUNT_WAS_CREATED" "0" \
    "existing account: ACCOUNT_WAS_CREATED=0, not left at 1 from the previous call"
}

# --- slice 5: configure_no_idle_lock / remove_no_idle_lock --------------------
#
# WHY THIS SLICE EXISTS (issue #18, empirical constraints 2 and 3, verbatim):
#   "Locking a live session makes Mutter close the active RemoteDesktop/ScreenCast
#    session and blocks recreation while locked ... Therefore 'remotely reachable'
#    and 'locked' are mutually exclusive on GNOME/Wayland."
#   "Corollary — idle auto-lock is fatal. An unattended account that idle-locks
#    will self-destruct its own capture and become unreachable."
# Slice 3 of the issue's CODE list: "Disable GNOME idle/screen-lock for the
# account (dconf), idempotent + reversed on uninstall."
#
# The issue names three settings (lock-enabled, idle-delay, lock-delay). The
# owner approved an EXPANDED set: idle-suspend (sleep-inactive-*-type) and the
# gnome-initial-setup first-boot wizard would each independently produce the same
# unreachability the three are there to prevent — a suspended box has no session
# at all, and a modal welcome tour covers the desktop nobody is present to click
# through.
#
# WHERE THE EXPECTED VALUES COME FROM (not from any implementation — none exists):
#   * key names + value types: the GNOME schemas installed on this target-class
#     box. `gsettings range org.gnome.desktop.screensaver lock-delay` -> "type u"
#     and the same for org.gnome.desktop.session idle-delay, which is why both
#     are written as dconf-keyfile `uint32 0` rather than a bare 0. `gsettings
#     range org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type` is an
#     enum whose members include 'nothing'; enums are single-quoted strings in a
#     dconf keyfile. Booleans are unquoted true/false.
#   * the reserved names in the blast-radius guard: this box really has
#     /etc/dconf/profile/user and /etc/dconf/db/local — dconf's own default
#     profile and the conventional system db. Writing either would change lock
#     and idle behaviour for potentially EVERY user on the machine.
#
# CONTRACT UNDER TEST — the implementation follows this, not the reverse.
#
#   configure_no_idle_lock <name> <home>
#     Both arguments are already resolved by the caller; this function performs
#     no passwd lookup of its own (same "detects nothing by itself" rule
#     host_account_removable follows). Writes four files, every one a FULL
#     OVERWRITE, never an append:
#
#     1. "${DC_DCONF_DIR:-/etc/dconf}/profile/<name>", exactly:
#            user-db:user
#            system-db:<name>
#     2. "${DC_DCONF_DIR:-/etc/dconf}/db/<name>.d/00-display-host", exactly:
#            [org/gnome/desktop/screensaver]
#            lock-enabled=false
#            idle-activation-enabled=false
#            lock-delay=uint32 0
#
#            [org/gnome/desktop/session]
#            idle-delay=uint32 0
#
#            [org/gnome/settings-daemon/plugins/power]
#            sleep-inactive-ac-type='nothing'
#            sleep-inactive-battery-type='nothing'
#     3. "<home>/.config/environment.d/dconf-profile.conf", exactly:
#            DCONF_PROFILE=<name>
#        (creating .config/environment.d/ if absent). Without this the session
#        loads the default profile and the db above is inert.
#     4. "<home>/.config/gnome-initial-setup-done", containing `yes`.
#
#     BLAST-RADIUS GUARD: if <name> is exactly "user" or "local", REFUSE —
#     return non-zero, say why on stderr, and write NOTHING AT ALL. This is the
#     single most important assertion in the slice.
#
#     Then, and only then: `run dconf update`.
#
#   remove_no_idle_lock <name> <home>
#     Reverses all four: profile file, db keyfile (and the <name>.d directory
#     once it is empty — a non-empty dir is left alone, not an error), the
#     environment.d FILE only (never the environment.d directory, which may hold
#     other drop-ins), and the initial-setup marker. Then `run dconf update`.
#     A no-op that exits 0 when nothing was ever configured.
#
#   THE DRY-RUN BOUNDARY IS EXACTLY ONE COMMAND. Only `dconf update` goes
#   through run(). The four file writes do NOT: they land in fixture-overridable
#   paths (DC_DCONF_DIR, <home>) that are always safe in a test, unlike slice 4's
#   useradd/usermod which have no fixture equivalent. So the tests assert file
#   content directly instead of parsing dry-run text, and
#   test_configure_no_idle_lock_gates_only_dconf_update_behind_run pins the
#   boundary in both directions at once: under DC_DRY_RUN=1 the files ARE written
#   and the dconf binary is NOT executed.
#
#   ASSERTION STYLE, chosen deliberately:
#     * the profile file (2 lines) is asserted as exact whole-file content.
#     * the db keyfile is asserted PER LINE with assert_line (exact-line match,
#       already used by slice 4), one assertion per key and per section header,
#       so a future edit that drops or retypes one key fails with that key's
#       name — which a single whole-file cmp would not tell you. Whole-file
#       stability is covered instead by the double-apply test's cmp, so blank
#       lines and ordering are still pinned against drift without making every
#       key assertion fragile.

# OWNERSHIP (coordinator decision, following install.sh's own precedent — it
# already does `chown "$USER_NAME:" "$USER_HOME/.config/systemd/user/..."` after
# installing a file as root into a user's home):
#
#   configure_no_idle_lock runs as root but writes two files INSIDE <home>. Both
#   must end up owned by <name>, using the same `chown "<name>:" <path>`
#   convention install.sh already uses (bare `<name>:` — the account's primary
#   group, not a hardcoded group name). The directories it creates on the way,
#   <home>/.config and <home>/.config/environment.d, are chowned too.
#
#   The /etc/dconf files are explicitly NOT chowned: they stay root-owned like
#   the rest of /etc/dconf.
#
#   A failing chown must NOT abort the function. At real install time the
#   account exists by the time this runs (ensure_host_account created it earlier
#   in the same flow), but nothing in this function enforces that ordering, and
#   losing the dconf configuration because of an ownership fixup would trade a
#   working unattended session for a cosmetic detail. Warn, continue, exit 0.
#
#   HOW THIS IS TESTED, and why not the obvious way. The obvious test — chown to
#   $(id -un) and assert `stat -c '%U'` — cannot fail: the fixture home is
#   created BY the test runner, so it already reports the runner's name whether
#   or not chown was ever called. That is a tautology, not a test. So ownership
#   is asserted at the call surface instead, with the PATH-shim technique slice 4
#   already uses for useradd/usermod: a recording `chown` shim makes the argv
#   observable for a fixture account name that does not exist on this box, which
#   is also the only way to assert the /etc/dconf files are NOT chowned.
#
#   Consequence for the builder: invoke chown by BARE NAME (not /usr/bin/chown),
#   and name each of the four paths explicitly. A single recursive
#   `chown -R "<name>:" "<home>/.config"` would be correct behaviour in the
#   field, but it is not what these tests assert, so use the explicit form.
#   Whether chown goes through run() is left open — under the non-dry runs used
#   here the shim records it either way.

# The dconf binary, shimmed away on PATH: it records its argv and exits 0. The
# suite's safety rail is that it never touches the real system, and DC_DCONF_DIR
# redirects OUR writes but not dconf's own /etc/dconf — so the real `dconf
# update` must never be reached, even in the non-dry tests.
make_dconf_shim() {  # dir -> echoes the call log path
  local d="$1"
  mkdir -p "$d"
  cat > "$d/dconf" <<EOF
#!/usr/bin/env bash
{ echo "== dconf"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
exit 0
EOF
  chmod +x "$d/dconf"
  : > "$d/calls.log"
  echo "$d/calls.log"
}

# dconf AND chown shimmed together, one call log, argv one element per line.
# chown_rc lets the second ownership test simulate the account not existing yet
# (`chown: invalid user`), which is exactly the ordering the function must not
# die on.
make_idle_shims() {  # dir chown_rc -> echoes the call log path
  local d="$1" rc="$2"
  mkdir -p "$d"
  cat > "$d/dconf" <<EOF
#!/usr/bin/env bash
{ echo "== dconf"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
exit 0
EOF
  cat > "$d/chown" <<EOF
#!/usr/bin/env bash
{ echo "== chown"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
[ $rc -eq 0 ] || echo "chown: invalid user: '\$1'" >&2
exit $rc
EOF
  chmod +x "$d/dconf" "$d/chown"
  : > "$d/calls.log"
  echo "$d/calls.log"
}

IDLE_OUT=""
IDLE_RC=0

run_configure() {  # dconf_dir name home shim_dir
  IDLE_OUT="$(DC_DRY_RUN= DC_DCONF_DIR="$1" PATH="$4:$PATH" \
              configure_no_idle_lock "$2" "$3" 2>&1)"
  IDLE_RC=$?
  return 0
}

run_remove() {  # dconf_dir name home shim_dir
  IDLE_OUT="$(DC_DRY_RUN= DC_DCONF_DIR="$1" PATH="$4:$PATH" \
              remove_no_idle_lock "$2" "$3" 2>&1)"
  IDLE_RC=$?
  return 0
}

# A missing function exits 127 having written nothing, which would make every
# "nothing was written" / "the files are gone" assertion below pass vacuously.
require_no_idle_lock() {  # label
  declare -F configure_no_idle_lock >/dev/null \
    && declare -F remove_no_idle_lock >/dev/null && return 0
  fail "$1: configure_no_idle_lock()/remove_no_idle_lock() not defined"
  return 1
}

# Fixture paths for one account, all under $TMP.
idle_fixture() {  # tag -> creates $TMP/<tag>/{dconf,home} and echoes both
  local tag="$1"
  mkdir -p "$TMP/$tag/dconf" "$TMP/$tag/home"
  echo "$TMP/$tag/dconf $TMP/$tag/home"
}

test_library_defines_the_idle_lock_functions() {
  local fn
  for fn in configure_no_idle_lock remove_no_idle_lock; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

# The profile is what points the account's session at our system db; both lines
# matter — dropping user-db:user would make the account's own dconf writes
# unreadable, dropping system-db:<name> would make the db below inert.
test_configure_no_idle_lock_writes_the_dconf_profile() {
  local d home shims body
  require_no_idle_lock "profile file" || return 0
  read -r d home <<<"$(idle_fixture idle-profile)"
  shims="$TMP/shims-idle-profile"; make_dconf_shim "$shims" >/dev/null
  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "configure_no_idle_lock exits 0 for a normal account"
  assert_file_exists "$d/profile/dreamconnect-host" "the dconf profile file is written"
  body="$(cat "$d/profile/dreamconnect-host" 2>/dev/null || true)"
  assert_eq "$body" "user-db:user
system-db:dreamconnect-host" "profile is exactly user-db:user + system-db:<name>"
}

# All seven keys, asserted one at a time so a future edit that drops or retypes
# one fails naming that key. Types come from the installed GNOME schemas:
# lock-delay/idle-delay are "type u" -> uint32, the sleep-inactive-*-type enums
# are strings -> single-quoted, booleans are unquoted.
test_configure_no_idle_lock_writes_all_seven_dconf_keys() {
  local d home shims f body
  require_no_idle_lock "dconf keys" || return 0
  read -r d home <<<"$(idle_fixture idle-keys)"
  shims="$TMP/shims-idle-keys"; make_dconf_shim "$shims" >/dev/null
  run_configure "$d" dreamconnect-host "$home" "$shims"
  f="$d/db/dreamconnect-host.d/00-display-host"
  assert_file_exists "$f" "the dconf system db keyfile is written"
  body="$(cat "$f" 2>/dev/null || true)"

  assert_line "$body" "[org/gnome/desktop/screensaver]" "screensaver section header"
  assert_line "$body" "lock-enabled=false"              "screensaver lock-enabled=false"
  assert_line "$body" "idle-activation-enabled=false"   "screensaver idle-activation-enabled=false"
  assert_line "$body" "lock-delay=uint32 0"             "screensaver lock-delay=uint32 0 (schema type u)"

  assert_line "$body" "[org/gnome/desktop/session]"     "session section header"
  assert_line "$body" "idle-delay=uint32 0"             "session idle-delay=uint32 0 (schema type u)"

  assert_line "$body" "[org/gnome/settings-daemon/plugins/power]" "power section header"
  assert_line "$body" "sleep-inactive-ac-type='nothing'"      "power sleep-inactive-ac-type='nothing'"
  assert_line "$body" "sleep-inactive-battery-type='nothing'" "power sleep-inactive-battery-type='nothing'"
}

# Without DCONF_PROFILE in the account's environment the session loads dconf's
# default profile and everything above is dead weight.
test_configure_no_idle_lock_points_the_session_at_the_profile() {
  local d home shims f
  require_no_idle_lock "environment.d" || return 0
  read -r d home <<<"$(idle_fixture idle-envd)"
  shims="$TMP/shims-idle-envd"; make_dconf_shim "$shims" >/dev/null
  run_configure "$d" dreamconnect-host "$home" "$shims"
  f="$home/.config/environment.d/dconf-profile.conf"
  assert_file_exists "$f" "environment.d drop-in is written (dir created if absent)"
  assert_eq "$(cat "$f" 2>/dev/null || true)" "DCONF_PROFILE=dreamconnect-host" \
    "environment.d drop-in is exactly DCONF_PROFILE=<name>"
}

# Same failure class as the lock screen: something covering the desktop of an
# account nobody is present to click through.
test_configure_no_idle_lock_skips_gnome_initial_setup() {
  local d home shims f
  require_no_idle_lock "initial-setup marker" || return 0
  read -r d home <<<"$(idle_fixture idle-gis)"
  shims="$TMP/shims-idle-gis"; make_dconf_shim "$shims" >/dev/null
  run_configure "$d" dreamconnect-host "$home" "$shims"
  f="$home/.config/gnome-initial-setup-done"
  assert_file_exists "$f" "gnome-initial-setup-done marker is written"
  assert_eq "$(cat "$f" 2>/dev/null || true)" "yes" \
    "gnome-initial-setup-done contains yes"
}

# THE BLAST-RADIUS GUARD. "user" is dconf's own default profile name and "local"
# its conventional system db — both present on this box under /etc/dconf. Writing
# either would disable lock and idle for potentially every user on the machine,
# not just the display-host account. Refuse, and write nothing at all.
test_configure_no_idle_lock_refuses_reserved_dconf_names() {
  local d home shims name entries
  require_no_idle_lock "reserved-name guard" || return 0
  shims="$TMP/shims-idle-reserved"; make_dconf_shim "$shims" >/dev/null
  for name in user local; do
    read -r d home <<<"$(idle_fixture "idle-reserved-$name")"
    run_configure "$d" "$name" "$home" "$shims"
    [ "$IDLE_RC" -ne 127 ] || { fail "reserved name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$IDLE_OUT" "command not found" \
      "reserved name '$name': refusal came from the guard, not the shell"
    [ "$IDLE_RC" -ne 0 ] || fail "reserved name '$name': expected non-zero exit, got $IDLE_RC"
    [ -n "$IDLE_OUT" ] || fail "reserved name '$name': expected a stderr line explaining the refusal"
    assert_file_absent "$d/profile/$name" "reserved name '$name': no dconf profile written"
    assert_file_absent "$d/db/$name.d/00-display-host" "reserved name '$name': no db keyfile written"
    assert_file_absent "$home/.config/environment.d/dconf-profile.conf" \
      "reserved name '$name': no environment.d drop-in written"
    entries="$(find "$d" -type f 2>/dev/null | wc -l)"
    assert_eq "${entries// /}" "0" "reserved name '$name': nothing at all written under DC_DCONF_DIR"
  done
}

# Idempotent = full overwrite. An appending writer gives two [org/gnome/...]
# sections, or a profile with system-db listed twice, and re-running install.sh
# would grow the files without bound.
test_configure_no_idle_lock_is_byte_identical_on_a_second_run() {
  local d home shims snap f
  require_no_idle_lock "double apply" || return 0
  read -r d home <<<"$(idle_fixture idle-twice)"
  shims="$TMP/shims-idle-twice"; make_dconf_shim "$shims" >/dev/null
  snap="$TMP/idle-twice-snap"; mkdir -p "$snap"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  cp "$d/profile/dreamconnect-host" "$snap/profile" 2>/dev/null || true
  cp "$d/db/dreamconnect-host.d/00-display-host" "$snap/db" 2>/dev/null || true
  cp "$home/.config/environment.d/dconf-profile.conf" "$snap/envd" 2>/dev/null || true
  cp "$home/.config/gnome-initial-setup-done" "$snap/gis" 2>/dev/null || true

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "second apply exits 0"
  cmp -s "$snap/profile" "$d/profile/dreamconnect-host" \
    || fail "second apply rewrites the profile byte-identically"
  cmp -s "$snap/db" "$d/db/dreamconnect-host.d/00-display-host" \
    || fail "second apply rewrites the db keyfile byte-identically"
  cmp -s "$snap/envd" "$home/.config/environment.d/dconf-profile.conf" \
    || fail "second apply rewrites the environment.d drop-in byte-identically"
  cmp -s "$snap/gis" "$home/.config/gnome-initial-setup-done" \
    || fail "second apply rewrites the initial-setup marker byte-identically"

  f="$d/db/dreamconnect-host.d/00-display-host"
  assert_eq "$(grep -c '^lock-enabled=false$' "$f" 2>/dev/null || echo 0)" "1" \
    "lock-enabled=false appears exactly once after two applies"
  assert_eq "$(grep -c '^system-db:' "$d/profile/dreamconnect-host" 2>/dev/null || echo 0)" "1" \
    "the profile has exactly one system-db line after two applies"
}

# Issue #18 back-compat clause: "uninstall MUST delete the account and fully
# revert autologin + SystemAccount marker + dconf lock settings."
test_remove_no_idle_lock_reverts_everything_configure_wrote() {
  local d home shims
  require_no_idle_lock "removal" || return 0
  read -r d home <<<"$(idle_fixture idle-remove)"
  shims="$TMP/shims-idle-remove"; make_dconf_shim "$shims" >/dev/null
  : > "$home/.config-sentinel" 2>/dev/null || true

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_file_exists "$d/profile/dreamconnect-host" "precondition: configured"

  # Another drop-in in the same directory: removal takes our file, not the dir.
  printf 'FOO=bar\n' > "$home/.config/environment.d/zz-other.conf"

  run_remove "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "remove_no_idle_lock exits 0"
  assert_file_absent "$d/profile/dreamconnect-host" "profile file removed"
  assert_file_absent "$d/db/dreamconnect-host.d/00-display-host" "db keyfile removed"
  assert_file_absent "$d/db/dreamconnect-host.d" "the now-empty <name>.d directory is removed"
  assert_file_absent "$home/.config/environment.d/dconf-profile.conf" \
    "environment.d drop-in removed"
  assert_file_absent "$home/.config/gnome-initial-setup-done" "initial-setup marker removed"
  assert_file_exists "$home/.config/environment.d/zz-other.conf" \
    "an unrelated environment.d drop-in survives (the directory is not deleted)"
}

# --uninstall runs on boxes where the opt-in was never used. Nothing configured
# must be a silent success, not a pile of "No such file or directory".
test_remove_no_idle_lock_is_a_no_op_when_nothing_was_configured() {
  local d home shims entries
  require_no_idle_lock "removal no-op" || return 0
  read -r d home <<<"$(idle_fixture idle-remove-noop)"
  shims="$TMP/shims-idle-noop"; make_dconf_shim "$shims" >/dev/null
  run_remove "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "remove on a never-configured box exits 0"
  assert_not_contains "$IDLE_OUT" "No such file" "remove on a never-configured box is quiet"
  entries="$(find "$d" -type f 2>/dev/null | wc -l)"
  assert_eq "${entries// /}" "0" "remove on a never-configured box creates nothing"
}

# The dry-run boundary, pinned in both directions: `dconf update` is the ONLY
# thing behind run(), so DC_DRY_RUN=1 must announce it and must not execute the
# binary — while the four fixture-path file writes still happen for real.
test_configure_no_idle_lock_gates_only_dconf_update_behind_run() {
  local d home shims log out
  require_no_idle_lock "dry-run boundary" || return 0
  read -r d home <<<"$(idle_fixture idle-dry)"
  shims="$TMP/shims-idle-dry"; log="$(make_dconf_shim "$shims")"

  out="$(DC_DRY_RUN=1 DC_DCONF_DIR="$d" PATH="$shims:$PATH" \
         configure_no_idle_lock dreamconnect-host "$home" 2>&1)"
  assert_contains "$out" "DRY: dconf update" "dry run announces the dconf update it skipped"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "dry run does not execute the dconf binary"
  assert_file_exists "$d/profile/dreamconnect-host" \
    "dry run still writes the profile (only dconf update is gated)"
  assert_file_exists "$d/db/dreamconnect-host.d/00-display-host" \
    "dry run still writes the db keyfile (only dconf update is gated)"
  assert_file_exists "$home/.config/environment.d/dconf-profile.conf" \
    "dry run still writes the environment.d drop-in"
  assert_file_exists "$home/.config/gnome-initial-setup-done" \
    "dry run still writes the initial-setup marker"

  out="$(DC_DRY_RUN=1 DC_DCONF_DIR="$d" PATH="$shims:$PATH" \
         remove_no_idle_lock dreamconnect-host "$home" 2>&1)"
  assert_contains "$out" "DRY: dconf update" "removal recompiles the db too (announced when dry)"
}

# Ownership: the two files inside <home> become the account's, by the same
# `chown "<name>:" <path>` form install.sh already uses for the user unit. The
# /etc/dconf files stay root-owned — a chown naming them would be a bug, and the
# shim log is the only place that is observable.
test_configure_no_idle_lock_chowns_the_home_files_to_the_account() {
  local d home shims log calls
  require_no_idle_lock "chown home files" || return 0
  read -r d home <<<"$(idle_fixture idle-chown)"
  shims="$TMP/shims-idle-chown"; log="$(make_idle_shims "$shims" 0)"
  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "configure exits 0 with chown shimmed"
  calls="$(cat "$log" 2>/dev/null || true)"

  assert_line "$calls" "== chown" "chown is invoked at all"
  assert_line "$calls" "[dreamconnect-host:]" \
    "chown targets <name>: as ONE argv element — the account and its primary group, as install.sh does"
  assert_line "$calls" "[$home/.config/environment.d/dconf-profile.conf]" \
    "the environment.d drop-in is chowned to the account"
  assert_line "$calls" "[$home/.config/gnome-initial-setup-done]" \
    "the initial-setup marker is chowned to the account"
  assert_line "$calls" "[$home/.config]" \
    "the .config directory it created is chowned to the account"
  assert_line "$calls" "[$home/.config/environment.d]" \
    "the environment.d directory it created is chowned to the account"

  assert_not_contains "$calls" "$d/profile" \
    "the dconf profile in /etc is NOT chowned (stays root-owned)"
  assert_not_contains "$calls" "$d/db" \
    "the dconf db keyfile in /etc is NOT chowned (stays root-owned)"
}

# A chown that fails (the account does not exist yet — nothing in this function
# enforces ensure_host_account having run first) must not cost us the dconf
# configuration. Warn, continue, exit 0, all four files still written.
test_configure_no_idle_lock_survives_a_failing_chown() {
  local d home shims log
  require_no_idle_lock "chown failure is not fatal" || return 0
  read -r d home <<<"$(idle_fixture idle-chown-fail)"
  shims="$TMP/shims-idle-chown-fail"; log="$(make_idle_shims "$shims" 1)"
  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "a failing chown does not fail configure_no_idle_lock"
  assert_line "$(cat "$log" 2>/dev/null || true)" "== chown" \
    "precondition: chown really was attempted and really did fail"
  assert_file_exists "$d/profile/dreamconnect-host" \
    "failing chown: the dconf profile is still written"
  assert_file_exists "$d/db/dreamconnect-host.d/00-display-host" \
    "failing chown: the db keyfile is still written"
  assert_file_exists "$home/.config/environment.d/dconf-profile.conf" \
    "failing chown: the environment.d drop-in is still written"
  assert_file_exists "$home/.config/gnome-initial-setup-done" \
    "failing chown: the initial-setup marker is still written"
  assert_contains "$(cat "$log" 2>/dev/null || true)" "$home/.config" \
    "failing chown: it did not stop after the first failure"
}

# --- breaker pass 2, defect #1: the two HOME files are clobbered without backup -
#
# WHY THESE TESTS EXIST. DREAMCONNECT_HOST_ACCOUNT may name an account that
# already exists and belongs to a human — ensure_host_account is built around
# exactly that possibility ("it may be a human's ... re-running install.sh must
# not disable their password or restamp their GECOS") and already backs the
# AccountsService file up once to <path>.dreamconnect.bak before overwriting it,
# with remove_accountsservice_marker giving it back on uninstall.
#
# configure_no_idle_lock writes two files inside that same human's home —
# <home>/.config/environment.d/dconf-profile.conf and
# <home>/.config/gnome-initial-setup-done — and does neither. It overwrites
# whatever is there, and remove_no_idle_lock then `rm -f`s both outright, so a
# pre-existing DCONF_PROFILE (pointing that account's session at ITS own dconf
# profile) is destroyed permanently by an install/uninstall cycle.
#
# CONTRACT UNDER TEST — the same one already stated for the AccountsService file
# in install-lib.sh's ensure_host_account/remove_accountsservice_marker comments,
# applied to each of these two files INDEPENDENTLY (they are separate files that
# may exist separately, so each gets its own .dreamconnect.bak sibling):
#
#   configure: before overwriting the file, if it exists AND no
#   <path>.dreamconnect.bak exists yet, back it up (cp -a). "Backs up once" — a
#   re-run must never copy OUR content over the original, and a file that was not
#   there gets no backup at all.
#
#   remove: .bak present -> restore it to the real path (and the .bak is
#   consumed); else file present -> remove it (we created it); else no-op.
#
# Everything else is unchanged and keeps its own tests above: the two /etc/dconf
# files, the <name>.d directory removal, the reserved-name and malformed-name
# guards.
#
# Expected values come from that contract, not from any implementation of it:
# the .dreamconnect.bak suffix and the once-only rule are fixed by the sibling
# functions; our own file contents (DCONF_PROFILE=<name>, "yes") are already
# pinned by the slice-5 tests above.

# What a human account's two files look like before dreamconnect ever runs. The
# contents are sentinels chosen to be distinguishable from ours — the property
# under test is "whatever bytes were there are preserved", and a fixture that
# happened to match our own output could not observe it.
plant_preexisting_home_files() {  # home
  local home="$1"
  mkdir -p "$home/.config/environment.d"
  printf 'DCONF_PROFILE=alice-custom\n' > "$home/.config/environment.d/dconf-profile.conf"
  printf 'already-done-by-the-human\n'  > "$home/.config/gnome-initial-setup-done"
}

# Case (a) for both files: the account already had content in each. Overwriting
# is unavoidable (DCONF_PROFILE=<name> is what makes our db apply), destroying it
# is not.
test_configure_no_idle_lock_backs_up_preexisting_home_files() {
  local d home shims envf gisf orig_env orig_gis
  require_no_idle_lock "backs up pre-existing home files" || return 0
  read -r d home <<<"$(idle_fixture idle-bak-existing)"
  shims="$TMP/shims-idle-bak-existing"; make_dconf_shim "$shims" >/dev/null
  envf="$home/.config/environment.d/dconf-profile.conf"
  gisf="$home/.config/gnome-initial-setup-done"
  orig_env="$TMP/idle-bak-existing-env-orig"; orig_gis="$TMP/idle-bak-existing-gis-orig"

  plant_preexisting_home_files "$home"
  cp "$envf" "$orig_env"; cp "$gisf" "$orig_gis"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "configure over a human's home exits 0 (stderr: $IDLE_OUT)"

  assert_file_exists "$envf.dreamconnect.bak" \
    "a pre-existing environment.d drop-in is backed up to <path>.dreamconnect.bak"
  cmp -s "$orig_env" "$envf.dreamconnect.bak" \
    || fail "the environment.d backup holds the ORIGINAL content byte-for-byte"
  assert_file_exists "$gisf.dreamconnect.bak" \
    "a pre-existing gnome-initial-setup-done is backed up to <path>.dreamconnect.bak"
  cmp -s "$orig_gis" "$gisf.dreamconnect.bak" \
    || fail "the initial-setup backup holds the ORIGINAL content byte-for-byte"

  assert_eq "$(cat "$envf" 2>/dev/null || true)" "DCONF_PROFILE=dreamconnect-host" \
    "the live environment.d drop-in is ours, a full overwrite"
  assert_eq "$(cat "$gisf" 2>/dev/null || true)" "yes" \
    "the live initial-setup marker is ours, a full overwrite"
}

# Case (b): nothing was there, so there is nothing to preserve. A backup here
# would be restored over the top on uninstall instead of the files being removed.
# (Slice 5's tests already pin the contents; this one pins the ABSENCE of .bak.)
test_configure_no_idle_lock_writes_no_backups_for_fresh_home_files() {
  local d home shims envf gisf
  require_no_idle_lock "no backup for fresh home files" || return 0
  read -r d home <<<"$(idle_fixture idle-bak-fresh)"
  shims="$TMP/shims-idle-bak-fresh"; make_dconf_shim "$shims" >/dev/null
  envf="$home/.config/environment.d/dconf-profile.conf"
  gisf="$home/.config/gnome-initial-setup-done"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "configure on an empty home exits 0 (stderr: $IDLE_OUT)"
  assert_eq "$(cat "$envf" 2>/dev/null || true)" "DCONF_PROFILE=dreamconnect-host" \
    "fresh home: the environment.d drop-in is written"
  assert_eq "$(cat "$gisf" 2>/dev/null || true)" "yes" \
    "fresh home: the initial-setup marker is written"
  assert_file_absent "$envf.dreamconnect.bak" \
    "fresh home: no environment.d backup is created"
  assert_file_absent "$gisf.dreamconnect.bak" \
    "fresh home: no initial-setup backup is created"
  assert_eq "$(ls -A "$home/.config/environment.d" | wc -l | tr -d ' ')" "1" \
    "fresh home: exactly the drop-in in environment.d, no residue"
}

# "Backs up once", the rule ensure_host_account and enable_autologin both state.
# A second install run must not re-back-up the file WE wrote over the original —
# that loses the very content the backup exists to hold.
test_configure_no_idle_lock_backs_up_home_files_only_once_across_reruns() {
  local d home shims envf gisf orig_env orig_gis
  require_no_idle_lock "home files backed up once" || return 0
  read -r d home <<<"$(idle_fixture idle-bak-twice)"
  shims="$TMP/shims-idle-bak-twice"; make_dconf_shim "$shims" >/dev/null
  envf="$home/.config/environment.d/dconf-profile.conf"
  gisf="$home/.config/gnome-initial-setup-done"
  orig_env="$TMP/idle-bak-twice-env-orig"; orig_gis="$TMP/idle-bak-twice-gis-orig"

  plant_preexisting_home_files "$home"
  cp "$envf" "$orig_env"; cp "$gisf" "$orig_gis"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  run_configure "$d" dreamconnect-host "$home" "$shims"
  run_configure "$d" dreamconnect-host "$home" "$shims"

  cmp -s "$orig_env" "$envf.dreamconnect.bak" \
    || fail "after three runs the environment.d backup STILL holds the original, not ours"
  assert_not_contains "$(cat "$envf.dreamconnect.bak" 2>/dev/null || true)" \
    "DCONF_PROFILE=dreamconnect-host" "our own drop-in was never backed up over the original"
  cmp -s "$orig_gis" "$gisf.dreamconnect.bak" \
    || fail "after three runs the initial-setup backup STILL holds the original, not ours"
  assert_file_absent "$envf.dreamconnect.bak.dreamconnect.bak" \
    "no backup of the environment.d backup is created"
  assert_file_absent "$gisf.dreamconnect.bak.dreamconnect.bak" \
    "no backup of the initial-setup backup is created"
  assert_eq "$(ls -A "$home/.config/environment.d" | wc -l | tr -d ' ')" "2" \
    "three runs leave exactly the drop-in and one backup in environment.d"
}

# The uninstall half of case (a): a backup means the account had these files
# before we clobbered them, and --uninstall owes them back rather than deleting
# them — which is what the bare `rm -f` does today.
test_remove_no_idle_lock_restores_backed_up_home_files() {
  local d home shims envf gisf orig_env orig_gis
  require_no_idle_lock "restores backed-up home files" || return 0
  read -r d home <<<"$(idle_fixture idle-bak-restore)"
  shims="$TMP/shims-idle-bak-restore"; make_dconf_shim "$shims" >/dev/null
  envf="$home/.config/environment.d/dconf-profile.conf"
  gisf="$home/.config/gnome-initial-setup-done"
  orig_env="$TMP/idle-bak-restore-env-orig"; orig_gis="$TMP/idle-bak-restore-gis-orig"

  plant_preexisting_home_files "$home"
  cp "$envf" "$orig_env"; cp "$gisf" "$orig_gis"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  run_remove    "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "remove after a clobber exits 0 (stderr: $IDLE_OUT)"

  assert_file_exists "$envf" "the human's environment.d drop-in exists after uninstall"
  cmp -s "$orig_env" "$envf" \
    || fail "the human's DCONF_PROFILE is restored byte-for-byte"
  assert_file_exists "$gisf" "the human's initial-setup marker exists after uninstall"
  cmp -s "$orig_gis" "$gisf" \
    || fail "the human's initial-setup marker is restored byte-for-byte"
  assert_file_absent "$envf.dreamconnect.bak" \
    "the environment.d backup is consumed, not left lying around"
  assert_file_absent "$gisf.dreamconnect.bak" \
    "the initial-setup backup is consumed, not left lying around"
  assert_eq "$(ls -A "$home/.config/environment.d" | wc -l | tr -d ' ')" "1" \
    "exactly the restored drop-in remains in environment.d"
}

# The uninstall half of case (b), stated in backup terms: no .bak means we made
# the files, so removal leaves the home as it was — today's behaviour, kept, plus
# the assertion that no backup residue is invented on the way.
test_remove_no_idle_lock_removes_fresh_home_files_it_created() {
  local d home shims envf gisf
  require_no_idle_lock "removes fresh home files" || return 0
  read -r d home <<<"$(idle_fixture idle-bak-remove-fresh)"
  shims="$TMP/shims-idle-bak-remove-fresh"; make_dconf_shim "$shims" >/dev/null
  envf="$home/.config/environment.d/dconf-profile.conf"
  gisf="$home/.config/gnome-initial-setup-done"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_file_exists "$envf" "precondition: configured a fresh home"
  run_remove "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "remove after a fresh configure exits 0 (stderr: $IDLE_OUT)"

  assert_file_absent "$envf" "a drop-in we created with nothing behind it is removed"
  assert_file_absent "$gisf" "a marker we created with nothing behind it is removed"
  assert_file_absent "$envf.dreamconnect.bak" "no environment.d backup residue"
  assert_file_absent "$gisf.dreamconnect.bak" "no initial-setup backup residue"
  assert_file_exists "$home/.config/environment.d" \
    "the environment.d directory itself is not deleted"
  assert_eq "$(ls -A "$home/.config/environment.d" | wc -l | tr -d ' ')" "0" \
    "nothing of ours is left in environment.d"
}

# The two files are independent: a human may well have a DCONF_PROFILE drop-in
# and no initial-setup marker (or the reverse). One shared "did anything exist?"
# flag would restore a file that never existed, or delete one that did.
test_no_idle_lock_backs_up_each_home_file_independently() {
  local d home shims envf gisf orig_env
  require_no_idle_lock "independent per-file backups" || return 0
  read -r d home <<<"$(idle_fixture idle-bak-mixed)"
  shims="$TMP/shims-idle-bak-mixed"; make_dconf_shim "$shims" >/dev/null
  envf="$home/.config/environment.d/dconf-profile.conf"
  gisf="$home/.config/gnome-initial-setup-done"
  orig_env="$TMP/idle-bak-mixed-env-orig"

  # Only the environment.d drop-in pre-exists.
  mkdir -p "$home/.config/environment.d"
  printf 'DCONF_PROFILE=alice-custom\n' > "$envf"
  cp "$envf" "$orig_env"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_file_exists "$envf.dreamconnect.bak" "mixed: the file that existed is backed up"
  cmp -s "$orig_env" "$envf.dreamconnect.bak" \
    || fail "mixed: the environment.d backup holds the original"
  assert_file_absent "$gisf.dreamconnect.bak" \
    "mixed: the file that did NOT exist gets no backup"

  run_remove "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "mixed: remove exits 0 (stderr: $IDLE_OUT)"
  cmp -s "$orig_env" "$envf" \
    || fail "mixed: the pre-existing drop-in is restored, not deleted"
  assert_file_absent "$gisf" "mixed: the marker we created is deleted, not restored"
  assert_file_absent "$envf.dreamconnect.bak" "mixed: no backup residue"
}

# --- breaker pass 3: the two dconf SYSTEM files are clobbered without backup ---
#
# WHY THESE TESTS EXIST. Same defect class as the AccountsService marker and the
# two home files, one seam further out. configure_no_idle_lock writes
#   ${DC_DCONF_DIR:-/etc/dconf}/profile/<name>
#   ${DC_DCONF_DIR:-/etc/dconf}/db/<name>.d/00-display-host
# as full overwrites with no backup, and remove_no_idle_lock `rm -f`s both. If a
# dconf profile or system db already exists under that exact name — DREAMCONNECT_
# HOST_ACCOUNT pointed at an account whose name was already used for a hand-rolled
# dconf profile, e.g. a "corp-lockdown" policy db — an install/uninstall cycle
# destroys it permanently, and the box silently loses the policy it had.
#
# CONTRACT UNDER TEST — the SAME contract already stated in install-lib.sh for
# ensure_host_account/remove_accountsservice_marker and for the two home files,
# applied to these two files INDEPENDENTLY (separate files, separate .bak
# siblings):
#
#   configure: before overwriting each file, if it EXISTS and no backup exists
#   yet, back it up (cp -a). Backs up ONCE — a re-run must never copy OUR content
#   over the original. A file that was not there gets no backup at all. Additive
#   only: the reserved-name and malformed-name guards still refuse before
#   anything is created or copied.
#
#   remove: the backup present -> restore it to the real path and consume it;
#   else the file present -> remove it (we created it); else no-op.
#
#   WHERE EACH BACKUP LIVES, and why they differ (coordinator decision):
#     * profile:  "$dir/profile/<name>.dreamconnect.bak" — a plain file beside
#       other plain files in a directory dconf does not scan as a unit.
#     * keyfile:  "$dir/db/<name>.d.dreamconnect.bak" — NEXT TO the <name>.d
#       directory, NOT inside it. dconf compiles EVERY regular file in a
#       <name>.d directory as a keyfile fragment, with no extension filtering
#       (unlike sysctl.d's .conf convention), so a backup left inside would be
#       compiled by `dconf update` — applying the very settings the install is
#       meant to override, or failing compilation outright. A backup that
#       introduces a new bug is not a backup. Hence the assertion below, in every
#       configure test, that <name>.d contains EXACTLY "00-display-host" and
#       nothing else: that is the property, not merely "the backup is called
#       something else".
#
#   THE DIRECTORY INTERACTION, re-traced for the new location.
#   remove_no_idle_lock also does `rmdir "$dir/db/<name>.d" 2>/dev/null || true`.
#   That must NOT take the directory away when the keyfile was RESTORED — a
#   policy db without its keyfile is not a restoration. The backup now arrives
#   from OUTSIDE the directory, so the restore is a move back IN: afterwards the
#   directory holds the restored keyfile and is non-empty, and the rmdir fails
#   harmlessly exactly as before. The reasoning holds, with one added ordering
#   requirement: restore BEFORE the rmdir, and into a directory that still
#   exists — an rmdir that fired first would leave the mv creating a plain FILE
#   named <name>.d where a directory belongs. The assertions are on the OUTCOME
#   (directory present, original keyfile inside it, no backup residue), so any
#   ordering or explicit guard achieving it passes. When the keyfile was ours and
#   is removed, the now-empty directory still goes, as it does today.
#
# Expected values come from that contract and from the slice-5 tests that already
# pin our own file contents — not from any implementation of the backup, which
# does not exist yet.

# What a box that already had a dconf profile/db of this name looks like. The
# sentinels are deliberately unlike ours: the property under test is "whatever
# bytes were there are preserved", which a fixture matching our output could not
# observe.
plant_preexisting_dconf_system_files() {  # dconf_dir name
  local d="$1" name="$2"
  mkdir -p "$d/profile" "$d/db/$name.d"
  printf 'user-db:user\nsystem-db:corp-lockdown\n' > "$d/profile/$name"
  printf '[org/gnome/desktop/screensaver]\nlock-enabled=true\nlock-delay=uint32 30\n' \
    > "$d/db/$name.d/00-display-host"
}

# Case (a) for both /etc/dconf files: something was already there under this
# name. Overwriting is unavoidable (the db is what disables the idle lock),
# destroying it is not.
test_configure_no_idle_lock_backs_up_preexisting_dconf_system_files() {
  local d home shims prof key keybak orig_prof orig_key
  require_no_idle_lock "backs up pre-existing dconf system files" || return 0
  read -r d home <<<"$(idle_fixture idle-dcbak-existing)"
  shims="$TMP/shims-idle-dcbak-existing"; make_dconf_shim "$shims" >/dev/null
  prof="$d/profile/dreamconnect-host"
  key="$d/db/dreamconnect-host.d/00-display-host"
  keybak="$d/db/dreamconnect-host.d.dreamconnect.bak"
  orig_prof="$TMP/idle-dcbak-existing-prof-orig"; orig_key="$TMP/idle-dcbak-existing-key-orig"

  plant_preexisting_dconf_system_files "$d" dreamconnect-host
  cp "$prof" "$orig_prof"; cp "$key" "$orig_key"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "configure over an existing dconf profile exits 0 (stderr: $IDLE_OUT)"

  assert_file_exists "$prof.dreamconnect.bak" \
    "a pre-existing dconf profile is backed up to <path>.dreamconnect.bak"
  cmp -s "$orig_prof" "$prof.dreamconnect.bak" \
    || fail "the dconf profile backup holds the ORIGINAL content byte-for-byte"
  assert_file_exists "$keybak" \
    "a pre-existing db keyfile is backed up to db/<name>.d.dreamconnect.bak, BESIDE the directory"
  cmp -s "$orig_key" "$keybak" \
    || fail "the db keyfile backup holds the ORIGINAL content byte-for-byte"

  # The dconf-compilation property: <name>.d is scanned whole, so anything in it
  # other than our keyfile gets compiled by `dconf update`.
  assert_eq "$(ls -A "$d/db/dreamconnect-host.d" | tr '\n' ' ')" "00-display-host " \
    "<name>.d holds ONLY the live keyfile — no backup inside a directory dconf compiles"

  assert_eq "$(cat "$prof" 2>/dev/null || true)" "user-db:user
system-db:dreamconnect-host" "the live dconf profile is ours, a full overwrite"
  assert_line "$(cat "$key" 2>/dev/null || true)" "lock-enabled=false" \
    "the live db keyfile is ours, a full overwrite"
}

# Case (b): nothing was there, so there is nothing to preserve. A backup here
# would be restored over the top on uninstall instead of the files being removed.
test_configure_no_idle_lock_writes_no_backups_for_fresh_dconf_system_files() {
  local d home shims prof key keybak
  require_no_idle_lock "no backup for fresh dconf system files" || return 0
  read -r d home <<<"$(idle_fixture idle-dcbak-fresh)"
  shims="$TMP/shims-idle-dcbak-fresh"; make_dconf_shim "$shims" >/dev/null
  prof="$d/profile/dreamconnect-host"
  key="$d/db/dreamconnect-host.d/00-display-host"
  keybak="$d/db/dreamconnect-host.d.dreamconnect.bak"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "configure on an empty /etc/dconf exits 0 (stderr: $IDLE_OUT)"
  assert_file_exists "$prof" "fresh dconf: the profile is written"
  assert_file_exists "$key"  "fresh dconf: the db keyfile is written"
  assert_file_absent "$prof.dreamconnect.bak" "fresh dconf: no profile backup is created"
  assert_file_absent "$keybak" "fresh dconf: no keyfile backup is created beside <name>.d"
  assert_file_absent "$key.dreamconnect.bak" \
    "fresh dconf: and none inside <name>.d either"
  assert_eq "$(ls -A "$d/db/dreamconnect-host.d" | tr '\n' ' ')" "00-display-host " \
    "fresh dconf: <name>.d holds ONLY the live keyfile"
}

# "Backs up once". A second install run must not re-back-up the files WE wrote
# over the originals — that loses the very content the backup exists to hold.
test_configure_no_idle_lock_backs_up_dconf_system_files_only_once_across_reruns() {
  local d home shims prof key keybak orig_prof orig_key
  require_no_idle_lock "dconf system files backed up once" || return 0
  read -r d home <<<"$(idle_fixture idle-dcbak-twice)"
  shims="$TMP/shims-idle-dcbak-twice"; make_dconf_shim "$shims" >/dev/null
  prof="$d/profile/dreamconnect-host"
  key="$d/db/dreamconnect-host.d/00-display-host"
  keybak="$d/db/dreamconnect-host.d.dreamconnect.bak"
  orig_prof="$TMP/idle-dcbak-twice-prof-orig"; orig_key="$TMP/idle-dcbak-twice-key-orig"

  plant_preexisting_dconf_system_files "$d" dreamconnect-host
  cp "$prof" "$orig_prof"; cp "$key" "$orig_key"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  run_configure "$d" dreamconnect-host "$home" "$shims"
  run_configure "$d" dreamconnect-host "$home" "$shims"

  cmp -s "$orig_prof" "$prof.dreamconnect.bak" \
    || fail "after three runs the dconf profile backup STILL holds the original, not ours"
  assert_not_contains "$(cat "$prof.dreamconnect.bak" 2>/dev/null || true)" \
    "system-db:dreamconnect-host" "our own profile was never backed up over the original"
  cmp -s "$orig_key" "$keybak" \
    || fail "after three runs the db keyfile backup STILL holds the original, not ours"
  assert_not_contains "$(cat "$keybak" 2>/dev/null || true)" \
    "lock-enabled=false" "our own keyfile was never backed up over the original"
  assert_file_absent "$prof.dreamconnect.bak.dreamconnect.bak" \
    "no backup of the profile backup is created"
  assert_file_absent "$keybak.dreamconnect.bak" \
    "no backup of the keyfile backup is created"
  assert_eq "$(ls -A "$d/db/dreamconnect-host.d" | tr '\n' ' ')" "00-display-host " \
    "three runs still leave ONLY the live keyfile in <name>.d — the backup is outside it"
}

# The uninstall half of case (a): a backup means the box had these files before
# we clobbered them, and --uninstall owes them back rather than deleting them.
# And the directory interaction: a restored keyfile must still be THERE, so the
# <name>.d directory survives with the original keyfile inside it.
test_remove_no_idle_lock_restores_backed_up_dconf_system_files() {
  local d home shims prof key keybak orig_prof orig_key
  require_no_idle_lock "restores backed-up dconf system files" || return 0
  read -r d home <<<"$(idle_fixture idle-dcbak-restore)"
  shims="$TMP/shims-idle-dcbak-restore"; make_dconf_shim "$shims" >/dev/null
  prof="$d/profile/dreamconnect-host"
  key="$d/db/dreamconnect-host.d/00-display-host"
  keybak="$d/db/dreamconnect-host.d.dreamconnect.bak"
  orig_prof="$TMP/idle-dcbak-restore-prof-orig"; orig_key="$TMP/idle-dcbak-restore-key-orig"

  plant_preexisting_dconf_system_files "$d" dreamconnect-host
  cp "$prof" "$orig_prof"; cp "$key" "$orig_key"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  run_remove    "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "remove after a dconf clobber exits 0 (stderr: $IDLE_OUT)"

  assert_file_exists "$prof" "the box's own dconf profile exists after uninstall"
  cmp -s "$orig_prof" "$prof" || fail "the box's dconf profile is restored byte-for-byte"
  assert_file_exists "$key" "the box's own db keyfile exists after uninstall"
  cmp -s "$orig_key" "$key" || fail "the box's db keyfile is restored byte-for-byte"
  # The directory must survive the rmdir precisely BECAUSE the keyfile was moved
  # back into it: restore first, rmdir second, rmdir fails harmlessly.
  [ -d "$d/db/dreamconnect-host.d" ] || \
    fail "the <name>.d DIRECTORY is NOT removed when the keyfile was restored into it (and is still a directory)"
  assert_file_absent "$prof.dreamconnect.bak" \
    "the profile backup is consumed, not left lying around"
  assert_file_absent "$keybak" \
    "the keyfile backup beside <name>.d is consumed, not left lying around"
  assert_eq "$(ls -A "$d/db/dreamconnect-host.d" | tr '\n' ' ')" "00-display-host " \
    "exactly the restored keyfile remains in <name>.d, nothing else"
}

# The uninstall half of case (b), stated in backup terms: no .bak means we made
# the files, so removal leaves /etc/dconf as it was — today's behaviour, kept,
# including taking the now-empty <name>.d directory with it.
test_remove_no_idle_lock_removes_fresh_dconf_system_files_it_created() {
  local d home shims prof key keybak
  require_no_idle_lock "removes fresh dconf system files" || return 0
  read -r d home <<<"$(idle_fixture idle-dcbak-remove-fresh)"
  shims="$TMP/shims-idle-dcbak-remove-fresh"; make_dconf_shim "$shims" >/dev/null
  prof="$d/profile/dreamconnect-host"
  key="$d/db/dreamconnect-host.d/00-display-host"
  keybak="$d/db/dreamconnect-host.d.dreamconnect.bak"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_file_exists "$prof" "precondition: configured a fresh /etc/dconf"
  run_remove "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "remove after a fresh dconf configure exits 0 (stderr: $IDLE_OUT)"

  assert_file_absent "$prof" "a profile we created with nothing behind it is removed"
  assert_file_absent "$key"  "a keyfile we created with nothing behind it is removed"
  assert_file_absent "$d/db/dreamconnect-host.d" \
    "the now-empty <name>.d directory is removed, as it is today"
  assert_file_absent "$prof.dreamconnect.bak" "no profile backup residue"
  assert_file_absent "$keybak" "no keyfile backup residue beside <name>.d"
}

# The two /etc/dconf files are independent: a box may have a profile of this name
# with no db of its own, or a db directory with no profile. One shared "did
# anything exist?" flag would restore a file that never existed, or delete one
# that did — and would get the directory decision wrong with it.
test_no_idle_lock_backs_up_each_dconf_system_file_independently() {
  local d home shims prof key keybak orig_prof
  require_no_idle_lock "independent per-file dconf backups" || return 0
  read -r d home <<<"$(idle_fixture idle-dcbak-mixed)"
  shims="$TMP/shims-idle-dcbak-mixed"; make_dconf_shim "$shims" >/dev/null
  prof="$d/profile/dreamconnect-host"
  key="$d/db/dreamconnect-host.d/00-display-host"
  keybak="$d/db/dreamconnect-host.d.dreamconnect.bak"
  orig_prof="$TMP/idle-dcbak-mixed-prof-orig"

  # Only the profile pre-exists; there is no db of this name at all.
  mkdir -p "$d/profile"
  printf 'user-db:user\nsystem-db:corp-lockdown\n' > "$prof"
  cp "$prof" "$orig_prof"

  run_configure "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "mixed dconf: configure exits 0 (stderr: $IDLE_OUT)"
  assert_file_exists "$prof.dreamconnect.bak" "mixed dconf: the file that existed is backed up"
  cmp -s "$orig_prof" "$prof.dreamconnect.bak" \
    || fail "mixed dconf: the profile backup holds the original"
  assert_file_absent "$keybak" \
    "mixed dconf: the keyfile that did NOT exist gets no backup beside <name>.d"
  assert_eq "$(ls -A "$d/db/dreamconnect-host.d" | tr '\n' ' ')" "00-display-host " \
    "mixed dconf: <name>.d holds ONLY the live keyfile"

  run_remove "$d" dreamconnect-host "$home" "$shims"
  assert_eq "$IDLE_RC" "0" "mixed dconf: remove exits 0 (stderr: $IDLE_OUT)"
  cmp -s "$orig_prof" "$prof" \
    || fail "mixed dconf: the pre-existing profile is restored, not deleted"
  assert_file_absent "$key" "mixed dconf: the keyfile we created is deleted, not restored"
  assert_file_absent "$d/db/dreamconnect-host.d" \
    "mixed dconf: the <name>.d directory we created goes with our keyfile"
  assert_file_absent "$prof.dreamconnect.bak" "mixed dconf: no backup residue"
}

# --- slice 6a: uninstall_host_account + the removal-side reserved-name guard ---
#
# WHY THIS SLICE EXISTS. Issue #18: "Creating a local account + autologin is
# high-risk: uninstall MUST delete the account and fully revert." Slice 3 built
# the six-rail gate that decides IF an account may be deleted;
# uninstall_host_account is the call that actually deletes it. It is the only
# place in this installer that runs `userdel -r`, so the gate and the deletion
# are tested together: the gate refusing must mean nothing destructive ran, not
# merely that a message was printed.
#
# CONTRACT UNDER TEST — the implementation follows this, not the reverse. No
# implementation of uninstall_host_account exists at the time these tests were
# written; the expected values are the coordinator's contract for slice 6a plus
# systemd's own subcommand names (`loginctl disable-linger` / `terminate-user`,
# loginctl(1)) and shadow-utils' `userdel -r`.
#
#   uninstall_host_account <name> <protected_user>
#
#   1. FIRST calls host_account_removable <name> <protected_user> (slice 3,
#      already implemented — not reimplemented here, and not bypassed). If it
#      refuses (non-zero), uninstall_host_account returns non-zero IMMEDIATELY
#      and runs NOTHING destructive: no loginctl, no userdel, not even an
#      attempt. Relaying the gate's stderr or adding its own line is the
#      builder's choice; the tests assert "nothing destructive ran", never the
#      wording.
#
#   2. If the gate allows it, run these three, IN THIS ORDER, every one THROUGH
#      run() so DC_DRY_RUN=1 makes all three observable-but-not-real:
#         a. loginctl disable-linger <name>
#         b. loginctl terminate-user <name>
#         c. userdel -r <name>
#      Linger must be dropped before the user is terminated, or systemd brings
#      the account's manager straight back up; the account must be terminated
#      before userdel, or its still-running session holds files open.
#
#   3. EXIT STATUS — which failures are swallowed and which are reported. Issue
#      #18 says "uninstall MUST delete the account and fully revert", so the
#      caller has to be able to tell a completed deletion from a failed one.
#      Corrected after the first pass of this contract said "returns 0 after
#      attempting all three", which made a failed `userdel` indistinguishable
#      from a successful one:
#
#        * `loginctl terminate-user` failing is NOT an error and is SUPPRESSED.
#          It fails whenever the account has no active session — the common case
#          on a box rebooted since install. `userdel -r` still runs after it.
#        * `loginctl disable-linger` failing is likewise SUPPRESSED (explicit
#          choice): an account that never had linger enabled — a fresh install
#          that failed part-way, or one where the opt-in was never used — makes
#          this call fail harmlessly, and refusing to delete the account over it
#          would leave exactly the leaked account this slice exists to prevent.
#        * `userdel -r` failing DOES propagate: its exit status becomes
#          uninstall_host_account's own. userdel is the deletion; if it failed,
#          the account is still there and the caller must not be told otherwise.
#
#      So: no unconditional `return 0` at the end. Suppress the two loginctl
#      calls individually (`|| true` binds to one line only), and let `run
#      userdel -r "$name"` be the last statement, whose status bash then takes as
#      the function's. run() itself is transparent to this: it either execs "$@"
#      (real status) or echoes (0, which is right for a dry run).
#
#   4. Returns 0 when the deletion succeeded, after attempting all three.
#
#   Invoke loginctl and userdel by BARE NAME (not /usr/bin/userdel) so the PATH
#   shims below can intercept them — the same rule slices 4 and 5 set for
#   useradd/usermod/chown/dconf.
#
# CAPTURE TECHNIQUE, the two slice 4 established, for the two questions neither
# answers alone:
#   * DC_DRY_RUN=1 + run()'s `echo "DRY: $*"` — "was the command emitted, and was
#     it gated by run() at all". The dry tests ALSO put the shims on PATH and
#     assert the shim log is empty: a bypass that called `userdel` directly
#     instead of through run() would execute for real under DC_DRY_RUN=1, and
#     that must fail loudly rather than silently.
#   * a recording PATH shim — ordering, and simulating terminate-user failing.

# loginctl and userdel, shimmed away on PATH: they record argv one element per
# line and exit 0. terminate_rc lets a test simulate the no-active-session case,
# which is the one failure the function must survive; userdel_rc (optional,
# default 0) simulates the deletion itself failing, which is the one it must
# report. 12 is shadow-utils' "can't remove home directory".
make_uninstall_shims() {  # dir terminate_rc [userdel_rc] -> echoes the call log path
  local d="$1" rc="$2" udrc="${3:-0}"
  mkdir -p "$d"
  cat > "$d/loginctl" <<EOF
#!/usr/bin/env bash
{ echo "== loginctl"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
if [ "\$1" = "terminate-user" ] && [ $rc -ne 0 ]; then
  echo "Failed to terminate user: No such process" >&2
  exit $rc
fi
exit 0
EOF
  cat > "$d/userdel" <<EOF
#!/usr/bin/env bash
{ echo "== userdel"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
[ $udrc -eq 0 ] || echo "userdel: cannot remove entry '\$2' from /etc/passwd" >&2
exit $udrc
EOF
  chmod +x "$d/loginctl" "$d/userdel"
  : > "$d/calls.log"
  echo "$d/calls.log"
}

UNINSTALL_OUT=""
UNINSTALL_RC=0

# Dry run, with the shims on PATH as a safety net: nothing may execute.
run_uninstall_dry() {  # passwd_db state_file sudo_user shim_dir name protected_user
  UNINSTALL_OUT="$(DC_DRY_RUN=1 DC_PASSWD_DB="$1" DC_STATE_FILE="$2" SUDO_USER="$3" \
                   PATH="$4:$PATH" uninstall_host_account "$5" "$6" 2>&1)"
  UNINSTALL_RC=$?
  return 0
}

# Real run, with loginctl and userdel shimmed away.
run_uninstall_shimmed() {  # passwd_db state_file shim_dir name protected_user
  UNINSTALL_OUT="$(DC_DRY_RUN= DC_PASSWD_DB="$1" DC_STATE_FILE="$2" SUDO_USER="" \
                   PATH="$3:$PATH" uninstall_host_account "$4" "$5" 2>&1)"
  UNINSTALL_RC=$?
  return 0
}

uninstall_dry_all() {  # every emitted command line, "DRY: " stripped
  printf '%s\n' "$UNINSTALL_OUT" | sed -n 's/^DRY: //p'
}

# The destructive operations in the order they were actually invoked, one per
# line. Deliberately matches the operation words only, so the assertion pins the
# ORDER without freezing the rest of each command line.
uninstall_op_sequence() {  # call_log
  grep -oE '(disable-linger|terminate-user|== userdel)' "$1" 2>/dev/null | sed 's/^== //'
}

# A missing function exits 127 having emitted nothing, which would make every
# "must NOT contain" assertion below pass vacuously.
require_uninstall_host_account() {  # label
  declare -F uninstall_host_account >/dev/null && return 0
  fail "$1: uninstall_host_account() is not defined"
  return 1
}

test_library_defines_uninstall_host_account() {
  declare -F uninstall_host_account >/dev/null || \
    fail "install-lib.sh defines uninstall_host_account(): not defined"
}

# Contract 2: the fully-removable shape — the same fixture
# test_host_account_removable_accepts_the_account_we_created uses, because this
# function must delete exactly what that gate approves and nothing else.
test_uninstall_host_account_removes_a_removable_account() {
  local db state shims log line
  require_uninstall_host_account "removable account" || return 0
  db="$(make_removal_passwd_db)"; state="$TMP/state-uninstall-ok/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  shims="$TMP/shims-uninstall-ok"; log="$(make_uninstall_shims "$shims" 0)"

  run_uninstall_dry "$db" "$state" "" "$shims" dreamconnect-host kogies
  assert_eq "$UNINSTALL_RC" "0" "a removable account: uninstall_host_account exits 0"

  line="$(uninstall_dry_all | grep -- 'disable-linger' || true)"
  [ -n "$line" ] || fail "removable: expected a disable-linger command, emitted [$UNINSTALL_OUT]"
  assert_contains "$line" "loginctl"          "linger is dropped via loginctl"
  assert_contains "$line" "dreamconnect-host" "disable-linger names the account"

  line="$(uninstall_dry_all | grep -- 'terminate-user' || true)"
  [ -n "$line" ] || fail "removable: expected a terminate-user command, emitted [$UNINSTALL_OUT]"
  assert_contains "$line" "loginctl"          "the user is terminated via loginctl"
  assert_contains "$line" "dreamconnect-host" "terminate-user names the account"

  line="$(uninstall_dry_all | grep -- 'userdel' || true)"
  [ -n "$line" ] || fail "removable: expected a userdel command, emitted [$UNINSTALL_OUT]"
  assert_contains "$line" "-r"                "userdel removes the home directory (-r)"
  assert_contains "$line" "dreamconnect-host" "userdel names the account"

  # Every one of the three went through run(): DC_DRY_RUN=1 really did mean
  # nothing on this machine changed.
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "dry run executes neither loginctl nor userdel for real"
}

# Contract 1, and the point of the whole safety-rail chain: a refusal from the
# gate is not advisory. Each scenario keeps every other rail valid and violates
# exactly one, reusing slice 3's decoy fixtures.
test_uninstall_host_account_runs_nothing_when_the_gate_refuses() {
  local db shims log state
  require_uninstall_host_account "gate refuses" || return 0
  db="$(make_removal_passwd_db)"

  # A human's account carrying no marker of ours (rail 6), the desktop user
  # itself (rail 3), and state naming a different account (rail 5c).
  local -a names=(dc-gecos-human dreamconnect-host dreamconnect-host)
  local -a protect=(kogies dreamconnect-host kogies)
  local -a acct=(dc-gecos-human dreamconnect-host dreamconnect-host2)
  local -a uids=(988 987 986)
  local -a labels=("wrong GECOS" "name == protected_user" "state names another account")
  local i out

  for i in 0 1 2; do
    state="$TMP/state-uninstall-refuse-$i/install.state"
    write_state_fixture "$state" "${acct[$i]}" "${uids[$i]}" 1 1
    shims="$TMP/shims-uninstall-refuse-$i"; log="$(make_uninstall_shims "$shims" 0)"

    run_uninstall_dry "$db" "$state" "" "$shims" "${names[$i]}" "${protect[$i]}"
    [ "$UNINSTALL_RC" -ne 127 ] || { fail "${labels[$i]}: exit 127, not a refusal"; continue; }
    assert_not_contains "$UNINSTALL_OUT" "command not found" \
      "${labels[$i]}: the refusal came from the gate, not the shell"
    [ "$UNINSTALL_RC" -ne 0 ] || \
      fail "${labels[$i]}: expected non-zero exit (nothing removed), got $UNINSTALL_RC"
    [ -n "$UNINSTALL_OUT" ] || fail "${labels[$i]}: expected a stderr line explaining the refusal"

    out="$UNINSTALL_OUT"
    assert_not_contains "$out" "disable-linger" "${labels[$i]}: no disable-linger was emitted"
    assert_not_contains "$out" "terminate-user" "${labels[$i]}: no terminate-user was emitted"
    assert_not_contains "$out" "userdel"        "${labels[$i]}: no userdel was emitted"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "${labels[$i]}: no account tool was executed either"
  done
}

# Contract 2: linger before terminate before userdel. Asserted from the shim log,
# where the real call order is observable — run()'s dry text happens to appear in
# order too, but only the log proves the commands were actually issued in it.
test_uninstall_host_account_runs_the_commands_in_order() {
  local db state shims log
  require_uninstall_host_account "ordering" || return 0
  db="$(make_removal_passwd_db)"; state="$TMP/state-uninstall-order/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  shims="$TMP/shims-uninstall-order"; log="$(make_uninstall_shims "$shims" 0)"

  run_uninstall_shimmed "$db" "$state" "$shims" dreamconnect-host kogies
  assert_eq "$UNINSTALL_RC" "0" "shimmed removal exits 0"
  assert_eq "$(uninstall_op_sequence "$log")" "disable-linger
terminate-user
userdel" "linger is dropped, then the user terminated, then the account deleted"
}

# Contract 3: `loginctl terminate-user` fails whenever the account has no active
# session — the common case after a reboot, and harmless. The deletion must not
# be abandoned because of it.
test_uninstall_host_account_deletes_even_when_terminate_user_fails() {
  local db state shims log calls
  require_uninstall_host_account "terminate-user failure" || return 0
  db="$(make_removal_passwd_db)"; state="$TMP/state-uninstall-noterm/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  shims="$TMP/shims-uninstall-noterm"; log="$(make_uninstall_shims "$shims" 1)"

  run_uninstall_shimmed "$db" "$state" "$shims" dreamconnect-host kogies
  calls="$(cat "$log" 2>/dev/null || true)"
  assert_contains "$calls" "[terminate-user]" \
    "precondition: terminate-user really was attempted and really did fail"
  assert_line "$calls" "== userdel" \
    "a failing terminate-user does not stop userdel from being attempted"
  assert_contains "$calls" "[dreamconnect-host]" "userdel still names the account"
  assert_eq "$(uninstall_op_sequence "$log")" "disable-linger
terminate-user
userdel" "the order is unchanged when terminate-user fails"
  assert_eq "$UNINSTALL_RC" "0" \
    "a failing terminate-user does not fail the uninstall (no session is not an error)"
}

# Contract 3, the other half: userdel IS the deletion. Issue #18 — "uninstall
# MUST delete the account and fully revert" — so a userdel that failed must not
# be reported to the caller as a completed removal: the account is still on the
# box, and whatever runs next (state-file cleanup, the uninstall summary) would
# otherwise record a removal that never happened.
#
# It must not stop early either: linger and the session are still worth clearing,
# so all three are attempted in order and only then is the failure reported.
test_uninstall_host_account_reports_a_failing_userdel() {
  local db state shims log
  require_uninstall_host_account "userdel failure" || return 0
  db="$(make_removal_passwd_db)"; state="$TMP/state-uninstall-udfail/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  shims="$TMP/shims-uninstall-udfail"; log="$(make_uninstall_shims "$shims" 0 12)"

  run_uninstall_shimmed "$db" "$state" "$shims" dreamconnect-host kogies
  assert_eq "$(uninstall_op_sequence "$log")" "disable-linger
terminate-user
userdel" "a failing userdel is still the third of three attempts, in order"
  [ "$UNINSTALL_RC" -ne 0 ] || fail \
    "userdel failed (exit 12) but uninstall_host_account returned 0 — a failed deletion reported as done"
  [ "$UNINSTALL_RC" -ne 127 ] || fail \
    "userdel failure: exit 127 (command not found), not a propagated status"
}

# loginctl/userdel shims where exactly ONE named loginctl subcommand fails and
# every other call succeeds. make_uninstall_shims above can only fail
# terminate-user; isolating disable-linger too is what lets the set -e test below
# prove each suppression separately rather than both at once.
make_loginctl_failing_shim() {  # dir failing_subcommand -> echoes the call log path
  local d="$1" bad="$2"
  mkdir -p "$d"
  cat > "$d/loginctl" <<EOF
#!/usr/bin/env bash
{ echo "== loginctl"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
if [ "\$1" = "$bad" ]; then
  echo "loginctl: $bad failed" >&2
  exit 1
fi
exit 0
EOF
  cat > "$d/userdel" <<EOF
#!/usr/bin/env bash
{ echo "== userdel"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
exit 0
EOF
  chmod +x "$d/loginctl" "$d/userdel"
  : > "$d/calls.log"
  echo "$d/calls.log"
}

# Contract 3, under the shell options the installer actually runs with.
#
# WHY THIS TEST EXISTS, separately from the two failure tests above. install.sh
# line 22 is `set -euo pipefail`, and errexit is inherited by every function the
# sourced library defines. This suite is deliberately `set -uo pipefail` (line
# 16) — no -e — so that a failing command inside a test does not abort the
# harness. That difference makes the two tests above blind to the exact thing
# contract 3 turns on: without errexit, a failing `run loginctl ...` inside
# uninstall_host_account continues to the next line whether or not the failure is
# suppressed, so they pass identically with and without the suppressions.
# Confirmed by mutation: deleting either `|| true` left the whole suite green.
#
# So this test does not run the function in the harness's shell at all. It runs
# it inside a real `bash -c 'set -euo pipefail; ...'` — the production shell
# options, taken from install.sh line 22, not from install-lib.sh — with exactly
# one of the two loginctl calls shimmed to fail, and asserts execution still
# reaches userdel and the shell is not killed. That is what contract 3's
# "SUPPRESSED" means when errexit is on; a bare `run loginctl disable-linger` or
# `run loginctl terminate-user` would abort the uninstall mid-way and leak the
# account.
#
# Expected values come from the contract (both loginctl failures suppressed,
# userdel still attempted, overall status 0 when userdel succeeds) plus
# install.sh's own `set -euo pipefail`. This is a guard on an invariant: it is
# green against today's code, and its value is the regression it would catch.
test_uninstall_host_account_survives_set_e_when_loginctl_fails() {
  local db state shims log out rc calls bad
  require_uninstall_host_account "set -e survival" || return 0
  db="$(make_removal_passwd_db)"

  for bad in disable-linger terminate-user; do
    state="$TMP/state-uninstall-sete-$bad/install.state"
    write_state_fixture "$state" dreamconnect-host 987 1 1
    shims="$TMP/shims-uninstall-sete-$bad"
    log="$(make_loginctl_failing_shim "$shims" "$bad")"

    # $1=library, $2=passwd db, $3=state file, $4=shim dir. The trailing echo is
    # unreachable if errexit killed the shell at the failing loginctl.
    out="$(bash -c '
      set -euo pipefail
      . "$1"
      DC_DRY_RUN= DC_PASSWD_DB="$2" DC_STATE_FILE="$3" SUDO_USER="" PATH="$4:$PATH" \
        uninstall_host_account dreamconnect-host kogies
      echo "UNINSTALL RETURNED $?"
    ' _ "$LIB" "$db" "$state" "$shims" 2>&1)"; rc=$?

    calls="$(cat "$log" 2>/dev/null || true)"
    assert_contains "$calls" "[$bad]" \
      "set -e / $bad: precondition — the failing call really was attempted"
    assert_contains "$out" "UNINSTALL RETURNED 0" \
      "set -e / $bad: a failing $bad does not abort uninstall_host_account under install.sh's set -e"
    assert_line "$calls" "== userdel" \
      "set -e / $bad: userdel is still reached after $bad failed under set -e"
    assert_contains "$calls" "[dreamconnect-host]" \
      "set -e / $bad: userdel still names the account"
    assert_eq "$rc" "0" \
      "set -e / $bad: the set -euo pipefail shell exits 0, not errexit's status"
  done
}

# The removal-side half of slice 5's blast-radius guard, tightened here.
#
# configure_no_idle_lock already refuses the reserved dconf names "user" and
# "local" before writing anything (slice 5). remove_no_idle_lock has no such
# guard, and from this slice on it is driven by HOST_ACCOUNT read off a state
# FILE rather than a freshly resolved argument: a hand-edited, truncated or
# tampered /etc/dreamconnect/install.state saying HOST_ACCOUNT=user would drive
# it to `rm -f /etc/dconf/profile/user` — dconf's own default profile — and
# HOST_ACCOUNT=local to `rmdir /etc/dconf/db/local.d`, the conventional system db
# on this box. That is precisely the blast radius these rails exist to prevent,
# and deleting it is worse than writing to it.
#
# Same guard as configure_no_idle_lock's, same source for the two names (the real
# /etc/dconf on the target-class box), and it must fire BEFORE any filesystem
# mutation: the fixture files below are planted first and must ALL still be there
# afterwards. `dconf update` is not run either — a refused removal recompiles
# nothing.
#
# Backwards-compatible tightening: no existing behaviour changes for any other
# name, so slice 5's twelve tests stand as they are.
test_remove_no_idle_lock_refuses_reserved_dconf_names() {
  local d home shims log name
  require_no_idle_lock "removal reserved-name guard" || return 0
  shims="$TMP/shims-idle-remove-reserved"; log="$(make_dconf_shim "$shims")"

  for name in user local; do
    read -r d home <<<"$(idle_fixture "idle-remove-reserved-$name")"
    # Pretend the real thing is already there: dconf's default profile / system
    # db, and a .config that belongs to somebody else entirely.
    mkdir -p "$d/profile" "$d/db/$name.d" "$home/.config/environment.d"
    printf 'user-db:user\nsystem-db:local\n' > "$d/profile/$name"
    printf '[org/gnome/desktop/screensaver]\nlock-enabled=true\n' > "$d/db/$name.d/00-display-host"
    printf 'DCONF_PROFILE=somebody-else\n' > "$home/.config/environment.d/dconf-profile.conf"
    printf 'yes\n' > "$home/.config/gnome-initial-setup-done"

    run_remove "$d" "$name" "$home" "$shims"
    [ "$IDLE_RC" -ne 127 ] || { fail "reserved name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$IDLE_OUT" "command not found" \
      "reserved name '$name': the refusal came from the guard, not the shell"
    [ "$IDLE_RC" -ne 0 ] || fail "reserved removal '$name': expected non-zero exit, got $IDLE_RC"
    [ -n "$IDLE_OUT" ] || fail "reserved removal '$name': expected a stderr line explaining the refusal"

    assert_file_exists "$d/profile/$name" \
      "reserved removal '$name': dconf's own profile file is NOT deleted"
    assert_file_exists "$d/db/$name.d/00-display-host" \
      "reserved removal '$name': the shared system db keyfile is NOT deleted"
    assert_file_exists "$d/db/$name.d" \
      "reserved removal '$name': the shared system db directory is NOT removed"
    assert_file_exists "$home/.config/environment.d/dconf-profile.conf" \
      "reserved removal '$name': somebody else's environment.d drop-in is NOT deleted"
    assert_file_exists "$home/.config/gnome-initial-setup-done" \
      "reserved removal '$name': the initial-setup marker is NOT deleted"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "reserved removal '$name': a refused removal does not run dconf update either"
  done
}

# --- slice 6b: account-name validation + AccountsService file preservation -----
#
# WHY THIS SLICE EXISTS. A red-team pass over slices 3-6a found five defects that
# all share one root: a name string is trusted to be a bare account name when it
# has never been checked, and a file this installer did not create is overwritten
# as if it had. Every contract below is written against that finding, not against
# any implementation — none of the two new functions exists at the time these
# tests were written, and the two extensions are named as extensions so the
# existing 53 tests stand unchanged.
#
# The reported defects, restated so the builder can see what each rail is for:
#
#   #1 ensure_host_account unconditionally overwrites
#      /var/lib/AccountsService/users/<name>. On an account that already existed
#      (contract B: "it may be a human's"), that silently destroys their
#      Session=/XSession=/Language=/Icon= settings with no way back — and
#      --uninstall then deletes the file outright.
#   #2 A numeric name. `getent passwd 1000` resolves by UID, not by name, so a
#      DREAMCONNECT_HOST_ACCOUNT=1000 binds the whole install to whatever account
#      happens to own uid 1000 — typically the human desktop user.
#   #3 A name containing "/" or ".". The dconf paths are built as
#      "$dir/profile/$name" and "$dir/db/$name.d", so "./user" normalises to
#      exactly the same file as "user" and walks straight past slice 5's
#      reserved-name guard, which compares the STRING.
#   #5 HOST_ACCOUNT=".." in a tampered/truncated install.state makes
#      `rm -f "$dir/profile/.."` fail ("Is a directory") and wedges the uninstall
#      before it ever reaches account deletion or state cleanup.
#
# CONTRACT UNDER TEST — the implementation follows this, not the reverse.
#
#   valid_account_name <name>
#     A pure predicate. No output required, no filesystem access, no passwd
#     lookup. Exit 0 iff ALL THREE hold:
#       1. <name> is non-empty;
#       2. <name> matches the POSIX-ish portable-username shape
#          ^[A-Za-z_][A-Za-z0-9_-]*$  — first character a letter or underscore,
#          the rest letters, digits, underscore or hyphen ONLY. This one rule is
#          what excludes all-numeric names (#2), "/" and "." in any position
#          including "." and ".." themselves (#3, #5), whitespace, and every
#          shell metacharacter (; | $ ` & > * ( ) newline ...);
#       3. its length is at most 32 characters — Linux's practical
#          LOGIN_NAME_MAX-ish limit; 32 is VALID, 33 is not.
#     Anything else: exit non-zero. The rule is a whitelist on purpose: a
#     blacklist of "/" and ".." would still let through the next character
#     nobody thought of.
#
#   host_account_removable <name> <protected_user>  — a SEVENTH rail
#     <name> must pass valid_account_name. If it does not, refuse: non-zero exit
#     and a line on stderr, exactly like the six rails already there. Position in
#     the sequence is the builder's choice. This is defence in depth: rails 1-6
#     can all be satisfied by a malformed name (a passwd source really can hold an
#     entry called "1000" or ".."), and this gate is the last thing standing
#     between a tampered install.state and `userdel -r`.
#     All six existing rails keep their current behaviour and their tests.
#
#   remove_no_idle_lock <name> <home>  — extended guard
#     Refuse via valid_account_name IN ADDITION to the existing exact-match
#     "user"/"local" guard, BEFORE any rm/rmdir/dconf update runs. Both refusals
#     are non-zero with a line on stderr, and both leave the filesystem exactly as
#     they found it. The "user"/"local" check may stay as an explicit first test
#     or be folded in, as long as both names are still refused and slice 5/6a's
#     twelve tests pass unchanged.
#
#   ensure_host_account <name>  — back up before clobbering (defect #1)
#     Let  f = "${DC_ACCOUNTSSERVICE_DIR:-/var/lib/AccountsService/users}/<name>".
#     Before writing the [User]/SystemAccount=true marker to f:
#       * if f EXISTS and "$f.dreamconnect.bak" does NOT exist -> copy f to
#         "$f.dreamconnect.bak" first;
#       * if f does not exist -> no backup, behave exactly as today;
#       * if "$f.dreamconnect.bak" already exists -> leave it alone.
#     That is the same "backs up once" pattern, the same ".dreamconnect.bak"
#     suffix and the same `[ -f "$conf.dreamconnect.bak" ] || cp -a "$conf" ...`
#     idiom enable_autologin already uses in this file — not a new convention.
#     The backup captures the ORIGINAL third-party content once and only once: a
#     second, third or n-th run must never re-back-up our own marker over it,
#     because the whole point is that the .bak is what the account looked like
#     before dreamconnect ever touched it.
#     Everything else about ensure_host_account is unchanged.
#
#   remove_accountsservice_marker <name>   — NEW, the uninstall counterpart
#     Same f as above. Exactly one of three outcomes, in this precedence:
#       * "$f.dreamconnect.bak" exists -> RESTORE it: f ends up with the backup's
#         content and the .bak file is gone. This is the revert path for an
#         account whose file we clobbered.
#       * no .bak, f exists -> remove f. This is today's behaviour, correct for
#         the file we created from scratch.
#       * neither exists -> exit 0, silently. --uninstall runs on boxes where the
#         opt-in was never used.
#     Whether the restore is a mv or a cp+rm is left open; whether it goes through
#     run() is left open too (the tests drive it non-dry, so both work).
#     install.sh's uninstall() calls this instead of its current bare `rm -f`.
#
# WHERE THE EXPECTED VALUES COME FROM. The name grammar and the 32-char bound are
# the contract above, agreed with the coordinator from the red-team findings, and
# match useradd(8)/adduser(8)'s own portable-name advice. The ".dreamconnect.bak"
# suffix and the back-up-once rule are read off enable_autologin in install-lib.sh
# (lines 52-57), which predates this slice. The pre-existing AccountsService file
# fixture below is the shape of a real /var/lib/AccountsService/users/<user> on a
# GNOME/GDM box — the keys GNOME writes there for a human account.

VALID_RC=0
VALID_ERR=""

try_valid_name() {  # name
  VALID_ERR="$(valid_account_name "$1" 2>&1 >/dev/null)"
  VALID_RC=$?
  return 0
}

# A missing function exits 127 with "command not found" on stderr, which is
# non-zero — so every rejection assertion would pass vacuously against a library
# that never defines valid_account_name at all.
require_valid_account_name() {  # label
  declare -F valid_account_name >/dev/null && return 0
  fail "$1: valid_account_name() is not defined"
  return 1
}

assert_name_rejected() {  # name label
  try_valid_name "$1"
  [ "$VALID_RC" -ne 127 ] || {
    fail "$2: exit 127 (not defined), not a rejection of [$1]"; return 0; }
  assert_not_contains "$VALID_ERR" "command not found" \
    "$2: the rejection came from the function, not the shell"
  [ "$VALID_RC" -ne 0 ] || fail "$2: expected non-zero (invalid) for [$1], got 0"
}

assert_name_accepted() {  # name label
  try_valid_name "$1"
  assert_eq "$VALID_RC" "0" "$2: expected valid (exit 0) for [$1] (stderr: $VALID_ERR)"
}

test_library_defines_the_name_and_marker_functions() {
  local fn
  for fn in valid_account_name remove_accountsservice_marker; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

# The names the installer itself uses and the shapes a human would reasonably
# pass to DREAMCONNECT_HOST_ACCOUNT. A validator that rejects any of these breaks
# the feature rather than protecting it.
test_valid_account_name_accepts_ordinary_names() {
  local n
  require_valid_account_name "accepts ordinary names" || return 0
  for n in dreamconnect-host dc_host a Z9 _svc dreamconnect-host2 \
           a-b_c host_2-x A1234567890; do
    assert_name_accepted "$n" "ordinary account name"
  done
}

# The length bound is inclusive: 32 characters is the last valid length.
test_valid_account_name_accepts_a_thirty_two_character_name() {
  local n
  require_valid_account_name "32-char boundary" || return 0
  n="dreamconnect-hostabcdefghijklmno"
  assert_eq "${#n}" "32" "precondition: the boundary fixture really is 32 characters"
  assert_name_accepted "$n" "32 characters is the inclusive upper bound"
}

# Rail 1: empty. install.sh can reach here with DREAMCONNECT_HOST_ACCOUNT="".
test_valid_account_name_rejects_an_empty_name() {
  require_valid_account_name "empty name" || return 0
  assert_name_rejected "" "the empty string is not an account name"
}

# Defect #2. `getent passwd 1000` resolves by UID, so a numeric "name" silently
# binds the install to whoever owns that uid — usually the human desktop user.
test_valid_account_name_rejects_numeric_names() {
  local n
  require_valid_account_name "numeric names" || return 0
  for n in 1000 0 42 007 9abc 1-host; do
    assert_name_rejected "$n" "a name starting with a digit resolves by uid, not by name"
  done
}

# Defect #3. "$dir/profile/./user" IS "$dir/profile/user", so a name carrying a
# path separator or a dot component walks straight past a string-equality guard
# on "user"/"local" and hits the shared file anyway.
test_valid_account_name_rejects_path_separators_and_dots() {
  local n
  require_valid_account_name "path separators" || return 0
  for n in ./user ../etc a/b /user user/ ../../etc/passwd a.b .hidden host.d; do
    assert_name_rejected "$n" "a name containing / or . can escape the path it is pasted into"
  done
}

# Defect #5, the exact reported trigger: a state file saying HOST_ACCOUNT=.. makes
# `rm -f "$dir/profile/.."` fail and wedges uninstall() before it ever reaches
# account deletion or state cleanup. Covered by the rule above, tested explicitly
# because this is the string that was actually reported.
test_valid_account_name_rejects_dot_and_dotdot() {
  require_valid_account_name "dot and dotdot" || return 0
  assert_name_rejected ".."  ".. is a directory reference, never an account"
  assert_name_rejected "."   ". is a directory reference, never an account"
  assert_name_rejected "..." "... is not an account name either"
}

# 32 is the last valid length; 33 and anything beyond is refused.
test_valid_account_name_rejects_overlong_names() {
  local n33 n64
  require_valid_account_name "overlong names" || return 0
  n33="dreamconnect-hostabcdefghijklmnop"
  assert_eq "${#n33}" "33" "precondition: the over-bound fixture really is 33 characters"
  assert_name_rejected "$n33" "33 characters is one past the bound"
  n64="$n33$n33"
  assert_name_rejected "$n64" "a 66-character name is refused"
}

# Belt and braces: the whitelist already excludes these, and each one of them is
# a name that would be pasted unquoted into a path or a command line somewhere.
test_valid_account_name_rejects_shell_metacharacters() {
  local n
  require_valid_account_name "shell metacharacters" || return 0
  for n in 'a b' 'a;b' 'a|b' 'a$b' 'a`b`' 'a&b' 'a>b' 'a*b' 'a(b)' 'a'"'"'b' \
           'a"b' 'a\b' 'a:b' 'a#b' '-a' '~root'; do
    assert_name_rejected "$n" "a name containing shell-special characters"
  done
  assert_name_rejected 'a
b' "a name containing a newline"
}

# passwd(5) fixture for the seventh rail. Deliberately separate from
# make_removal_passwd_db so slice 3's decoys are untouched. Every entry here
# satisfies ALL SIX existing rails — non-zero uid, safe home, not the protected
# user, not $SUDO_USER, state will agree, exact GECOS marker — and violates ONLY
# the name shape, so any of these being "removable" means rail 7 is missing.
#
# An entry literally called "1000" is what a passwd source looks like from
# host_account_removable's point of view once a numeric name has been let through
# upstream; ".." and "./dreamconnect-host" are the paths-in-a-name cases.
make_malformed_name_passwd_db() {
  cat > "$TMP/passwd-malformed" <<'EOF'
root:x:0:0:Super User:/root:/bin/bash
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
1000:x:989:989:DreamConnect display host:/var/lib/dc-numeric:/bin/bash
./dreamconnect-host:x:990:990:DreamConnect display host:/var/lib/dc-dotslash:/bin/bash
..:x:991:991:DreamConnect display host:/var/lib/dc-dotdot:/bin/bash
dc host:x:992:992:DreamConnect display host:/var/lib/dc-space:/bin/bash
EOF
  echo "$TMP/passwd-malformed"
}

# Rail 7. Same harness as the other six (try_removable + assert_refused), same
# shape of fixture: five-of-six valid is not enough, and here it is six-of-seven.
test_host_account_removable_refuses_a_malformed_account_name() {
  local db state name i
  local -a names=(1000 ./dreamconnect-host .. "dc host")
  local -a uids=(989 990 991 992)
  db="$(make_malformed_name_passwd_db)"
  i=0
  for name in "${names[@]}"; do
    state="$TMP/state-malformed-$i/install.state"
    write_state_fixture "$state" "$name" "${uids[$i]}" 1 1
    try_removable "$db" "$state" "" "$name" kogies
    assert_refused "malformed account name rail ([$name], every other rail satisfied)"
    i=$((i + 1))
  done
}

# Defect #3 at the WRITE seam — the other half of the asymmetry. Slice 5's guard
# compares the STRING to "user"/"local", so "./user" sails past it and then
# `mkdir -p "$dir/db/./user.d"` and `> "$dir/profile/./user"` land on exactly the
# files the guard exists to protect: dconf's own default profile and system db,
# for every user on the box.
#
# The reasoning is the same defence in depth as rail 7 and the removal-side
# guard: a function this destructive validates its own argument rather than
# trusting whatever install.sh checked at the entry point. Refuse before ANY of
# the six things this function does — the four writes, the chowns and
# `dconf update` — mirroring test_configure_no_idle_lock_refuses_reserved_dconf_names
# exactly, which is why the "nothing at all was written" assertion is the one
# that matters most here too.
#
# The existing "user"/"local" guard keeps its own test and its own behaviour;
# this is purely additive.
test_configure_no_idle_lock_refuses_malformed_account_names() {
  local d home shims log name tag i
  require_no_idle_lock "write-side malformed-name guard" || return 0
  shims="$TMP/shims-idle-configure-malformed"; log="$(make_idle_shims "$shims" 0)"

  i=0
  for name in ./user .. . 1000 "dc host"; do
    tag="idle-configure-malformed-$i"; i=$((i + 1))
    read -r d home <<<"$(idle_fixture "$tag")"

    run_configure "$d" "$name" "$home" "$shims"
    [ "$IDLE_RC" -ne 127 ] || { fail "malformed name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$IDLE_OUT" "command not found" \
      "malformed name '$name': the refusal came from the guard, not the shell"
    [ "$IDLE_RC" -ne 0 ] || fail "malformed configure '$name': expected non-zero exit, got $IDLE_RC"
    [ -n "$IDLE_OUT" ] || fail "malformed configure '$name': expected a stderr line explaining the refusal"

    assert_file_absent "$d/profile/user" \
      "malformed configure '$name': dconf's own default profile is NOT written"
    assert_file_absent "$d/db/user.d/00-display-host" \
      "malformed configure '$name': no keyfile lands in the shared user.d"
    assert_file_absent "$home/.config/environment.d/dconf-profile.conf" \
      "malformed configure '$name': no environment.d drop-in is written"
    assert_file_absent "$home/.config/gnome-initial-setup-done" \
      "malformed configure '$name': no initial-setup marker is written"
    assert_eq "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
      "malformed configure '$name': nothing at all written under DC_DCONF_DIR"
    assert_eq "$(find "$home" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
      "malformed configure '$name': nothing at all written under <home>"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "malformed configure '$name': neither chown nor dconf update was run"
  done
}

# Defects #3 and #5 at the removal seam. remove_no_idle_lock is driven by
# HOST_ACCOUNT read off a state FILE, so the name reaching it may never have been
# validated anywhere. "./user" targets exactly the files "user" would — dconf's
# own default profile and system db — and ".." makes `rm -f "$dir/profile/.."`
# fail and wedge the uninstall.
#
# Same assertion style as the reserved-name test above it: plant the real thing,
# refuse, and prove NOTHING moved — not the /etc/dconf tree, not somebody else's
# home files, and no `dconf update` either.
test_remove_no_idle_lock_refuses_malformed_account_names() {
  local d home shims log name tag before after i
  require_no_idle_lock "removal malformed-name guard" || return 0
  shims="$TMP/shims-idle-remove-malformed"; log="$(make_dconf_shim "$shims")"

  i=0
  for name in ./user .. . 1000 "dc host"; do
    tag="idle-remove-malformed-$i"; i=$((i + 1))
    read -r d home <<<"$(idle_fixture "$tag")"

    # dconf's own default profile and system db, plus a .config belonging to
    # somebody else entirely — exactly what "./user" and ".." would reach.
    mkdir -p "$d/profile" "$d/db/user.d" "$d/db/local.d" "$home/.config/environment.d"
    printf 'user-db:user\nsystem-db:local\n' > "$d/profile/user"
    printf 'user-db:user\n'                  > "$d/profile/local"
    printf '[org/gnome/desktop/screensaver]\nlock-enabled=true\n' > "$d/db/user.d/00-display-host"
    printf '[org/gnome/desktop/screensaver]\nlock-enabled=true\n' > "$d/db/local.d/00-display-host"
    printf 'DCONF_PROFILE=somebody-else\n' > "$home/.config/environment.d/dconf-profile.conf"
    printf 'yes\n' > "$home/.config/gnome-initial-setup-done"
    before="$(find "$d" "$home" | sort)"

    run_remove "$d" "$name" "$home" "$shims"
    [ "$IDLE_RC" -ne 127 ] || { fail "malformed name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$IDLE_OUT" "command not found" \
      "malformed name '$name': the refusal came from the guard, not the shell"
    [ "$IDLE_RC" -ne 0 ] || fail "malformed removal '$name': expected non-zero exit, got $IDLE_RC"
    [ -n "$IDLE_OUT" ] || fail "malformed removal '$name': expected a stderr line explaining the refusal"
    assert_not_contains "$IDLE_OUT" "Is a directory" \
      "malformed removal '$name': refused before any rm ran, so no rm error leaks out"

    assert_file_exists "$d/profile/user" \
      "malformed removal '$name': dconf's own default profile is NOT deleted"
    assert_file_exists "$d/db/user.d/00-display-host" \
      "malformed removal '$name': the user.d keyfile is NOT deleted"
    assert_file_exists "$d/db/local.d/00-display-host" \
      "malformed removal '$name': the shared system db keyfile is NOT deleted"
    assert_file_exists "$home/.config/environment.d/dconf-profile.conf" \
      "malformed removal '$name': somebody else's environment.d drop-in is NOT deleted"
    assert_file_exists "$home/.config/gnome-initial-setup-done" \
      "malformed removal '$name': the initial-setup marker is NOT deleted"

    after="$(find "$d" "$home" | sort)"
    assert_eq "$after" "$before" \
      "malformed removal '$name': nothing at all under DC_DCONF_DIR or <home> changed"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "malformed removal '$name': a refused removal does not run dconf update either"
  done
}

# The shape of a real /var/lib/AccountsService/users/<user> for a HUMAN account on
# a GNOME/GDM box: the keys GNOME writes there when a person picks a session, a
# language and an avatar. This is the content defect #1 destroys.
plant_preexisting_accountsservice_file() {  # path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
[User]
Session=gnome
XSession=gnome
Icon=/var/lib/AccountsService/icons/dreamconnect-host
SystemAccount=false
Language=en_GB.UTF-8
EOF
}

# Case (a): nothing was there, so there is nothing to preserve. A backup here
# would be noise at best and, on the next uninstall, would restore a copy of our
# own marker instead of removing it.
test_ensure_host_account_writes_no_backup_for_a_new_marker_file() {
  local db dir shims
  require_ensure_host_account "no backup for a new file" || return 0
  db="$(make_fresh_passwd_db)"; dir="$TMP/as-bak-new"; mkdir -p "$dir"
  shims="$TMP/shims-as-bak-new"; make_cmd_shims "$shims" >/dev/null

  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  assert_file_exists "$dir/dreamconnect-host" "a fresh account still gets its marker file"
  assert_contains "$(cat "$dir/dreamconnect-host" 2>/dev/null || true)" "SystemAccount=true" \
    "the fresh marker file is ours"
  assert_file_absent "$dir/dreamconnect-host.dreamconnect.bak" \
    "no pre-existing file means no backup is created"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "1" \
    "a fresh install leaves exactly one file in the AccountsService dir"
}

# Defect #1. The account already exists and already has an AccountsService file
# that is none of our business. Overwriting it is unavoidable — SystemAccount=true
# is what hides the account from the greeter — but destroying it is not.
test_ensure_host_account_backs_up_a_preexisting_accountsservice_file() {
  local db dir shims f bak orig body
  require_ensure_host_account "backs up a pre-existing file" || return 0
  db="$(make_passwd_db)"; dir="$TMP/as-bak-existing"; mkdir -p "$dir"
  shims="$TMP/shims-as-bak-existing"; make_cmd_shims "$shims" >/dev/null
  f="$dir/dreamconnect-host"; bak="$f.dreamconnect.bak"; orig="$TMP/as-bak-existing-orig"

  plant_preexisting_accountsservice_file "$f"
  cp "$f" "$orig"

  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host

  assert_file_exists "$bak" \
    "a pre-existing AccountsService file is backed up to <path>.dreamconnect.bak"
  cmp -s "$orig" "$bak" \
    || fail "the backup holds the ORIGINAL content byte-for-byte, not ours"
  body="$(cat "$f" 2>/dev/null || true)"
  assert_contains "$body" "SystemAccount=true" "the live file now carries our marker"
  assert_not_contains "$body" "XSession=gnome" \
    "the live file is a full overwrite, not our marker appended to theirs"
}

# "Backs up once", the same rule enable_autologin states in its own comment. A
# second install run must not re-back-up the marker WE wrote over the original —
# that would lose the very content the backup exists to hold.
test_ensure_host_account_backs_up_only_once_across_reruns() {
  local db dir shims f bak orig
  require_ensure_host_account "backs up once" || return 0
  db="$(make_passwd_db)"; dir="$TMP/as-bak-twice"; mkdir -p "$dir"
  shims="$TMP/shims-as-bak-twice"; make_cmd_shims "$shims" >/dev/null
  f="$dir/dreamconnect-host"; bak="$f.dreamconnect.bak"; orig="$TMP/as-bak-twice-orig"

  plant_preexisting_accountsservice_file "$f"
  cp "$f" "$orig"

  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host

  cmp -s "$orig" "$bak" \
    || fail "after three runs the backup STILL holds the original content, not our marker"
  assert_not_contains "$(cat "$bak" 2>/dev/null || true)" "SystemAccount=true" \
    "our own marker was never backed up over the original"
  assert_file_absent "$bak.dreamconnect.bak" "no backup of the backup is created"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "2" \
    "three runs leave exactly two files: the marker and one backup"
}

# A missing function exits 127 having removed nothing, which would make the
# "nothing left behind" assertions below pass vacuously.
require_remove_accountsservice_marker() {  # label
  declare -F remove_accountsservice_marker >/dev/null && return 0
  fail "$1: remove_accountsservice_marker() is not defined"
  return 1
}

REMOVE_MARKER_OUT=""
REMOVE_MARKER_RC=0

run_remove_marker() {  # accountsservice_dir name
  REMOVE_MARKER_OUT="$(DC_DRY_RUN= DC_ACCOUNTSSERVICE_DIR="$1" \
                       remove_accountsservice_marker "$2" 2>&1)"
  REMOVE_MARKER_RC=$?
  return 0
}

# Outcome 1: a backup exists, so the account had a file before we touched it and
# uninstall must give it back — not delete it, which is what the bare `rm -f` in
# install.sh's uninstall() does today.
test_remove_accountsservice_marker_restores_a_backed_up_file() {
  local dir f bak orig
  require_remove_accountsservice_marker "restore from backup" || return 0
  dir="$TMP/as-rm-restore"; mkdir -p "$dir"
  f="$dir/dreamconnect-host"; bak="$f.dreamconnect.bak"; orig="$TMP/as-rm-restore-orig"

  # The state ensure_host_account leaves behind for a clobbered account.
  plant_preexisting_accountsservice_file "$bak"
  cp "$bak" "$orig"
  printf '[User]\nSystemAccount=true\n' > "$f"

  run_remove_marker "$dir" dreamconnect-host
  assert_eq "$REMOVE_MARKER_RC" "0" "restoring exits 0 (stderr: $REMOVE_MARKER_OUT)"
  assert_file_exists "$f" "the AccountsService file still exists after uninstall"
  cmp -s "$orig" "$f" \
    || fail "the pre-existing content is restored byte-for-byte"
  assert_file_absent "$bak" "the backup is consumed, not left lying around"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "1" \
    "exactly the restored file remains"
}

# Outcome 2: no backup means we created the file from scratch, so removing it
# leaves the box as it was. This is today's behaviour, preserved.
test_remove_accountsservice_marker_removes_a_marker_we_created() {
  local dir f
  require_remove_accountsservice_marker "remove our own marker" || return 0
  dir="$TMP/as-rm-ours"; mkdir -p "$dir"
  f="$dir/dreamconnect-host"
  printf '[User]\nSystemAccount=true\n' > "$f"

  run_remove_marker "$dir" dreamconnect-host
  assert_eq "$REMOVE_MARKER_RC" "0" "removing our own marker exits 0 (stderr: $REMOVE_MARKER_OUT)"
  assert_file_absent "$f" "a marker we created with nothing behind it is removed"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "0" \
    "nothing is left behind in the AccountsService dir"
}

# Outcome 3: --uninstall runs on boxes where the opt-in was never used.
test_remove_accountsservice_marker_is_a_no_op_when_nothing_exists() {
  local dir
  require_remove_accountsservice_marker "no-op" || return 0
  dir="$TMP/as-rm-nothing"; mkdir -p "$dir"

  run_remove_marker "$dir" dreamconnect-host
  assert_eq "$REMOVE_MARKER_RC" "0" "removing nothing exits 0"
  assert_not_contains "$REMOVE_MARKER_OUT" "No such file" \
    "removing nothing is quiet, not a pile of ENOENT"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "0" "removing nothing creates nothing"
}

# The whole point of defects #1's fix, end to end: install over a human's account,
# then uninstall, and their AccountsService file is exactly as it was. Asserted
# through the two public functions only — nothing here knows how the backup is
# stored beyond the .dreamconnect.bak name the contract fixes.
test_accountsservice_marker_round_trips_a_preexisting_file() {
  local db dir shims f orig
  require_ensure_host_account "round trip" || return 0
  require_remove_accountsservice_marker "round trip" || return 0
  db="$(make_passwd_db)"; dir="$TMP/as-roundtrip"; mkdir -p "$dir"
  shims="$TMP/shims-as-roundtrip"; make_cmd_shims "$shims" >/dev/null
  f="$dir/dreamconnect-host"; orig="$TMP/as-roundtrip-orig"

  plant_preexisting_accountsservice_file "$f"
  cp "$f" "$orig"

  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  run_ensure_shimmed "$db" "$dir" "$shims" dreamconnect-host
  run_remove_marker "$dir" dreamconnect-host

  assert_eq "$REMOVE_MARKER_RC" "0" "the round trip's removal exits 0"
  cmp -s "$orig" "$f" \
    || fail "install-then-uninstall leaves a pre-existing AccountsService file untouched"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "1" \
    "install-then-uninstall leaves exactly the original file, no backup residue"
}

# Defects #3 and #5 at the LAST unguarded seam. remove_accountsservice_marker is
# the one function added for slice 6b that never validates its own argument, and
# it is driven from install.sh's uninstall() with $HOST_ACCOUNT read off a state
# FILE — so the name reaching it may never have been validated anywhere.
#
# conf is built as "${DC_ACCOUNTSSERVICE_DIR}/$name", so a name carrying "../"
# escapes the AccountsService directory entirely and both branches then act on a
# file that is none of this installer's business: `rm -f` DELETES it, and
# `mv -f "$conf.dreamconnect.bak" "$conf"` OVERWRITES it. The property under test
# is therefore not "returns non-zero" but "the file outside the fixture survives
# byte-for-byte" — which is why each case plants a victim at the traversal
# destination first and compares it afterwards.
#
# Contract: slice 6b's header above — "<name> must pass valid_account_name. If it
# does not, refuse: non-zero exit and a line on stderr ... and both leave the
# filesystem exactly as they found it", applied here for the same reason it is
# applied to host_account_removable, configure_no_idle_lock and
# remove_no_idle_lock: a function this destructive validates its own argument
# rather than trusting whatever install.sh checked at the entry point. The three
# well-formed-name outcomes above are unaffected and keep their tests.
test_remove_accountsservice_marker_refuses_malformed_account_names() {
  local base dir victim name tag i before after
  require_remove_accountsservice_marker "malformed-name guard" || return 0

  # Case A: the remove branch. No .bak, so today's `rm -f "$conf"` deletes a file
  # that lives outside DC_ACCOUNTSSERVICE_DIR altogether.
  base="$TMP/as-rm-traversal-remove"; dir="$base/users"; victim="$base/victim"
  mkdir -p "$dir" "$victim"
  printf 'somebody-elses-important-data\n' > "$victim/data"
  before="$(find "$base" | sort)"

  run_remove_marker "$dir" "../victim/data"
  [ "$REMOVE_MARKER_RC" -ne 127 ] || fail "traversal (remove branch): exit 127, not a refusal"
  assert_not_contains "$REMOVE_MARKER_OUT" "command not found" \
    "traversal (remove branch): the refusal came from the guard, not the shell"
  [ "$REMOVE_MARKER_RC" -ne 0 ] || \
    fail "traversal (remove branch): expected non-zero exit, got $REMOVE_MARKER_RC"
  [ -n "$REMOVE_MARKER_OUT" ] || \
    fail "traversal (remove branch): expected a stderr line explaining the refusal"
  assert_file_exists "$victim/data" \
    "traversal (remove branch): a file OUTSIDE DC_ACCOUNTSSERVICE_DIR is NOT deleted"
  assert_eq "$(cat "$victim/data" 2>/dev/null || true)" "somebody-elses-important-data" \
    "traversal (remove branch): the outside file still holds its own content"
  assert_eq "$(find "$base" | sort)" "$before" \
    "traversal (remove branch): nothing anywhere under the fixture changed"

  # Case B: the restore branch, which takes precedence. A planted .bak next to the
  # traversal target makes today's `mv -f` overwrite the victim rather than delete
  # it — the same escape, a different verb.
  base="$TMP/as-rm-traversal-restore"; dir="$base/users"; victim="$base/victim"
  mkdir -p "$dir" "$victim"
  printf 'somebody-elses-important-data\n' > "$victim/data"
  printf '[User]\nSession=attacker\n'      > "$victim/data.dreamconnect.bak"
  before="$(find "$base" | sort)"

  run_remove_marker "$dir" "../victim/data"
  [ "$REMOVE_MARKER_RC" -ne 0 ] || \
    fail "traversal (restore branch): expected non-zero exit, got $REMOVE_MARKER_RC"
  [ -n "$REMOVE_MARKER_OUT" ] || \
    fail "traversal (restore branch): expected a stderr line explaining the refusal"
  assert_eq "$(cat "$victim/data" 2>/dev/null || true)" "somebody-elses-important-data" \
    "traversal (restore branch): the outside file is NOT overwritten by the .bak"
  assert_file_exists "$victim/data.dreamconnect.bak" \
    "traversal (restore branch): refused before the mv, so the .bak is not consumed"
  assert_eq "$(find "$base" | sort)" "$before" \
    "traversal (restore branch): nothing anywhere under the fixture changed"

  # And the rest of the malformed shapes, each against a fixture holding both a
  # well-formed marker and its backup: a refusal touches neither.
  i=0
  for name in ".." "." "./dreamconnect-host" 1000 "dc host" ""; do
    tag="as-rm-malformed-$i"; i=$((i + 1))
    dir="$TMP/$tag"; mkdir -p "$dir"
    printf '[User]\nSystemAccount=true\n' > "$dir/dreamconnect-host"
    plant_preexisting_accountsservice_file "$dir/dreamconnect-host.dreamconnect.bak"
    before="$(find "$dir" | sort)"

    run_remove_marker "$dir" "$name"
    [ "$REMOVE_MARKER_RC" -ne 127 ] || { fail "malformed name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$REMOVE_MARKER_OUT" "command not found" \
      "malformed name '$name': the refusal came from the guard, not the shell"
    [ "$REMOVE_MARKER_RC" -ne 0 ] || \
      fail "malformed marker removal '$name': expected non-zero exit, got $REMOVE_MARKER_RC"
    [ -n "$REMOVE_MARKER_OUT" ] || \
      fail "malformed marker removal '$name': expected a stderr line explaining the refusal"
    assert_not_contains "$REMOVE_MARKER_OUT" "Is a directory" \
      "malformed marker removal '$name': refused before any mv/rm ran, so no error leaks out"
    after="$(find "$dir" | sort)"
    assert_eq "$after" "$before" \
      "malformed marker removal '$name': the AccountsService dir is left exactly as found"
  done
}

# Defects #2, #3 and #5 at the seam that CREATES the account. ensure_host_account
# is now the sole account-touching function with no guard of its own:
# host_account_removable (rail 7), configure_no_idle_lock, remove_no_idle_lock and
# remove_accountsservice_marker all validate their own <name> before doing
# anything mutating, and this one — the only function in the installer that runs
# `useradd`, `usermod -p '*'` and writes into the AccountsService directory —
# does not.
#
# Contract: slice 6b's header above states the rule the other four were given —
# "a function this destructive validates its own argument rather than trusting
# whatever install.sh checked at the entry point", refusing with "non-zero exit
# and a line on stderr" and leaving "the filesystem exactly as they found it".
# Applied here it means: valid_account_name BEFORE the passwd_entry lookup,
# before useradd/usermod, and before any file write.
#
# Two properties, and the second is the one that matters:
#   * the refusal itself — non-zero exit, a stderr line;
#   * NOTHING happened. `conf`/the install target are built as
#     "${DC_ACCOUNTSSERVICE_DIR}/$name", so "../victim/data" escapes the
#     AccountsService directory entirely and `install -D -m 0644` then OVERWRITES
#     a file that is none of this installer's business; and a malformed name
#     reaching `useradd --system --create-home` would create a real account under
#     whatever name the shell made of it. Hence the planted victim compared
#     byte-for-byte, and the PATH shim log asserted empty.
#
# The eight existing ensure_host_account tests cover the well-formed name and are
# untouched: this is purely additive.
test_ensure_host_account_refuses_malformed_account_names() {
  local db base dir victim shims log name tag i before

  require_ensure_host_account "malformed-name guard" || return 0
  db="$(make_fresh_passwd_db)"

  # Case A: the traversal. Account absent in the passwd fixture, so today's code
  # takes the create path and then writes through "$dir/../victim/data".
  base="$TMP/as-create-traversal"; dir="$base/users"; victim="$base/victim"
  mkdir -p "$dir" "$victim"
  printf 'somebody-elses-important-data\n' > "$victim/data"
  shims="$TMP/shims-as-create-traversal"; log="$(make_cmd_shims "$shims")"
  before="$(find "$base" | sort)"

  run_ensure_shimmed "$db" "$dir" "$shims" "../victim/data"
  [ "$ENSURE_RC" -ne 127 ] || fail "traversal: exit 127, not a refusal"
  assert_not_contains "$ENSURE_OUT" "command not found" \
    "traversal: the refusal came from the guard, not the shell"
  [ "$ENSURE_RC" -ne 0 ] || fail "traversal: expected non-zero exit, got $ENSURE_RC"
  [ -n "$ENSURE_OUT" ] || fail "traversal: expected a stderr line explaining the refusal"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "traversal: refused before useradd/usermod — no account tool was invoked"
  assert_eq "$(cat "$victim/data" 2>/dev/null || true)" "somebody-elses-important-data" \
    "traversal: a file OUTSIDE DC_ACCOUNTSSERVICE_DIR is NOT overwritten"
  assert_eq "$(ls -A "$dir" | wc -l | tr -d ' ')" "0" \
    "traversal: nothing is written inside DC_ACCOUNTSSERVICE_DIR either"
  assert_eq "$(find "$base" | sort)" "$before" \
    "traversal: nothing anywhere under the fixture changed"

  # And the rest of the malformed shapes, each against an empty fixture dir: a
  # refusal creates no account and leaves no file at all.
  i=0
  for name in ".." "." "./dreamconnect-host" 1000 "dc host" ""; do
    tag="as-create-malformed-$i"; i=$((i + 1))
    dir="$TMP/$tag"; mkdir -p "$dir"
    shims="$TMP/shims-$tag"; log="$(make_cmd_shims "$shims")"

    run_ensure_shimmed "$db" "$dir" "$shims" "$name"
    [ "$ENSURE_RC" -ne 127 ] || { fail "malformed name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$ENSURE_OUT" "command not found" \
      "malformed name '$name': the refusal came from the guard, not the shell"
    [ "$ENSURE_RC" -ne 0 ] || \
      fail "malformed ensure '$name': expected non-zero exit, got $ENSURE_RC"
    [ -n "$ENSURE_OUT" ] || \
      fail "malformed ensure '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "malformed ensure '$name': neither useradd nor usermod was invoked"
    assert_eq "$(find "$dir" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
      "malformed ensure '$name': nothing at all written under DC_ACCOUNTSSERVICE_DIR"
  done
}

# --- issue #24: wait_for_user_bus --------------------------------------------
#
# WHY THIS SLICE EXISTS (issue #24, the observed failure):
#   install.sh:291 `loginctl enable-linger "$USER_NAME"` starts user@<uid>.service
#   ASYNCHRONOUSLY. Lines 292-293 then run `systemctl --user daemon-reload` /
#   `enable --now` as that account, and on a first install /run/user/<uid>/bus does
#   not exist yet, so systemctl dies with
#       Failed to connect to user scope bus via local transport: No such file or directory
#   and install.sh's `set -euo pipefail` (line 22) kills the whole install. A
#   second run succeeds because by then the bus is up. A pure startup race.
#
# CONTRACT UNDER TEST — owner-confirmed, and the implementation follows it, not
# the reverse. No implementation exists at the time these tests were written.
#
#   wait_for_user_bus <uid> [timeout_seconds]
#
#   * Path checked: "${DC_RUNTIME_DIR_ROOT:-/run/user}/<uid>/bus". The env
#     override exists so these tests need neither root nor a real /run/user; the
#     /run/user default is deliberately NOT asserted, for the same reason
#     DC_ACCOUNTSSERVICE_DIR's default is not (slice 4): a test that forgot the
#     override must not be able to reach the real thing.
#   * Predicate: `[ -S <path> ]` — a real unix socket, not `-e`. What systemctl
#     needs is something to CONNECT to; a leftover regular file at that path
#     satisfies -e and still fails the connect, which is the very error this
#     function exists to prevent.
#   * Bounded poll: default timeout 30 seconds when arg 2 is omitted; arg 2
#     overrides it. Poll interval "${DC_BUS_POLL_INTERVAL:-0.2}", also
#     overridable — both so the failure-path tests below finish in ~1s.
#   * Returns 0 as soon as the socket appears; non-zero if the timeout elapses
#     without it, with something informative on stderr.
#   * DC_DRY_RUN=1 -> return 0 immediately, no polling, no filesystem access. A
#     dry run must never block for infrastructure that will never appear.
#
#   CALL SITE (asserted separately, as text, by the last test in this section):
#   install.sh must CALL it, after `loginctl enable-linger` and before the first
#   `systemctl --user` that follows. A helper nobody calls fixes nothing.
#
# WHERE THE EXPECTED VALUES COME FROM: the contract above (exit status, the -S
# predicate, the timeout bound, the dry-run short-circuit) and real unix sockets
# bound by python3 — not by touch/mkfifo — because -S is exactly the distinction
# under test and only a real AF_UNIX bind produces one.

BUS_PIDS=""

# Bind a REAL AF_UNIX socket at <path>, in the background, <delay> seconds from
# now, and hold it <hold> seconds. python3 is already a dependency of this repo's
# gate (run-tests.sh runs the daemon's unittest suite with it).
bind_bus_socket() {  # path delay_seconds hold_seconds
  mkdir -p "$(dirname "$1")"
  python3 -c '
import socket, sys, time
path, delay, hold = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
time.sleep(delay)
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.listen(1)
time.sleep(hold)
' "$1" "$2" "$3" &
  BUS_PIDS="$BUS_PIDS $!"
}

await_bus_socket() {  # path -> 0 once it is a socket, 1 after ~5s
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -S "$1" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

reap_bus_binders() {
  local p
  for p in $BUS_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  BUS_PIDS=""
  return 0
}

BUS_RC=0
BUS_ERR=""
BUS_MS=0

# Call it, capturing exit status, stderr and wall-clock milliseconds. Arg 4 empty
# means "omit timeout_seconds entirely", which is how the default is exercised
# without a 30-second test.
run_wait_bus() {  # dry runtime_root uid timeout_or_empty poll_interval
  local start end
  start="$(date +%s%3N)"
  if [ -n "$4" ]; then
    BUS_ERR="$(DC_DRY_RUN="$1" DC_RUNTIME_DIR_ROOT="$2" DC_BUS_POLL_INTERVAL="$5" \
               wait_for_user_bus "$3" "$4" 2>&1 >/dev/null)"; BUS_RC=$?
  else
    BUS_ERR="$(DC_DRY_RUN="$1" DC_RUNTIME_DIR_ROOT="$2" DC_BUS_POLL_INTERVAL="$5" \
               wait_for_user_bus "$3" 2>&1 >/dev/null)"; BUS_RC=$?
  fi
  end="$(date +%s%3N)"
  BUS_MS=$((end - start))
  return 0
}

# A missing function exits 127 with "command not found" on stderr, which is
# non-zero with a non-empty message — i.e. it would satisfy every timeout
# assertion below vacuously. Same rail assert_refused puts in front of slice 3.
require_wait_for_user_bus() {  # label
  declare -F wait_for_user_bus >/dev/null && return 0
  fail "$1: wait_for_user_bus() is not defined"
  return 1
}

assert_bus_failed() {  # label
  [ "$BUS_RC" -ne 127 ] || { fail "$1: exit 127 (command not found), not a timeout"; return 0; }
  assert_not_contains "$BUS_ERR" "command not found" \
    "$1: the failure came from wait_for_user_bus, not the shell"
  [ "$BUS_RC" -ne 0 ] || fail "$1: expected non-zero exit on timeout, got $BUS_RC"
  [ -n "$BUS_ERR" ] || fail "$1: expected an informative stderr line, got none"
}

test_library_defines_wait_for_user_bus() {
  declare -F wait_for_user_bus >/dev/null || \
    fail "install-lib.sh defines wait_for_user_bus(): not defined"
}

# (a) The bus is already up — the second-install case, and the one every later
# run hits. Returns 0 without waiting. timeout_seconds is OMITTED here, so this
# also pins that arg 2 is optional (under install.sh's `set -u`, a bare "$2"
# would abort) and that the default path does not sleep when the socket is there.
test_wait_for_user_bus_returns_zero_when_the_socket_already_exists() {
  local root
  require_wait_for_user_bus "socket already present" || return 0
  command -v python3 >/dev/null || { fail "socket already present: python3 is required"; return 0; }
  root="$TMP/bus-present"
  bind_bus_socket "$root/1000/bus" 0 5
  await_bus_socket "$root/1000/bus" || { fail "precondition: no socket was bound"; reap_bus_binders; return 0; }

  run_wait_bus "" "$root" 1000 "" 0.05
  assert_eq "$BUS_RC" "0" "existing bus socket: returns 0 (stderr: $BUS_ERR)"
  [ "$BUS_MS" -lt 2000 ] || fail "existing bus socket: returned in ${BUS_MS}ms, expected no waiting"
  reap_bus_binders
}

# (b) The race itself: the bus appears shortly AFTER the wait starts. Returning 0
# is only half the assertion — a stub that returns 0 unconditionally would satisfy
# that — so the elapsed lower bound pins that it actually waited for the socket
# rather than declaring victory on a path that did not exist yet.
test_wait_for_user_bus_returns_zero_when_the_socket_appears_while_polling() {
  local root path
  require_wait_for_user_bus "socket appears late" || return 0
  command -v python3 >/dev/null || { fail "socket appears late: python3 is required"; return 0; }
  root="$TMP/bus-late"; path="$root/1000/bus"
  mkdir -p "$root/1000"
  bind_bus_socket "$path" 0.6 5
  [ -S "$path" ] && fail "precondition: the socket was already bound before the wait started"

  run_wait_bus "" "$root" 1000 10 0.05
  assert_eq "$BUS_RC" "0" "late bus socket: returns 0 once it appears (stderr: $BUS_ERR)"
  [ "$BUS_MS" -ge 400 ] || \
    fail "late bus socket: returned after ${BUS_MS}ms — it cannot have waited for a socket bound 600ms in"
  [ "$BUS_MS" -lt 9000 ] || \
    fail "late bus socket: took ${BUS_MS}ms, expected a return soon after the socket appeared"
  [ -S "$path" ] || fail "late bus socket: postcondition — the bound path is a socket"
  reap_bus_binders
}

# (c) The bus never appears — a genuinely broken user manager. Bounded by the
# timeout ARGUMENT, so the installer reports a clear failure instead of hanging:
# the <15s ceiling is what proves arg 2 overrode the 30-second default.
test_wait_for_user_bus_fails_when_the_socket_never_appears() {
  local root
  require_wait_for_user_bus "socket never appears" || return 0
  root="$TMP/bus-never"; mkdir -p "$root/1000"

  run_wait_bus "" "$root" 1000 1 0.05
  assert_bus_failed "socket never appears"
  [ "$BUS_MS" -ge 900 ] || \
    fail "socket never appears: gave up after ${BUS_MS}ms, before the 1s timeout elapsed"
  [ "$BUS_MS" -lt 15000 ] || \
    fail "socket never appears: took ${BUS_MS}ms — timeout_seconds=1 did not override the 30s default"
  assert_contains "$BUS_ERR" "1000" "socket never appears: stderr names the uid it waited for"
}

# (c2) `-S`, not `-e`. A leftover regular file at the bus path is exactly what an
# existence check would accept and systemctl would still refuse to connect to.
test_wait_for_user_bus_ignores_a_plain_file_at_the_bus_path() {
  local root
  require_wait_for_user_bus "plain file at the bus path" || return 0
  root="$TMP/bus-plainfile"; mkdir -p "$root/1000"
  : > "$root/1000/bus"
  [ -e "$root/1000/bus" ] || fail "precondition: the plain file was not created"

  run_wait_bus "" "$root" 1000 1 0.05
  assert_bus_failed "plain file at the bus path"
  [ "$BUS_MS" -ge 900 ] || \
    fail "plain file at the bus path: returned in ${BUS_MS}ms — a regular file satisfied the check"
}

# (d) DC_DRY_RUN=1 returns 0 immediately, polls nothing and touches nothing. The
# runtime root deliberately does not exist: a dry run must not create it, and
# must not sit out the timeout waiting for a bus that will never be started.
test_wait_for_user_bus_returns_zero_immediately_when_dry() {
  local root
  require_wait_for_user_bus "dry run" || return 0
  root="$TMP/bus-dry-never-created"

  run_wait_bus 1 "$root" 1000 3 0.05
  assert_eq "$BUS_RC" "0" "DC_DRY_RUN=1: returns 0 (stderr: $BUS_ERR)"
  [ "$BUS_MS" -lt 1000 ] || \
    fail "DC_DRY_RUN=1: took ${BUS_MS}ms — it polled instead of short-circuiting"
  assert_file_absent "$root" "DC_DRY_RUN=1: creates nothing under DC_RUNTIME_DIR_ROOT"
}

# --- issue #24, slice 2: what `-S` alone cannot tell you ---------------------
#
# CONTRACT ADDITION (owner-approved after the red team pass): `-S` proves the
# path is a socket INODE, not that anything is listening on it. When a prior
# user@<uid>.service crashes, the kernel does NOT unlink its AF_UNIX inode, so
# /run/user/<uid>/bus survives as a socket that refuses every connect. `-S`
# accepts it, `systemctl --user` then dies with exactly the connect failure this
# function exists to prevent, and the installer aborts. So after `-S` is true,
# wait_for_user_bus must ATTEMPT A CONNECT and only treat a successful connect as
# "the bus is live"; ConnectionRefusedError/OSError means "not yet, keep polling".
# python3 is a hard runtime dependency by the time this runs (install.sh installs
# it at :244, the user-service section is at :285), so it is fair game here.
#
# WHERE THE EXPECTED VALUE COMES FROM: measured, not reasoned. Against a real
# orphaned inode (bind, listen, close the listener) on this kernel:
#     test -S <path>  -> 0            (the file still looks like a bus)
#     connect(<path>) -> ConnectionRefusedError [Errno 111]
# and against a bound-but-never-listen()ed socket, connect() is refused too —
# which is why every "live socket" fixture in this file calls .listen().

# Leave an ORPHANED socket inode at <path>: bind, listen, then close the
# listener. Synchronous — when it returns, the inode is there and dead. This is
# the crashed-user-manager leftover, reproduced exactly.
orphan_bus_socket() {  # path
  mkdir -p "$(dirname "$1")"
  python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
s.close()   # AF_UNIX does not unlink the inode when the listener dies
' "$1"
}

# (f) The orphan. Before the connect probe this returned 0 in a few ms and the
# install then died on the systemctl --user that followed; it must instead keep
# polling and time out like any other absent bus.
test_wait_for_user_bus_rejects_an_orphaned_socket_that_refuses_connections() {
  local root path
  require_wait_for_user_bus "orphaned bus socket" || return 0
  command -v python3 >/dev/null || { fail "orphaned bus socket: python3 is required"; return 0; }
  root="$TMP/bus-orphan"; path="$root/1000/bus"
  orphan_bus_socket "$path"
  [ -S "$path" ] || { fail "precondition: the orphaned inode is not a socket — the fixture proves nothing"; return 0; }

  run_wait_bus "" "$root" 1000 1 0.05
  assert_bus_failed "orphaned bus socket"
  [ "$BUS_MS" -ge 900 ] || \
    fail "orphaned bus socket: returned in ${BUS_MS}ms — a socket inode that refuses connect() was accepted as a live bus"
  [ -S "$path" ] || fail "orphaned bus socket: postcondition — the probe must not unlink the inode"
}

# --- issue #24, slice 2: timeout_seconds is input, so validate it -------------
#
# CONTRACT ADDITION (owner-approved): arg 2, when given, must be a non-negative
# integer no greater than 86400 (one day — a per-boot startup race that has not
# resolved inside a day is not going to). Anything else is a caller bug and must
# be REFUSED, fast and in this function's own voice, never fed to unguarded
# arithmetic.
#
# WHY, measured on this shell (bash, install.sh runs `set -euo pipefail`):
#   arg2="abc"               -> `$(( timeout * 1000 ))` under set -u aborts with
#                               "install-lib.sh: line 359: abc: unbound variable"
#                               — the caller's `|| die` never runs, the operator
#                               gets a line number instead of a diagnosis.
#   arg2=99999999999999999   -> *1000 overflows 64 bits to a positive ~7.7e18ms
#                               deadline; the "bounded" poll never returns. I
#                               measured this hanging past a 6s `timeout`, hence
#                               the watchdog below: a hang must fail the test,
#                               not stall the suite.
#
# Both cases therefore assert: non-zero, in well under a second, with stderr that
# names the bad argument and is NOT a shell crash and NOT a timeout report — the
# function never waited, so claiming it timed out would be a lie to the operator.

# Like run_wait_bus, but in a watchdogged child shell, because the behaviour
# under test today is an unbounded hang. Exit 124 is the watchdog firing.
run_wait_bus_guarded() {  # runtime_root uid timeout_arg poll_interval watchdog_seconds
  local start end
  start="$(date +%s%3N)"
  BUS_ERR="$(DC_RUNTIME_DIR_ROOT="$1" DC_BUS_POLL_INTERVAL="$4" \
             timeout "$5" bash -c 'set -uo pipefail; . "$1"; wait_for_user_bus "$2" "$3"' \
             _ "$LIB" "$2" "$3" 2>&1 >/dev/null)"; BUS_RC=$?
  end="$(date +%s%3N)"
  BUS_MS=$((end - start))
  return 0
}

assert_bus_arg_refused() {  # label bad_value
  [ "$BUS_RC" -ne 124 ] || { fail "$1: still running after the watchdog fired — '$2' was accepted and the poll is unbounded"; return 0; }
  # No 127 bail here, unlike assert_bus_failed: require_wait_for_user_bus has
  # already proved the function exists, and 127 is exactly what bash returns when
  # an expansion crashes the shell — the failure mode under test. The stderr
  # assertions below tell a crash apart from a refusal.
  [ "$BUS_RC" -ne 0 ] || fail "$1: expected non-zero exit for timeout_seconds='$2', got 0"
  [ "$BUS_MS" -lt 1000 ] || fail "$1: took ${BUS_MS}ms — an invalid timeout_seconds must be refused before any polling"
  [ -n "$BUS_ERR" ] || fail "$1: expected an informative stderr line, got none"
  assert_not_contains "$BUS_ERR" "unbound variable" \
    "$1: the shell crashed on the arithmetic instead of the function refusing the argument"
  assert_not_contains "$BUS_ERR" "command not found" "$1: the refusal came from the function, not the shell"
  assert_not_contains "$BUS_ERR" "timed out" \
    "$1: reported a timeout it never served — an invalid argument is a caller bug, not a slow bus"
  assert_contains "$BUS_ERR" "$2" "$1: stderr names the rejected value"
}

# (g) Non-numeric timeout_seconds.
test_wait_for_user_bus_refuses_a_non_numeric_timeout() {
  local root
  require_wait_for_user_bus "non-numeric timeout" || return 0
  root="$TMP/bus-arg-abc"; mkdir -p "$root/1000"

  run_wait_bus_guarded "$root" 1000 abc 0.05 3
  assert_bus_arg_refused "non-numeric timeout" "abc"
}

# (h) Numeric but absurd: 99999999999999999 overflows the millisecond deadline.
# The bound this asserts is 86400 seconds (one day); 99999999999999999 is far
# past it, so the builder may enforce the cap any way it likes.
test_wait_for_user_bus_refuses_a_timeout_beyond_the_86400_second_cap() {
  local root
  require_wait_for_user_bus "oversized timeout" || return 0
  root="$TMP/bus-arg-huge"; mkdir -p "$root/1000"

  run_wait_bus_guarded "$root" 1000 99999999999999999 0.05 3
  assert_bus_arg_refused "oversized timeout" "99999999999999999"
}

# (i) The other side of that cap, so it cannot be satisfied by refusing
# everything: 86400 is the documented maximum and must be ACCEPTED. Asserted
# with the bus already live, so accepting it costs milliseconds, not a day.
test_wait_for_user_bus_accepts_the_documented_maximum_timeout_of_86400() {
  local root
  require_wait_for_user_bus "maximum timeout accepted" || return 0
  command -v python3 >/dev/null || { fail "maximum timeout accepted: python3 is required"; return 0; }
  root="$TMP/bus-arg-max"
  bind_bus_socket "$root/1000/bus" 0 5
  await_bus_socket "$root/1000/bus" || { fail "precondition: no socket was bound"; reap_bus_binders; return 0; }

  run_wait_bus_guarded "$root" 1000 86400 0.05 5
  assert_eq "$BUS_RC" "0" "maximum timeout accepted: timeout_seconds=86400 is within the cap (stderr: $BUS_ERR)"
  [ "$BUS_MS" -lt 2000 ] || fail "maximum timeout accepted: returned in ${BUS_MS}ms with the bus already up"
  reap_bus_binders
}

# --- issue #24, slice 3: leading zeros are OCTAL, and the cap in isolation -----
#
# CONTRACT ADDITION (the safer of the two readings; see the contract question at
# the end of this block): timeout_seconds must be a PLAIN decimal integer. A
# digit string with a leading zero and more than one character ("08", "010",
# "0300") is AMBIGUOUS — it reads as decimal to the operator who typed it and as
# octal to `$(( ))` — so it is refused as a caller bug, exactly like "abc". It is
# never silently reinterpreted in either base. "0" itself stays valid: it is one
# character, unambiguous, and inside the documented 0..86400 range.
#
# WHY, measured on this shell (bash 5.3.9) against the code as it stands today:
#   arg2="08"   -> `deadline=$(( $(date +%s%3N) + timeout * 1000 ))` reports
#                  "install-lib.sh: line 392: 08: value too great for base
#                  (error token is "08")" — 8 is not an octal digit. That is an
#                  EXPANSION error, not a `return 1`, and it does not reach the
#                  call site as a failure: install.sh's shape,
#                      wait_for_user_bus "$USER_UID" || die "..."
#                  was measured printing the arithmetic error, NOT running die,
#                  and then continuing into the next statement with status 0 —
#                  i.e. straight on into the `systemctl --user` race that issue
#                  #24 exists to prevent, which is worse than the crash.
#   arg2="010"  -> valid octal, so no error at all: the deadline is built from 8
#                  seconds, the wait is a fifth shorter than asked for, and the
#                  timeout line then reports "timed out after 010s". Silently
#                  wrong duration, wrongly reported.
#
# WHERE THE EXPECTED VALUES COME FROM: the contract above plus install.sh's own
# call-site shape (`|| die`, itself asserted as text by the wiring test below) —
# not from the current implementation, which is what these two tests exist to
# contradict.
#
# CONTRACT QUESTION left for the owner: reject vs normalise. Stripping leading
# zeros (`${timeout##+(0)}`, or forcing base 10 with `$((10#$timeout))`) would
# accept "08" as 8 seconds instead. Rejecting is chosen here because it cannot
# guess wrong about what the caller meant and needs no new parsing; if the owner
# prefers normalisation, these two tests are the ones to change.

# install.sh's call site, reproduced: `set -euo pipefail`, then the call guarded
# by `|| die`. This is the seam the defect actually shows at — a refusal that
# arrives as an uncaught expansion error instead of a non-zero RETURN skips the
# `||` branch entirely, so asserting only on exit status and stderr would miss
# it. The two markers are echoed to stderr so they land in BUS_ERR alongside
# whatever the function itself said.
run_wait_bus_at_call_site() {  # runtime_root uid timeout_arg poll_interval watchdog_seconds
  local start end
  start="$(date +%s%3N)"
  BUS_ERR="$(DC_RUNTIME_DIR_ROOT="$1" DC_BUS_POLL_INTERVAL="$4" \
             timeout "$5" bash -c '
               set -euo pipefail
               . "$1"
               die() { echo "CALL-SITE-DIED: $*" >&2; exit 9; }
               wait_for_user_bus "$2" "$3" || die "the user bus never came up"
               echo "CALL-SITE-CONTINUED" >&2
             ' _ "$LIB" "$2" "$3" 2>&1 >/dev/null)"; BUS_RC=$?
  end="$(date +%s%3N)"
  BUS_MS=$((end - start))
  return 0
}

# assert_bus_arg_refused, plus the part that tells a REFUSAL apart from a CRASH
# that happens to be non-zero and happens to quote the bad value back. A bash
# expansion error is always prefixed with the file it blew up in and carries one
# of these base/token/syntax phrasings; the function's own message carries none
# of them. Deliberately no assertion on the wording of the refusal itself — that
# is the builder's to choose.
assert_bus_arg_refused_cleanly() {  # label bad_value
  assert_bus_arg_refused "$1" "$2"
  assert_not_contains "$BUS_ERR" "install-lib.sh" \
    "$1: stderr names the library file — that is bash reporting a crash at a line number, not the function refusing an argument"
  assert_not_contains "$BUS_ERR" "value too great for base" \
    "$1: '$2' reached arithmetic expansion and was parsed as octal instead of being refused"
  assert_not_contains "$BUS_ERR" "error token" \
    "$1: '$2' reached arithmetic expansion instead of being refused"
  assert_not_contains "$BUS_ERR" "syntax error" \
    "$1: '$2' reached arithmetic expansion instead of being refused"
}

# (j) "08": a leading zero that is not even valid octal. Three separate things
# are asserted, because the exit status alone cannot see the defect (the crash
# also exits non-zero): the refusal is clean and in the function's own voice; it
# carries the SAME status the function already gives any other invalid timeout,
# rather than whatever an uncaught expansion error happens to leave behind; and
# at install.sh's call site the `|| die` branch actually runs.
test_wait_for_user_bus_refuses_a_leading_zero_timeout_that_is_not_valid_octal() {
  local root refusal_rc
  require_wait_for_user_bus "leading-zero timeout 08" || return 0
  root="$TMP/bus-arg-08"; mkdir -p "$root/1000"

  # The status this function uses to refuse a bad timeout, taken from the case
  # already pinned by test (g) rather than hard-coded here.
  run_wait_bus_guarded "$root" 1000 abc 0.05 3
  refusal_rc="$BUS_RC"

  run_wait_bus_guarded "$root" 1000 08 0.05 3
  assert_bus_arg_refused_cleanly "leading-zero timeout 08" "08"
  assert_eq "$BUS_RC" "$refusal_rc" \
    "leading-zero timeout 08: refused with the same status as any other invalid timeout, not an uncaught shell error's status"

  run_wait_bus_at_call_site "$root" 1000 08 0.05 3
  assert_contains "$BUS_ERR" "CALL-SITE-DIED" \
    "leading-zero timeout 08: install.sh's '|| die' must fire — a refusal has to arrive as a non-zero RETURN, not an expansion error that skips the || branch"
  assert_not_contains "$BUS_ERR" "CALL-SITE-CONTINUED" \
    "leading-zero timeout 08: the caller ran on past a failed wait, straight into the systemctl --user race issue #24 is about"
  [ "$BUS_MS" -lt 1000 ] || \
    fail "leading-zero timeout 08: the call site took ${BUS_MS}ms — an invalid timeout must be refused before any polling"
}

# (k) "010": a leading zero that IS valid octal, so nothing crashes and nothing
# is reported — the wait is simply 8 seconds instead of 10. The watchdog is set
# below that 8s so a silently-accepted "010" shows up as exit 124 rather than as
# a test that quietly passes after sitting out the octal duration.
test_wait_for_user_bus_refuses_a_leading_zero_timeout_that_is_valid_octal() {
  local root
  require_wait_for_user_bus "leading-zero timeout 010" || return 0
  root="$TMP/bus-arg-010"; mkdir -p "$root/1000"

  run_wait_bus_guarded "$root" 1000 010 0.05 3
  assert_bus_arg_refused_cleanly "leading-zero timeout 010" "010"
}

# (l) The cap, isolated. Test (h) passes 99999999999999999, which any
# length-based proxy check refuses on digit count alone — so it cannot tell
# whether the 86400 bound itself is enforced. 90000 is five digits, the same
# width as the accepted maximum 86400, so only a comparison against the cap can
# refuse it. Falsification checked before this was committed: with the cap
# raised to 999999 in a throwaway copy of install-lib.sh, test (h) still passes
# and this test fails (exit 124 — 90000 accepted, watchdog fired).
test_wait_for_user_bus_refuses_a_timeout_just_past_the_cap() {
  local root
  require_wait_for_user_bus "timeout just past the cap" || return 0
  root="$TMP/bus-arg-90000"; mkdir -p "$root/1000"

  run_wait_bus_guarded "$root" 1000 90000 0.05 3
  assert_bus_arg_refused_cleanly "timeout just past the cap" "90000"
}

# (e) The wiring. Everything above can be green with the helper orphaned, in
# which case issue #24 is not fixed at all — so this asserts the call site in
# install.sh itself, by line ordering.
#
# Scoped to the lines AFTER `loginctl enable-linger`: install.sh's uninstall()
# also runs `systemctl --user` (lines 84/86 today), long before the install path,
# and those are not what this race is about. Comment lines are skipped so that
# documenting the call does not count as making it.
first_code_line() {  # file regex [after_line] -> line number, or empty
  awk -v re="$2" -v after="${3:-0}" \
    'NR > after && $0 ~ re && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$1"
}

test_install_sh_waits_for_the_user_bus_before_the_first_systemctl_user_call() {
  local sh linger waited sysd
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  linger="$(first_code_line "$sh" 'loginctl enable-linger')"
  [ -n "$linger" ] || { fail "call site: no 'loginctl enable-linger' line in install.sh"; return 0; }
  sysd="$(first_code_line "$sh" 'systemctl --user' "$linger")"
  [ -n "$sysd" ] || { fail "call site: no 'systemctl --user' line after enable-linger"; return 0; }
  waited="$(first_code_line "$sh" 'wait_for_user_bus' "$linger")"
  [ -n "$waited" ] || {
    fail "call site: install.sh never calls wait_for_user_bus after enable-linger (linger at line $linger, first systemctl --user at line $sysd) — the helper is orphaned and issue #24 is not fixed"
    return 0; }

  [ "$linger" -lt "$waited" ] || \
    fail "call site: wait_for_user_bus (line $waited) must come AFTER loginctl enable-linger (line $linger)"
  [ "$waited" -lt "$sysd" ] || \
    fail "call site: wait_for_user_bus (line $waited) must come BEFORE the first systemctl --user after linger (line $sysd)"
}

# (e2) The call site's ERROR WIRING, which the ordering test above cannot see.
# Mutating install.sh's `wait_for_user_bus "$USER_UID" || die "..."` down to
# `|| true` leaves that test — and the whole suite — green, while the installer
# sails past a dead bus straight into the `systemctl --user` failure this slice
# exists to prevent. install.sh cannot be executed here (it demands root and does
# top-level work), so this is a text assertion, scoped to the one statement that
# contains the call and deliberately blind to wording and layout: the die message
# may be rewritten and the continuation reflowed without failing it.
logical_statement_at() {  # file line -> that line plus its backslash continuations, joined
  awk -v start="$2" '
    NR < start { next }
    { cont = ($0 ~ /\\[[:space:]]*$/); line = $0; sub(/\\[[:space:]]*$/, "", line); buf = buf line " " }
    cont == 0 { print buf; exit }
  ' "$1"
}

test_install_sh_aborts_the_install_when_the_user_bus_never_comes_up() {
  local sh waited linger stmt
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  linger="$(first_code_line "$sh" 'loginctl enable-linger')"
  [ -n "$linger" ] || { fail "error wiring: no 'loginctl enable-linger' line in install.sh"; return 0; }
  waited="$(first_code_line "$sh" 'wait_for_user_bus' "$linger")"
  [ -n "$waited" ] || { fail "error wiring: install.sh never calls wait_for_user_bus after enable-linger"; return 0; }

  stmt="$(logical_statement_at "$sh" "$waited")"
  [ -n "$stmt" ] || { fail "error wiring: could not read the statement at install.sh:$waited"; return 0; }

  [[ "$stmt" =~ \|\|[[:space:]]*die[[:space:]]+[^[:space:]] ]] || \
    fail "error wiring: install.sh:$waited must handle a wait_for_user_bus failure with '|| die <message>' — a failed wait that does not abort lets the install run on into the systemctl --user failure issue #24 is about. Statement was: [$stmt]"
  assert_not_contains "$stmt" "|| true" \
    "error wiring: install.sh:$waited swallows a wait_for_user_bus failure"
  assert_not_contains "$stmt" "|| :" \
    "error wiring: install.sh:$waited swallows a wait_for_user_bus failure"
}

# --- runner ------------------------------------------------------------------
for CURRENT in \
  test_sourcing_is_side_effect_free \
  test_library_defines_the_installer_functions \
  test_run_executes_the_command_by_default \
  test_run_suppresses_execution_when_dry \
  test_resolve_host_identity_defaults_to_fallback_user \
  test_resolve_host_identity_prefers_the_named_account \
  test_resolve_host_identity_socket_is_run_user_uid_dreamconnect_sock \
  test_resolve_host_identity_fails_when_the_account_is_absent \
  test_library_defines_the_state_and_removal_functions \
  test_write_install_state_creates_parent_dirs_and_all_four_keys \
  test_write_install_state_overwrites_rather_than_appends \
  test_install_state_round_trips_all_four_values \
  test_read_install_state_resets_to_safe_defaults_when_absent \
  test_host_account_removable_accepts_the_account_we_created \
  test_host_account_removable_refuses_an_unknown_account \
  test_host_account_removable_refuses_uid_zero \
  test_host_account_removable_refuses_dangerous_home_dirs \
  test_host_account_removable_refuses_the_protected_user \
  test_host_account_removable_allows_an_empty_protected_user \
  test_host_account_removable_refuses_sudo_user \
  test_host_account_removable_refuses_when_state_says_not_created \
  test_host_account_removable_refuses_when_state_file_is_absent \
  test_host_account_removable_refuses_when_state_names_another_account \
  test_host_account_removable_refuses_a_wrong_gecos_marker \
  test_library_defines_ensure_host_account \
  test_ensure_host_account_creates_a_system_account_with_the_marker \
  test_ensure_host_account_grants_no_supplementary_groups \
  test_ensure_host_account_disables_the_password \
  test_ensure_host_account_writes_nothing_when_dry \
  test_ensure_host_account_skips_useradd_when_the_account_exists \
  test_ensure_host_account_writes_the_hidden_marker_file_idempotently \
  test_ensure_host_account_passes_the_marker_as_one_argument \
  test_ensure_host_account_reports_whether_it_created_the_account \
  test_library_defines_the_idle_lock_functions \
  test_configure_no_idle_lock_writes_the_dconf_profile \
  test_configure_no_idle_lock_writes_all_seven_dconf_keys \
  test_configure_no_idle_lock_points_the_session_at_the_profile \
  test_configure_no_idle_lock_skips_gnome_initial_setup \
  test_configure_no_idle_lock_refuses_reserved_dconf_names \
  test_configure_no_idle_lock_is_byte_identical_on_a_second_run \
  test_remove_no_idle_lock_reverts_everything_configure_wrote \
  test_remove_no_idle_lock_is_a_no_op_when_nothing_was_configured \
  test_configure_no_idle_lock_gates_only_dconf_update_behind_run \
  test_configure_no_idle_lock_chowns_the_home_files_to_the_account \
  test_configure_no_idle_lock_survives_a_failing_chown \
  test_configure_no_idle_lock_backs_up_preexisting_home_files \
  test_configure_no_idle_lock_writes_no_backups_for_fresh_home_files \
  test_configure_no_idle_lock_backs_up_home_files_only_once_across_reruns \
  test_remove_no_idle_lock_restores_backed_up_home_files \
  test_remove_no_idle_lock_removes_fresh_home_files_it_created \
  test_no_idle_lock_backs_up_each_home_file_independently \
  test_configure_no_idle_lock_backs_up_preexisting_dconf_system_files \
  test_configure_no_idle_lock_writes_no_backups_for_fresh_dconf_system_files \
  test_configure_no_idle_lock_backs_up_dconf_system_files_only_once_across_reruns \
  test_remove_no_idle_lock_restores_backed_up_dconf_system_files \
  test_remove_no_idle_lock_removes_fresh_dconf_system_files_it_created \
  test_no_idle_lock_backs_up_each_dconf_system_file_independently \
  test_library_defines_uninstall_host_account \
  test_uninstall_host_account_removes_a_removable_account \
  test_uninstall_host_account_runs_nothing_when_the_gate_refuses \
  test_uninstall_host_account_runs_the_commands_in_order \
  test_uninstall_host_account_deletes_even_when_terminate_user_fails \
  test_uninstall_host_account_reports_a_failing_userdel \
  test_uninstall_host_account_survives_set_e_when_loginctl_fails \
  test_remove_no_idle_lock_refuses_reserved_dconf_names \
  test_library_defines_the_name_and_marker_functions \
  test_valid_account_name_accepts_ordinary_names \
  test_valid_account_name_accepts_a_thirty_two_character_name \
  test_valid_account_name_rejects_an_empty_name \
  test_valid_account_name_rejects_numeric_names \
  test_valid_account_name_rejects_path_separators_and_dots \
  test_valid_account_name_rejects_dot_and_dotdot \
  test_valid_account_name_rejects_overlong_names \
  test_valid_account_name_rejects_shell_metacharacters \
  test_host_account_removable_refuses_a_malformed_account_name \
  test_configure_no_idle_lock_refuses_malformed_account_names \
  test_remove_no_idle_lock_refuses_malformed_account_names \
  test_ensure_host_account_writes_no_backup_for_a_new_marker_file \
  test_ensure_host_account_backs_up_a_preexisting_accountsservice_file \
  test_ensure_host_account_backs_up_only_once_across_reruns \
  test_remove_accountsservice_marker_restores_a_backed_up_file \
  test_remove_accountsservice_marker_removes_a_marker_we_created \
  test_remove_accountsservice_marker_is_a_no_op_when_nothing_exists \
  test_accountsservice_marker_round_trips_a_preexisting_file \
  test_remove_accountsservice_marker_refuses_malformed_account_names \
  test_ensure_host_account_refuses_malformed_account_names \
  test_library_defines_wait_for_user_bus \
  test_wait_for_user_bus_returns_zero_when_the_socket_already_exists \
  test_wait_for_user_bus_returns_zero_when_the_socket_appears_while_polling \
  test_wait_for_user_bus_fails_when_the_socket_never_appears \
  test_wait_for_user_bus_ignores_a_plain_file_at_the_bus_path \
  test_wait_for_user_bus_returns_zero_immediately_when_dry \
  test_wait_for_user_bus_rejects_an_orphaned_socket_that_refuses_connections \
  test_wait_for_user_bus_refuses_a_non_numeric_timeout \
  test_wait_for_user_bus_refuses_a_timeout_beyond_the_86400_second_cap \
  test_wait_for_user_bus_accepts_the_documented_maximum_timeout_of_86400 \
  test_wait_for_user_bus_refuses_a_leading_zero_timeout_that_is_not_valid_octal \
  test_wait_for_user_bus_refuses_a_leading_zero_timeout_that_is_valid_octal \
  test_wait_for_user_bus_refuses_a_timeout_just_past_the_cap \
  test_install_sh_waits_for_the_user_bus_before_the_first_systemctl_user_call \
  test_install_sh_aborts_the_install_when_the_user_bus_never_comes_up
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
echo "installer shell tests passed"
