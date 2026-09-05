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
  for fn in die detect_user detect_pm pm_install detect_monitor run; do
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
#
#   read_install_state
#     No args. Sets FOUR variables in the CALLER's scope from "$DC_STATE_FILE":
#     HOST_ACCOUNT, HOST_UID, CREATED_ACCOUNT. When the file does
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
write_state_fixture() {  # path account uid created [ignored]
  # Arg 5 is accepted and ignored: it was AUTOLOGIN_SET, retired with autologin.
  # Call sites still pass it, and read_install_state ignores unknown keys, so a
  # state file written by an older install still parses.
  mkdir -p "$(dirname "$1")"
  {
    echo "HOST_ACCOUNT=$2"
    echo "HOST_UID=$3"
    echo "CREATED_ACCOUNT=$4"
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
test_write_install_state_creates_parent_dirs_and_all_keys() {
  local body
  local DC_STATE_FILE="$TMP/state-fresh/dreamconnect/install.state"
  local state="$DC_STATE_FILE"
  write_install_state dreamconnect-host 987 1 1
  assert_file_exists "$state" "write_install_state creates the file and its parents"
  body="$(cat "$state" 2>/dev/null || true)"
  assert_contains "$body" "HOST_ACCOUNT=dreamconnect-host" "state file records HOST_ACCOUNT"
  assert_contains "$body" "HOST_UID=987"                   "state file records HOST_UID"
  assert_contains "$body" "CREATED_ACCOUNT=1"              "state file records CREATED_ACCOUNT"
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
  assert_eq "${lines// /}" "3" "rewritten state file still has exactly 3 lines"
  accounts="$(grep -c '^HOST_ACCOUNT=' "$state" 2>/dev/null || echo 0)"
  assert_eq "$accounts" "1" "rewritten state file has exactly one HOST_ACCOUNT line"
  assert_contains "$(cat "$state" 2>/dev/null || true)" "HOST_ACCOUNT=dreamconnect-host2" \
    "the second write wins"
}

# Breaker lap 2, finding 1 (CHECKPOINT.md): "a bare `sudo ./install.sh` re-run
# with DREAMCONNECT_HOST_ACCOUNT unset takes the warn-and-reuse path, re-enters
# ensure_host_account which finds the account already exists
# (ACCOUNT_WAS_CREATED=0 this run), and write_install_state then overwrites the
# previously-recorded CREATED_ACCOUNT=1 with 0 — permanently disarming
# host_account_removable's gate, so --uninstall can never remove that account
# again." That is issue #21's own failure mode ("uninstall MUST delete the
# account and fully revert") arriving through the ordinary upgrade path.
#
# So CREATED_ACCOUNT is STICKY ONCE TRUE, PER ACCOUNT NAME. Extending the
# write_install_state contract above:
#
#   Before writing, read what is already recorded. When the recorded
#   HOST_ACCOUNT is EXACTLY <name>, the CREATED_ACCOUNT written is 1 if EITHER
#   the recorded value or arg 3 is 1 (a logical OR); otherwise arg 3 is written
#   as given. A record naming a DIFFERENT account carries nothing over — its 1
#   belongs to that account, not this one — and neither does an absent record.
#
#   Only CREATED_ACCOUNT is sticky. HOST_ACCOUNT, HOST_UID and AUTOLOGIN_SET are
#   always this run's arguments, so "keep the whole previous record" is not the
#   fix: it would make a re-run that stops setting autologin unrevertable in the
#   other direction.
#
# The prior record is written BY HAND, as everywhere else in this slice, so the
# writer under test cannot vouch for its own starting point; the result is read
# back through read_install_state, the seam host_account_removable's rail 5
# actually consults.
test_write_install_state_never_downgrades_created_account_for_the_same_account() {
  local c prior_acct prior_created acct created expected label i=0
  local DC_STATE_FILE
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT
  # prior_account prior_created  this_account this_created  expected_recorded
  local cases=(
    "dreamconnect-host  1  dreamconnect-host   0  1"
    "dreamconnect-host  0  dreamconnect-host   1  1"
    "dreamconnect-host  1  dreamconnect-host   1  1"
    "dreamconnect-host  0  dreamconnect-host   0  0"
    "dreamconnect-host  1  dreamconnect-host2  0  0"
  )
  for c in "${cases[@]}"; do
    read -r prior_acct prior_created acct created expected <<<"$c"
    DC_STATE_FILE="$TMP/state-sticky-$i/install.state"; i=$((i + 1))
    label="recorded $prior_acct/CREATED_ACCOUNT=$prior_created, this run $acct/$created"

    write_state_fixture "$DC_STATE_FILE" "$prior_acct" 987 "$prior_created" 1
    write_install_state "$acct" 986 "$created"

    read_install_state
    assert_eq "$CREATED_ACCOUNT" "$expected" "$label: CREATED_ACCOUNT"
    assert_eq "$HOST_ACCOUNT" "$acct"        "$label: HOST_ACCOUNT is this run's account"
    assert_eq "$HOST_UID" "986"              "$label: HOST_UID is this run's uid"
  done
}

# Crash-safety (CHECKPOINT.md "Breaker findings on slice 1", finding 2): "an
# interrupted write (crash/power-loss/ENOSPC) leaves an empty or truncated
# install.state, which host_account_installable then reads as 'nothing
# recorded' — silently re-opening #21's exact strand-the-old-account failure".
# So the contract is: a write that dies part way through leaves the PREVIOUS
# complete record in place. Never an empty file, never half a record.
#
# The interruption is real, not simulated: RLIMIT_FSIZE=0 (`ulimit -f 0`) lets
# the open/truncate through and then kills the writer with SIGXFSZ on the very
# first byte it tries to write — the crash window between truncating the state
# file and finishing it. Deterministic, no timing race. Nested one process deep
# with its stderr discarded so the shell's "File size limit exceeded" notice
# and any core file stay out of the suite; `ulimit -c 0` for the same reason.
# The fixture is written BY HAND, as everywhere else in this slice, so the
# writer under test cannot be the thing that vouches for its own starting point.
test_write_install_state_survives_a_write_killed_part_way_through() {
  local state before after rc
  local DC_STATE_FILE="$TMP/state-interrupted/install.state"
  state="$DC_STATE_FILE"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  before="$(cat "$state")"

  rc="$(bash -c '
    exec 2>/dev/null
    ulimit -c 0; ulimit -f 0
    . "$1"
    ( DC_STATE_FILE="$2" write_install_state dreamconnect-host2 986 0 0 >/dev/null 2>&1 )
    echo "$?"
  ' _ "$LIB" "$state")"
  [ "${rc:-0}" -gt 128 ] || fail "precondition: the writer was not killed mid-write (rc=$rc)"

  after="$(cat "$state" 2>/dev/null || true)"
  assert_eq "$after" "$before" \
    "an interrupted write leaves the previous install.state byte-for-byte intact"

  # The consequence the finding names, asserted at the seam that suffers it:
  # a reader must still see the recorded account, not "nothing recorded".
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT
  read_install_state
  assert_eq "$HOST_ACCOUNT"    "dreamconnect-host" "interrupted write: HOST_ACCOUNT still recorded"
  assert_eq "$CREATED_ACCOUNT" "1"                 "interrupted write: CREATED_ACCOUNT still recorded"
}

test_install_state_round_trips_all_four_values() {
  local DC_STATE_FILE="$TMP/state-roundtrip/install.state"
  local HOST_ACCOUNT="stale" HOST_UID="stale" CREATED_ACCOUNT="stale"
  write_install_state dreamconnect-host 987 1 0
  read_install_state
  assert_eq "$HOST_ACCOUNT"    "dreamconnect-host" "round-trip HOST_ACCOUNT"
  assert_eq "$HOST_UID"        "987"               "round-trip HOST_UID"
  assert_eq "$CREATED_ACCOUNT" "1"                 "round-trip CREATED_ACCOUNT"
}

# The stale-global bug class: a reader that only assigns when the file exists
# leaves the PREVIOUS account's name in HOST_ACCOUNT, and the gate would then
# green-light deleting it.
test_read_install_state_resets_to_safe_defaults_when_absent() {
  local DC_STATE_FILE="$TMP/state-stale/install.state"
  local HOST_ACCOUNT="" HOST_UID="" CREATED_ACCOUNT=""
  write_install_state dreamconnect-host 987 1 1
  read_install_state
  assert_eq "$HOST_ACCOUNT" "dreamconnect-host" "precondition: state was read"
  DC_STATE_FILE="$TMP/state-stale/no-such-file.state"
  read_install_state
  assert_eq "$HOST_ACCOUNT"    "" "absent state file resets HOST_ACCOUNT to empty"
  assert_eq "$HOST_UID"        "" "absent state file resets HOST_UID to empty"
  assert_eq "$CREATED_ACCOUNT" "0" "absent state file resets CREATED_ACCOUNT to 0"
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

# The desktop half of the same keyfile: stock GNOME (no taskbar extension) with
# the admin toolset pinned to the dash in a fixed order.
test_configure_no_idle_lock_configures_the_backstage_desktop() {
  local d home shims f body fav
  require_no_idle_lock "backstage desktop" || return 0
  read -r d home <<<"$(idle_fixture backstage-desktop)"
  shims="$TMP/shims-backstage-desktop"; make_dconf_shim "$shims" >/dev/null
  run_configure "$d" dreamconnect-host "$home" "$shims"
  f="$d/db/dreamconnect-host.d/00-display-host"
  body="$(cat "$f" 2>/dev/null || true)"

  # Animations off: an overview transition is ~0.3s of full-screen change that
  # gets captured/encoded/shipped for nothing, and is the app-switcher "chug" on
  # a CPU-contended box. Disabling them halves the interaction CPU.
  assert_line "$body" "[org/gnome/desktop/interface]" "interface section header"
  assert_line "$body" "enable-animations=false" "GNOME animations are disabled for the remote desktop"

  assert_line "$body" "[org/gnome/shell]" "shell section header"
  # Vanilla layout: NO window-list / taskbar extension, and the operator asked
  # specifically for stock GNOME back. Pinning an extension here would resurrect
  # the bottom bar whose window labels overlapped the dash.
  assert_not_contains "$body" "enabled-extensions" \
    "no shell extensions are forced — this is vanilla GNOME, not the window-list layout"
  assert_not_contains "$body" "window-list" "the window-list taskbar is gone"

  assert_contains "$body" "favorite-apps=" "the dash is pre-pinned"
  fav="$(printf '%s\n' "$body" | sed -n 's/^favorite-apps=//p')"
  # The exact order the operator specified: Files, Terminal, Disks, dconf-editor
  # (registry), Logs (event viewer), Services, System Monitor (resources),
  # System Information, Firewall, Text Editor (notepad).
  local want="['org.gnome.Nautilus.desktop', 'org.gnome.Ptyxis.desktop', 'org.gnome.DiskUtility.desktop', 'ca.desrt.dconf-editor.desktop', 'org.gnome.Logs.desktop', 'dreamconnect-services.desktop', 'org.gnome.SystemMonitor.desktop', 'dreamconnect-sysinfo.desktop', 'firewall-config.desktop', 'org.gnome.TextEditor.desktop']"
  assert_eq "$fav" "$want" "the dash is pinned in the requested order"

  # The two tools GNOME ships no GUI for get custom launchers in the account's
  # own applications dir (disposable with the home on uninstall).
  assert_file_exists "$home/.local/share/applications/dreamconnect-services.desktop" \
    "a System Services launcher is created"
  assert_file_exists "$home/.local/share/applications/dreamconnect-sysinfo.desktop" \
    "a System Information launcher is created"
  assert_contains "$(cat "$home/.local/share/applications/dreamconnect-services.desktop" 2>/dev/null)" \
    "systemctl" "the services launcher runs systemctl"
  assert_contains "$(cat "$home/.local/share/applications/dreamconnect-services.desktop" 2>/dev/null)" \
    "Terminal=true" "the services launcher opens in a terminal, not hardcoding one"
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

# --- issue #21, breaker lap 1 defect 2: the account was deleted by hand -------
#
# WHY THESE TESTS EXIST. Issue #21's own motivating scenario is an account that
# is removed OUTSIDE this tool (`userdel -r dchost` by hand) before
# `sudo ./install.sh --uninstall` ever runs. Traced through the code as it
# stands, that scenario now dead-ends:
#
#   uninstall_host_account dchost  ->  host_account_removable dchost  ->  the
#   "no such account in the passwd source" rail refuses  ->  non-zero  ->
#   install.sh's uninstall() sets account_removed=0 and therefore SKIPS
#   `rm -f "$(install_state_file)"` (install.sh:155-159), printing "state
#   preserved ... so a future --uninstall can retry account removal". No retry
#   can ever succeed: the account is gone, so that same rail refuses every time.
#   install.state is then stuck naming dchost forever, and slice 1's
#   host_account_installable refuses to install under ANY other account for as
#   long as it is there. Issue #21's exact repro, blocked by our own slice 1 fix.
#
# CONTRACT UNDER TEST — an extension of the slice 6a contract above; the
# implementation follows this, not the reverse. No implementation of this branch
# exists at the time these tests were written. Expected values come from issue
# #21's scenario plus install.sh's caller contract (account_removed=1 is what
# clears install.state), NOT from what any code currently does:
#
#   0. BEFORE consulting host_account_removable, uninstall_host_account asks
#      whether <name> has a passwd entry AT ALL. If <name> is non-empty and the
#      passwd source has no entry for it, the account is already gone: there is
#      nothing to delete, which IS the success case. Return 0, having run
#      NOTHING — no `loginctl disable-linger`, no `loginctl terminate-user`, no
#      `userdel` (every one of them is meaningless on an account that does not
#      exist, and userdel would simply fail). Say so in the output, naming the
#      account, so install.sh's ">> removed display-host account X" is not the
#      only thing the operator sees. The wording is the builder's; these tests
#      assert only that the account is named.
#
#   0b. An EMPTY <name> is still a refusal, exactly as today. "No such account"
#      is a claim about a named account; an empty name names none, and reporting
#      a removal that was never even asked for would clear install.state on a
#      nonsense call.
#
#   1-4. For a name that DOES have a passwd entry, behaviour is COMPLETELY
#      unchanged: host_account_removable is still consulted first and every one
#      of its rails still refuses exactly as before.
#
#   host_account_removable's own contract is NOT touched by this. Its "no such
#   account in the passwd source" rail keeps refusing — it is the right answer
#   for a caller that does not already know the account is gone. The fix belongs
#   in the caller that does know.

# The box in issue #21's scenario: the same removal fixture as everywhere else
# in this slice, with the dreamconnect-host line ALREADY REMOVED — what
# /etc/passwd actually looks like after a hand-run `userdel -r dreamconnect-host`.
# Every decoy entry is kept, so a test that accidentally names one still sees it.
make_hand_deleted_passwd_db() {
  cat > "$TMP/passwd-hand-deleted" <<'EOF'
root:x:0:0:Super User:/root:/bin/bash
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
dc-uid0:x:0:0:DreamConnect display host:/var/lib/dc-uid0:/bin/bash
dc-home-slash:x:981:981:DreamConnect display host:/:/bin/bash
dc-home-home:x:982:982:DreamConnect display host:/home:/bin/bash
dc-home-root:x:983:983:DreamConnect display host:/root:/bin/bash
dc-gecos-empty:x:984:984::/var/lib/dc-gecos-empty:/bin/bash
dc-gecos-trailing:x:985:985:DreamConnect display host :/var/lib/dc-gecos-trailing:/bin/bash
dc-gecos-lower:x:986:986:dreamconnect display host:/var/lib/dc-gecos-lower:/bin/bash
dc-gecos-human:x:988:988:Roger Rickard:/var/lib/dc-gecos-human:/bin/bash
EOF
  echo "$TMP/passwd-hand-deleted"
}

# Contract 0. The state file still records exactly what a successful install
# wrote (HOST_ACCOUNT=dreamconnect-host, CREATED_ACCOUNT=1) — that is the whole
# point: install.state outlives the account, and is what has to be cleared.
#
# The last phase is the anti-vacuous control: an implementation that returned 0
# and ran nothing UNCONDITIONALLY would satisfy every assertion above it, so the
# same call against the same state and the same shims — differing ONLY in that
# the passwd entry is still there — must still reach userdel.
test_uninstall_host_account_treats_a_hand_deleted_account_as_already_removed() {
  local gone_db live_db state shims log
  require_uninstall_host_account "hand-deleted account" || return 0
  gone_db="$(make_hand_deleted_passwd_db)"
  live_db="$(make_removal_passwd_db)"
  state="$TMP/state-uninstall-gone/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1

  # Precondition: the fixture really is issue #21's box.
  assert_eq "$(DC_PASSWD_DB="$gone_db" passwd_entry dreamconnect-host)" "" \
    "precondition: the hand-deleted fixture has no dreamconnect-host entry"

  # Dry run first: nothing may even be EMITTED, let alone executed.
  shims="$TMP/shims-uninstall-gone-dry"; log="$(make_uninstall_shims "$shims" 0)"
  run_uninstall_dry "$gone_db" "$state" "" "$shims" dreamconnect-host kogies
  [ "$UNINSTALL_RC" -ne 127 ] || { fail "hand-deleted: exit 127, not a result"; return 0; }
  assert_eq "$UNINSTALL_RC" "0" \
    "an account already deleted by hand: uninstall_host_account exits 0 (nothing to remove IS removed) so install.sh clears install.state"
  assert_eq "$(uninstall_dry_all)" "" \
    "hand-deleted: no command is even emitted — there is no account to disable-linger, terminate or userdel"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "hand-deleted (dry): nothing was executed either"
  assert_contains "$UNINSTALL_OUT" "dreamconnect-host" \
    "hand-deleted: the output names the account it found nothing to remove"

  # And for real, with loginctl/userdel shimmed away: still nothing runs.
  shims="$TMP/shims-uninstall-gone-real"; log="$(make_uninstall_shims "$shims" 0)"
  run_uninstall_shimmed "$gone_db" "$state" "$shims" dreamconnect-host kogies
  assert_eq "$UNINSTALL_RC" "0" "hand-deleted (real run): exits 0"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "hand-deleted (real run): neither loginctl nor userdel was invoked on a nonexistent account"

  # Control: the ONLY difference is that the passwd entry is still there.
  shims="$TMP/shims-uninstall-gone-control"; log="$(make_uninstall_shims "$shims" 0)"
  run_uninstall_shimmed "$live_db" "$state" "$shims" dreamconnect-host kogies
  assert_eq "$UNINSTALL_RC" "0" "control: an account that IS still there is removed, exit 0"
  assert_eq "$(uninstall_op_sequence "$log")" "disable-linger
terminate-user
userdel" "control: an account that IS still there still gets the full removal, in order"
}

# Contract 0b + 1-4: the regression guard on the fix above. "The account is gone"
# is the ONLY thing that may short-circuit the gate. An account that is really
# there, and a call with no account name at all, must refuse exactly as before —
# a short-circuit that swallowed those would report a removal that never
# happened and let install.sh delete the state file that proves the account is
# ours (install.sh:151-159).
test_uninstall_host_account_still_refuses_an_account_that_is_really_there() {
  local db shims log state i
  require_uninstall_host_account "still refuses" || return 0
  db="$(make_removal_passwd_db)"

  #      name                recorded account    created  label
  local -a names=(dreamconnect-host dreamconnect-host dc-gecos-human "")
  local -a acct=(dreamconnect-host  dreamconnect-host dc-gecos-human dreamconnect-host)
  local -a created=(0 1 1 1)
  local -a nostate=(0 1 0 0)
  local -a labels=("CREATED_ACCOUNT=0 for an account that exists"
                   "no state file at all for an account that exists"
                   "wrong GECOS on an account that exists"
                   "no account name given")

  for i in 0 1 2 3; do
    state="$TMP/state-uninstall-present-$i/install.state"
    if [ "${nostate[$i]}" = "1" ]; then
      state="$TMP/state-uninstall-present-$i-absent/install.state"
      rm -f "$state"
    else
      write_state_fixture "$state" "${acct[$i]}" 987 "${created[$i]}" 1
    fi
    shims="$TMP/shims-uninstall-present-$i"; log="$(make_uninstall_shims "$shims" 0)"

    run_uninstall_dry "$db" "$state" "" "$shims" "${names[$i]}" kogies
    [ "$UNINSTALL_RC" -ne 127 ] || { fail "${labels[$i]}: exit 127, not a refusal"; continue; }
    [ "$UNINSTALL_RC" -ne 0 ] || fail \
      "${labels[$i]}: expected non-zero (nothing removed), got 0 — a safety rail was weakened by the already-absent short-circuit"
    [ -n "$UNINSTALL_OUT" ] || fail "${labels[$i]}: expected a line explaining the refusal"
    assert_eq "$(uninstall_dry_all)" "" "${labels[$i]}: no command was emitted"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "${labels[$i]}: no account tool was executed"
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

# --- slice 7: host_account_installable (one host account per box) ------------
#
# Contract under test (issue #21 sub-problem 1; factory/CHECKPOINT.md slice 1,
# owner-confirmed design decisions):
#
#   "Re-run with a different DREAMCONNECT_HOST_ACCOUNT than install.state
#    records: REFUSE, name the recorded account, point at --uninstall. No new
#    state format (install.state stays single-slot)."
#   "DREAMCONNECT_HOST_ACCOUNT unset on re-run while install.state has one
#    recorded: WARN and proceed with the recorded account."
#
#   host_account_installable <requested_or_empty>
#
#   Decides whether this run may proceed under <requested>, and says which
#   account the run must actually use. Follows resolve_host_identity's
#   convention — the resolution on stdout, complaints on stderr, non-zero on
#   refusal — because install.sh has no test harness of its own, so the decision
#   has to live in the library (checkpoint seams: "so new logic lands in the
#   testable surface").
#
#   Reads the recorded account from the install state (DC_STATE_FILE honoured,
#   absent file = nothing recorded).
#
#     * nothing recorded              -> exit 0, stdout <requested> (may be
#                                        empty), stderr EMPTY.
#     * requested == recorded         -> exit 0, stdout <requested>, stderr EMPTY.
#     * requested empty, one recorded -> exit 0, stdout <recorded>, and a
#                                        "warning:" line on stderr naming the
#                                        recorded account. (install-lib.sh's own
#                                        warning convention, cf. the chown
#                                        warning in configure_no_idle_lock.)
#     * requested non-empty and
#       different from recorded       -> NON-ZERO, nothing on stdout, a stderr
#                                        line naming the RECORDED account and
#                                        telling the operator to run --uninstall
#                                        first. The state file is left byte-for-
#                                        byte alone: the whole point of the
#                                        refusal is that the earlier account's
#                                        dconf profile/db, linger and
#                                        AccountsService marker stay reachable by
#                                        --uninstall, which a single-slot state
#                                        file can only do while it still names
#                                        them.
#
# Called from install.sh before write_install_state, i.e. before ensure_host_account
# has created anything — but that wiring is install.sh's, and out of scope here.

INSTALLABLE_RC=0
INSTALLABLE_OUT=""
INSTALLABLE_ERR=""

# stdout and stderr are separate parts of this contract, so they are captured
# separately rather than folded together. Command substitution is a subshell, so
# the state globals the function reads stay out of the harness.
try_installable() {  # state_file requested
  local errf="$TMP/installable.err"
  : > "$errf"
  INSTALLABLE_OUT="$(DC_STATE_FILE="$1" host_account_installable "$2" 2>"$errf")"
  INSTALLABLE_RC=$?
  INSTALLABLE_ERR="$(cat "$errf" 2>/dev/null || true)"
  return 0
}

# Same reasoning as assert_refused: a missing function also exits non-zero with
# text on stderr, and a refusal test that accepts that asserts nothing.
assert_install_refused() {  # label
  declare -F host_account_installable >/dev/null || {
    fail "$1: host_account_installable() is not defined — refusal not demonstrated"; return 0; }
  [ "$INSTALLABLE_RC" -ne 127 ] || { fail "$1: exit 127 (command not found), not a refusal"; return 0; }
  assert_not_contains "$INSTALLABLE_ERR" "command not found" \
    "$1: the refusal came from the guard, not the shell"
  [ "$INSTALLABLE_RC" -ne 0 ] || fail "$1: expected non-zero exit (NOT installable), got $INSTALLABLE_RC"
  [ -n "$INSTALLABLE_ERR" ] || fail "$1: expected a stderr line explaining the refusal, got none"
}

test_library_defines_host_account_installable() {
  declare -F host_account_installable >/dev/null || \
    fail "install-lib.sh defines host_account_installable(): not defined"
}

# The bug in #21: a second run with a different DREAMCONNECT_HOST_ACCOUNT
# overwrote the single-slot state file, and the first account's dconf profile,
# linger and AccountsService marker became unreachable by --uninstall forever.
test_host_account_installable_refuses_a_different_account_than_recorded() {
  local state before
  state="$TMP/state-installable-different/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1
  before="$(cat "$state")"

  try_installable "$state" dreamconnect-host2
  assert_install_refused "requested account differs from the recorded one"
  assert_contains "$INSTALLABLE_ERR" "dreamconnect-host" \
    "the refusal names the previously recorded account"
  assert_contains "$INSTALLABLE_ERR" "--uninstall" \
    "the refusal tells the operator to run --uninstall first"
  assert_eq "$INSTALLABLE_OUT" "" "a refusal resolves no account on stdout"
  assert_eq "$(cat "$state" 2>/dev/null || true)" "$before" \
    "the refusal leaves install.state untouched (single slot, still naming the old account)"
}

# A bare `sudo ./install.sh` re-run must keep working, and must keep working
# against the account already installed — silently switching back to the desktop
# user would strand exactly the same set of artefacts #21 is about.
test_host_account_installable_warns_and_reuses_the_recorded_account_when_unset() {
  local state
  state="$TMP/state-installable-unset/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1

  try_installable "$state" ""
  assert_eq "$INSTALLABLE_RC" "0" \
    "no account requested on a re-run proceeds (stderr: $INSTALLABLE_ERR)"
  assert_eq "$INSTALLABLE_OUT" "dreamconnect-host" \
    "the run continues under the previously recorded account"
  assert_contains "$INSTALLABLE_ERR" "warning:" \
    "reusing the recorded account is announced as a warning"
  assert_contains "$INSTALLABLE_ERR" "dreamconnect-host" \
    "the warning names the account being reused"
}

# The ordinary re-run: same account as last time. Nothing to warn about, so
# nothing on stderr — a warning here would train the operator to ignore them.
test_host_account_installable_accepts_the_recorded_account_silently() {
  local state
  state="$TMP/state-installable-same/install.state"
  write_state_fixture "$state" dreamconnect-host 987 1 1

  try_installable "$state" dreamconnect-host
  assert_eq "$INSTALLABLE_RC" "0" \
    "re-requesting the recorded account proceeds (stderr: $INSTALLABLE_ERR)"
  assert_eq "$INSTALLABLE_OUT" "dreamconnect-host" "the requested account is the resolved one"
  assert_eq "$INSTALLABLE_ERR" "" "an unchanged account name is not worth a warning"
}

# Fresh box: no state file at all. Every request is installable, including the
# empty one (today's no-host-account install), and none of them warn.
test_host_account_installable_accepts_any_account_on_a_fresh_install() {
  local state
  state="$TMP/state-installable-fresh/install.state"
  assert_file_absent "$state" "precondition: no state file"

  try_installable "$state" dreamconnect-host
  assert_eq "$INSTALLABLE_RC" "0" \
    "a named account on a fresh install proceeds (stderr: $INSTALLABLE_ERR)"
  assert_eq "$INSTALLABLE_OUT" "dreamconnect-host" "fresh install resolves the requested account"
  assert_eq "$INSTALLABLE_ERR" "" "fresh install with a named account is silent"

  try_installable "$state" ""
  assert_eq "$INSTALLABLE_RC" "0" \
    "no account requested on a fresh install proceeds (stderr: $INSTALLABLE_ERR)"
  assert_eq "$INSTALLABLE_OUT" "" "fresh install with no account resolves no account"
  assert_eq "$INSTALLABLE_ERR" "" "fresh install with no account is silent"
}

# The recorded name is adopted by this function and becomes the account the
# WHOLE run uses — install.sh reassigns DREAMCONNECT_HOST_ACCOUNT from this
# stdout, and its own two entry-point guards (the reserved dconf `case` and the
# valid_account_name check, install.sh ~175-190) have already run against the
# ORIGINAL env var by then. So whatever comes out of here is never validated
# again before ensure_host_account/enable_autologin act on it. host_account_removable
# already draws exactly this conclusion for exactly this file — it re-validates
# the recorded name because install.state is "the last thing standing between a
# tampered install.state and `userdel -r`" — and an adopted name has the same
# provenance and a comparable blast radius (useradd/usermod, an AccountsService
# path, a dconf profile, GDM autologin).
#
# Contract this asserts, extending the slice-7 block above:
#
#     * recorded name fails valid_account_name -> NON-ZERO, nothing on stdout,
#       a stderr line naming the recorded name and saying it is "not a valid
#       account name" (the wording ensure_host_account and host_account_removable
#       both already use for this rail). Applies to BOTH adopting paths: the
#       empty request that reuses the record, and requested == recorded.
test_host_account_installable_refuses_a_malformed_recorded_account() {
  local state before name i=0
  for name in ".." "." "./dreamconnect-host" "../victim" 1000 "dc host" "-lead-dash"; do
    state="$TMP/state-installable-malformed-$i/install.state"; i=$((i + 1))
    write_state_fixture "$state" "$name" 987 1 1
    before="$(cat "$state")"

    # The reuse path: no account requested, so the recorded one would be adopted.
    try_installable "$state" ""
    assert_install_refused "malformed recorded account '$name' (no account requested)"
    assert_eq "$INSTALLABLE_OUT" "" \
      "malformed recorded account '$name': nothing is resolved on stdout for the run to use"
    assert_contains "$INSTALLABLE_ERR" "not a valid account name" \
      "malformed recorded account '$name': the refusal names the rail"
    assert_contains "$INSTALLABLE_ERR" "$name" \
      "malformed recorded account '$name': the refusal names the recorded account"

    # And the match-confirms path: agreeing with a tampered record does not
    # launder it either.
    try_installable "$state" "$name"
    assert_install_refused "malformed recorded account '$name' (requested == recorded)"
    assert_eq "$INSTALLABLE_OUT" "" \
      "malformed recorded account '$name': requesting it too still resolves nothing"

    assert_eq "$(cat "$state" 2>/dev/null || true)" "$before" \
      "malformed recorded account '$name': install.state is left byte-for-byte alone"
  done
}

# "user" and "local" are dconf's own default profile and its shared system db.
# install.sh refuses them at the entry point BEFORE anything is created,
# precisely "so a reserved name can never leave an account behind that the later
# failure never recorded" (install.sh ~171-181) — configure_no_idle_lock's own
# refusal comes far too late. A name adopted out of install.state reaches
# ensure_host_account by the same road and must meet the same gate, with the
# same distinct wording, because the operator's fix differs: a reserved name is
# not malformed, it is a name dconf has already claimed.
test_host_account_installable_refuses_a_reserved_recorded_account() {
  local state before name
  for name in user local; do
    state="$TMP/state-installable-reserved-$name/install.state"
    write_state_fixture "$state" "$name" 987 1 1
    before="$(cat "$state")"

    try_installable "$state" ""
    assert_install_refused "reserved recorded account '$name' (no account requested)"
    assert_eq "$INSTALLABLE_OUT" "" \
      "reserved recorded account '$name': nothing is resolved on stdout for the run to use"
    assert_contains "$INSTALLABLE_ERR" "reserved" \
      "reserved recorded account '$name': the refusal says the name is reserved"
    assert_contains "$INSTALLABLE_ERR" "$name" \
      "reserved recorded account '$name': the refusal names the recorded account"

    try_installable "$state" "$name"
    assert_install_refused "reserved recorded account '$name' (requested == recorded)"
    assert_eq "$INSTALLABLE_OUT" "" \
      "reserved recorded account '$name': requesting it too still resolves nothing"

    assert_eq "$(cat "$state" 2>/dev/null || true)" "$before" \
      "reserved recorded account '$name': install.state is left byte-for-byte alone"
  done
}

# The whole of breaker lap 2 finding 1, driven end to end at the library seam in
# install.sh's own order (install.sh:196-219 has no harness of its own):
#
#   host_account_installable ""      -> adopts the recorded account (warn-and-reuse)
#   ensure_host_account <adopted>    -> the account is already there, so
#                                       ACCOUNT_WAS_CREATED=0 for THIS run
#   write_install_state ... "$ACCOUNT_WAS_CREATED" 1
#
# The consequence is asserted where it is actually paid — issue #18's rule that
# "uninstall MUST delete the account and fully revert", i.e. host_account_removable
# must still say yes afterwards. A bare re-run is the ordinary upgrade path, so
# this must hold however many times it runs.
test_a_bare_rerun_keeps_the_account_created_by_the_installer_removable() {
  local state resolved
  local ACCOUNT_WAS_CREATED="junk"
  local DC_DRY_RUN=1 DC_PASSWD_DB DC_ACCOUNTSSERVICE_DIR DC_STATE_FILE
  require_ensure_host_account "bare re-run keeps the account removable" || return 0

  state="$TMP/state-rerun/install.state"
  DC_STATE_FILE="$state"
  DC_PASSWD_DB="$(make_removal_passwd_db)"
  DC_ACCOUNTSSERVICE_DIR="$TMP/as-rerun"; mkdir -p "$DC_ACCOUNTSSERVICE_DIR"

  # What the FIRST run left behind: it created dreamconnect-host itself.
  write_state_fixture "$state" dreamconnect-host 987 1 1

  # The second run: nothing in the environment, so the recorded account is
  # adopted; the account exists, so this run did not create it.
  resolved="$(host_account_installable "" 2>/dev/null)"
  assert_eq "$resolved" "dreamconnect-host" \
    "precondition: a bare re-run adopts the recorded account"
  ensure_host_account "$resolved" >/dev/null 2>&1
  assert_eq "$ACCOUNT_WAS_CREATED" "0" \
    "precondition: the re-run did not create the account that already existed"

  write_install_state "$resolved" 987 "$ACCOUNT_WAS_CREATED"

  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT
  read_install_state
  assert_eq "$CREATED_ACCOUNT" "1" \
    "a bare re-run does not forget that the installer created the account"

  try_removable "$DC_PASSWD_DB" "$state" "" dreamconnect-host kogies
  assert_eq "$REMOVE_RC" "0" \
    "after a bare re-run --uninstall may still remove the account (stderr: $REMOVE_ERR)"
}

# --- slice 8: the reserved-name set (root) + locale-independent name shape -----
#
# CONTRACT UNDER TEST — issue #21 sub-problem 3, quoted:
#
#   "DREAMCONNECT_HOST_ACCOUNT=root passes both the entry-point guard and
#    valid_account_name, and would reach enable_autologin "$GDM_CONF" root (GDM
#    itself refuses root autologin, so this fails closed today, but relying on GDM
#    rather than our own guard is fragile) ... worth tightening to
#    [[:upper:][:lower:]] in the C locale or an explicit ASCII-only check, and
#    adding root to the reserved-name list alongside user/local."
#
# and factory/CHECKPOINT.md's slice-2 row: "reserved-name guard (root + user +
# local at all 6 call sites) + LC_ALL=C fix in valid_account_name".
#
# So there is ONE reserved set — root, user, local — and every function that
# already refuses "user"/"local", plus every function that acts destructively on
# an account name and refuses neither, must refuse all three. Per call site:
#
#   1. host_account_installable <requested>   — the library half of install.sh's
#      entry-point `case` (install.sh:179). Today the fresh-box path echoes
#      <requested> back UNVALIDATED, so DREAMCONNECT_HOST_ACCOUNT=root survives
#      the whole resolution. Refuse a reserved REQUESTED name, on a fresh box and
#      on a re-run alike: non-zero, nothing on stdout, a stderr line saying
#      "reserved" and naming the account, and install.state untouched. The
#      RECORDED-name path (slice 1) gains root on top of user/local.
#   2. configure_no_idle_lock / remove_no_idle_lock — the existing reserved `case`
#      gains root. Same shape as the user/local tests already here: non-zero, a
#      stderr line, and not one byte written or removed.
#   3. ensure_host_account — no reserved check at all today. root exists in every
#      passwd source, so the guard is what stops `install -D` stamping
#      SystemAccount=true onto /var/lib/AccountsService/users/root and hiding root
#      from the greeter. Refuse before the passwd lookup, useradd/usermod and any
#      write.
#   4. remove_accountsservice_marker — no reserved check today; from --uninstall
#      the name comes off a state FILE, so `rm -f`/`mv -f` on .../users/root is one
#      tampered line away. Refuse, and leave the directory exactly as found.
#   5. enable_autologin <conf> <name> — validates NOTHING today; GDM's own refusal
#      of root autologin is the only thing standing between us and
#      AutomaticLogin=root in /etc/gdm/custom.conf. Refuse a reserved name (and,
#      by the same rail every other destructive function here already carries, a
#      name failing valid_account_name): non-zero, a stderr line, the conf file
#      byte-for-byte unchanged and no .dreamconnect.bak created. A well-formed
#      name keeps today's behaviour.
#   6. host_account_removable — the architect's survey says this one is already
#      sound via the uid-0 and /root-home rails. Verified below, AND extended: a
#      passwd source is data, so an entry literally named "root" with a non-zero
#      uid and a safe home satisfies all seven rails today and `userdel -r root`
#      follows. The reserved set is a name rail, not a uid rail.
#
#   valid_account_name — the shape rule is UNCHANGED (^[A-Za-z_][A-Za-z0-9_-]*$,
#   =32 chars, slice 6b's contract) but must mean the SAME thing in every locale:
#   [A-Za-z] is an LC_COLLATE/LC_CTYPE-dependent range, and this box accepts "é"
#   under en_US.utf8 while rejecting it under C. ASCII-only, whatever LC_ALL the
#   invoking shell carries. valid_account_name itself stays a pure SHAPE
#   predicate: "root"/"user"/"local" are well-shaped names, and the reserved
#   refusals above are a separate rail with their own distinct wording, because
#   the operator's fix differs ("choose another name" vs "that is not a name").

# Loud skip: a box without a given locale must not silently lose the coverage.
SKIPPED=0
skip() { echo "  SKIP: $*"; SKIPPED=$((SKIPPED + 1)); }

# The locales this box actually has, out of a candidate list chosen for their
# LC_CTYPE: en_US.utf8 is the one demonstrated to accept "é" today, tr_TR.utf8 is
# the classic dotless-i case-folding trap. C is always present and always listed
# first, so the test can never be entirely vacuous.
available_ctype_locales() {
  local l have
  have="$(locale -a 2>/dev/null || true)"
  echo "C"
  for l in en_US.utf8 en_US.UTF-8 tr_TR.utf8 tr_TR.UTF-8 de_DE.utf8 fr_FR.utf8; do
    case $'\n'"$have"$'\n' in *$'\n'"$l"$'\n'*) echo "$l" ;; esac
  done
}

# valid_account_name is evaluated in a sub-bash so the locale is really in force
# for the [[ =~ ]] match, the same sub-bash technique
# test_sourcing_is_side_effect_free uses. Echoes "valid" or "invalid".
name_verdict_under_locale() {  # locale name
  if LC_ALL="$1" bash -c '. "$1"; valid_account_name "$2"' _ "$LIB" "$2" 2>/dev/null; then
    echo valid
  else
    echo invalid
  fi
}

test_valid_account_name_is_locale_independent() {
  local loc n locales count=0
  require_valid_account_name "locale independence" || return 0
  locales="$(available_ctype_locales)"
  count="$(printf '%s\n' "$locales" | grep -c . || true)"
  [ "$count" -gt 1 ] || skip "locale independence: no non-C locale installed (locale -a); only C exercised"

  for loc in $locales; do
    # An account name is ASCII. "é" is a letter to [A-Za-z] under a UTF-8
    # LC_CTYPE and not one under C — the whole defect.
    for n in "é" "dréam" "naïve" "Ünal"; do
      assert_eq "$(name_verdict_under_locale "$loc" "$n")" "invalid" \
        "LC_ALL=$loc: a non-ASCII letter is not an account name [$n]"
    done
    # And the fix must not over-tighten: the ordinary names slice 6b accepts stay
    # accepted in every locale, including tr_TR's dotless-i.
    for n in dreamconnect-host _svc A1 Iiz; do
      assert_eq "$(name_verdict_under_locale "$loc" "$n")" "valid" \
        "LC_ALL=$loc: an ordinary ASCII account name is still accepted [$n]"
    done
  done
}

# Call site 1, the fresh-box path: install.sh's entry-point `case` is the only
# thing refusing a reserved REQUESTED name today, and install.sh has no harness —
# so the refusal has to exist here too, where it can be tested and where a name
# adopted out of install.state meets the same gate.
test_host_account_installable_refuses_a_reserved_requested_account() {
  local state name
  for name in root user local; do
    state="$TMP/state-installable-requested-$name/install.state"
    mkdir -p "$(dirname "$state")"
    assert_file_absent "$state" "precondition: fresh box, no state file"

    try_installable "$state" "$name"
    assert_install_refused "reserved requested account '$name' (fresh install)"
    assert_eq "$INSTALLABLE_OUT" "" \
      "reserved requested account '$name': nothing is resolved on stdout for the run to use"
    assert_contains "$INSTALLABLE_ERR" "reserved" \
      "reserved requested account '$name': the refusal says the name is reserved"
    assert_contains "$INSTALLABLE_ERR" "$name" \
      "reserved requested account '$name': the refusal names the account"
    assert_file_absent "$state" \
      "reserved requested account '$name': a refusal writes no state file"
  done
}

# Call site 1, the adoption path: slice 1 added this for user/local only and
# deliberately left root to this slice. Same two adopting paths, same wording.
test_host_account_installable_refuses_root_as_the_recorded_account() {
  local state before
  state="$TMP/state-installable-recorded-root/install.state"
  write_state_fixture "$state" root 0 1 1
  before="$(cat "$state")"

  try_installable "$state" ""
  assert_install_refused "recorded account 'root' (no account requested)"
  assert_eq "$INSTALLABLE_OUT" "" \
    "recorded account 'root': nothing is resolved on stdout for the run to use"
  assert_contains "$INSTALLABLE_ERR" "root" \
    "recorded account 'root': the refusal names the recorded account"

  try_installable "$state" root
  assert_install_refused "recorded account 'root' (requested == recorded)"
  assert_eq "$INSTALLABLE_OUT" "" \
    "recorded account 'root': requesting it too still resolves nothing"
  assert_eq "$(cat "$state" 2>/dev/null || true)" "$before" \
    "recorded account 'root': install.state is left byte-for-byte alone"
}

# Call site 2, write side. Same assertions as the user/local test above it: the
# one that matters is that nothing at all was written.
test_configure_no_idle_lock_refuses_root_as_a_dconf_name() {
  local d home shims log
  require_no_idle_lock "write-side root guard" || return 0
  shims="$TMP/shims-idle-configure-root"; log="$(make_idle_shims "$shims" 0)"
  read -r d home <<<"$(idle_fixture "idle-configure-root")"

  run_configure "$d" root "$home" "$shims"
  [ "$IDLE_RC" -ne 127 ] || { fail "root: exit 127, not a refusal"; return 0; }
  assert_not_contains "$IDLE_OUT" "command not found" \
    "root: the refusal came from the guard, not the shell"
  [ "$IDLE_RC" -ne 0 ] || fail "configure 'root': expected non-zero exit, got $IDLE_RC"
  [ -n "$IDLE_OUT" ] || fail "configure 'root': expected a stderr line explaining the refusal"
  assert_eq "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "configure 'root': nothing at all written under DC_DCONF_DIR"
  assert_eq "$(find "$home" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "configure 'root': nothing at all written under <home>"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "configure 'root': neither chown nor dconf update was run"
}

# Call site 2, removal side — and sharper, because here the name comes off a
# state FILE: HOST_ACCOUNT=root would delete /etc/dconf/profile/root and the
# root account's own db.
test_remove_no_idle_lock_refuses_root_as_a_dconf_name() {
  local d home shims log before
  require_no_idle_lock "removal-side root guard" || return 0
  shims="$TMP/shims-idle-remove-root"; log="$(make_dconf_shim "$shims")"
  read -r d home <<<"$(idle_fixture "idle-remove-root")"

  mkdir -p "$d/profile" "$d/db/root.d" "$home/.config/environment.d"
  printf 'user-db:user\nsystem-db:root\n' > "$d/profile/root"
  printf '[org/gnome/desktop/screensaver]\nlock-enabled=true\n' > "$d/db/root.d/00-display-host"
  printf 'DCONF_PROFILE=somebody-else\n' > "$home/.config/environment.d/dconf-profile.conf"
  printf 'yes\n' > "$home/.config/gnome-initial-setup-done"
  before="$(find "$d" "$home" | sort)"

  run_remove "$d" root "$home" "$shims"
  [ "$IDLE_RC" -ne 127 ] || { fail "root: exit 127, not a refusal"; return 0; }
  assert_not_contains "$IDLE_OUT" "command not found" \
    "root: the refusal came from the guard, not the shell"
  [ "$IDLE_RC" -ne 0 ] || fail "removal 'root': expected non-zero exit, got $IDLE_RC"
  [ -n "$IDLE_OUT" ] || fail "removal 'root': expected a stderr line explaining the refusal"
  assert_eq "$(find "$d" "$home" | sort)" "$before" \
    "removal 'root': nothing at all under DC_DCONF_DIR or <home> changed"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "removal 'root': a refused removal does not run dconf update either"
}

# Call site 3. root is in every passwd source, so ensure_host_account takes its
# "account already exists" path and writes SystemAccount=true into
# .../AccountsService/users/root — hiding root from the greeter, with a backup
# of whatever was there. user/local may or may not exist; both are refused for
# the same reason install.sh refuses them at the entry point.
test_ensure_host_account_refuses_reserved_account_names() {
  local db dir shims log name tag i=0
  require_ensure_host_account "reserved-name guard" || return 0
  db="$(make_fresh_passwd_db)"

  for name in root user local; do
    tag="as-create-reserved-$i"; i=$((i + 1))
    dir="$TMP/$tag"; mkdir -p "$dir"
    shims="$TMP/shims-$tag"; log="$(make_cmd_shims "$shims")"

    run_ensure_shimmed "$db" "$dir" "$shims" "$name"
    [ "$ENSURE_RC" -ne 127 ] || { fail "reserved name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$ENSURE_OUT" "command not found" \
      "reserved name '$name': the refusal came from the guard, not the shell"
    [ "$ENSURE_RC" -ne 0 ] || \
      fail "reserved ensure '$name': expected non-zero exit, got $ENSURE_RC"
    [ -n "$ENSURE_OUT" ] || \
      fail "reserved ensure '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "reserved ensure '$name': neither useradd nor usermod was invoked"
    assert_eq "$(find "$dir" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
      "reserved ensure '$name': nothing at all written under DC_ACCOUNTSSERVICE_DIR"
  done
}

# Call site 4, the --uninstall counterpart, driven by a name off a state FILE:
# HOST_ACCOUNT=root makes the restore branch overwrite root's AccountsService
# file and the remove branch delete it.
test_remove_accountsservice_marker_refuses_reserved_account_names() {
  local dir name tag i=0 before
  require_remove_accountsservice_marker "reserved-name guard" || return 0

  for name in root user local; do
    tag="as-rm-reserved-$i"; i=$((i + 1))
    dir="$TMP/$tag"; mkdir -p "$dir"
    printf '[User]\nSystemAccount=true\n' > "$dir/$name"
    plant_preexisting_accountsservice_file "$dir/$name.dreamconnect.bak"
    before="$(find "$dir" | sort)"

    run_remove_marker "$dir" "$name"
    [ "$REMOVE_MARKER_RC" -ne 127 ] || { fail "reserved name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$REMOVE_MARKER_OUT" "command not found" \
      "reserved name '$name': the refusal came from the guard, not the shell"
    [ "$REMOVE_MARKER_RC" -ne 0 ] || \
      fail "reserved marker removal '$name': expected non-zero exit, got $REMOVE_MARKER_RC"
    [ -n "$REMOVE_MARKER_OUT" ] || \
      fail "reserved marker removal '$name': expected a stderr line explaining the refusal"
    assert_eq "$(find "$dir" | sort)" "$before" \
      "reserved marker removal '$name': the AccountsService dir is left exactly as found"
  done
}

# Call site 5, the one the issue names outright: "would reach enable_autologin
# "$GDM_CONF" root (GDM itself refuses root autologin, so this fails closed
# today, but relying on GDM rather than our own guard is fragile)".
#
# NARROWED (breaker lap 1, slice 2). This function has TWO callers with
# genuinely different notions of a valid name — install.sh:344 (host-account
# mode, a name this installer is about to CREATE, already validated for shape
# and the reserved set at install.sh:183-192, host_account_installable and
# ensure_host_account) and install.sh:349 (classic mode, DREAMCONNECT_AUTOLOGIN=1,
# a PRE-EXISTING desktop account resolved through detect_user/resolve_host_identity
# that no rule of ours ever governed). So enable_autologin is not the place for
# "is this shaped like a new account name" or for the dconf profile reservations
# (user/local), which classic mode never touches. See the acceptance test below.
#
# What stays is the narrower, caller-independent rail: names that break the
# mechanism this function IS. `root` — a graphical autologin as root is the
# hazard issue #21 sub-problem 3 names at this exact call site, GDM refuses it
# itself, and neither mode has a legitimate reason to ask for it. An empty name,
# which writes an `AutomaticLogin=` key nothing can ever satisfy. And a name
# carrying a newline or carriage return, which is not a name-policy question at
# all: it is pasted verbatim into the [daemon] section and would inject arbitrary
# GDM config keys. Everything else is the caller's business, not this function's.

# The other half of call site 5, so the guard above cannot be satisfied by
# refusing everything: an ordinary account still gets autologin configured, and
# the backup enable_autologin's own comment promises. This documents today's
# behaviour (it passes before the guard exists) and pins it afterwards.

# The other caller: install.sh:346-351, classic mode. `$USER_NAME` there is the
# machine's EXISTING desktop user — detect_user/resolve_host_identity, resolved
# out of the passwd source, never created by this installer and never subject to
# its new-account rules. On an SSSD/AD-joined box that name is routinely
# `john.doe`; it can exceed 32 characters; it can be literally `user` or `local`,
# which are dconf PROFILE reservations and mean nothing here because classic mode
# touches neither dconf nor AccountsService nor useradd. Every one of these is a
# real Linux account whose owner has opted in with DREAMCONNECT_AUTOLOGIN=1.
#
# Expected value from GDM's custom.conf format — `AutomaticLogin=<name>`, the
# account name verbatim — and from the classic-mode contract at install.sh:346.
# A refusal here aborts install.sh under `set -euo pipefail` at line 349, AFTER
# deps, build, deploy, the daemon unit and enable-linger have all run.

# The third way a name pasted into [daemon] corrupts the conf, and the one the
# newline/CR rail above cannot see. enable_autologin hands the name to awk as
# `awk -v user="$user"`, and a -v assignment is NOT a verbatim string: POSIX
# (awk, OPERANDS: "an assignment ... shall be evaluated as if it were an
# assignment with a string literal") makes awk process C escape sequences in the
# VALUE before the script runs. So a shell string holding the two characters
# backslash and `n` — no newline byte anywhere in it, which is why the *$'\n'*
# case pattern never matches — becomes a real newline INSIDE awk, and
# `print "AutomaticLogin=" user` emits two lines. `\t` becomes a tab, `\\`
# becomes one backslash; every one of them writes something other than the
# account the caller named.
#
# `DOMAIN\nick` is not a contrived string: backslash is the NSS/winbind
# separator between a domain and the local part (`winbind separator = \` is the
# Samba default), so it is exactly what a domain-joined box hands classic mode
# through detect_user. Its corruption is invisible: rc 0, and
# disable_autologin's undo only drops AutomaticLogin* keys, so the stray bare
# line survives uninstall.
#
# Expected value from GDM's custom.conf format (key=value, one key per line — a
# bare word on its own line is not a valid entry) and from this function's own
# stated rail: a name that would corrupt the file rather than merely name the
# wrong account is REFUSED before the backup. Same shape as the newline/CR
# refusal directly above: non-zero exit, a stderr line, the conf byte-identical,
# no .dreamconnect.bak. Not a name-policy question — the classic-mode acceptance
# test above still stands, and no legitimate GDM AutomaticLogin value can carry
# a backslash, because GDM would receive the escaped form, not the name.

# Call site 6. Two halves, because a passwd source is DATA, not a fact about the
# box: the real root entry is refused by the uid-0 and /root-home rails that are
# already there (verifying the architect's "already sound"), while an entry
# literally NAMED root carrying a non-zero uid, a safe home, our GECOS marker and
# a matching state record satisfies every one of those seven rails — and
# `userdel -r root` follows. The reserved set is a NAME rail, not a uid rail.
make_root_named_passwd_db() {
  cat > "$TMP/passwd-root-named" <<'EOF'
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
root:x:993:993:DreamConnect display host:/var/lib/dc-root:/bin/bash
EOF
  echo "$TMP/passwd-root-named"
}

test_host_account_removable_refuses_root_however_the_passwd_source_spells_it() {
  local db state
  # Half 1: the genuine root entry (uid 0, home /root) — already refused today.
  db="$(make_removal_passwd_db)"
  state="$TMP/state-removable-real-root/install.state"
  write_state_fixture "$state" root 0 1 1
  try_removable "$db" "$state" "" root kogies
  assert_refused "the real root entry (uid 0, home /root)"

  # Half 2: an entry named root that satisfies all seven existing rails.
  db="$(make_root_named_passwd_db)"
  state="$TMP/state-removable-named-root/install.state"
  write_state_fixture "$state" root 993 1 1
  try_removable "$db" "$state" "" root kogies
  assert_refused "an entry NAMED root with a non-zero uid and a safe home"
  assert_contains "$REMOVE_ERR" "root" "the refusal names the account it protected"
}

# --- slice 9: valid_home_dir — the home argument nobody validates --------------
#
# CONTRACT UNDER TEST — issue #21 sub-problem 2, quoted verbatim:
#
#   "`remove_no_idle_lock` doesn't validate its `home` argument. It validates
#    `name` via `valid_account_name` but not `home`. If the host account is
#    deleted by hand before running `--uninstall`, `passwd_entry | cut -f6`
#    yields an empty string, and root then runs
#    `rm -f "/.config/environment.d/dconf-profile.conf"` and
#    `rm -f "/.config/gnome-initial-setup-done"` — harmless today (nothing
#    typically lives at literal `/.config`), but unguarded."
#
# and factory/CHECKPOINT.md's slice-3 row: "home-dir guard (valid_home_dir):
# non-empty, absolute, not / /home /root, no `..`. Hard error in
# configure_no_idle_lock, skip-the-home-half-and-continue in remove_no_idle_lock,
# guard on install.sh:85's rm -f."
#
#   valid_home_dir <path>
#     A pure SHAPE predicate, exactly like valid_account_name beside it: no
#     output, no filesystem, no passwd lookup, exit 0 for usable / non-zero for
#     not. It answers one question only — "is it safe to paste this into
#     `rm -f "$home/.config/..."`, `install -d "$home/.config/systemd/user"`,
#     `sed > "$home/..."` and `chown <name>: "$home/.config"` as root?" — and
#     each rail below is one call site's failure, not a generic checklist:
#
#       1. NON-EMPTY. The issue's literal trigger: an account deleted by hand
#          makes `passwd_entry | cut -d: -f6` yield "", and every path above
#          collapses onto /.config/... — root's own rm/chown target.
#       2. ABSOLUTE (starts with "/"). passwd(5) field 6 is absolute by
#          definition, so a relative value is already corrupt data; pasted in, it
#          resolves against root's CWD, which for install.sh is the checkout the
#          operator happened to run it from.
#       3. NOT EXACTLY "/". Same paths as rail 1, reached a different way; and
#          `chown <name>: "/.config"` hands a directory at the filesystem root to
#          the display-host account.
#       4. NOT EXACTLY "/home" OR "/root". Not invented here: install-lib.sh's
#          host_account_removable already refuses exactly these three values with
#          "home directory is $home", so the dangerous set is the repo's own,
#          reused. /home/.config would be created, chowned and later deleted in a
#          directory shared by every human on the box; /root puts our dconf
#          drop-in inside root's home and chowns it to the host account.
#       5. NO ".." PATH COMPONENT. A COMPONENT, not a substring: /var/lib/x/..
#          walks the rm/install/chown one level out of the home it was given,
#          exactly the reasoning valid_account_name's "./user" rail already
#          carries — while /var/lib/dc..host is an ordinary directory name and
#          must stay valid.
#
#     Deliberately NOT a rail: whitespace. USER_HOME with a space does truncate
#     at install.sh:214's `read -r NAME UID HOME _`, but this same predicate
#     guards classic mode, where <home> is a human's real passwd entry —
#     rejecting it would abort a legitimate install, which is the exact mistake
#     slice 2's breaker lap 1 found in enable_autologin. Noted, not enforced here.
#
#   remove_no_idle_lock <name> <home>, home unusable
#     SKIP THE HOME HALF, DO THE REST, CONTINUE. The two /etc/dconf reverts
#     (profile, keyfile, the now-empty <name>.d) and `dconf update` are wholly
#     independent of <home> and are the half that actually matters — they are
#     what --uninstall leaves behind otherwise. So they still run, a warning
#     naming the problem goes to stderr, the two home files are left completely
#     alone, and the function exits 0: the account's home is gone or unusable, so
#     there is nothing there to have failed to revert, and install.sh:113 would
#     otherwise print "could not fully revert idle-lock config — continuing" over
#     a successful revert.
#
#   configure_no_idle_lock <name> <home>, home unusable
#     HARD ERROR, and nothing at all written — the same shape as its reserved-
#     and malformed-name guards above. This is the WRITE side, running during
#     install: files created under a bad home path are artefacts --uninstall can
#     never find again, and install is exactly when there is an operator present
#     to read the failure.
#
#   Both refusals name the account and use the word "home", so the operator can
#   tell this rail from the name rails at a glance.
#
# install.sh's own two consumers of the same unvalidated value — the
# `rm -f "$target_home/.config/systemd/user/dreamconnect-daemon.service"` at
# install.sh:85 and the `install -d` / sed / chown on $USER_HOME at
# install.sh:298-302 — get the same guard, but install.sh has no harness (see the
# header of this file), so they are verified by hand-trace + bash -n + this suite,
# not by a test here. Same caveat as slices 1 and 2.

HOMEDIR_RC=0
HOMEDIR_ERR=""

try_valid_home() {  # path
  HOMEDIR_ERR="$(valid_home_dir "$1" 2>&1 >/dev/null)"
  HOMEDIR_RC=$?
  return 0
}

# A missing function exits 127 with "command not found" on stderr, which is
# non-zero — so every rejection assertion below would pass vacuously against a
# library that never defines valid_home_dir at all.
require_valid_home_dir() {  # label
  declare -F valid_home_dir >/dev/null && return 0
  fail "$1: valid_home_dir() is not defined"
  return 1
}

assert_home_rejected() {  # path label
  try_valid_home "$1"
  [ "$HOMEDIR_RC" -ne 127 ] || {
    fail "$2: exit 127 (not defined), not a rejection of [$1]"; return 0; }
  assert_not_contains "$HOMEDIR_ERR" "command not found" \
    "$2: the rejection came from the function, not the shell"
  [ "$HOMEDIR_RC" -ne 0 ] || fail "$2: expected non-zero (unusable) for [$1], got 0"
}

assert_home_accepted() {  # path label
  try_valid_home "$1"
  assert_eq "$HOMEDIR_RC" "0" "$2: expected usable (exit 0) for [$1] (stderr: $HOMEDIR_ERR)"
}

test_library_defines_valid_home_dir() {
  declare -F valid_home_dir >/dev/null \
    || fail "install-lib.sh defines valid_home_dir(): not defined"
}

# The homes this installer actually meets: /var/lib/<name> from
# `useradd --system --create-home` (host-account mode, and the shape the passwd
# fixtures at the top of this file already use), and a human's /home/<user> from
# the passwd source (classic mode, including the dotted AD-style name slice 2's
# breaker lap established really does reach these paths). A predicate that
# rejects any of these breaks the feature rather than protecting it.
test_valid_home_dir_accepts_real_home_directories() {
  local p
  require_valid_home_dir "accepts real homes" || return 0
  for p in /var/lib/dreamconnect-host /var/lib/dreamconnect-host2 /home/kogies \
           /home/john.doe /srv/dreamconnect /home/dc-host2; do
    assert_home_accepted "$p" "an ordinary home directory"
  done
  # Rail 5 is about a PATH COMPONENT: dots inside a directory NAME traverse
  # nothing, and a predicate matching the substring ".." would reject this.
  assert_home_accepted "/var/lib/dc..host" "dots inside a component are not traversal"
}

# Rails 1 and 2. The empty string is the issue's literal repro; a relative path
# resolves against root's CWD wherever install.sh was launched from.
test_valid_home_dir_rejects_empty_and_relative_paths() {
  require_valid_home_dir "empty and relative" || return 0
  assert_home_rejected "" "an account deleted by hand yields an empty passwd field 6"
  assert_home_rejected "var/lib/dreamconnect-host" "a home with no leading slash is not absolute"
  assert_home_rejected "home/kogies" "a relative path resolves against root's CWD"
  assert_home_rejected "./dreamconnect-host" "a dot-relative path is not a home directory"
}

# Rail 3 and 4. The set is install-lib.sh's own: host_account_removable already
# refuses exactly / , /home and /root as a home directory, and these are the
# values that make the rm/install/chown land on shared ground.
test_valid_home_dir_rejects_the_shared_roots() {
  require_valid_home_dir "shared roots" || return 0
  assert_home_rejected "/"     "the filesystem root is never an account's home"
  assert_home_rejected "/home" "/home is every human's parent directory, not a home"
  assert_home_rejected "/root" "/root is root's own home"
  # Only the three values themselves: a real home UNDER /home must stay valid,
  # or classic mode stops installing at all.
  assert_home_accepted "/home/kogies" "a home under /home is still a home"
}

# Rails 3 and 4 again, spelled the way a passwd file, an operator or a shell
# variable actually spells them — breaker lap 1 finding #1, quoted from
# factory/CHECKPOINT.md:
#
#   "valid_home_dir's /, /home, /root reserved-path rail is a literal string
#    compare, bypassed by non-canonical spellings: /root/, //root, /root/.,
#    /./root. As root, configure_no_idle_lock dchost "/root/" would chown
#    /root/.config (and subdirs) to the host account"
#
# The dangerous value is the PATH, not the spelling. A trailing slash, a doubled
# slash and a "." component are all no-ops on the resolved path — POSIX 4.13
# pathname resolution: "." names the directory itself, a sequence of slashes is
# equivalent to one, a trailing slash is equivalent to a trailing "/." — so
# every string below IS /, /home or /root, and `rm -f "$home/.config/..."`,
# `install -d` and `chown <name>: "$home/.config"` land on exactly the ground
# the three literals were added to protect. Rail 5 catches none of these: not one
# of them contains a ".." component.
test_valid_home_dir_rejects_noncanonical_spellings_of_the_shared_roots() {
  local p
  require_valid_home_dir "non-canonical shared roots" || return 0

  # The four the breaker demonstrated, on the value it demonstrated them with.
  for p in "/root/" "//root" "/root/." "/./root"; do
    assert_home_rejected "$p" "[$p] resolves to /root, root's own home"
  done
  # The same three transforms on the other two reserved values, and stacked:
  # nothing here is a different rule, only a different spelling of the same one.
  for p in "/home/" "//home" "/home/." "/./home" "/home/./" "//home//" \
           "//" "///" "/." "/./" "/.//" "//root/" "/root/./" "/./root/." \
           "//./root" "/root//."; do
    assert_home_rejected "$p" "[$p] resolves to a shared root"
  done

  # The anti-overreach half. Normalising for the comparison must not start
  # rejecting paths that merely CONTAIN a slash run or a "." component: these all
  # resolve to an ordinary home under /home or /var/lib, and classic mode meets
  # trailing-slash passwd entries in the wild.
  for p in "/home/kogies/" "//home/kogies" "/home/./kogies" "/home/kogies/." \
           "/var/lib/dreamconnect-host/" "//var/lib/dreamconnect-host" \
           "/var/lib/./dc..host" "/home/john.doe/"; do
    assert_home_accepted "$p" "[$p] resolves to an ordinary home directory"
  done
}

# Rail 5. Each of these makes `rm -f "$home/.config/..."` and
# `chown <name>: "$home/.config"` act one or more levels OUT of the directory the
# caller named — the same escape valid_account_name's "./user" rail closes for
# the name half.
test_valid_home_dir_rejects_dotdot_components() {
  local p
  require_valid_home_dir "dotdot components" || return 0
  for p in ".." "../etc" "/.." "/var/lib/dreamconnect-host/.." "/var/../root" \
           "/home/../home" "/var/lib/../../etc"; do
    assert_home_rejected "$p" "a .. component walks out of the home it was given"
  done
  # Regression guard for breaker lap 1 finding #1's fix: normalising "." away
  # must NOT normalise ".." away with it. ".." is rejected because a home that
  # traverses is unsafe whatever it resolves to — a separate rail from the
  # reserved-name one, and it stays a rejection, not something resolved out.
  # /root/../etc would otherwise "normalise" to /etc and pass; /home/x/.. to
  # /home and be caught by the wrong rail with the wrong message.
  for p in "/root/../etc" "/home/x/.." "/var/lib/host/../../root" \
           "/home/./x/.." "//home//x//.." "/root/.././root"; do
    assert_home_rejected "$p" "[$p] still has a .. component after normalisation"
  done
  # And the substring guard, restated here because the fix touches this string:
  # ".." inside a component name traverses nothing and must survive.
  assert_home_accepted "/var/lib/dc..host" "dots inside a component are not traversal"
  assert_home_accepted "/home/..john" "a leading double dot in a NAME is not a component"
}

# /etc/dconf as configure_no_idle_lock leaves it, planted by hand rather than by
# calling configure: this test is about the REMOVAL contract, and the contents of
# these two files are already pinned by the slice-5 tests above.
plant_configured_dconf_tree() {  # dconf_dir name
  local d="$1" name="$2"
  mkdir -p "$d/profile" "$d/db/$name.d"
  printf 'user-db:user\nsystem-db:%s\n' "$name" > "$d/profile/$name"
  printf '[org/gnome/desktop/screensaver]\nlock-enabled=false\n' \
    > "$d/db/$name.d/00-display-host"
}

# THE ISSUE'S CASE. Both halves of the contract at once: the /etc/dconf revert
# still happens (skipping it would strand exactly what --uninstall exists to
# remove) and the home half does not (a bad <home> is the whole point).
#
# Round 1 is the issue's literal repro — the account deleted by hand, passwd
# field 6 empty. Round 2 makes the skip OBSERVABLE with real files: <home> is a
# path with a .. component, so the two home paths resolve onto planted files that
# today's bare `rm -f` deletes and the guard must leave untouched. Asserting the
# absence of an effect at literal /.config is not something this non-root suite
# can do, so round 2 is where the destructive behaviour is actually pinned.
test_remove_no_idle_lock_skips_the_home_half_for_an_unusable_home() {
  local d home shims log bad envf gisf
  require_no_idle_lock "unusable-home skip" || return 0

  # --- round 1: empty home (account deleted by hand before --uninstall) -------
  shims="$TMP/shims-idle-remove-emptyhome"; log="$(make_dconf_shim "$shims")"
  read -r d home <<<"$(idle_fixture idle-remove-emptyhome)"
  plant_configured_dconf_tree "$d" dreamconnect-host

  run_remove "$d" dreamconnect-host "" "$shims"
  [ "$IDLE_RC" -ne 127 ] || { fail "empty home: exit 127, not a guarded skip"; return 0; }
  assert_eq "$IDLE_RC" "0" \
    "empty home: the uninstall continues — the /etc/dconf half succeeded (stderr: $IDLE_OUT)"
  [ -n "$IDLE_OUT" ] || fail "empty home: expected a stderr warning about the unusable home"
  assert_contains "$IDLE_OUT" "home" \
    "empty home: the warning says it is the HOME that is unusable, not the name"
  assert_contains "$IDLE_OUT" "dreamconnect-host" \
    "empty home: the warning names the account it was reverting"
  assert_file_absent "$d/profile/dreamconnect-host" \
    "empty home: the dconf profile is STILL removed"
  assert_file_absent "$d/db/dreamconnect-host.d/00-display-host" \
    "empty home: the db keyfile is STILL removed"
  assert_file_absent "$d/db/dreamconnect-host.d" \
    "empty home: the now-empty <name>.d directory is STILL removed"
  assert_contains "$(cat "$log" 2>/dev/null || true)" "== dconf" \
    "empty home: dconf update STILL runs — the db must be recompiled either way"

  # --- round 2: a .. component, with real files behind it --------------------
  shims="$TMP/shims-idle-remove-badhome"; log="$(make_dconf_shim "$shims")"
  read -r d home <<<"$(idle_fixture idle-remove-badhome)"
  plant_configured_dconf_tree "$d" dreamconnect-host
  bad="$home/.."
  envf="$TMP/idle-remove-badhome/.config/environment.d/dconf-profile.conf"
  gisf="$TMP/idle-remove-badhome/.config/gnome-initial-setup-done"
  mkdir -p "$(dirname "$envf")"
  printf 'DCONF_PROFILE=somebody-else\n' > "$envf"
  printf 'already-done-by-the-human\n'   > "$gisf"

  run_remove "$d" dreamconnect-host "$bad" "$shims"
  [ "$IDLE_RC" -ne 127 ] || { fail "traversing home: exit 127, not a guarded skip"; return 0; }
  assert_eq "$IDLE_RC" "0" \
    "traversing home: the uninstall continues (stderr: $IDLE_OUT)"
  assert_contains "$IDLE_OUT" "home" \
    "traversing home: the warning says it is the HOME that is unusable"
  assert_file_exists "$envf" \
    "traversing home: a file one level out of the given home is NOT deleted"
  assert_eq "$(cat "$envf" 2>/dev/null || true)" "DCONF_PROFILE=somebody-else" \
    "traversing home: somebody else's DCONF_PROFILE is byte-for-byte untouched"
  assert_file_exists "$gisf" \
    "traversing home: the initial-setup marker outside the home is NOT deleted"
  assert_file_absent "$d/profile/dreamconnect-host" \
    "traversing home: the dconf profile is STILL removed"
  assert_file_absent "$d/db/dreamconnect-host.d/00-display-host" \
    "traversing home: the db keyfile is STILL removed"
  assert_contains "$(cat "$log" 2>/dev/null || true)" "== dconf" \
    "traversing home: dconf update STILL runs"
}

# The WRITE side of the same defect, unnamed by the issue but the same class:
# configure_no_idle_lock validates <name> and not <home> either. Here the answer
# is the opposite one — refuse outright, write nothing — because an install that
# lays a dconf profile, a system db and two home files down under a bad path
# leaves artefacts --uninstall can never find, and there is an operator watching.
# Same assertion shape as its reserved- and malformed-name tests above: the one
# that matters is that NOTHING at all was written.
test_configure_no_idle_lock_refuses_an_unusable_home() {
  local d home shims log bad
  require_no_idle_lock "write-side home guard" || return 0

  # --- round 1: empty home ---------------------------------------------------
  shims="$TMP/shims-idle-configure-emptyhome"; log="$(make_idle_shims "$shims" 0)"
  read -r d home <<<"$(idle_fixture idle-configure-emptyhome)"

  run_configure "$d" dreamconnect-host "" "$shims"
  [ "$IDLE_RC" -ne 127 ] || { fail "empty home: exit 127, not a refusal"; return 0; }
  assert_not_contains "$IDLE_OUT" "command not found" \
    "empty home: the refusal came from the guard, not the shell"
  [ "$IDLE_RC" -ne 0 ] || fail "configure with an empty home: expected non-zero exit, got 0"
  assert_contains "$IDLE_OUT" "home" \
    "empty home: the refusal says it is the HOME that is unusable, not the name"
  assert_contains "$IDLE_OUT" "dreamconnect-host" \
    "empty home: the refusal names the account"
  assert_eq "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "empty home: nothing at all written under DC_DCONF_DIR"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "empty home: neither chown nor dconf update was run"

  # --- round 2: a .. component, with a real directory behind it --------------
  shims="$TMP/shims-idle-configure-badhome"; log="$(make_idle_shims "$shims" 0)"
  read -r d home <<<"$(idle_fixture idle-configure-badhome)"
  bad="$home/.."

  run_configure "$d" dreamconnect-host "$bad" "$shims"
  [ "$IDLE_RC" -ne 127 ] || { fail "traversing home: exit 127, not a refusal"; return 0; }
  [ "$IDLE_RC" -ne 0 ] || fail "configure with a traversing home: expected non-zero exit, got 0"
  assert_contains "$IDLE_OUT" "home" \
    "traversing home: the refusal says it is the HOME that is unusable"
  assert_file_absent "$TMP/idle-configure-badhome/.config" \
    "traversing home: no .config is created one level out of the given home"
  assert_eq "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "traversing home: nothing at all written under DC_DCONF_DIR"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "traversing home: neither chown nor dconf update was run"

  # --- round 3: the breaker's own demonstration, at the call site ------------
  # factory/CHECKPOINT.md, breaker lap 1 finding #1: "As root,
  # configure_no_idle_lock dchost "/root/" would chown /root/.config (and
  # subdirs) to the host account". This round is that call, verbatim in shape.
  #
  # The observable that does NOT need root: configure writes the dconf profile
  # and the system db BEFORE it ever touches <home>, so an unguarded run leaves
  # files under DC_DCONF_DIR whatever it then fails to do to /root. The refusal
  # must happen before any of that, and must name the HOME.
  #
  # Skipped under root, deliberately: this call really does create and chown
  # /root/.config on a box where the guard is missing, which is the defect
  # itself — a test must not be the thing that performs it.
  if [ "$(id -u)" -eq 0 ]; then
    skip "configure with /root/: not run as root — this call is destructive without the guard"
  else
    shims="$TMP/shims-idle-configure-rootslash"; log="$(make_idle_shims "$shims" 0)"
    read -r d home <<<"$(idle_fixture idle-configure-rootslash)"

    run_configure "$d" dreamconnect-host "/root/" "$shims"
    [ "$IDLE_RC" -ne 127 ] || { fail "/root/: exit 127, not a refusal"; return 0; }
    [ "$IDLE_RC" -ne 0 ] || fail "configure with /root/: expected non-zero exit, got 0"
    assert_contains "$IDLE_OUT" "home" \
      "/root/: the refusal says it is the HOME that is unusable"
    assert_eq "$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
      "/root/: nothing at all written under DC_DCONF_DIR"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "/root/: neither chown nor dconf update was run"
  fi
}

# --- slice 9b: resolve_host_identity is the PRODUCER of the unvalidated home ---
#
# CONTRACT UNDER TEST — factory/CHECKPOINT.md, "Seraph gate: FAIL", quoted:
#
#   "`resolve_host_identity` emits a space-delimited string
#    `"$name $uid $home /run/user/$uid/dreamconnect.sock"`. When `$home` is empty
#    ... the string has a double space; bash's
#    `read -r USER_NAME USER_UID USER_HOME _ <<<"$IDENTITY"` word-splitting on
#    default IFS COLLAPSES the empty field, shifting the socket path into
#    `$USER_HOME` instead of leaving it empty. Site B's `valid_home_dir
#    "$USER_HOME"` guard then checks the socket path (which IS a valid-looking
#    absolute path), passes, and install proceeds writing into
#    `/run/user/$uid/dreamconnect.sock/.config/...` as if it were a home
#    directory."
#
# So the rail belongs in the producer, where the value is still a variable rather
# than a field in a string that has already lost its boundaries:
#
#   resolve_host_identity <account_or_empty> <fallback_user>, resolved home
#   unusable (fails valid_home_dir — empty, relative, "/", "/home", "/root", or
#   carrying a ".." component)
#     REFUSE. Non-zero exit, NOTHING on stdout, and a message on stderr naming
#     the account and the offending home value. This happens AFTER the passwd
#     entry is found and BEFORE the four-field line is ever echoed, so no caller
#     can be handed a string whose fields have shifted: it gets a complete,
#     valid identity or it gets nothing.
#
#     install.sh:223's `IDENTITY="$(resolve_host_identity ...)" || die` already
#     handles a non-zero exit correctly, so nothing changes there.
#
#     The predicate is valid_home_dir, not a second opinion — the same rails the
#     slice-9 tests above pin, applied at the one place the home enters the run.
#
# Deliberately NOT asserted: a home containing whitespace (`/home/john doe`)
# shifts the same read the same way, but valid_home_dir has no whitespace rail on
# purpose (see the slice-9 header: it also guards classic mode's real human
# passwd entry, and slice 2's breaker lap already found what over-tightening a
# shared path costs). Out of scope here, and named as a known gap.

# Homes that valid_home_dir rejects, one per account, in passwd(5) shape.
# dchost-nohome's field 6 is EMPTY — note the double colon; that is the exact
# defect trigger. dchost-good carries a normal home and is the anti-vacuous
# control: a resolve_host_identity that refused everything would pass every
# rejection assertion below and this one catches it.
make_passwd_db_bad_homes() {
  cat > "$TMP/passwd-bad-homes" <<'EOF'
dchost-nohome:x:1500:1500:DreamConnect display host::/bin/bash
dchost-slash:x:1501:1501:DreamConnect display host:/:/bin/bash
dchost-root:x:1502:1502:DreamConnect display host:/root:/bin/bash
dchost-homes:x:1503:1503:DreamConnect display host:/home:/bin/bash
dchost-relative:x:1504:1504:DreamConnect display host:var/lib/dchost-relative:/bin/bash
dchost-dotdot:x:1505:1505:DreamConnect display host:/var/lib/dchost-dotdot/..:/bin/bash
dchost-good:x:1506:1506:DreamConnect display host:/var/lib/dchost-good:/bin/bash
EOF
  echo "$TMP/passwd-bad-homes"
}

IDENT_RC=0
IDENT_OUT=""
IDENT_ERR=""

# resolve_host_identity with stdout and stderr kept apart, because "nothing on
# stdout" is half the contract and 2>&1 would hide it.
run_resolve() {  # db account fallback
  local err="$TMP/resolve-home.err"
  IDENT_RC=0
  IDENT_OUT="$(DC_PASSWD_DB="$1" resolve_host_identity "$2" "$3" 2>"$err")" || IDENT_RC=$?
  IDENT_ERR="$(cat "$err" 2>/dev/null || true)"
  return 0
}

assert_identity_refused() {  # db account label
  run_resolve "$1" "$2" kogies
  [ "$IDENT_RC" -ne 127 ] || { fail "$3: exit 127 (not defined), not a refusal"; return 0; }
  [ "$IDENT_RC" -ne 0 ] || fail "$3: expected non-zero exit for [$2], got 0 (stdout: [$IDENT_OUT])"
  assert_eq "$IDENT_OUT" "" "$3: a refused identity prints nothing to stdout"
  assert_contains "$IDENT_ERR" "$2" "$3: the refusal names the account"
  assert_contains "$IDENT_ERR" "home" "$3: the refusal says it is the HOME that is unusable"
}

# (a) The defect's own trigger: passwd field 6 blank. Refused outright, so the
# shiftable string is never produced in the first place.
test_resolve_host_identity_refuses_an_empty_home_field() {
  local db
  db="$(make_passwd_db_bad_homes)"
  assert_identity_refused "$db" dchost-nohome "an empty passwd field 6"
}

# The rest of valid_home_dir's rails, reached through the producer. One account
# per rail, everything else about each entry valid, so a refusal can only be the
# home.
test_resolve_host_identity_refuses_every_home_valid_home_dir_rejects() {
  local db
  db="$(make_passwd_db_bad_homes)"
  assert_identity_refused "$db" dchost-slash    "a home of exactly /"
  assert_identity_refused "$db" dchost-root     "a home of /root"
  assert_identity_refused "$db" dchost-homes    "a home of /home"
  assert_identity_refused "$db" dchost-relative "a relative home resolves against root's CWD"
  assert_identity_refused "$db" dchost-dotdot   "a .. component walks out of the home"
  # nobody's home really is "/" on this class of box — that line is captured
  # verbatim from a real /etc/passwd at the top of this file, not invented here.
  assert_identity_refused "$(make_passwd_db)" nobody "a captured real entry whose home is /"
}

# The anti-vacuous guard. A producer that refused everything would satisfy every
# assertion above and break every install; both identities the installer can
# actually produce must still resolve to the same four fields as before.
test_resolve_host_identity_still_resolves_a_usable_home() {
  local db
  db="$(make_passwd_db_bad_homes)"
  run_resolve "$db" dchost-good kogies
  assert_eq "$IDENT_RC" "0" "a normal home still resolves (stderr: $IDENT_ERR)"
  assert_eq "$IDENT_OUT" \
    "dchost-good 1506 /var/lib/dchost-good /run/user/1506/dreamconnect.sock" \
    "a normal home resolves NAME UID HOME SOCKET unchanged"

  db="$(make_passwd_db)"
  run_resolve "$db" "" kogies
  assert_eq "$IDENT_RC" "0" "the fallback desktop user still resolves"
  assert_eq "$IDENT_OUT" "kogies 1000 /home/kogies /run/user/1000/dreamconnect.sock" \
    "classic mode's identity is unchanged"
  run_resolve "$db" dreamconnect-host kogies
  assert_eq "$IDENT_RC" "0" "the host account still resolves"
  assert_eq "$IDENT_OUT" \
    "dreamconnect-host 987 /var/lib/dreamconnect-host /run/user/987/dreamconnect.sock" \
    "host-account mode's identity is unchanged"
}

# THE FIELD SHIFT, from the caller's side. install.sh:223-225 verbatim:
#
#   IDENTITY="$(resolve_host_identity ...)" || die ...
#   read -r USER_NAME USER_UID USER_HOME _ <<<"$IDENTITY"
#
# Default IFS collapses the double space an empty home leaves behind, so the
# socket path lands in USER_HOME and install.sh:232's valid_home_dir guard waves
# it through — an absolute path with no ".." in it. What this test pins is the
# property the guard cannot provide: a caller parsing exactly this way either
# stops, or holds the account's REAL home. Never a value from another field.
test_resolve_host_identity_never_hands_the_caller_a_shifted_home() {
  local db identity rc name uid home rest
  db="$(make_passwd_db_bad_homes)"

  rc=0
  identity="$(DC_PASSWD_DB="$db" resolve_host_identity dchost-nohome kogies 2>/dev/null)" || rc=$?
  name=""; uid=""; home=""; rest=""
  read -r name uid home rest <<<"$identity"

  [ "$rc" -ne 0 ] || fail \
    "install.sh's caller must stop: resolve_host_identity returned 0 with [$identity]"
  assert_not_contains "$home" "dreamconnect.sock" \
    "USER_HOME must never be the socket path (field shift): got [$home]"
  assert_eq "$home" "" "a refused identity leaves USER_HOME empty, not shifted"
  assert_eq "$rest" "" "nothing is left over in the read's catch-all"
  assert_eq "$name" "" "a refused identity leaves USER_NAME empty"
  assert_eq "$uid" "" "a refused identity leaves USER_UID empty"

  # And the guard install.sh applies to the parsed value: today it PASSES on the
  # shifted socket path, which is why it cannot be the fix.
  if [ "$rc" -eq 0 ]; then
    valid_home_dir "$home" \
      && fail "the shifted value [$home] passes valid_home_dir — the downstream guard is blind to it"
  fi
}

# --- slice 3, rail 2: the SAME non-canonical spellings, at the userdel seam ----
#
# host_account_removable's rail 2 delegates its home check to valid_home_dir
# rather than repeating that predicate's literals. Nothing pinned the
# delegation: restoring the old `case "$home" in /|/home|/root) ... esac` in
# THIS function alone left the whole suite green, because every existing rail-2
# test (test_host_account_removable_refuses_dangerous_home_dirs) uses the three
# canonically-spelled values a literal compare still catches.
#
# The expectation is not read off the implementation. It is breaker lap 1
# finding #1, quoted at valid_home_dir's contract above — "/root/, //root,
# /root/., /./root" are bypasses of a literal compare — plus POSIX 4.13
# pathname resolution, under which every home below IS /, /home or /root. And
# the consequence at THIS call site is the worst one in the installer:
# uninstall_host_account runs `userdel -r <name>`, which deletes the home named
# in field 6. A passwd entry reading "/root/" therefore means `userdel -r` on
# root's own home directory.
#
# Every entry satisfies all six other rails — valid account name, non-zero uid,
# exact GECOS marker, matching state record with CREATED_ACCOUNT=1, and it is
# neither the protected user nor $SUDO_USER — so the home field is the only
# thing that can refuse them. dc-home-ok is the control that proves it: same
# fixture shape, ordinary home, and it MUST be removable. Without it a fixture
# typo would make every refusal below pass vacuously.
make_noncanonical_home_passwd_db() {
  cat > "$TMP/passwd-noncanonical-home" <<'EOF'
kogies:x:1000:1000:Kogies:/home/kogies:/bin/bash
dc-home-ok:x:970:970:DreamConnect display host:/var/lib/dc-home-ok:/bin/bash
dc-root-trailing:x:971:971:DreamConnect display host:/root/:/bin/bash
dc-root-double:x:972:972:DreamConnect display host://root:/bin/bash
dc-root-dot:x:973:973:DreamConnect display host:/root/.:/bin/bash
dc-root-leaddot:x:974:974:DreamConnect display host:/./root:/bin/bash
dc-home-trailing:x:975:975:DreamConnect display host:/home/:/bin/bash
dc-slash-triple:x:976:976:DreamConnect display host:///:/bin/bash
EOF
  echo "$TMP/passwd-noncanonical-home"
}

test_host_account_removable_refuses_a_reserved_home_however_it_is_spelled() {
  local db state acct
  db="$(make_noncanonical_home_passwd_db)"

  # The control: this fixture really does satisfy every other rail.
  state="$TMP/state-noncanon-ok/install.state"
  write_state_fixture "$state" dc-home-ok 970 1 1
  try_removable "$db" "$state" "" dc-home-ok kogies
  assert_eq "$REMOVE_RC" "0" \
    "control: an ordinary home in this fixture is removable (stderr: $REMOVE_ERR)"

  for acct in dc-root-trailing dc-root-double dc-root-dot dc-root-leaddot \
              dc-home-trailing dc-slash-triple; do
    state="$TMP/state-noncanon-$acct/install.state"
    write_state_fixture "$state" "$acct" 971 1 1
    try_removable "$db" "$state" "" "$acct" kogies
    assert_refused "userdel -r would delete a reserved directory ($acct)"
    assert_contains "$REMOVE_ERR" "home" \
      "$acct: the refusal names the HOME rail, not another one"
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

# --- slice 10: backstage (headless) session ----------------------------------
# Backstage removes the dummy plug and the autologin requirement by running the
# bridge against `gnome-shell --headless`. The resolution is load-bearing there
# in a way it never was for physical capture: a RecordVirtual stream has no
# intrinsic size, so this value becomes the screen size AND the per-frame shm
# allocation (w*h*4). An unvalidated one reaches Mutter directly.

test_library_defines_the_backstage_helpers() {
  local fn
  for fn in backstage_resolution backstage_supported; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

test_backstage_resolution_defaults_to_1280x720() {
  local out rc
  out="$(backstage_resolution 2>&1)"; rc=$?
  assert_eq "$rc" "0" "unset resolution is accepted"
  assert_eq "$out" "1280x720" "unset resolution defaults to the low-bandwidth size"
  out="$(backstage_resolution "" 2>&1)"; rc=$?
  assert_eq "$rc" "0" "empty resolution is accepted"
  assert_eq "$out" "1280x720" "empty resolution defaults"
}

test_backstage_resolution_passes_through_a_valid_value() {
  local out rc
  out="$(backstage_resolution "1280x720" 2>&1)"; rc=$?
  assert_eq "$rc" "0" "1280x720 accepted"
  assert_eq "$out" "1280x720" "1280x720 echoed back"
}

test_backstage_resolution_accepts_an_uppercase_separator() {
  local out
  out="$(backstage_resolution "1600X900" 2>/dev/null)"
  assert_eq "$out" "1600x900" "uppercase X is normalised to lowercase"
}

test_backstage_resolution_normalises_leading_zeros() {
  local out
  # 08 must not be read as invalid octal by the arithmetic validation.
  out="$(backstage_resolution "0800x0600" 2>/dev/null)"
  assert_eq "$out" "800x600" "leading zeros are stripped, not rejected"
}

assert_res_refused() {  # value label
  local out rc
  out="$(backstage_resolution "$1" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] || fail "$2: expected '$1' to be refused, got exit 0 and [$out]"
  [ -n "$out" ] || fail "$2: refusing '$1' must explain why, got no output"
}

test_backstage_resolution_refuses_malformed_values() {
  assert_res_refused "1920"        "no separator"
  assert_res_refused "1920x"       "missing height"
  assert_res_refused "x1080"       "missing width"
  assert_res_refused "1920x1080x1" "three components"
  assert_res_refused "wide x tall" "non-numeric"
  assert_res_refused "-1920x1080"  "negative width"
  assert_res_refused "1920 1080"   "space separator"
}

test_backstage_resolution_refuses_zero_dimensions() {
  assert_res_refused "0x1080" "zero width"
  assert_res_refused "1920x0" "zero height"
}

# The ceiling exists because the daemon copies w*h*4 bytes per frame into shm.
# 192000x1080 is a plausible typo and would ask for ~800 MB a frame.
test_backstage_resolution_refuses_dimensions_past_the_16384_ceiling() {
  assert_res_refused "192000x1080" "width past the ceiling"
  assert_res_refused "1920x20000"  "height past the ceiling"
}

test_backstage_resolution_accepts_the_documented_maximum() {
  local out rc
  out="$(backstage_resolution "16384x16384" 2>&1)"; rc=$?
  assert_eq "$rc" "0" "16384x16384 is accepted"
  assert_eq "$out" "16384x16384" "16384x16384 echoed back"
}

# The installer's ceiling and the daemon's MAX_DIMENSION must not drift apart:
# a value the installer writes into the unit must be one the daemon will accept,
# or the daemon exits on argument validation and the unit crash-loops.
test_backstage_ceiling_matches_the_daemon_max_dimension() {
  local daemon max
  daemon="$HERE/runtime/dreamconnect_daemon.py"
  assert_file_exists "$daemon" "daemon source is present"
  [ -f "$daemon" ] || return 0
  max="$(sed -n 's/^MAX_DIMENSION[[:space:]]*=[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$daemon" | head -1)"
  [ -n "$max" ] || { fail "could not read MAX_DIMENSION from $daemon"; return 0; }
  assert_eq "$max" "16384" \
    "daemon MAX_DIMENSION and backstage_resolution's ceiling must agree"
}

# backstage_supported gates on gnome-shell being installed; without it the
# backstage unit crash-loops forever and the only symptom is "no capture".
test_backstage_supported_follows_gnome_shell_presence() {
  local rc
  ( PATH="$TMP/empty-path"; mkdir -p "$PATH"; backstage_supported ) && rc=0 || rc=1
  assert_eq "$rc" "1" "backstage_supported is false with no gnome-shell on PATH"

  mkdir -p "$TMP/fake-path"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/fake-path/gnome-shell"
  chmod +x "$TMP/fake-path/gnome-shell"
  ( PATH="$TMP/fake-path:$PATH"; backstage_supported ) && rc=0 || rc=1
  assert_eq "$rc" "0" "backstage_supported is true when gnome-shell is on PATH"
}

# --- slice 10b: the unit templates the installer renders ----------------------
# install.sh substitutes @SESSION_UNIT@/@DAEMON_ARGS@ so one daemon unit serves
# both modes. If a placeholder is renamed in the template but not in install.sh,
# the rendered unit ships a literal @...@ and systemd fails at start.

test_daemon_unit_template_placeholders_are_all_substituted_by_install_sh() {
  local unit sh ph
  unit="$HERE/systemd/dreamconnect-daemon.service"
  sh="$HERE/install.sh"
  assert_file_exists "$unit" "daemon unit template is present"
  [ -f "$unit" ] && [ -f "$sh" ] || return 0
  for ph in $(grep -o '@[A-Z_]\{1,\}@' "$unit" | sort -u); do
    grep -q -- "$ph" "$sh" || \
      fail "daemon unit uses $ph but install.sh never substitutes it — the rendered unit would keep the literal"
  done
}

test_backstage_unit_template_placeholders_are_all_substituted_by_install_sh() {
  local unit sh ph
  unit="$HERE/systemd/dreamconnect-backstage.service"
  sh="$HERE/install.sh"
  assert_file_exists "$unit" "backstage unit template is present"
  [ -f "$unit" ] && [ -f "$sh" ] || return 0
  for ph in $(grep -o '@[A-Z_]\{1,\}@' "$unit" | sort -u); do
    grep -q -- "$ph" "$sh" || \
      fail "backstage unit uses $ph but install.sh never substitutes it"
  done
}

# The backstage unit must NOT hang off graphical-session.target — that target is
# never reached by a spawned headless shell (verified on GNOME 50.2), which is
# the whole reason the autologin requirement went away.
test_backstage_unit_does_not_depend_on_a_graphical_session() {
  local unit
  unit="$HERE/systemd/dreamconnect-backstage.service"
  [ -f "$unit" ] || { fail "backstage unit template is missing"; return 0; }
  assert_not_contains "$(grep -E '^(WantedBy|After|Requires|PartOf|BindsTo)=' "$unit")" \
    "graphical-session.target" \
    "backstage unit must not depend on graphical-session.target"
  assert_contains "$(grep '^WantedBy=' "$unit")" "default.target" \
    "backstage unit is started by the lingering user manager via default.target"
}

# The agent drop-in reads the display env file with a leading '-' so a classic
# install, which never writes one, is unaffected.
test_agent_dropin_tolerates_a_missing_display_env_file() {
  local conf line
  conf="$HERE/systemd/dreamconnect-agent.conf"
  assert_file_exists "$conf" "agent drop-in template is present"
  [ -f "$conf" ] || return 0
  line="$(grep '^EnvironmentFile=' "$conf" || true)"
  [ -n "$line" ] || { fail "agent drop-in must read the backstage display env file"; return 0; }
  assert_contains "$line" "EnvironmentFile=-" \
    "the display env file must be optional ('-'), or a classic install fails to start SC"
}

# --- slice 10c: the X-probe wrapper is display-number agnostic ---------------
# ScreenConnect's startup probes every X display it can find cookies for, with
# no timeout of its own, so one display that accepts connections and never
# completes the handshake blocks SC's main thread forever (it never reaches the
# relay: "online" never happens). Every gnome-shell creates exactly such a
# socket for GNOME_SETUP_DISPLAY.
#
# The wrapper used to hardcode ":1". Backstage keeps the GDM greeter running
# permanently, and the greeter's dead socket is ":1025" on this host — so the
# hardcoded skip missed it and SC hung. The wrapper must therefore key on
# BEHAVIOUR (did the probe answer in time?), never on a display number.

XPROBE="$HERE/host-fixes/xprobe-skip-broken-display.sh"

# Stage a wrapper whose "real tool" directory is a fixture instead of /usr/bin,
# so no production path hook has to exist for the sake of the tests.
stage_xprobe() {  # dir
  mkdir -p "$1/bin" "$1/real" "$1/run"
  sed "s#^real_dirs=.*#real_dirs=\"$1/real\"#" "$XPROBE" > "$1/bin/xdpyinfo"
  chmod +x "$1/bin/xdpyinfo"
}

fake_tool() {  # path body
  printf '#!/bin/sh\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

run_xprobe() {  # dir display -> sets XP_OUT / XP_RC
  XP_OUT="$(DISPLAY="$2" XDG_RUNTIME_DIR="$1/run" DREAMCONNECT_XPROBE_TIMEOUT=1 \
            "$1/bin/xdpyinfo" 2>/dev/null)"
  XP_RC=$?
}

# SC's probe chain is `xdpyinfo || xwininfo || xdotool || xrandr || xrdb`. Any
# tool NOT shadowed runs unbounded, and the hang simply moves down the chain —
# which is exactly what happened once the first two were memoised as dead.
test_every_tool_in_the_probe_chain_is_shadowed() {
  local sh t
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  for t in xdpyinfo xwininfo xdotool xrandr xrdb; do
    grep -qE "^[[:space:]]*for t in .*\\b$t\\b" "$sh" || \
      fail "install.sh does not shadow $t — SC's probe chain falls through to it unbounded and hangs there instead"
  done
}

# The wrapper must find the real tool wherever the distro puts it: xdotool is in
# /usr/sbin on Fedora, so a hardcoded /usr/bin makes the wrapper exec nothing.
test_xprobe_wrapper_searches_more_than_usr_bin() {
  local dirs
  [ -f "$XPROBE" ] || return 0
  dirs="$(grep -m1 '^real_dirs=' "$XPROBE")"
  [ -n "$dirs" ] || { fail "the wrapper does not declare a real_dirs search list"; return 0; }
  assert_contains "$dirs" "/usr/sbin" \
    "the wrapper must look in /usr/sbin — xdotool lives there on Fedora"
  assert_not_contains "$dirs" "PATH" \
    "the search list must not come from PATH: this runs as root in SC's environment"
}

test_xprobe_wrapper_passes_a_healthy_display_through() {
  local d="$TMP/xprobe-ok"
  [ -f "$XPROBE" ] || { fail "x-probe wrapper is missing"; return 0; }
  stage_xprobe "$d"
  fake_tool "$d/real/xdpyinfo" 'echo "  dimensions:    1920x1080 pixels"'
  run_xprobe "$d" ":0"
  assert_eq "$XP_RC" "0" "a healthy display exits 0"
  assert_contains "$XP_OUT" "1920x1080" "a healthy display's output reaches SC unchanged"
}

test_xprobe_wrapper_preserves_a_real_nonzero_exit() {
  local d="$TMP/xprobe-rc"
  [ -f "$XPROBE" ] || return 0
  stage_xprobe "$d"
  # "no such display" must stay a fast, ordinary failure, not be mistaken for a
  # hang and cached as a dead display.
  fake_tool "$d/real/xdpyinfo" 'exit 1'
  run_xprobe "$d" ":7"
  [ "$XP_RC" -ne 0 ] || fail "a failing probe must not report success"
  assert_file_absent "$d/run/dreamconnect-xprobe/_7" \
    "a fast failure is not a hang and must not be cached as a dead display"
}

# The regression itself, with the display number that actually bit us.
test_xprobe_wrapper_gives_up_on_a_hanging_display_whatever_its_number() {
  local d start elapsed disp
  [ -f "$XPROBE" ] || return 0
  for disp in ":1" ":1025" ":42"; do
    d="$TMP/xprobe-hang${disp//:/_}"
    stage_xprobe "$d"
    fake_tool "$d/real/xdpyinfo" 'sleep 30'
    start=$SECONDS
    run_xprobe "$d" "$disp"
    elapsed=$((SECONDS - start))
    [ "$XP_RC" -ne 0 ] || fail "hanging display $disp: must not report success"
    [ "$elapsed" -lt 10 ] || \
      fail "hanging display $disp: wrapper blocked ${elapsed}s — SC's main thread hangs with it"
  done
}

test_xprobe_wrapper_short_circuits_a_display_already_known_dead() {
  local d start elapsed
  [ -f "$XPROBE" ] || return 0
  d="$TMP/xprobe-cache"
  stage_xprobe "$d"
  fake_tool "$d/real/xdpyinfo" 'sleep 30'
  run_xprobe "$d" ":1025"                      # first probe pays the timeout
  start=$SECONDS
  run_xprobe "$d" ":1025"                      # second must be instant
  elapsed=$((SECONDS - start))
  [ "$XP_RC" -ne 0 ] || fail "a cached dead display must keep failing"
  [ "$elapsed" -le 1 ] || \
    fail "a known-dead display cost ${elapsed}s again — SC re-probes every few seconds, so this must be free"
}

test_xprobe_wrapper_does_not_blacklist_other_displays() {
  local d
  [ -f "$XPROBE" ] || return 0
  d="$TMP/xprobe-scope"
  stage_xprobe "$d"
  fake_tool "$d/real/xdpyinfo" 'case "$DISPLAY" in :1025) sleep 30 ;; *) echo "  dimensions:    1920x1080 pixels" ;; esac'
  run_xprobe "$d" ":1025"
  [ "$XP_RC" -ne 0 ] || fail "the dead display must fail"
  run_xprobe "$d" ":0"
  assert_eq "$XP_RC" "0" "a healthy display must still work after another was cached dead"
  assert_contains "$XP_OUT" "1920x1080" "the healthy display's output is unaffected"
}

# --- slice 10d: the backstage display publisher -------------------------------
# The SC drop-in reads DISPLAY/XAUTHORITY from an EnvironmentFile, and systemd
# reads an EnvironmentFile once, at unit start. Mutter's xauth file carries a
# fresh random suffix every time the shell starts, so publishing that path
# directly leaves a long-running SC JVM pointing at a file that no longer exists
# the moment backstage restarts. The publisher must therefore hand out a STABLE
# path whose contents it refreshes.

PUBLISHER="$HERE/runtime/dreamconnect-backstage-env.sh"

stage_publisher() {  # dir display xauth_path
  mkdir -p "$1/bin" "$1/run"
  cat > "$1/bin/systemctl" <<EOF
#!/bin/sh
printf 'DISPLAY=%s\nXAUTHORITY=%s\nWAYLAND_DISPLAY=dreamconnect\n' "$2" "$3"
EOF
  chmod +x "$1/bin/systemctl"
}

run_publisher() {  # dir -> sets PUB_RC
  ( PATH="$1/bin:$PATH"; XDG_RUNTIME_DIR="$1/run" \
    DREAMCONNECT_DISPLAY_TIMEOUT=3 sh "$PUBLISHER" >/dev/null 2>&1 )
  PUB_RC=$?
}

test_publisher_writes_the_display_env_file() {
  local d="$TMP/pub-basic"
  [ -f "$PUBLISHER" ] || { fail "backstage env publisher is missing"; return 0; }
  mkdir -p "$d/run"
  printf 'cookie-one\n' > "$d/run/.mutter-Xwaylandauth.AAAAAA"
  stage_publisher "$d" ":0" "$d/run/.mutter-Xwaylandauth.AAAAAA"
  run_publisher "$d"
  assert_eq "$PUB_RC" "0" "publisher succeeds when the shell has exported a display"
  assert_file_exists "$d/run/dreamconnect-display.env" "the env file is written"
  assert_contains "$(cat "$d/run/dreamconnect-display.env" 2>/dev/null)" "DISPLAY=:0" \
    "the env file carries the display the shell reported"
}

# The regression: a restarted backstage shell gets a NEW random xauth filename,
# and an already-running SC JVM keeps whatever path it was started with.
test_publisher_publishes_a_stable_xauthority_path() {
  local d first second env1 env2
  [ -f "$PUBLISHER" ] || return 0
  d="$TMP/pub-stable"
  mkdir -p "$d/run"

  printf 'cookie-one\n' > "$d/run/.mutter-Xwaylandauth.AAAAAA"
  stage_publisher "$d" ":0" "$d/run/.mutter-Xwaylandauth.AAAAAA"
  run_publisher "$d"
  env1="$(cat "$d/run/dreamconnect-display.env" 2>/dev/null)"
  first="$(printf '%s\n' "$env1" | sed -n 's/^XAUTHORITY=//p')"

  # Restart with a different mutter xauth file, exactly as a real restart does.
  printf 'cookie-two\n' > "$d/run/.mutter-Xwaylandauth.BBBBBB"
  stage_publisher "$d" ":0" "$d/run/.mutter-Xwaylandauth.BBBBBB"
  run_publisher "$d"
  env2="$(cat "$d/run/dreamconnect-display.env" 2>/dev/null)"
  second="$(printf '%s\n' "$env2" | sed -n 's/^XAUTHORITY=//p')"

  [ -n "$first" ] && [ -n "$second" ] || { fail "publisher produced no XAUTHORITY"; return 0; }
  assert_eq "$second" "$first" \
    "the published XAUTHORITY path must not change across a backstage restart — a running SC JVM cannot re-read it"
  assert_not_contains "$first" "AAAAAA" \
    "the published path must not be mutter's per-start random filename"
  assert_eq "$(cat "$first" 2>/dev/null)" "cookie-two" \
    "the stable file's CONTENTS must be refreshed to the current shell's cookie"
}

test_publisher_keeps_the_published_xauthority_owner_only() {
  local d xauth perms
  [ -f "$PUBLISHER" ] || return 0
  d="$TMP/pub-perms"
  mkdir -p "$d/run"
  printf 'cookie\n' > "$d/run/.mutter-Xwaylandauth.CCCCCC"
  stage_publisher "$d" ":0" "$d/run/.mutter-Xwaylandauth.CCCCCC"
  run_publisher "$d"
  xauth="$(sed -n 's/^XAUTHORITY=//p' "$d/run/dreamconnect-display.env" 2>/dev/null)"
  [ -n "$xauth" ] && [ -f "$xauth" ] || { fail "no published xauth file to check"; return 0; }
  # An X cookie is a capability to drive the session; other local users must not
  # be able to read it out of the runtime dir.
  perms="$(stat -c '%a' "$xauth" 2>/dev/null)"
  assert_eq "$perms" "600" "the published X cookie must be owner-only"
}

test_publisher_fails_when_no_display_ever_appears() {
  local d start elapsed
  [ -f "$PUBLISHER" ] || return 0
  d="$TMP/pub-none"
  mkdir -p "$d/bin" "$d/run"
  printf '#!/bin/sh\nexit 0\n' > "$d/bin/systemctl"   # exports nothing
  chmod +x "$d/bin/systemctl"
  start=$SECONDS
  run_publisher "$d"
  elapsed=$((SECONDS - start))
  [ "$PUB_RC" -ne 0 ] || \
    fail "publisher must fail when the shell never exported a display, or the daemon starts against nothing"
  [ "$elapsed" -lt 20 ] || fail "publisher ignored its timeout (${elapsed}s)"
  assert_file_absent "$d/run/dreamconnect-display.env" \
    "no env file may be left behind when there is no display"
}

# --- slice 11: sudo for the display-host account ------------------------------
# The host account is created with password '*' (no password can ever match), so
# any sudo rule for it MUST be NOPASSWD or it is inert — sudo would prompt into a
# session with no tty and hang. And a malformed file in /etc/sudoers.d can break
# sudo for everyone on the box, so nothing is installed until visudo has
# validated it.

stage_sudoers() {  # dir
  mkdir -p "$1/sudoers.d" "$1/bin"
  printf 'root ALL=(ALL) ALL\n#includedir /etc/sudoers.d\n' > "$1/sudoers"
  # A visudo stub: accepts anything containing "ALL", rejects the rest. Enough
  # to prove the call is wired and its verdict is honoured.
  cat > "$1/bin/visudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -cf) shift; f="$1" ;; -c|-q|-s) : ;; *) f="$1" ;; esac; shift; done
grep -q ALL "$f" || { echo "parse error" >&2; exit 1; }
EOF
  chmod +x "$1/bin/visudo"
}

grant_in() {  # dir name -> sets SUDO_OUT / SUDO_RC
  SUDO_OUT="$(PATH="$1/bin:$PATH" DC_SUDOERS_DIR="$1/sudoers.d" DC_SUDOERS_MAIN="$1/sudoers" \
              grant_host_account_sudo "$2" 2>&1)"
  SUDO_RC=$?
}

test_library_defines_the_host_account_sudo_helpers() {
  local fn
  for fn in grant_host_account_sudo revoke_host_account_sudo; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

test_grant_host_account_sudo_writes_a_nopasswd_rule() {
  local d="$TMP/sudo-grant" body
  stage_sudoers "$d"
  grant_in "$d" "screenconnect"
  assert_eq "$SUDO_RC" "0" "granting sudo succeeds"
  assert_file_exists "$d/sudoers.d/dreamconnect-screenconnect" "the sudoers drop-in is written"
  body="$(cat "$d/sudoers.d/dreamconnect-screenconnect" 2>/dev/null)"
  assert_contains "$body" "screenconnect" "the rule names the account"
  # Without NOPASSWD the rule is useless: the account has no password to give.
  assert_contains "$body" "NOPASSWD" \
    "the rule must be NOPASSWD — the host account's password is '*' and can never be entered"
}

test_grant_host_account_sudo_file_is_not_group_or_world_writable() {
  local d="$TMP/sudo-perms" perms
  stage_sudoers "$d"
  grant_in "$d" "screenconnect"
  perms="$(stat -c '%a' "$d/sudoers.d/dreamconnect-screenconnect" 2>/dev/null)"
  [ -n "$perms" ] || { fail "no sudoers file to check"; return 0; }
  # sudo itself refuses to read a drop-in that others can write; 0440 is the
  # convention. Anything writable by group/other is a local root escalation.
  assert_eq "$perms" "440" "the sudoers drop-in must be mode 0440"
}

# The load-bearing safety property: a file that visudo rejects must never land in
# sudoers.d, because sudo refuses to run at all when any drop-in fails to parse.
test_grant_host_account_sudo_installs_nothing_when_visudo_rejects_it() {
  local d="$TMP/sudo-invalid"
  stage_sudoers "$d"
  printf '#!/bin/sh\necho "parse error" >&2\nexit 1\n' > "$d/bin/visudo"
  chmod +x "$d/bin/visudo"
  grant_in "$d" "screenconnect"
  [ "$SUDO_RC" -ne 0 ] || fail "a visudo rejection must make the grant fail"
  assert_file_absent "$d/sudoers.d/dreamconnect-screenconnect" \
    "a rule visudo rejected must not be installed — an unparseable drop-in breaks sudo for every user on the box"
}

test_grant_host_account_sudo_refuses_a_name_that_escapes_sudoers_d() {
  local d="$TMP/sudo-traverse"
  stage_sudoers "$d"
  grant_in "$d" "../sudoers"
  [ "$SUDO_RC" -ne 0 ] || fail "a traversing account name must be refused"
  # The staged main file must still be the one we wrote, not overwritten.
  assert_contains "$(cat "$d/sudoers" 2>/dev/null)" "includedir" \
    "a traversing name must not overwrite /etc/sudoers itself"
}

test_grant_host_account_sudo_warns_when_sudoers_d_is_not_included() {
  local d="$TMP/sudo-noinclude"
  stage_sudoers "$d"
  printf 'root ALL=(ALL) ALL\n' > "$d/sudoers"     # no includedir directive
  grant_in "$d" "screenconnect"
  # Non-fatal, but it must say so: the drop-in would be silently inert.
  assert_contains "$SUDO_OUT" "includedir" \
    "grant must warn when /etc/sudoers does not include sudoers.d — the rule would do nothing"
}

test_revoke_host_account_sudo_removes_the_rule_and_is_idempotent() {
  local d="$TMP/sudo-revoke" rc
  stage_sudoers "$d"
  grant_in "$d" "screenconnect"
  assert_file_exists "$d/sudoers.d/dreamconnect-screenconnect" "rule present before revoke"
  DC_SUDOERS_DIR="$d/sudoers.d" revoke_host_account_sudo "screenconnect" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "revoke succeeds"
  assert_file_absent "$d/sudoers.d/dreamconnect-screenconnect" "the rule is removed"
  DC_SUDOERS_DIR="$d/sudoers.d" revoke_host_account_sudo "screenconnect" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "revoking an absent rule is not an error (uninstall runs it unconditionally)"
}

test_revoke_host_account_sudo_refuses_a_traversing_name() {
  local d="$TMP/sudo-revoke-traverse" rc
  stage_sudoers "$d"
  printf 'keep me\n' > "$d/sudoers.d/other"
  DC_SUDOERS_DIR="$d/sudoers.d" revoke_host_account_sudo "../sudoers" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "revoke must refuse a traversing name"
  assert_file_exists "$d/sudoers" "revoke must not delete /etc/sudoers"
}

# Uninstall must revoke unconditionally, the same way it removes the daemon unit:
# the state file does not record whether sudo was granted.
test_install_sh_revokes_host_account_sudo_on_uninstall() {
  local sh
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }
  grep -q "revoke_host_account_sudo" "$sh" || \
    fail "install.sh never calls revoke_host_account_sudo — an uninstalled box would keep a passwordless root rule"
}

# --- slice 11b: the shm frame path is per-account -----------------------------
# /dev/shm is sticky, so a frame left by an install under a different account
# cannot be unlinked by the new one — every write fails with EACCES and the
# operator sees a desktop frozen on the old install's last frame (#27). Hit for
# real when switching a box to a display-host account. Scoping the path by uid
# makes the collision impossible; the daemon's reclaim is the backstop.

test_daemon_unit_and_agent_dropin_agree_on_the_shm_path() {
  local unit conf sh
  unit="$HERE/systemd/dreamconnect-daemon.service"
  conf="$HERE/systemd/dreamconnect-agent.conf"
  sh="$HERE/install.sh"
  [ -f "$unit" ] && [ -f "$conf" ] && [ -f "$sh" ] || { fail "unit templates missing"; return 0; }
  # The agent reads the file the daemon writes. If the two templates name it
  # differently the bridge shows nothing at all, so they must share one
  # placeholder that install.sh substitutes once.
  grep -q '@SHM_PATH@' "$conf" || \
    fail "the agent drop-in must take the shm path from @SHM_PATH@, not hardcode one"
  grep -q '@SHM_PATH@' "$unit" || \
    fail "the daemon unit must take the shm path from @SHM_PATH@, not rely on the daemon default"
  grep -q 'SHM_PATH=' "$sh" || fail "install.sh never defines SHM_PATH"
}

# A re-run must apply the unit it just wrote. `enable --now` is a no-op against a
# running unit, so an upgrade would leave the previous ExecStart in memory — the
# exact way the uid-scoped shm path failed to take effect the first time.
test_install_sh_restarts_the_units_so_a_rerun_applies_changes() {
  local sh
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  grep -qE 'systemctl --user restart dreamconnect-(daemon|backstage)\.service' "$sh" || \
    fail "install.sh only enables its units; a re-run would keep running the previous ExecStart"
  grep -qE 'systemctl --user enable --now dreamconnect-' "$sh" && \
    fail "install.sh still uses 'enable --now', which does not apply changes to an already-running unit"
  return 0
}

test_install_sh_removes_the_shm_frame_on_uninstall() {
  local sh body
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  # Scoped to the uninstall function so an install-time cleanup line can't
  # satisfy this by accident.
  body="$(awk '/^uninstall\(\) \{/,/^\}/' "$sh")"
  assert_contains "$body" "/dev/shm/dreamconnect.frame" \
    "uninstall must remove the shm frame — a survivor blocks the next install under a different account (#27)"
}

# The session-switch CLI repoints the SC drop-in between accounts. Its renderer
# must produce the same wiring shape install.sh writes (uid-scoped socket + shm,
# the perf args, the optional display env file), or a switch would misconfigure
# the client. DC_RENDER_ONLY=1 exercises the pure renderer with no root/systemd.
test_session_cli_renders_a_valid_dropin() {
  local cli out
  cli="$HERE/runtime/dreamconnect-session"
  assert_file_exists "$cli" "the session-switch CLI is present"
  [ -f "$cli" ] || return 0
  assert_contains "$(bash -n "$cli" 2>&1 || echo SYNTAXERR)" "" "the CLI parses"

  out="$(DC_RENDER_ONLY=1 DREAMCONNECT_FPS=60 DREAMCONNECT_LOGONTTL=300 INSTALL_DIR=/opt/dreamconnect \
         bash "$cli" 1000 kogies 2>&1)"
  assert_contains "$out" "socket=/run/user/1000/dreamconnect.sock" "socket is uid-scoped"
  assert_contains "$out" "shm=/dev/shm/dreamconnect.frame.1000"    "shm is uid-scoped"
  assert_contains "$out" "label=kogies"                            "the label names the account"
  assert_contains "$out" "maxfps=60"                               "the fps knob is carried onto the session"
  assert_contains "$out" "logonttl=300"                            "the probe-cache knob is carried"
  assert_contains "$out" "EnvironmentFile=-/run/user/1000/dreamconnect-display.env" \
    "the display env file is optional (leading -) and uid-scoped"

  # FPS=0 must drop maxfps entirely (stock), never emit maxfps=0.
  out="$(DC_RENDER_ONLY=1 DREAMCONNECT_FPS=0 DREAMCONNECT_LOGONTTL=300 bash "$cli" 1000 kogies 2>&1)"
  assert_not_contains "$out" "maxfps" "FPS=0 renders no maxfps arg (stock ceiling)"
}

# Uninstall must remove the CLI symlink and its runtime state, or a stale
# /usr/local/bin/dreamconnect-session and /run/dreamconnect linger after removal.
test_uninstall_removes_the_session_cli() {
  local sh body
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  body="$(awk '/^uninstall\(\) \{/,/^\}/' "$sh")"
  assert_contains "$body" "/usr/local/bin/dreamconnect-session" \
    "uninstall removes the session-switch CLI symlink"
  assert_contains "$body" "/run/dreamconnect" \
    "uninstall removes the active-session state dir"
}

test_install_sh_scopes_the_shm_path_by_uid() {
  local sh line
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  line="$(grep -m1 '^SHM_PATH=' "$sh")"
  [ -n "$line" ] || { fail "install.sh does not define SHM_PATH"; return 0; }
  assert_contains "$line" "USER_UID" \
    "the shm path must be scoped by uid, or two accounts collide on one sticky /dev/shm file (#27)"
}

# Backstage lifts SC's 20 fps ceiling by default (measured 20->62 fps for ~2%
# CPU on dedicated hardware); a classic install into a human's session stays
# stock so their machine is never pushed harder without asking. The append must
# be gated on >0 so DREAMCONNECT_FPS=0 disables it cleanly.
test_install_sh_defaults_backstage_fps_and_leaves_classic_stock() {
  local sh line
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  line="$(grep -m1 'DREAMCONNECT_FPS:=' "$sh")"
  [ -n "$line" ] || { fail "install.sh does not default DREAMCONNECT_FPS"; return 0; }
  assert_contains "$line" "BACKSTAGE" \
    "the fps default must depend on backstage mode"
  assert_contains "$line" "60" "backstage defaults to 60 fps"
  assert_contains "$line" "0" "classic mode defaults to 0 (SC's stock ceiling)"
  # The maxfps arg must only be appended when the value is > 0.
  grep -q 'DREAMCONNECT_FPS.*-gt 0' "$sh" || grep -q '\[ "\$DREAMCONNECT_FPS" -gt 0 \]' "$sh" || \
    fail "install.sh must only append maxfps when DREAMCONNECT_FPS > 0 (so 0 = stock)"
}

# --- slice 13: autologin is gone ----------------------------------------------
# Autologin existed only to manufacture a graphical session so the bridge had
# something to attach to — never to make the login screen viewable, which Mutter
# forbids outright. Backstage creates that session directly, so the workaround
# and its GDM edit were removed. These pin the removal: a reintroduced GDM edit
# is a security regression (a box booting to an unlocked desktop), not a feature.

test_the_autologin_helpers_are_gone() {
  local fn
  for fn in enable_autologin disable_autologin gdm_conf; do
    declare -F "$fn" >/dev/null && \
      fail "install-lib.sh still defines $fn(): autologin was removed, and a GDM edit must not come back without a decision"
  done
  return 0
}

test_the_installer_never_edits_the_display_manager_config() {
  local sh lib
  sh="$HERE/install.sh"; lib="$HERE/install-lib.sh"
  [ -f "$sh" ] && [ -f "$lib" ] || { fail "installer sources missing"; return 0; }
  # Comments may still explain the history; code must not touch the file.
  local code
  code="$(grep -vE '^[[:space:]]*#' "$sh" "$lib")"
  assert_not_contains "$code" "custom.conf" \
    "the installer must not read or write the GDM config any more"
  assert_not_contains "$code" "AutomaticLogin" \
    "the installer must not set AutomaticLogin* — that boots the box to an unlocked desktop"
}

test_no_autologin_environment_variable_is_honoured() {
  local sh code
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  code="$(grep -vE '^[[:space:]]*#' "$sh")"
  assert_not_contains "$code" "DREAMCONNECT_AUTOLOGIN" \
    "DREAMCONNECT_AUTOLOGIN was removed; honouring it again would silently reintroduce the GDM edit"
}

# With autologin gone, a display-host account has no way to reach a session
# except backstage — it never logs in. Installing one in classic mode would
# create the account, wire the daemon to graphical-session.target, and produce a
# box where nothing ever starts.
test_a_host_account_implies_backstage() {
  local sh body
  sh="$HERE/install.sh"
  [ -f "$sh" ] || return 0
  body="$(grep -vE '^[[:space:]]*#' "$sh")"
  assert_contains "$body" "DREAMCONNECT_HOST_ACCOUNT" "install.sh still reads the host-account variable"
  # The implication must be applied AFTER host_account_installable resolves, or a
  # bare re-run on a box that already records an account misses it.
  local resolved implied
  resolved="$(first_code_line "$sh" 'host_account_installable')"
  implied="$(first_code_line "$sh" 'BACKSTAGE=1' "$resolved")"
  [ -n "$resolved" ] || { fail "install.sh no longer calls host_account_installable"; return 0; }
  [ -n "$implied" ] || {
    fail "install.sh never turns backstage on after resolving the host account — a recorded account would install in classic mode and never start"
    return 0; }
  [ "$resolved" -lt "$implied" ] || \
    fail "the backstage implication (line $implied) must come after host_account_installable (line $resolved)"
}

# --- slice 12: detect_user must never pick the display manager ----------------
# The GDM greeter runs a real, active, Wayland logind session (uid 60578,
# gnome-shell --mode=gdm), so a filter of "active AND graphical" matches it. On a
# box parked at the greeter — which is every backstage box, permanently, by
# design — detect_user then returns "gdm-greeter", and a classic-mode install
# targets the greeter's account while an uninstall silently reverts nothing.

stage_loginctl() {  # dir <<sessions
  mkdir -p "$1/bin"
  cat > "$1/bin/loginctl" <<'EOF'
#!/bin/sh
# Fixture: sessions live in $FIXTURE/sessions, one "sid uid name class type active" per line.
case "$1" in
  list-sessions) awk '{print $1, $2, $3, "seat0"}' "$FIXTURE/sessions" ;;
  show-session)
    sid="$2"; prop=""
    for a in "$@"; do case "$a" in -p) prop=NEXT ;; *) [ "$prop" = NEXT ] && { prop="$a"; break; } ;; esac; done
    awk -v s="$sid" -v p="$prop" '$1==s {
      if (p=="Class") print $4; else if (p=="Type") print $5; else if (p=="Active") print $6 }' "$FIXTURE/sessions" ;;
esac
EOF
  chmod +x "$1/bin/loginctl"
}

detect_user_with() {  # dir -> sets DU_OUT / DU_RC
  DU_OUT="$(PATH="$1/bin:$PATH" FIXTURE="$1" bash -c '
      . "$1"; unset DREAMCONNECT_USER; detect_user' _ "$LIB" 2>/dev/null)"
  DU_RC=$?
}

test_detect_user_skips_the_greeter_and_picks_the_human() {
  local d="$TMP/detect-both"
  stage_loginctl "$d"
  # The greeter is listed first, exactly as loginctl orders it on a box where
  # the greeter started before anyone logged in.
  printf 'c1 60578 gdm-greeter greeter wayland yes\n5 1000 kogies user wayland yes\n' > "$d/sessions"
  detect_user_with "$d"
  assert_eq "$DU_OUT" "kogies" \
    "detect_user must skip the greeter session and return the human, even when the greeter is listed first"
}

test_detect_user_refuses_a_box_with_only_a_greeter() {
  local d="$TMP/detect-greeter-only"
  stage_loginctl "$d"
  printf 'c1 60578 gdm-greeter greeter wayland yes\n' > "$d/sessions"
  detect_user_with "$d"
  [ "$DU_RC" -ne 0 ] || \
    fail "a box sitting at the greeter has no desktop user; detect_user must fail, not return [$DU_OUT]"
  assert_not_contains "$DU_OUT" "gdm" \
    "detect_user must never hand back a display-manager account"
}

test_detect_user_still_finds_an_ordinary_session() {
  local d="$TMP/detect-plain"
  stage_loginctl "$d"
  printf '3 1000 kogies user wayland yes\n' > "$d/sessions"
  detect_user_with "$d"
  assert_eq "$DU_OUT" "kogies" "an ordinary graphical session is still detected"
}

test_detect_user_ignores_inactive_and_non_graphical_sessions() {
  local d="$TMP/detect-noise"
  stage_loginctl "$d"
  printf '2 1000 kogies user tty yes\n4 1000 kogies user wayland no\n7 1000 realuser user x11 yes\n' > "$d/sessions"
  detect_user_with "$d"
  assert_eq "$DU_OUT" "realuser" "only the active graphical session counts"
}

# --- runner ------------------------------------------------------------------
# --- issue #53 slice 1: the session registry writers -------------------------
#
# #51 made the agent READ /run/dreamconnect/sessions/<uid>. These functions are
# what write it, from install.sh (backstage) and runtime/dreamconnect-session
# (a session coming up or going down). If a written entry does not satisfy the
# reader exactly, the agent ignores it in silence and the whole feature is inert
# — so these tests are written against the committed reader, not against a
# summary of it: agent/boot/dreamconnect/boot/Bridge.java, parseRegistryEntry()
# and readRegistry():
#
#   * filename must be ALL DIGITS  (readRegistry: `if (!allDigits(n)) continue`)
#   * `key=value` per line, first `=` splits, unknown keys ignored
#   * required: uid user display shm socket   (a missing one -> entry dropped)
#   * blank value == missing                  (`if (v.isEmpty()) continue`)
#   * uid must parse as a number              (`Long.parseLong` -> null on fail)
#   * label optional; blank or `ERR ...` is dropped by sanitizeLabel()
#
# SHAPES CHOSEN (the builder implements to these; say so if you would rather
# name them differently):
#   render_registry_entry <uid> <user> <display> <shm> <socket> [label] -> stdout
#   write_registry_entry  <dir> <uid> <user> <display> <shm> <socket> [label]
#   remove_registry_entry <dir> <uid>
#   session_display       <envfile> -> stdout
#
# WHAT THESE TESTS CANNOT PROVE, stated plainly rather than faked: this suite
# refuses to run as root (see the header), so nothing here demonstrates the
# ownership half of the reader's trust rule — that the directory and entries are
# owned by uid 0. Only modes, content, atomicity, refusals and idempotence are
# testable as an ordinary user. A parameterised owner (as Bridge.trustedFile
# took) would buy nothing here: these functions do not CHECK ownership, they
# inherit it from running as root, so there is no predicate to parameterise.
# Root ownership stays a review item and a live-install check.
#
# DECISION, since the coordinator asked which: a value containing a newline is
# REJECTED, not escaped. The format has no escape syntax — the reader splits on
# \n and unescapes nothing — so any "escaping" would either arrive corrupted or
# smuggle a second key. None of these fields can legitimately contain a newline
# (a uid, a login name, an X display, two paths). Rejecting is the only choice
# that cannot produce a valid-looking entry that means something else.

require_registry_writers() {  # label
  local fn
  for fn in render_registry_entry write_registry_entry remove_registry_entry; do
    declare -F "$fn" >/dev/null && continue
    fail "$1: $fn() is not defined — the assertions below would pass vacuously"
    return 1
  done
  return 0
}

test_library_defines_the_registry_writers() {
  local fn
  for fn in render_registry_entry write_registry_entry remove_registry_entry session_display; do
    declare -F "$fn" >/dev/null || fail "install-lib.sh defines $fn(): not defined"
  done
}

# Every key the reader requires, spelled exactly as it parses them. Asserted as
# whole lines: `uid=1000 ` or ` uid=1000` would still parse (the reader trims),
# but a writer that emits `uid = 1000` writes the key " uid" — which trims to
# "uid" too — while `uid:1000` silently drops the entry. Exact lines pin the
# format the reader documents rather than the subset it tolerates.
test_render_registry_entry_emits_every_key_the_reader_requires() {
  local out rc
  out="$(render_registry_entry 1000 kogies :1 /dev/shm/dreamconnect.frame.1000 \
         /run/user/1000/dreamconnect.sock '[Backstage]' 2>/dev/null)"; rc=$?
  assert_eq "$rc" "0" "render_registry_entry succeeds on a complete session"
  assert_line "$out" "uid=1000"                                "entry carries uid"
  assert_line "$out" "user=kogies"                             "entry carries user"
  assert_line "$out" "display=:1"                              "entry carries display"
  assert_line "$out" "shm=/dev/shm/dreamconnect.frame.1000"    "entry carries shm"
  assert_line "$out" "socket=/run/user/1000/dreamconnect.sock" "entry carries socket"
  assert_line "$out" "label=[Backstage]"                       "entry carries label"
}

# A blank value is a MISSING value to the reader, so a `label=` line with
# nothing after it is not a neutral default — it is a line that exists only to
# be discarded. Omit it.
test_render_registry_entry_omits_label_when_absent() {
  local out rc
  out="$(render_registry_entry 992 backstage :0 /dev/shm/f /run/user/992/s 2>/dev/null)"; rc=$?
  assert_eq "$rc" "0" "render_registry_entry succeeds without a label"
  assert_not_contains "$out" "label=" "no label given -> no label line at all, not a blank one"
  assert_line "$out" "uid=992" "the rest of the entry is still complete"
}

# A required field that is empty produces an entry the reader drops on the
# floor. Refuse loudly at the writer instead, where the operator can see it.
test_render_registry_entry_refuses_a_missing_required_field() {
  local out rc i label
  local -a args
  local names=(uid user display shm socket)
  require_registry_writers "render refuses missing fields" || return 0
  for i in 0 1 2 3 4; do
    args=(1000 kogies :1 /dev/shm/f /run/user/1000/s)
    args[$i]=""
    label="render refuses an empty ${names[$i]}"
    out="$(render_registry_entry "${args[@]}" 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] || fail "$label: expected non-zero exit, got 0"
    assert_eq "$out" "" "$label: writes nothing to stdout"
  done
  # Too few arguments at all is the same refusal, not an entry with holes.
  out="$(render_registry_entry 1000 kogies 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "render refuses a short argument list: expected non-zero exit"
  assert_eq "$out" "" "render refuses a short argument list: writes nothing"
}

# The reader parses uid with Long.parseLong and returns null on failure, so a
# non-numeric uid is not a degraded entry — it is an invisible one. It is also
# what would name the file, and readRegistry ignores any filename that is not
# all digits.
test_render_registry_entry_refuses_a_non_numeric_uid() {
  local out rc bad
  require_registry_writers "render refuses a non-numeric uid" || return 0
  for bad in root 1000x 10.0 -1 " " "1 000"; do
    out="$(render_registry_entry "$bad" kogies :1 /dev/shm/f /run/user/1000/s 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] || fail "render refuses uid [$bad]: expected non-zero exit, got 0"
    assert_eq "$out" "" "render refuses uid [$bad]: writes nothing to stdout"
  done
}

# The security-relevant one. `label` reaches the operator's session picker and
# every field is interpolated into a line-oriented file, so a value carrying a
# newline could append `uid=0` — or a socket= line pointing anywhere — to an
# entry root itself wrote. Rejected, not escaped (see the decision at the top of
# this section).
test_render_registry_entry_refuses_a_value_containing_a_newline() {
  local out rc label
  require_registry_writers "render refuses embedded newlines" || return 0
  out="$(render_registry_entry 1000 kogies :1 /dev/shm/f /run/user/1000/s "$(printf 'x\nuid=0')" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "render refuses a label with a newline: expected non-zero exit, got 0"
  assert_eq "$out" "" "render refuses a label with a newline: writes nothing"
  assert_not_contains "$out" "uid=0" "a smuggled uid=0 never reaches stdout"

  out="$(render_registry_entry 1000 "$(printf 'kogies\nsocket=/tmp/evil.sock')" :1 \
         /dev/shm/f /run/user/1000/s 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "render refuses a user with a newline: expected non-zero exit, got 0"
  assert_not_contains "$out" "/tmp/evil.sock" "a smuggled socket= never reaches stdout"

  out="$(render_registry_entry 1000 kogies "$(printf ':1\nshm=/tmp/evil.frame')" \
         /dev/shm/f /run/user/1000/s 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "render refuses a display with a newline: expected non-zero exit, got 0"
  assert_not_contains "$out" "/tmp/evil.frame" "a smuggled shm= never reaches stdout"
}

# The file is named for the uid and nothing else: readRegistry ignores every
# name that is not all digits, so `1000.tmp` or `session-1000` is not an entry.
# Mode is asserted under a deliberately hostile umask, because 0644 has to be
# set, not inherited: a 0002 umask would otherwise leave the entry
# group-writable and the reader refuses the whole registry for that.
test_write_registry_entry_writes_the_entry_at_the_uid_filename() {
  local dir body rendered mode dirmode
  dir="$TMP/registry-write"
  require_registry_writers "write_registry_entry" || return 0
  ( umask 000; write_registry_entry "$dir" 1000 kogies :1 /dev/shm/dreamconnect.frame.1000 \
      /run/user/1000/dreamconnect.sock kogies >/dev/null 2>&1 )
  assert_file_exists "$dir/1000" "write_registry_entry writes <dir>/<uid>"
  body="$(cat "$dir/1000" 2>/dev/null || true)"
  rendered="$(render_registry_entry 1000 kogies :1 /dev/shm/dreamconnect.frame.1000 \
              /run/user/1000/dreamconnect.sock kogies 2>/dev/null)"
  assert_eq "$body" "$rendered" "the file content is exactly what render_registry_entry emits"
  mode="$(stat -c '%a' "$dir/1000" 2>/dev/null)"
  assert_eq "$mode" "644" "entry mode is 0644 even under umask 000 (the reader refuses group/other-writable)"
  dirmode="$(stat -c '%a' "$dir" 2>/dev/null)"
  assert_eq "$dirmode" "755" "registry directory is created 0755, whatever the umask"
}

# Atomic means renamed into place, never truncated and refilled: a reader that
# opens the entry mid-write must see the old one or the new one. The inode is
# the observable — rename(2) puts a NEW inode at the name, an in-place
# `> "$f"` keeps the old one. Also: no staging file may be left behind, because
# a leftover `1000.tmp` that happens to parse is a second entry for one display,
# which the agent refuses as ambiguous (#51 round 6).
test_write_registry_entry_replaces_an_existing_entry_atomically() {
  local dir before after body names
  dir="$TMP/registry-atomic"
  require_registry_writers "write_registry_entry is atomic" || return 0
  write_registry_entry "$dir" 1000 kogies :1 /dev/shm/f1 /run/user/1000/s1 first >/dev/null 2>&1
  before="$(stat -c '%i' "$dir/1000" 2>/dev/null)"
  write_registry_entry "$dir" 1000 kogies :2 /dev/shm/f2 /run/user/1000/s2 second >/dev/null 2>&1
  after="$(stat -c '%i' "$dir/1000" 2>/dev/null)"
  body="$(cat "$dir/1000" 2>/dev/null || true)"

  assert_line "$body" "display=:2" "the rewrite wins"
  assert_not_contains "$body" "display=:1" "and leaves nothing of the previous entry behind"
  assert_not_contains "$body" "label=first" "a rewrite replaces, it does not append"
  [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ] \
    || fail "atomic rewrite: expected a new inode at <dir>/1000 (rename), got [$before] then [$after]"
  names="$(ls -A "$dir" 2>/dev/null | tr '\n' ' ')"
  assert_eq "$names" "1000 " "no staging file survives the write (dir holds only the entry)"
}

# A refusal must leave the registry exactly as it found it: no half-entry, no
# staging file, and — the case that matters on a re-registration — no damage to
# the entry that was already there and is still true.
test_write_registry_entry_leaves_nothing_behind_when_it_refuses() {
  local dir rc names body
  dir="$TMP/registry-refuse"
  require_registry_writers "write_registry_entry refusals" || return 0
  write_registry_entry "$dir" 1000 kogies :1 /dev/shm/f1 /run/user/1000/s1 good >/dev/null 2>&1
  body="$(cat "$dir/1000" 2>/dev/null || true)"

  write_registry_entry "$dir" 1000 "" :1 /dev/shm/f1 /run/user/1000/s1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "write refuses an empty user: expected non-zero exit, got 0"
  assert_eq "$(cat "$dir/1000" 2>/dev/null || true)" "$body" \
    "a refused rewrite leaves the existing entry byte-identical"

  write_registry_entry "$dir" 1001 kogies :1 /dev/shm/f1 /run/user/1001/s1 "$(printf 'x\nuid=0')" \
    >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "write refuses a newline in a value: expected non-zero exit, got 0"
  assert_file_absent "$dir/1001" "a refused write creates no entry"

  write_registry_entry "$dir" not-a-uid kogies :1 /dev/shm/f1 /run/user/1000/s1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "write refuses a non-numeric uid: expected non-zero exit, got 0"

  names="$(ls -A "$dir" 2>/dev/null | tr '\n' ' ')"
  assert_eq "$names" "1000 " "no staging or partial file survives a refusal"
}

# Teardown must actually remove the entry: a stale entry pointing at a dead
# daemon is the one case where a planted frame could still be met (issue #53's
# own criteria). Idempotent because teardown runs on paths that may already have
# run — and because a session that never registered must not fail its own
# cleanup.
test_remove_registry_entry_is_idempotent_and_leaves_others_alone() {
  local dir rc
  dir="$TMP/registry-remove"
  require_registry_writers "remove_registry_entry" || return 0
  write_registry_entry "$dir" 1000 kogies :1 /dev/shm/f1 /run/user/1000/s1 one >/dev/null 2>&1
  write_registry_entry "$dir" 992 backstage :0 /dev/shm/f2 /run/user/992/s2 two >/dev/null 2>&1

  remove_registry_entry "$dir" 1000 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "remove_registry_entry succeeds on an entry that exists"
  assert_file_absent "$dir/1000" "the entry is gone"
  assert_file_exists "$dir/992" "the other session's entry is untouched"

  remove_registry_entry "$dir" 1000 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "removing an already-absent entry succeeds (teardown is idempotent)"
  assert_file_exists "$dir" "the registry directory itself is never removed"
}

# remove_registry_entry runs as root and takes a uid from its caller. If that
# uid is pasted into a path unchecked, `../../etc/passwd` is a root `rm` outside
# the registry. The reader already says only all-digit names are entries; the
# writer must agree, and refuse.
test_remove_registry_entry_refuses_a_uid_that_is_not_a_number() {
  local dir rc bad
  dir="$TMP/registry-traversal"
  require_registry_writers "remove_registry_entry refuses traversal" || return 0
  mkdir -p "$dir/sessions"
  : > "$dir/victim"
  write_registry_entry "$dir/sessions" 1000 kogies :1 /dev/shm/f1 /run/user/1000/s1 one >/dev/null 2>&1
  for bad in "../victim" "1000/../../victim" "" "*" "."; do
    remove_registry_entry "$dir/sessions" "$bad" >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] || fail "remove refuses uid [$bad]: expected non-zero exit, got 0"
  done
  assert_file_exists "$dir/victim" "nothing outside the registry directory was removed"
  assert_file_exists "$dir/sessions/1000" "and the real entry survived every refusal"
}

# Where a session's display comes from at registration time: the env file
# runtime/dreamconnect-backstage-env.sh publishes, whose exact bytes are
# `printf 'DISPLAY=%s\nXAUTHORITY=%s\n'` — unquoted, one per line.
test_session_display_reads_the_published_display() {
  local f out rc
  f="$TMP/display-env-ok"
  printf 'DISPLAY=:3\nXAUTHORITY=/run/user/992/dreamconnect.Xauthority\n' > "$f"
  out="$(session_display "$f" 2>/dev/null)"; rc=$?
  assert_eq "$rc" "0" "session_display succeeds on a published env file"
  assert_eq "$out" ":3" "session_display prints the DISPLAY value and nothing else"
}

# No display is not an empty display: registering `display=` writes an entry the
# reader drops, so the caller has to be told to stop instead.
test_session_display_fails_when_there_is_no_usable_display() {
  local f out rc
  declare -F session_display >/dev/null || {
    fail "session_display(): not defined — the assertions below would pass vacuously"; return 0; }

  out="$(session_display "$TMP/display-env-absent" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "session_display on a missing file: expected non-zero exit, got 0"
  assert_eq "$out" "" "session_display on a missing file prints nothing"

  f="$TMP/display-env-blank"
  printf 'DISPLAY=\nXAUTHORITY=/run/user/992/x\n' > "$f"
  out="$(session_display "$f" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "session_display on a blank DISPLAY: expected non-zero exit, got 0"
  assert_eq "$out" "" "session_display on a blank DISPLAY prints nothing"

  f="$TMP/display-env-none"
  printf 'XAUTHORITY=/run/user/992/x\n' > "$f"
  out="$(session_display "$f" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "session_display with no DISPLAY line: expected non-zero exit, got 0"

  # A key that merely ENDS in DISPLAY is not DISPLAY. An unanchored match would
  # register the wrong display for the session, which is the whole family of
  # bug #51 exists to prevent.
  f="$TMP/display-env-decoy"
  printf 'XDISPLAY=:9\nGDM_DISPLAY=:8\n' > "$f"
  out="$(session_display "$f" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "session_display with only decoy keys: expected non-zero exit, got 0"
  assert_eq "$out" "" "session_display never returns a value from XDISPLAY=/GDM_DISPLAY="
}

# --- issue #53 slice 2: wiring the registry writers into the callers ---------
#
# Slice 1 built render/write/remove_registry_entry and session_display; nothing
# called them, so the registry was still never written and #51's reader had
# nothing to read. This slice is the call sites: runtime/dreamconnect-session
# (a session coming up or going down) and install.sh (backstage).
#
# THE SEAM, and what it does NOT prove. runtime/dreamconnect-session is a CLI
# that dispatches at the bottom, and install.sh demands root and does top-level
# work, so neither can be sourced or executed here. These are STATIC call-site
# assertions over the script text, the same technique
# test_install_sh_waits_for_the_user_bus_before_the_first_systemctl_user_call
# uses and for the same reason: the risk is a call that is missing, orphaned or
# in the wrong order, and that is visible in the text.
#
# They prove the wiring is present and ordered. They do NOT prove systemd
# started anything, that the daemon accepted the arguments, or that the entry
# root writes is one the agent will trust at runtime. That is a live-install
# check, and the reader's own rules are covered by the Java suite.

func_range() {  # file funcname -> "start end" (body lines), or empty
  awk -v fn="$2" '
    index($0, fn "()") == 1 { start = NR; next }
    start && /^}/ { print start " " NR; exit }
  ' "$1"
}

code_line_in_func() {  # file funcname regex -> line number within that function, or empty
  local range start end
  range="$(func_range "$1" "$2")"
  [ -n "$range" ] || return 0
  start="${range% *}"; end="${range#* }"
  awk -v re="$3" -v s="$start" -v e="$end" \
    'NR > s && NR < e && $0 ~ re && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$1"
}

SESSION_CLI_HINT="runtime/dreamconnect-session"

# The daemon that answers the agent must know its own display and name. A daemon
# started without --display answers UNKNOWN however new it is, which is what
# looked like version skew; without --label the picker shows the login name.
test_session_cli_starts_the_daemon_with_display_and_label() {
  local cli daemon stmt
  cli="$HERE/runtime/dreamconnect-session"
  assert_file_exists "$cli" "$SESSION_CLI_HINT is present"
  [ -f "$cli" ] || return 0

  daemon="$(code_line_in_func "$cli" bring_up_user 'systemd-run --user --unit=dreamconnect-session-daemon')"
  [ -n "$daemon" ] || { fail "call site: bring_up_user no longer starts the capture daemon"; return 0; }
  stmt="$(logical_statement_at "$cli" "$daemon")"
  [ -n "$stmt" ] || { fail "call site: could not read the daemon statement at $SESSION_CLI_HINT:$daemon"; return 0; }

  assert_contains "$stmt" "--shm" "the daemon is still told which frame to write"
  assert_contains "$stmt" "--display" \
    "the daemon must be given --display, or it answers UNKNOWN and the agent will not select it"
  assert_contains "$stmt" "--label" \
    "the daemon must be given --label, or the picker names the session after the account"
}

# Ordering, install side: the display env only exists once the backstage session
# is actually running, so registration has to come after the units are started.
test_install_sh_starts_registration_after_its_session_is_running() {
  local sh started reg
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  # `restart`, not `enable`: enabling only wires the unit for boot, and
  # install.sh deliberately restarts to apply this run's changes. The restart is
  # the line after which a session is actually running and has published a
  # display.
  started="$(first_code_line "$sh" 'systemctl --user restart')"
  [ -n "$started" ] || { fail "call site: install.sh no longer starts the user units"; return 0; }
  reg="$(first_code_line "$sh" 'write_registry_entry')"
  [ -n "$reg" ] || { fail "call site: install.sh never calls write_registry_entry"; return 0; }

  [ "$started" -lt "$reg" ] || \
    fail "call site: write_registry_entry (line $reg) must come AFTER the session units are started (line $started) — before that there is no published display to register"
}

# Uninstall already removes /run/dreamconnect wholesale. That still covers the
# registry — but only while the registry lives under it.
#
# REVISED, round 4: this used to look for the string "sessions" in install.sh,
# and the only line that matched was a REGISTRY_DIR variable install.sh no
# longer reads. Deleting that dead code would have REDDENED the test — it was
# passing for the wrong reason. The registry path now comes from the script that
# actually writes it, the removal from uninstall(), and the assertion is the
# real relationship between them.
test_uninstall_removes_the_registry_with_the_run_directory() {
  local sh reg_dir range start end removed
  sh="$HERE/install.sh"
  [ -f "$sh" ] && [ -f "$REGISTER_SH" ] || {
    fail "registry coverage: need install.sh and runtime/dreamconnect-register.sh"; return 0; }

  # However the script spells its default (a DC_REGISTRY_DIR_DEFAULT constant
  # today, a ${VAR:-default} expansion before that): take the registry path it
  # actually carries, not one this test hardcodes.
  reg_dir="$(sed -n -e 's/^DC_REGISTRY_DIR[A-Z_]*=\"\([^\"]*\)\".*/\1/p' \
                    -e 's/.*DC_REGISTRY_DIR:-\([^}\"]*\).*/\1/p' "$REGISTER_SH" | head -n 1)"
  [ -n "$reg_dir" ] || {
    fail "registry coverage: cannot find the registry directory the register script writes to"; return 0; }

  range="$(func_range "$sh" uninstall)"
  [ -n "$range" ] || { fail "install.sh has no uninstall() to scope this to"; return 0; }
  start="${range% *}"; end="${range#* }"
  removed="$(awk -v s="$start" -v e="$end" \
    'NR > s && NR < e && $0 !~ /^[[:space:]]*#/ && /rm -rf \/run\/dreamconnect/ { print NR; exit }' "$sh")"
  [ -n "$removed" ] || {
    fail "uninstall: nothing removes /run/dreamconnect, so the session registry survives an uninstall and keeps naming sessions that no longer exist"
    return 0; }

  case "$reg_dir" in
    /run/dreamconnect/*) ;;
    *) fail "registry coverage: the register script writes to [$reg_dir], which uninstall's 'rm -rf /run/dreamconnect' does not cover" ;;
  esac
}

# --- issue #53 slice 3: registration is a property of a session being up -----
#
# Slice 2 registered inline, from install.sh and dreamconnect-session. Review
# killed that design, and the reason is worth keeping in the tests: /run is
# tmpfs, so after a reboot backstage's entry is gone while the first
# `dreamconnect-session to <user>` writes one — and #51's known-wrong-fallback
# rule then REFUSES backstage's own ScreenConnect child. Backstage is
# black-holed until someone re-runs the installer. Registration therefore has
# to live and die with the session, not with an install.
#
# The shape: runtime/dreamconnect-register.sh (root, sourceable, functions
# above a main guard) does the work; systemd/dreamconnect-register@.service
# binds an entry's lifetime to a unit instance (ExecStart registers, ExecStop
# deregisters, RemainAfterExit=yes). install.sh enables the instance for its
# account; dreamconnect-session starts and stops it per on-demand session.
#
# SIGNATURES CHOSEN (say so if you would rather name them differently):
#   register_label      <account>                       -> the picker name
#   account_for_uid     <uid>                           -> login name (DC_PASSWD_DB honoured)
#   register_session    <uid> <registry_dir> [envfile] [timeout_seconds]
#   deregister_session  <uid> <registry_dir>
# envfile defaults to /run/user/<uid>/dreamconnect-display.env and is a
# parameter only so this suite can point it somewhere writable; the timeout is
# the bounded wait for a session that is still coming up.
#
# What this seam proves and does not: the register script's LOGIC is executed
# for real here (temp registry dirs, temp env files, DC_STATE_FILE/DC_PASSWD_DB
# fixtures). The call sites and units are static text assertions, as in slice 2
# — present and ordered, not "systemd did it".

REGISTER_SH="$HERE/runtime/dreamconnect-register.sh"
REGISTER_UNIT="$HERE/systemd/dreamconnect-register@.service"
# Sourced if it exists; every test below guards, so a missing script fails each
# of them by name instead of exploding once at startup.
[ -f "$REGISTER_SH" ] && . "$REGISTER_SH"

require_register_script() {  # label
  local fn
  [ -f "$REGISTER_SH" ] || { fail "$1: runtime/dreamconnect-register.sh does not exist"; return 1; }
  for fn in register_label account_for_uid register_session deregister_session; do
    declare -F "$fn" >/dev/null && continue
    fail "$1: $fn() is not defined by runtime/dreamconnect-register.sh"
    return 1
  done
  return 0
}

# Same rule install-lib.sh lives by, and for the same reason: the unit sources
# nothing, but this suite does, and a script that acts on being read cannot be
# unit-tested at all.
test_register_script_is_sourceable_side_effect_free() {
  local out rc
  [ -f "$REGISTER_SH" ] || { fail "runtime/dreamconnect-register.sh does not exist"; return 0; }
  out="$(bash -c 'set -euo pipefail; . "$1"' _ "$REGISTER_SH" 2>&1)"; rc=$?
  assert_eq "$rc" "0" "sourcing dreamconnect-register.sh exits 0 (functions above a main guard)"
  assert_eq "$out" "" "sourcing dreamconnect-register.sh is silent"
}

test_register_script_defines_its_functions() {
  require_register_script "register script functions" || return 0
}

# The registry writers live in install-lib.sh. The register script runs from
# $INSTALL_DIR on a real box, where only what install.sh copies exists — so it
# must source the library AND install.sh must ship it, or under `set -e` the
# unit fails at its first call and the session is never registered.
test_register_script_can_call_the_registry_writers_at_runtime() {
  local sh sourced
  [ -f "$REGISTER_SH" ] || { fail "runtime/dreamconnect-register.sh does not exist"; return 0; }
  sh="$HERE/install.sh"
  sourced="$(first_code_line "$REGISTER_SH" '(\.|source)[[:space:]]+[^[:space:]]*install-lib\.sh')"
  [ -n "$sourced" ] || [ -n "$(first_code_line "$REGISTER_SH" '^write_registry_entry\(\)')" ] || {
    fail "runtime: dreamconnect-register.sh neither sources install-lib.sh nor defines the writers itself"
    return 0; }
  if [ -n "$sourced" ]; then
    [ -n "$(first_code_line "$sh" 'install .*install-lib\.sh')" ] || \
      fail "runtime: dreamconnect-register.sh sources install-lib.sh but install.sh never installs it into \$INSTALL_DIR"
  fi
  [ -n "$(first_code_line "$sh" 'install .*dreamconnect-register\.sh')" ] || \
    fail "runtime: install.sh never installs dreamconnect-register.sh, so the unit's ExecStart has nothing to run"
}

# Backstage is the account recorded as HOST_ACCOUNT; it is the one entry the
# operator must be able to pick out by name, and the spec names it
# "[Backstage]". Every other account is called by its own name — an on-demand
# user session named "[Backstage]" would be worse than unlabelled.
test_register_label_marks_the_backstage_account_and_names_everyone_else() {
  local DC_STATE_FILE="$TMP/register-label/install.state"
  require_register_script "register_label" || return 0
  mkdir -p "$(dirname "$DC_STATE_FILE")"
  printf 'HOST_ACCOUNT=dreamconnect-host\nHOST_UID=992\nCREATED_ACCOUNT=1\n' > "$DC_STATE_FILE"

  assert_eq "$(register_label dreamconnect-host 2>/dev/null)" "[Backstage]" \
    "the recorded host account is the backstage session in the picker"
  assert_eq "$(register_label kogies 2>/dev/null)" "kogies" \
    "any other account is named after itself"
}

# The whole point of the entry is the display, and the display only exists once
# the session's Xwayland has published it. No display means no entry: an entry
# naming a display nothing serves is worse than no entry at all, because #51
# refuses that display rather than falling back (finding 3 of this review).
test_register_session_refuses_when_no_display_was_published() {
  local dir env rc
  local DC_STATE_FILE="$TMP/register-nodisplay/install.state"
  local DC_PASSWD_DB="$TMP/register-nodisplay/passwd"
  require_register_script "register_session refusals" || return 0
  mkdir -p "$TMP/register-nodisplay"
  printf 'HOST_ACCOUNT=dreamconnect-host\nHOST_UID=992\nCREATED_ACCOUNT=1\n' > "$DC_STATE_FILE"
  printf 'kogies:x:1000:1000::/home/kogies:/bin/bash\n' > "$DC_PASSWD_DB"
  dir="$TMP/register-nodisplay/sessions"

  # Never published: the bounded wait must give up, not hang the unit.
  register_session 1000 "$dir" "$TMP/register-nodisplay/absent.env" 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "register_session with no published display: expected non-zero exit, got 0"
  assert_file_absent "$dir/1000" "and no entry is written for a session with no display"

  # Published but empty — the unset-variable shape the publisher can leave.
  env="$TMP/register-nodisplay/blank.env"
  printf 'DISPLAY=\nXAUTHORITY=/run/user/1000/x\n' > "$env"
  register_session 1000 "$dir" "$env" 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "register_session with a blank DISPLAY: expected non-zero exit, got 0"
  assert_file_absent "$dir/1000" "and still nothing is written"
}

test_register_session_falls_back_to_the_user_managers_display() {
  local dir rc
  local DC_STATE_FILE="$TMP/register-fallback/install.state"
  local DC_PASSWD_DB="$TMP/register-fallback/passwd"
  require_register_script "register_session manager fallback" || return 0
  mkdir -p "$TMP/register-fallback"
  printf 'HOST_ACCOUNT=dreamconnect-host\nHOST_UID=992\nCREATED_ACCOUNT=1\n' > "$DC_STATE_FILE"
  printf 'kogies:x:1000:1000::/home/kogies:/bin/bash\n' > "$DC_PASSWD_DB"
  dir="$TMP/register-fallback/sessions"

  # Only backstage writes the envfile. A person who simply logged in has none,
  # and that is the whole population discovery exists to reach -- so the display
  # has to come from their user manager instead, or every discovered session is
  # refused and nothing is ever reachable.
  manager_display() { printf ':7\n'; }
  register_session 1000 "$dir" "$TMP/register-fallback/absent.env" 1 >/dev/null 2>&1; rc=$?
  unset -f manager_display
  [ "$rc" -eq 0 ] || fail "register_session with no envfile but a manager display: expected 0, got $rc"
  assert_file_present "$dir/1000" "an entry is written from the manager's display"
  grep -qx 'display=:7' "$dir/1000" \
    || fail "the entry should carry the manager's display, got: $(grep '^display=' "$dir/1000")"
}

# The state file is how the script knows which account is backstage. Without it
# every session would be labelled by name, including backstage — the picker
# entry operators are told to look for silently disappears.
test_register_session_refuses_when_the_install_state_names_no_account() {
  local dir env rc
  local DC_STATE_FILE="$TMP/register-nostate/install.state"
  local DC_PASSWD_DB="$TMP/register-nostate/passwd"
  require_register_script "register_session without state" || return 0
  mkdir -p "$TMP/register-nostate"
  printf 'kogies:x:1000:1000::/home/kogies:/bin/bash\n' > "$DC_PASSWD_DB"
  env="$TMP/register-nostate/display.env"
  printf 'DISPLAY=:3\nXAUTHORITY=/run/user/1000/x\n' > "$env"
  dir="$TMP/register-nostate/sessions"

  register_session 1000 "$dir" "$env" 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "register_session with no install state: expected non-zero exit, got 0"
  assert_file_absent "$dir/1000" "no entry is written when the state file is missing"

  printf 'HOST_ACCOUNT=\nHOST_UID=\nCREATED_ACCOUNT=0\n' > "$DC_STATE_FILE"
  register_session 1000 "$dir" "$env" 1 >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "register_session with a blank HOST_ACCOUNT: expected non-zero exit, got 0"
  assert_file_absent "$dir/1000" "nor when the state records no account"
}

# The entry has to satisfy the shipped reader, which is the authority here:
# agent/boot/dreamconnect/boot/Bridge.java — parseRegistryEntry requires
# uid/user/display/shm/socket, readRegistry ignores any filename that is not all
# digits and any file that is group- or other-writable, and usableShm requires
# the frame to be the entry uid's own.
test_register_session_writes_an_entry_the_reader_accepts() {
  local dir env body mode
  local DC_STATE_FILE="$TMP/register-ok/install.state"
  local DC_PASSWD_DB="$TMP/register-ok/passwd"
  require_register_script "register_session" || return 0
  mkdir -p "$TMP/register-ok"
  printf 'HOST_ACCOUNT=dreamconnect-host\nHOST_UID=992\nCREATED_ACCOUNT=1\n' > "$DC_STATE_FILE"
  printf 'dreamconnect-host:x:992:992::/home/dreamconnect-host:/bin/bash\n' > "$DC_PASSWD_DB"
  env="$TMP/register-ok/display.env"
  printf 'DISPLAY=:7\nXAUTHORITY=/run/user/992/dreamconnect.Xauthority\n' > "$env"
  dir="$TMP/register-ok/sessions"

  ( umask 000; register_session 992 "$dir" "$env" 1 >/dev/null 2>&1 )
  assert_file_exists "$dir/992" "the entry is written at <registry>/<uid>"
  [ -f "$dir/992" ] || return 0
  body="$(cat "$dir/992" 2>/dev/null || true)"
  assert_line "$body" "uid=992"                                  "entry carries the uid"
  assert_line "$body" "user=dreamconnect-host"                   "entry carries the account name"
  assert_line "$body" "display=:7"                               "entry carries the PUBLISHED display, read from the env file"
  assert_line "$body" "shm=/dev/shm/dreamconnect.frame.992"      "entry carries the uid-scoped frame the daemon writes"
  assert_line "$body" "socket=/run/user/992/dreamconnect.sock"   "entry carries the uid's control socket"
  assert_line "$body" "label=[Backstage]"                        "and the backstage account is labelled for the picker"
  mode="$(stat -c '%a' "$dir/992" 2>/dev/null)"
  assert_eq "$mode" "644" "entry mode is 0644 even under umask 000 — the reader ignores anything group/other-writable"
}

# ExecStop is what makes deregistration automatic; this is the function it runs.
test_deregister_session_removes_that_entry_only() {
  local dir env rc
  local DC_STATE_FILE="$TMP/register-dereg/install.state"
  local DC_PASSWD_DB="$TMP/register-dereg/passwd"
  require_register_script "deregister_session" || return 0
  mkdir -p "$TMP/register-dereg"
  printf 'HOST_ACCOUNT=dreamconnect-host\nHOST_UID=992\nCREATED_ACCOUNT=1\n' > "$DC_STATE_FILE"
  printf 'dreamconnect-host:x:992:992::/home/dreamconnect-host:/bin/bash\nkogies:x:1000:1000::/home/kogies:/bin/bash\n' > "$DC_PASSWD_DB"
  env="$TMP/register-dereg/display.env"
  printf 'DISPLAY=:7\n' > "$env"
  dir="$TMP/register-dereg/sessions"
  register_session 992 "$dir" "$env" 1 >/dev/null 2>&1
  register_session 1000 "$dir" "$env" 1 >/dev/null 2>&1

  deregister_session 992 "$dir" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "deregister_session succeeds"
  assert_file_absent "$dir/992" "the entry is gone with the session"
  assert_file_exists "$dir/1000" "the other session's entry is untouched"
  deregister_session 992 "$dir" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "and deregistering twice is not an error (ExecStop can run after a failed start)"
}

# --- unit files --------------------------------------------------------------

# FINDING 1, and the reason this slice exists at all: the daemon unit gained
# `EnvironmentFile=-/run/user/@UID@/dreamconnect-display.env`, but install.sh's
# sed for that unit substitutes @INSTALL_DIR@/@SESSION_UNIT@/@SHM_PATH@/
# @DAEMON_ARGS@ only. The literal @UID@ survived, the leading `-` silenced the
# missing file, ${DISPLAY} expanded to empty and the daemon still answered
# UNKNOWN. It is a systemd USER unit, so %t already IS /run/user/<uid>: no
# substitution needed, and nothing left to forget.
test_daemon_unit_environment_file_needs_no_substitution() {
  local unit line
  unit="$HERE/systemd/dreamconnect-daemon.service"
  assert_file_exists "$unit" "daemon unit template is present"
  [ -f "$unit" ] || return 0

  line="$(awk '/^EnvironmentFile=/ { print; exit }' "$unit")"
  [ -n "$line" ] || { fail "daemon unit no longer reads the published display env at all"; return 0; }
  assert_not_contains "$line" "@" \
    "the EnvironmentFile path must carry no @PLACEHOLDER@ — one that install.sh does not substitute survives into the rendered unit and silently disables the display"
  assert_contains "$line" "%t" \
    "a user unit's %t already means /run/user/<uid>, which is what removes the need to substitute anything"
}

# Real directives rather than substrings: a token in a comment, or under the
# wrong section, is not a property of the unit.
unit_directive() {  # section key file -> one value per line
  awk -v want="$1" -v key="$2" '
    /^[[:space:]]*[#;]/ { next }
    /^\[/ { sec = $0; sub(/^\[/, "", sec); sub(/\].*$/, "", sec); next }
    sec == want {
      i = index($0, "=")
      if (i > 0) {
        k = substr($0, 1, i - 1); gsub(/[[:space:]]/, "", k)
        if (k == key) print substr($0, i + 1)
      }
    }' "$3"
}

# REVISED, round 4 — the previous version asserted the substring
# `user@%i.service` anywhere in the file, which `After=` alone satisfies. It
# therefore named a property the unit did not have: review demonstrated that
# with only `After=`+`Wants=`, stopping the session's user manager leaves this
# unit ACTIVE, so the entry outlives the session. A later session that reclaims
# that display number then makes two entries for one display, the agent refuses,
# and that session is black permanently — the exact failure this unit design
# exists to prevent.
#
# What is asserted now is the stop-propagating dependency itself. BindsTo=,
# PartOf= or StopPropagatedFrom= naming user@%i.service all satisfy it, because
# all three propagate a stop; After=/Wants= alone no longer do. My
# recommendation is BindsTo=, because it also covers the manager FAILING rather
# than being cleanly stopped — but the choice is the implementer's and this does
# not force it. After= is still required alongside: a stop-propagating
# dependency with no ordering can race the thing it depends on.
test_register_unit_ties_the_entry_to_the_unit_lifetime() {
  local u="$REGISTER_UNIT" bind
  [ -f "$u" ] || { fail "systemd/dreamconnect-register@.service does not exist"; return 0; }

  assert_contains "$(unit_directive Service ExecStart "$u")" "register" \
    "the unit registers on start"
  assert_contains "$(unit_directive Service ExecStop "$u")" "deregister" \
    "the unit deregisters on stop — this is what removes the stale-entry case"
  assert_eq "$(unit_directive Service RemainAfterExit "$u" | tr -d ' ')" "yes" \
    "without RemainAfterExit=yes the oneshot goes inactive at once and ExecStop never runs"
  assert_contains "$(unit_directive Service ExecStart "$u")" "%i" \
    "the instance name is the uid being registered"
  assert_contains "$(unit_directive Unit After "$u")" "user@%i.service" \
    "ordered after the user manager: /run/user/<uid> and its display env do not exist before it"
  [ -n "$(unit_directive Install WantedBy "$u")" ] || \
    fail "the unit has no [Install] WantedBy, so it cannot be enabled and a reboot never re-registers"

  bind="$(unit_directive Unit BindsTo "$u")$(unit_directive Unit PartOf "$u")$(unit_directive Unit StopPropagatedFrom "$u")"
  case "$bind" in
    *user@%i.service*) ;;
    *) fail "the unit has no stop-propagating dependency on user@%i.service (BindsTo=/PartOf=/StopPropagatedFrom=) — with only After=/Wants= the session's manager can stop while this unit stays active, and the entry outlives the session it promises" ;;
  esac
}

# STRENGTHENED (the seraph found the old shape vacuous): the previous test
# grepped each placeholder against the WHOLE of install.sh, so @UID@ in the
# daemon unit was satisfied by any unrelated line mentioning @UID@ elsewhere —
# which is exactly how finding 1 shipped. Now every placeholder is checked
# against the sed statement that renders ITS OWN file.
render_statement_for() {  # install_sh template_basename -> the joined sed statement, or empty
  local sh="$1" base="$2" line stmt
  for line in $(awk '/sed -e/ && $0 !~ /^[[:space:]]*#/ { print NR }' "$sh"); do
    stmt="$(logical_statement_at "$sh" "$line")"
    case "$stmt" in *"$base"*) printf '%s\n' "$stmt"; return 0 ;; esac
  done
  return 0
}

test_every_unit_template_placeholder_is_substituted_by_its_own_render() {
  local sh unit base ph stmt checked=0
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }
  for unit in "$HERE"/systemd/*.service; do
    [ -f "$unit" ] || continue
    base="$(basename "$unit")"
    # Only templates that actually carry placeholders need a render.
    local phs; phs="$(grep -o '@[A-Z_]\{1,\}@' "$unit" 2>/dev/null | sort -u)"
    [ -n "$phs" ] || continue
    stmt="$(render_statement_for "$sh" "$base")"
    [ -n "$stmt" ] || { fail "$base carries placeholders ($(echo $phs)) but install.sh has no sed that renders it"; continue; }
    for ph in $phs; do
      checked=$((checked + 1))
      case "$stmt" in
        *"$ph"*) ;;
        *) fail "$base uses $ph but the sed that renders $base never substitutes it — the literal survives into the unit systemd reads" ;;
      esac
    done
  done
  [ "$checked" -gt 0 ] || fail "placeholder guard checked nothing — the loop found no unit template with placeholders, so this test proves nothing"
}

# --- call sites, revised for the new lifecycle -------------------------------

# Is a line inside an `if [ "$BACKSTAGE" -eq 1 ]` THEN-branch? Walks the file
# keeping a stack of if/else/fi, so a line in the else-branch answers no.
guarded_by_backstage() {  # file line -> yes|no
  awk -v target="$2" '
    NR == target { for (i = 1; i <= depth; i++) if (bs[i] && !el[i]) { print "yes"; exit } print "no"; exit }
    /^[[:space:]]*if[[:space:]]+\[[[:space:]]*"\$BACKSTAGE"[[:space:]]+-eq[[:space:]]+1/ { depth++; bs[depth] = 1; el[depth] = 0; next }
    /^[[:space:]]*if[[:space:]]/ { depth++; bs[depth] = 0; el[depth] = 0; next }
    /^[[:space:]]*else([[:space:]]|$)/ { if (depth > 0) el[depth] = 1; next }
    /^[[:space:]]*fi([[:space:]]|$)/ { if (depth > 0) depth--; next }
  ' "$1"
}

# install.sh no longer writes entries itself: it enables the instance so the
# session re-registers on every boot.
test_install_sh_enables_registration_for_its_account() {
  local sh enabled started stmt
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }

  enabled="$(first_code_line "$sh" 'systemctl[[:space:]]+enable[[:space:]]+.*dreamconnect-register@')"
  [ -n "$enabled" ] || {
    fail "call site: install.sh never enables dreamconnect-register@<uid>.service — after a reboot the session it installed is unregistered and #51 refuses it"
    return 0; }
  stmt="$(logical_statement_at "$sh" "$enabled")"
  assert_contains "$stmt" 'USER_UID' "the instance is the uid of the account being installed"

  started="$(first_code_line "$sh" 'systemctl[[:space:]]+(start|restart)[[:space:]]+.*dreamconnect-register@')"
  [ -n "$started" ] || \
    fail "call site: install.sh must also START the register instance, or this install stays unregistered until the next boot"
}

# NEW, round 4. Nothing publishes /run/user/<uid>/dreamconnect-display.env
# outside backstage (only dreamconnect-backstage.service and
# dreamconnect-session write it), so on a classic install the register unit
# burns its whole bounded wait and then fails — on every boot, forever.
# A classic install is single-session: with no registry the agent falls back to
# the static shm=/socket= args, which is exactly today's behaviour and is
# correct. So registration there buys nothing and costs a permanently failed
# unit.
test_install_sh_enables_registration_only_for_backstage() {
  local sh line
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }

  local range ustart uend
  range="$(func_range "$sh" uninstall)"
  ustart="${range% *}"; uend="${range#* }"
  [ -n "$range" ] || { ustart=0; uend=0; }
  [ -n "$(first_code_line "$sh" 'systemctl[[:space:]]+(enable|start|restart)[[:space:]]+.*dreamconnect-register@')" ] || {
    fail "call site: install.sh never enables registration at all, so this test would check nothing"
    return 0; }
  # Only the install path: uninstall() legitimately disables the instance for
  # any account, backstage or not.
  for line in $(awk -v us="$ustart" -v ue="$uend" \
      '/systemctl[[:space:]]+(enable|start|restart)[[:space:]]+.*dreamconnect-register@/ \
       && $0 !~ /^[[:space:]]*#/ && !(NR > us && NR < ue) { print NR }' "$sh"); do
    assert_eq "$(guarded_by_backstage "$sh" "$line")" "yes" \
      "install.sh:$line touches dreamconnect-register@ outside the backstage branch — a classic install has nothing publishing a display env, so the unit waits out its timeout and then fails on every boot"
  done
}

# And a classic install must still finish with no registry whatsoever: that
# fallback is what makes skipping registration there safe rather than a
# regression, so a failed registration must never be fatal either.
test_classic_install_needs_no_registry_at_all() {
  local sh started stmt
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }
  [ -z "$(first_code_line "$sh" 'write_registry_entry')" ] || \
    fail "call site: install.sh writes a registry entry directly; a classic install must need no registry at all"

  started="$(first_code_line "$sh" 'systemctl[[:space:]]+(start|restart)[[:space:]]+.*dreamconnect-register@')"
  if [ -n "$started" ]; then
    stmt="$(logical_statement_at "$sh" "$started")"
    case "$stmt" in
      *"||"*) ;;
      *) fail "call site: install.sh:$started lets a failed registration abort the install — an unregistered session still works from the static args, so this must be non-fatal: [$stmt]" ;;
    esac
  fi
}

# FINDING 3: a classic install registered ${DISPLAY:-} — the installing shell's
# display, which over `ssh -X` is localhost:10.0. That names a display nothing
# serves, and #51 refuses rather than falls back, so it is strictly worse than
# not registering. Both the inline write and the guess have to be gone.
test_install_sh_no_longer_registers_inline_or_guesses_the_display() {
  local sh
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }

  [ -z "$(first_code_line "$sh" 'write_registry_entry')" ] || \
    fail "call site: install.sh still writes a registry entry inline — that entry dies with the next reboot while the unit-managed one does not"
  [ -z "$(first_code_line "$sh" 'DISPLAY:-')" ] || \
    fail "call site: install.sh still falls back to \${DISPLAY:-}, the installing shell's own display — over ssh -X that registers localhost:10.0 and the session then refuses"
}

test_install_sh_starts_registration_after_its_session_is_running() {
  local sh started reg
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }

  started="$(first_code_line "$sh" 'systemctl --user restart')"
  [ -n "$started" ] || { fail "call site: install.sh no longer starts the user units"; return 0; }
  reg="$(first_code_line "$sh" 'systemctl[[:space:]]+(enable|start|restart)[[:space:]]+.*dreamconnect-register@')"
  [ -n "$reg" ] || { fail "call site: install.sh never starts dreamconnect-register@"; return 0; }
  [ "$started" -lt "$reg" ] || \
    fail "call site: registration (line $reg) must come AFTER the session units are started (line $started) — before that there is no published display to register"
}

# The CLI keeps its ordering — publish, start the daemon, then register — but
# now by starting the unit instance rather than writing the file itself.
test_session_cli_starts_registration_after_the_daemon() {
  local cli published daemon reg
  cli="$HERE/runtime/dreamconnect-session"
  [ -f "$cli" ] || { fail "$SESSION_CLI_HINT is present"; return 0; }

  published="$(code_line_in_func "$cli" bring_up_user 'dreamconnect-backstage-env\.sh')"
  daemon="$(code_line_in_func "$cli" bring_up_user 'systemd-run --user --unit=dreamconnect-session-daemon')"
  reg="$(code_line_in_func "$cli" bring_up_user 'dreamconnect-register@')"
  [ -n "$published" ] && [ -n "$daemon" ] || { fail "call site: bring_up_user no longer publishes the display or starts the daemon"; return 0; }
  [ -n "$reg" ] || {
    fail "call site: bring_up_user never starts dreamconnect-register@<uid> — the session it brings up is invisible to the agent"
    return 0; }

  [ "$published" -lt "$reg" ] || \
    fail "call site: registration (line $reg) must come AFTER the display is published (line $published)"
  [ "$daemon" -lt "$reg" ] || \
    fail "call site: registration (line $reg) must come AFTER the daemon is started (line $daemon) — an entry is a promise that the session can be attached to"
}

test_session_cli_stops_registration_on_teardown() {
  local cli stopped stmt
  cli="$HERE/runtime/dreamconnect-session"
  [ -f "$cli" ] || { fail "$SESSION_CLI_HINT is present"; return 0; }

  stopped="$(code_line_in_func "$cli" tear_down_user 'dreamconnect-register@')"
  [ -n "$stopped" ] || {
    fail "call site: tear_down_user never stops dreamconnect-register@<uid> — the entry outlives the daemon and that display refuses until it is removed by hand"
    return 0; }
  stmt="$(logical_statement_at "$cli" "$stopped")"
  assert_contains "$stmt" "stop" "teardown STOPS the instance, which is what runs its ExecStop deregistration"
  assert_contains "$stmt" 'uid' "and it names the uid whose session is going away"
}

# The CLI must stop writing the registry itself, and must stop hard-failing
# commands that never touch it: the top-level `declare -F … || die` guard
# aborted `status` and `backstage` too.
test_session_cli_no_longer_writes_the_registry_itself() {
  local cli guard range start end
  cli="$HERE/runtime/dreamconnect-session"
  [ -f "$cli" ] || { fail "$SESSION_CLI_HINT is present"; return 0; }

  [ -z "$(first_code_line "$cli" 'write_registry_entry')" ] || \
    fail "call site: $SESSION_CLI_HINT still writes registry entries inline instead of starting the unit that owns them"
  [ -z "$(first_code_line "$cli" 'remove_registry_entry')" ] || \
    fail "call site: $SESSION_CLI_HINT still removes registry entries inline"

  guard="$(first_code_line "$cli" 'declare -F .*(die|exit)')"
  if [ -n "$guard" ]; then
    range="$(func_range "$cli" bring_up_user)"
    start="${range% *}"; end="${range#* }"
    { [ -n "$range" ] && [ "$guard" -gt "$start" ] && [ "$guard" -lt "$end" ]; } || \
      fail "call site: the 'declare -F … || die' guard at line $guard runs at top level, so it kills 'status' and 'backstage' — commands that never register anything"
  fi
}

unquote() { local v="$1"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s\n' "$v"; }

# A literal is its own value; "$var" is resolved to the single assignment of
# that name inside the function. Empty means "the text cannot say" — either the
# name is never assigned there, or it is assigned more than once, and a call
# site whose value cannot be read is reported rather than assumed.
resolved_value_in_func() {  # file func token -> value, or empty
  local file="$1" func="$2" tok name range start end count
  tok="$(unquote "$3")"
  case "$tok" in
    '$'*) name="${tok#\$}"; name="${name#\{}"; name="${name%\}}" ;;
    *) printf '%s\n' "$tok"; return 0 ;;
  esac
  range="$(func_range "$file" "$func")"
  [ -n "$range" ] || return 0
  start="${range% *}"; end="${range#* }"
  count="$(awk -v s="$start" -v e="$end" -v n="$name" \
    'NR > s && NR < e && $0 !~ /^[[:space:]]*#/ \
       && $0 ~ "(^|[[:space:];])(local[[:space:]]+)?" n "=" { c++ } END { print c + 0 }' "$file")"
  [ "$count" = "1" ] || return 0
  awk -v s="$start" -v e="$end" -v n="$name" \
    'NR > s && NR < e && $0 !~ /^[[:space:]]*#/ {
       if (match($0, "(^|[[:space:];])(local[[:space:]]+)?" n "=")) {
         v = substr($0, RSTART + RLENGTH)
         sub(/^"/, "", v); sub(/".*$/, "", v)
         print v; exit } }' "$file"
}

# Cross-file: the daemon writes one frame and the register script claims
# another, and nothing errors — the reader just drops the entry (usableShm
# requires the frame to be the entry uid's own). Slice 2 checked this within one
# file; the paths now live in two, so this is where drift would hide.
test_register_script_and_the_daemon_agree_on_the_uid_scoped_paths() {
  local cli daemon dstmt dshm dval body
  cli="$HERE/runtime/dreamconnect-session"
  [ -f "$cli" ] && [ -f "$REGISTER_SH" ] || {
    fail "path agreement: need both $SESSION_CLI_HINT and runtime/dreamconnect-register.sh"
    return 0; }

  daemon="$(code_line_in_func "$cli" bring_up_user 'systemd-run --user --unit=dreamconnect-session-daemon')"
  [ -n "$daemon" ] || { fail "path agreement: bring_up_user no longer starts the daemon"; return 0; }
  dstmt="$(logical_statement_at "$cli" "$daemon")"
  dshm="$(printf '%s\n' "$dstmt" | sed -n 's/.*--shm[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p')"
  dval="$(resolved_value_in_func "$cli" bring_up_user "$dshm")"
  [ -n "$dval" ] || { fail "path agreement: cannot tell what the daemon's --shm [$dshm] holds in bring_up_user"; return 0; }
  assert_eq "$dval" '/dev/shm/dreamconnect.frame.$uid' "the daemon writes this uid's own frame"

  body="$(grep -v '^[[:space:]]*#' "$REGISTER_SH" 2>/dev/null || true)"
  assert_contains "$body" '/dev/shm/dreamconnect.frame.' \
    "and the register script claims a uid-scoped frame, not the legacy unscoped one"
  assert_contains "$body" '/run/user/' \
    "and the uid's own runtime socket"
  assert_not_contains "$body" '"/dev/shm/dreamconnect.frame"' \
    "the unscoped frame path must not be what gets registered — the reader drops an entry whose frame is not the account's"
}

# --- issue #53 round 4: what a green suite was hiding -------------------------

# Uninstall left /etc/systemd/system/dreamconnect-register@.service and its
# multi-user.target.wants symlink behind. $INSTALL_DIR is deliberately kept, so
# the ExecStart still resolves and the enabled instance keeps failing on every
# boot of a box that has been uninstalled. The same gap swallows an account
# change: the old dreamconnect-register@<olduid> stays enabled.
test_uninstall_disables_and_removes_the_register_unit() {
  local sh range start end disabled removed
  sh="$HERE/install.sh"
  [ -f "$sh" ] || { fail "install.sh is present"; return 0; }
  range="$(func_range "$sh" uninstall)"
  [ -n "$range" ] || { fail "install.sh has no uninstall() to scope this to"; return 0; }
  start="${range% *}"; end="${range#* }"

  disabled="$(awk -v s="$start" -v e="$end" \
    'NR > s && NR < e && $0 !~ /^[[:space:]]*#/ && /systemctl.*disable.*dreamconnect-register@/ { print NR; exit }' "$sh")"
  [ -n "$disabled" ] || \
    fail "uninstall: nothing disables dreamconnect-register@<uid> — the instance stays enabled and fails on every boot after the software is gone"

  removed="$(awk -v s="$start" -v e="$end" \
    'NR > s && NR < e && $0 !~ /^[[:space:]]*#/ && /dreamconnect-register@\.service/ && /rm|unlink/ { print NR; exit }' "$sh")"
  [ -n "$removed" ] || \
    fail "uninstall: the unit file /etc/systemd/system/dreamconnect-register@.service is never removed"
}

# register_label parsed HOST_ACCOUNT with its own sed (FIRST match) while the
# rest of the codebase uses read_install_state (LAST match). A duplicated key
# made them disagree, and the disagreement is not cosmetic: a human's session
# gets labelled [Backstage], so the operator is told an attended session is the
# unattended one. Asserted as AGREEMENT with the shipped reader, so any
# implementation that agrees passes.
test_register_label_agrees_with_the_state_reader_on_a_duplicated_key() {
  local DC_STATE_FILE="$TMP/label-dup/install.state"
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT
  require_register_script "register_label duplicate key" || return 0
  mkdir -p "$TMP/label-dup"
  printf 'HOST_ACCOUNT=someone-else\nHOST_UID=1000\nHOST_ACCOUNT=dreamconnect-host\nCREATED_ACCOUNT=1\n' \
    > "$DC_STATE_FILE"

  read_install_state
  assert_eq "$HOST_ACCOUNT" "dreamconnect-host" \
    "precondition: the shipped state reader takes the LAST HOST_ACCOUNT"
  assert_eq "$(register_label dreamconnect-host 2>/dev/null)" "[Backstage]" \
    "register_label agrees with it: the account the reader reports is the backstage one"
  assert_eq "$(register_label someone-else 2>/dev/null)" "someone-else" \
    "and an account the reader does NOT report is not [Backstage] — labelling an attended session as the unattended one is what this prevents"
}

# A CRLF state file (edited on Windows, or written through a tool that adds
# them) leaves HOST_ACCOUNT="dreamconnect-host\r". A parser that does not strip
# it silently stops recognising the backstage account, and backstage loses its
# name in the picker with nothing in any log.
test_register_label_survives_a_crlf_state_file() {
  local DC_STATE_FILE="$TMP/label-crlf/install.state"
  require_register_script "register_label CRLF" || return 0
  mkdir -p "$TMP/label-crlf"
  printf 'HOST_ACCOUNT=dreamconnect-host\r\nHOST_UID=992\r\nCREATED_ACCOUNT=1\r\n' > "$DC_STATE_FILE"

  assert_eq "$(register_label dreamconnect-host 2>/dev/null)" "[Backstage]" \
    "a CRLF state file still names the backstage account"
  assert_eq "$(register_label kogies 2>/dev/null)" "kogies" \
    "and still names everyone else after themselves"
}

for CURRENT in \
  test_daemon_unit_and_agent_dropin_agree_on_the_shm_path \
  test_install_sh_restarts_the_units_so_a_rerun_applies_changes \
  test_install_sh_removes_the_shm_frame_on_uninstall \
  test_session_cli_renders_a_valid_dropin \
  test_uninstall_removes_the_session_cli \
  test_install_sh_scopes_the_shm_path_by_uid \
  test_install_sh_defaults_backstage_fps_and_leaves_classic_stock \
  test_the_autologin_helpers_are_gone \
  test_the_installer_never_edits_the_display_manager_config \
  test_no_autologin_environment_variable_is_honoured \
  test_a_host_account_implies_backstage \
  test_detect_user_skips_the_greeter_and_picks_the_human \
  test_detect_user_refuses_a_box_with_only_a_greeter \
  test_detect_user_still_finds_an_ordinary_session \
  test_detect_user_ignores_inactive_and_non_graphical_sessions \
  test_library_defines_the_host_account_sudo_helpers \
  test_grant_host_account_sudo_writes_a_nopasswd_rule \
  test_grant_host_account_sudo_file_is_not_group_or_world_writable \
  test_grant_host_account_sudo_installs_nothing_when_visudo_rejects_it \
  test_grant_host_account_sudo_refuses_a_name_that_escapes_sudoers_d \
  test_grant_host_account_sudo_warns_when_sudoers_d_is_not_included \
  test_revoke_host_account_sudo_removes_the_rule_and_is_idempotent \
  test_revoke_host_account_sudo_refuses_a_traversing_name \
  test_install_sh_revokes_host_account_sudo_on_uninstall \
  test_publisher_writes_the_display_env_file \
  test_publisher_publishes_a_stable_xauthority_path \
  test_publisher_keeps_the_published_xauthority_owner_only \
  test_publisher_fails_when_no_display_ever_appears \
  test_every_tool_in_the_probe_chain_is_shadowed \
  test_xprobe_wrapper_searches_more_than_usr_bin \
  test_xprobe_wrapper_passes_a_healthy_display_through \
  test_xprobe_wrapper_preserves_a_real_nonzero_exit \
  test_xprobe_wrapper_gives_up_on_a_hanging_display_whatever_its_number \
  test_xprobe_wrapper_short_circuits_a_display_already_known_dead \
  test_xprobe_wrapper_does_not_blacklist_other_displays \
  test_library_defines_the_backstage_helpers \
  test_backstage_resolution_defaults_to_1280x720 \
  test_backstage_resolution_passes_through_a_valid_value \
  test_backstage_resolution_accepts_an_uppercase_separator \
  test_backstage_resolution_normalises_leading_zeros \
  test_backstage_resolution_refuses_malformed_values \
  test_backstage_resolution_refuses_zero_dimensions \
  test_backstage_resolution_refuses_dimensions_past_the_16384_ceiling \
  test_backstage_resolution_accepts_the_documented_maximum \
  test_backstage_ceiling_matches_the_daemon_max_dimension \
  test_backstage_supported_follows_gnome_shell_presence \
  test_daemon_unit_template_placeholders_are_all_substituted_by_install_sh \
  test_backstage_unit_template_placeholders_are_all_substituted_by_install_sh \
  test_backstage_unit_does_not_depend_on_a_graphical_session \
  test_agent_dropin_tolerates_a_missing_display_env_file \
  test_sourcing_is_side_effect_free \
  test_library_defines_the_installer_functions \
  test_run_executes_the_command_by_default \
  test_run_suppresses_execution_when_dry \
  test_resolve_host_identity_defaults_to_fallback_user \
  test_resolve_host_identity_prefers_the_named_account \
  test_resolve_host_identity_socket_is_run_user_uid_dreamconnect_sock \
  test_resolve_host_identity_fails_when_the_account_is_absent \
  test_library_defines_the_state_and_removal_functions \
  test_write_install_state_creates_parent_dirs_and_all_keys \
  test_write_install_state_overwrites_rather_than_appends \
  test_write_install_state_never_downgrades_created_account_for_the_same_account \
  test_write_install_state_survives_a_write_killed_part_way_through \
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
  test_configure_no_idle_lock_configures_the_backstage_desktop \
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
  test_uninstall_host_account_treats_a_hand_deleted_account_as_already_removed \
  test_uninstall_host_account_still_refuses_an_account_that_is_really_there \
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
  test_library_defines_host_account_installable \
  test_host_account_installable_refuses_a_different_account_than_recorded \
  test_host_account_installable_warns_and_reuses_the_recorded_account_when_unset \
  test_host_account_installable_accepts_the_recorded_account_silently \
  test_host_account_installable_accepts_any_account_on_a_fresh_install \
  test_host_account_installable_refuses_a_malformed_recorded_account \
  test_host_account_installable_refuses_a_reserved_recorded_account \
  test_a_bare_rerun_keeps_the_account_created_by_the_installer_removable \
  test_valid_account_name_is_locale_independent \
  test_host_account_installable_refuses_a_reserved_requested_account \
  test_host_account_installable_refuses_root_as_the_recorded_account \
  test_configure_no_idle_lock_refuses_root_as_a_dconf_name \
  test_remove_no_idle_lock_refuses_root_as_a_dconf_name \
  test_ensure_host_account_refuses_reserved_account_names \
  test_remove_accountsservice_marker_refuses_reserved_account_names \
  test_host_account_removable_refuses_root_however_the_passwd_source_spells_it \
  test_library_defines_valid_home_dir \
  test_valid_home_dir_accepts_real_home_directories \
  test_valid_home_dir_rejects_empty_and_relative_paths \
  test_valid_home_dir_rejects_the_shared_roots \
  test_valid_home_dir_rejects_noncanonical_spellings_of_the_shared_roots \
  test_valid_home_dir_rejects_dotdot_components \
  test_remove_no_idle_lock_skips_the_home_half_for_an_unusable_home \
  test_configure_no_idle_lock_refuses_an_unusable_home \
  test_resolve_host_identity_refuses_an_empty_home_field \
  test_resolve_host_identity_refuses_every_home_valid_home_dir_rejects \
  test_resolve_host_identity_still_resolves_a_usable_home \
  test_resolve_host_identity_never_hands_the_caller_a_shifted_home \
  test_host_account_removable_refuses_a_reserved_home_however_it_is_spelled \
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
  test_install_sh_aborts_the_install_when_the_user_bus_never_comes_up \
  test_library_defines_the_registry_writers \
  test_render_registry_entry_emits_every_key_the_reader_requires \
  test_render_registry_entry_omits_label_when_absent \
  test_render_registry_entry_refuses_a_missing_required_field \
  test_render_registry_entry_refuses_a_non_numeric_uid \
  test_render_registry_entry_refuses_a_value_containing_a_newline \
  test_write_registry_entry_writes_the_entry_at_the_uid_filename \
  test_write_registry_entry_replaces_an_existing_entry_atomically \
  test_write_registry_entry_leaves_nothing_behind_when_it_refuses \
  test_remove_registry_entry_is_idempotent_and_leaves_others_alone \
  test_remove_registry_entry_refuses_a_uid_that_is_not_a_number \
  test_session_display_reads_the_published_display \
  test_session_display_fails_when_there_is_no_usable_display \
  test_session_cli_starts_the_daemon_with_display_and_label \
  test_install_sh_starts_registration_after_its_session_is_running \
  test_uninstall_removes_the_registry_with_the_run_directory \
  test_register_script_is_sourceable_side_effect_free \
  test_register_script_defines_its_functions \
  test_register_script_can_call_the_registry_writers_at_runtime \
  test_register_label_marks_the_backstage_account_and_names_everyone_else \
  test_register_session_refuses_when_no_display_was_published \
  test_register_session_falls_back_to_the_user_managers_display \
  test_register_session_refuses_when_the_install_state_names_no_account \
  test_register_session_writes_an_entry_the_reader_accepts \
  test_deregister_session_removes_that_entry_only \
  test_daemon_unit_environment_file_needs_no_substitution \
  test_register_unit_ties_the_entry_to_the_unit_lifetime \
  test_every_unit_template_placeholder_is_substituted_by_its_own_render \
  test_install_sh_enables_registration_for_its_account \
  test_install_sh_no_longer_registers_inline_or_guesses_the_display \
  test_session_cli_starts_registration_after_the_daemon \
  test_session_cli_stops_registration_on_teardown \
  test_session_cli_no_longer_writes_the_registry_itself \
  test_register_script_and_the_daemon_agree_on_the_uid_scoped_paths \
  test_install_sh_enables_registration_only_for_backstage \
  test_classic_install_needs_no_registry_at_all \
  test_uninstall_disables_and_removes_the_register_unit \
  test_register_label_agrees_with_the_state_reader_on_a_duplicated_key \
  test_register_label_survives_a_crlf_state_file
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

[ "${SKIPPED:-0}" -eq 0 ] \
  || echo "$SKIPPED skipped check(s) — that coverage was NOT exercised on this box"

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
echo "installer shell tests passed"
