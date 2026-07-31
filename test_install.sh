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
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT AUTOLOGIN_SET
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
    write_install_state "$acct" 986 "$created" 0

    read_install_state
    assert_eq "$CREATED_ACCOUNT" "$expected" "$label: CREATED_ACCOUNT"
    assert_eq "$HOST_ACCOUNT" "$acct"        "$label: HOST_ACCOUNT is this run's account"
    assert_eq "$HOST_UID" "986"              "$label: HOST_UID is this run's uid"
    assert_eq "$AUTOLOGIN_SET" "0"           "$label: AUTOLOGIN_SET is this run's value, not sticky"
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
  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT AUTOLOGIN_SET
  read_install_state
  assert_eq "$HOST_ACCOUNT"    "dreamconnect-host" "interrupted write: HOST_ACCOUNT still recorded"
  assert_eq "$CREATED_ACCOUNT" "1"                 "interrupted write: CREATED_ACCOUNT still recorded"
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

# --- issue #26, slice 1: push_dconf_environment -------------------------------
#
# WHY THIS EXISTS. configure_no_idle_lock's environment.d drop-in above is only
# ever read by `systemd --user` AT MANAGER START, and install.sh starts that
# manager earlier and unconditionally (`loginctl enable-linger`, line 327) than
# it writes the drop-in (configure_no_idle_lock, line 354). So the file is
# correct on disk and the value never reaches the live manager — issue #26's
# reported symptom, "DCONF_PROFILE was absent from both the gnome-shell process
# env and `systemctl --user show-environment`". Not a race: that order holds on
# every install.
#
# CONTRACT UNDER TEST (factory/CHECKPOINT.md, issue #26 seams + slice 1 row):
#
#   push_dconf_environment <name> <uid>
#
#   * runs `systemctl --user set-environment DCONF_PROFILE=<name>` against the
#     already-running user manager,
#   * as the target account, through the same sudo/env invocation form install.sh
#     already builds for running something in another user's session
#     (install.sh:239-240 —
#        sudo -u "$USER_NAME" env "XDG_RUNTIME_DIR=/run/user/$USER_UID" \
#             "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus"),
#   * behind the same reserved/valid-name guard as configure_no_idle_lock.
#
# Every literal asserted below is read off that contract, not off any
# implementation: there is none yet.
#
# HOW IT IS TESTED. The same PATH-shim technique slice 4 uses for useradd and
# slice 5 uses for dconf/chown — the suite never runs as root and must never
# reach the real systemd. `sudo` is shimmed to record its own argv and then run
# the tail, so the real /usr/bin/env in the middle sets the two variables and
# execs the SHIMMED systemctl, which records the argv it was actually handed and
# the two variables that actually reached its environment. That distinction is
# the point: seeing "DCONF_PROFILE=..." somewhere on sudo's command line does not
# prove it arrives at systemctl as one argument, and seeing XDG_RUNTIME_DIR as a
# word in sudo's argv does not prove it is in systemctl's environment.
make_push_env_shims() {  # dir systemctl_rc -> echoes the call log path
  local d="$1" rc="$2"
  mkdir -p "$d"

  # A deliberately thin sudo: record everything, remember who -u named, then run
  # whatever command followed. Anything else it is handed is recorded and
  # skipped, so a differently-flagged invocation still shows up in the log
  # rather than silently doing nothing.
  cat > "$d/sudo" <<EOF
#!/usr/bin/env bash
{ echo "== sudo"; printf '[%s]\n' "\$@"; } >> "$d/calls.log"
sudo_user=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -u) sudo_user="\$2"; shift 2 ;;
    -*) shift ;;
     *) break ;;
  esac
done
echo "sudo-user=\$sudo_user" >> "$d/calls.log"
[ \$# -gt 0 ] || exit 0
exec "\$@"
EOF

  # systemctl records its argv AND the two session variables as they reached its
  # own environment — empty if they never did.
  cat > "$d/systemctl" <<EOF
#!/usr/bin/env bash
{ echo "== systemctl"; printf '[%s]\n' "\$@"
  echo "env-XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-}"
  echo "env-DBUS_SESSION_BUS_ADDRESS=\${DBUS_SESSION_BUS_ADDRESS:-}"
  echo "env-whoami=\$(id -un)"; } >> "$d/calls.log"
exit $rc
EOF

  chmod +x "$d/sudo" "$d/systemctl"
  : > "$d/calls.log"
  echo "$d/calls.log"
}

PUSH_OUT=""
PUSH_RC=0

run_push_env() {  # shim_dir name uid
  PUSH_OUT="$(DC_DRY_RUN= PATH="$1:$PATH" push_dconf_environment "$2" "$3" 2>&1)"
  PUSH_RC=$?
  return 0
}

# A missing function exits 127 having run nothing, which would make the guard
# test's "systemctl was never invoked" assertion pass vacuously.
require_push_dconf_environment() {  # label
  declare -F push_dconf_environment >/dev/null && return 0
  fail "$1: push_dconf_environment() is not defined"
  return 1
}

# The whole point of the slice: the value has to reach the RUNNING manager, and
# it reaches it as `systemctl --user set-environment DCONF_PROFILE=<name>` run in
# the account's own session. Asserted at systemctl's own argv and environment, so
# a rewrite that pushes the wrong variable name, the uid instead of the name, the
# system manager instead of the user one, or loses the bus address on the way
# fails here.
#
# TWO DIFFERENT (name, uid) PAIRS, deliberately (breaker lap 1, CHECKPOINT row 5).
# With one literal pair this test could not tell `set-environment
# "DCONF_PROFILE=$1"` from `set-environment DCONF_PROFILE=dreamconnect-host`, nor
# /run/user/$2 from /run/user/1234 — both mutants matched the single fixture and
# stayed green. The second pair shares no substring with the first, so every
# assertion below is now a function of the arguments rather than of one fixture.
# "dc_host2" is chosen to also exercise the underscore and the trailing digit
# valid_account_name allows, and 4242 a uid with no digit in common with 1234.
test_push_dconf_environment_invokes_set_environment_with_the_profile_name() {
  local shims log calls name uid i pair
  require_push_dconf_environment "set-environment invocation" || return 0

  i=0
  for pair in "dreamconnect-host 1234" "dc_host2 4242"; do
    read -r name uid <<<"$pair"
    shims="$TMP/shims-push-env-$i"; i=$((i + 1))
    log="$(make_push_env_shims "$shims" 0)"

    run_push_env "$shims" "$name" "$uid"
    assert_not_contains "$PUSH_OUT" "command not found" \
      "push_dconf_environment ($name/$uid): it ran the shims, not something missing from PATH"
    assert_eq "$PUSH_RC" "0" \
      "push_dconf_environment ($name/$uid) exits 0 when set-environment succeeds"

    calls="$(cat "$log" 2>/dev/null || true)"
    assert_line "$calls" "== systemctl" "systemctl is invoked at all ($name/$uid)"
    assert_line "$calls" "[--user]" \
      "the target is the USER manager (--user), the one holding the session's environment ($name/$uid)"
    assert_not_contains "$calls" "[--system]" \
      "the system manager is never touched ($name/$uid)"
    assert_line "$calls" "[set-environment]" \
      "the verb is set-environment — pushing into the already-running manager ($name/$uid)"
    assert_line "$calls" "[DCONF_PROFILE=$name]" \
      "DCONF_PROFILE=<name> reaches systemctl as ONE argument, built from ARGUMENT 1 ($name), not a baked-in account name"

    assert_line "$calls" "sudo-user=$name" \
      "it runs as the display-host account named by argument 1 ($name), not as the caller"
    assert_line "$calls" "env-XDG_RUNTIME_DIR=/run/user/$uid" \
      "XDG_RUNTIME_DIR=/run/user/<uid> is in systemctl's environment, built from ARGUMENT 2 ($uid) — install.sh:239-240 form"
    assert_line "$calls" "env-DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus is in systemctl's environment, built from ARGUMENT 2 ($uid)"
  done
}

# THE BLAST-RADIUS GUARD, same one configure_no_idle_lock carries and for the
# same reason: "user" is dconf's own default profile and "local" its conventional
# system db, and "root" is the account every rail here exists to protect. Pushing
# DCONF_PROFILE=user into a live manager would point that session at dconf's
# default profile. Refuse, and run nothing at all.
test_push_dconf_environment_refuses_reserved_dconf_names() {
  local shims log name
  require_push_dconf_environment "reserved-name guard" || return 0

  for name in root user local; do
    shims="$TMP/shims-push-reserved-$name"; log="$(make_push_env_shims "$shims" 0)"
    run_push_env "$shims" "$name" 1234
    [ "$PUSH_RC" -ne 127 ] || { fail "reserved name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$PUSH_OUT" "command not found" \
      "reserved name '$name': the refusal came from the guard, not the shell"
    [ "$PUSH_RC" -ne 0 ] || fail "reserved name '$name': expected non-zero exit, got $PUSH_RC"
    [ -n "$PUSH_OUT" ] || fail "reserved name '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "reserved name '$name': neither sudo nor systemctl was run at all"
  done
}

# The OTHER HALF of that guard, which the reserved-name test above cannot see
# (breaker lap 1, CHECKPOINT row 5: deleting push_dconf_environment's
# `valid_account_name` call left the whole suite green). The reserved `case`
# compares the STRING, so "./user" walks straight past it — and the name is
# pasted both into the pushed VALUE and into the account `sudo -u` switches to,
# which is the same asymmetry test_configure_no_idle_lock_refuses_malformed_
# account_names closes on the write side. Same five names as that test, same
# assertion style: refuse, non-zero, say why, invoke nothing at all.
#
# "1000" matters twice over here: `sudo -u 1000` resolves by UID, not by name, so
# an unvalidated numeric name would push DCONF_PROFILE=1000 into whichever
# account owns that uid — typically the human desktop user.
test_push_dconf_environment_refuses_malformed_account_names() {
  local shims log name i
  require_push_dconf_environment "malformed-name guard" || return 0

  i=0
  for name in ./user .. . 1000 "dc host"; do
    shims="$TMP/shims-push-malformed-$i"; i=$((i + 1))
    log="$(make_push_env_shims "$shims" 0)"
    run_push_env "$shims" "$name" 1234
    [ "$PUSH_RC" -ne 127 ] || { fail "malformed name '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$PUSH_OUT" "command not found" \
      "malformed name '$name': the refusal came from the guard, not the shell"
    [ "$PUSH_RC" -ne 0 ] || fail "malformed name '$name': expected non-zero exit, got $PUSH_RC"
    [ -n "$PUSH_OUT" ] || fail "malformed name '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "malformed name '$name': neither sudo nor systemctl was run at all"
  done
}

# --- issue #26, breaker lap 1: the UNPUSH, unpush_dconf_environment ------------
#
# THE DEFECT (factory/CHECKPOINT.md row 4). push_dconf_environment above has no
# undo. `install.sh --uninstall` deletes /etc/dconf/profile/<name> via
# remove_no_idle_lock (install.sh:127) but never clears DCONF_PROFILE from the
# account's live `systemd --user` manager — and for a REUSED account
# (DREAMCONNECT_HOST_ACCOUNT naming a pre-existing human, CREATED_ACCOUNT=0) that
# manager is never stopped either: install.sh gates `loginctl terminate-user` /
# account deletion on CREATED_ACCOUNT=1 (install.sh:139-153), and disable-linger
# alone does not kill a manager with a live session. So the manager keeps
# DCONF_PROFILE=<name> pointing at a profile file that has just been deleted.
#
# WHERE THE EXPECTED BEHAVIOUR COMES FROM — two independent sources, neither of
# them any implementation (there is none):
#
#   1. dconf's own behaviour, observed on this box (breaker, verbatim):
#        $ DCONF_PROFILE=dreamconnect-host gsettings set org.gnome.desktop.session idle-delay 42
#        dconf-WARNING: unable to open named profile (dreamconnect-host): using
#        the null configuration.
#        The key is not writable
#      A DCONF_PROFILE naming an absent profile does not fall back to the default
#      profile — it falls to the NULL configuration, and every gsettings read and
#      write in that session fails until the manager is restarted. Uninstalling
#      this tool must not leave a human's account in that state.
#
#   2. systemd's own interface for the inverse of set-environment, systemctl(1):
#        "unset-environment VARIABLE... — Unset one or more systemd manager
#         environment variables. If only a variable name is specified, it will be
#         removed REGARDLESS OF ITS VALUE. If a variable and a value are
#         specified, the variable is only removed if it has the specified value."
#      The bare-name form is the one required here, and the distinction is
#      load-bearing rather than stylistic: remove_no_idle_lock deletes
#      /etc/dconf/profile/<name> unconditionally, so the clear has to be
#      unconditional too. `unset-environment DCONF_PROFILE=<name>` would leave the
#      variable in place whenever the live manager holds a DCONF_PROFILE this
#      run's push did not write — a re-install under a different account name, or
#      a value the account's own drop-in set — which is exactly the dangling
#      state the null-configuration failure above comes from.
#
# CONTRACT UNDER TEST:
#
#   unpush_dconf_environment <name> <uid>
#
#   * runs `systemctl --user unset-environment DCONF_PROFILE` against the
#     already-running user manager — the bare variable name, one argument;
#   * as the target account, through the same sudo/env invocation form
#     push_dconf_environment uses (install.sh:239-240);
#   * behind the same reserved/valid-name guard as push_dconf_environment,
#     refusing before anything at all is invoked.
#
# WHY A SEPARATE FUNCTION rather than a third `uid` parameter on
# remove_no_idle_lock (both are wireable — install.sh's uninstall path has
# $target_uid in scope at line 74): remove_no_idle_lock's contract says "THE
# DRY-RUN BOUNDARY IS EXACTLY ONE COMMAND. Only `dconf update` goes through
# run()" (this file, lines 987-994), and its ten existing tests drive it with two
# arguments through make_dconf_shim, which shims `dconf` and NOT sudo/systemctl.
# Folding a sudo call into it would send every one of those tests at the real
# sudo with an empty uid — /run/user//bus — breaking the suite's one safety rail
# ("never run as root ... must not be able to reach the real system", lines
# 11-13). The pairing is also the one this diff already established:
# configure_no_idle_lock/remove_no_idle_lock own the FILES,
# push_dconf_environment/unpush_dconf_environment own the LIVE MANAGER.
#
# Shimmed with make_push_env_shims, exactly as the push tests are: the suite has
# no root, no second account and no user manager to talk to.
UNPUSH_OUT=""
UNPUSH_RC=0

run_unpush_env() {  # shim_dir name uid
  UNPUSH_OUT="$(DC_DRY_RUN= PATH="$1:$PATH" unpush_dconf_environment "$2" "$3" 2>&1)"
  UNPUSH_RC=$?
  return 0
}

# A missing function exits 127 having run nothing, which would make the guard
# test's "systemctl was never invoked" assertion pass vacuously.
require_unpush_dconf_environment() {  # label
  declare -F unpush_dconf_environment >/dev/null && return 0
  fail "$1: unpush_dconf_environment() is not defined — --uninstall deletes /etc/dconf/profile/<name> and leaves DCONF_PROFILE=<name> set in the account's live user manager, which puts dconf into the null configuration for that account until it logs out"
  return 1
}

# Two (name, uid) pairs for the same reason the push invocation test carries
# them: one literal pair cannot distinguish "$1"/"$2" from a baked-in fixture.
test_unpush_dconf_environment_unsets_the_profile_from_the_running_manager() {
  local shims log calls name uid i pair
  require_unpush_dconf_environment "unset-environment invocation" || return 0

  i=0
  for pair in "dreamconnect-host 1234" "dc_host2 4242"; do
    read -r name uid <<<"$pair"
    shims="$TMP/shims-unpush-env-$i"; i=$((i + 1))
    log="$(make_push_env_shims "$shims" 0)"

    run_unpush_env "$shims" "$name" "$uid"
    assert_not_contains "$UNPUSH_OUT" "command not found" \
      "unpush_dconf_environment ($name/$uid): it ran the shims, not something missing from PATH"
    assert_eq "$UNPUSH_RC" "0" \
      "unpush_dconf_environment ($name/$uid) exits 0 when unset-environment succeeds"

    calls="$(cat "$log" 2>/dev/null || true)"
    assert_line "$calls" "== systemctl" "systemctl is invoked at all ($name/$uid)"
    assert_line "$calls" "[--user]" \
      "the target is the USER manager (--user), the one still holding DCONF_PROFILE ($name/$uid)"
    assert_not_contains "$calls" "[--system]" \
      "the system manager is never touched ($name/$uid)"
    assert_line "$calls" "[unset-environment]" \
      "the verb is unset-environment — the inverse of the push, against the same running manager ($name/$uid)"
    assert_not_contains "$calls" "[set-environment]" \
      "unpush must not re-push: set-environment is the verb this function undoes ($name/$uid)"
    assert_line "$calls" "[DCONF_PROFILE]" \
      "the BARE variable name reaches systemctl as one argument — systemctl(1): a name alone is removed regardless of its value ($name/$uid)"
    assert_not_contains "$calls" "[DCONF_PROFILE=" \
      "never the VALUE-QUALIFIED form: 'unset-environment DCONF_PROFILE=<name>' only removes the variable if the manager happens to hold exactly that value, and remove_no_idle_lock deletes the profile file unconditionally ($name/$uid)"

    assert_line "$calls" "sudo-user=$name" \
      "it runs against the account named by argument 1 ($name), not the caller's own manager"
    assert_line "$calls" "env-XDG_RUNTIME_DIR=/run/user/$uid" \
      "XDG_RUNTIME_DIR=/run/user/<uid> is in systemctl's environment, built from ARGUMENT 2 ($uid)"
    assert_line "$calls" "env-DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus is in systemctl's environment, built from ARGUMENT 2 ($uid)"
  done
}

# The same blast-radius guard push_dconf_environment carries, and sharper for the
# same reason remove_no_idle_lock's is sharper than configure_no_idle_lock's: on
# the removal side <name> comes off install.state, a FILE, so a tampered or
# truncated record is what reaches this function. Both halves — the reserved
# `case` and valid_account_name — and nothing invoked at all on a refusal.
# `sudo -u root systemctl --user unset-environment ...` against root's manager,
# or `sudo -u 1000 ...` against whoever owns uid 1000, is precisely the blast
# radius every other rail in this file exists to prevent.
test_unpush_dconf_environment_refuses_reserved_and_malformed_names() {
  local shims log name i
  require_unpush_dconf_environment "unpush name guard" || return 0

  i=0
  for name in root user local ./user .. . 1000 "dc host"; do
    shims="$TMP/shims-unpush-guard-$i"; i=$((i + 1))
    log="$(make_push_env_shims "$shims" 0)"
    run_unpush_env "$shims" "$name" 1234
    [ "$UNPUSH_RC" -ne 127 ] || { fail "unpush guard '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$UNPUSH_OUT" "command not found" \
      "unpush guard '$name': the refusal came from the guard, not the shell"
    [ "$UNPUSH_RC" -ne 0 ] || fail "unpush guard '$name': expected non-zero exit, got $UNPUSH_RC"
    [ -n "$UNPUSH_OUT" ] || fail "unpush guard '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
      "unpush guard '$name': neither sudo nor systemctl was run at all"
  done
}

# --- reviewer finding 2 (non-blocking): the dry-run boundary for the live pair --
#
# THE CONTRACT, quoted, not invented. DC_DRY_RUN=1 means "nothing on this machine
# changed" — this file states it for the write side already: "DC_DRY_RUN=1 must
# mean 'nothing on this machine changed', and a bare `> "$dir/$name"` redirect
# would silently punch through the dry run" (contract D, lines 650-656). run() is
# the single mechanism that makes it mean that ("Run a command, or announce it
# when DC_DRY_RUN=1. Lets the destructive steps be exercised by the tests without
# touching the real system." — install-lib.sh:11-15), and every other
# state-mutating call in the library goes through it: `run useradd`, `run userdel`,
# `run loginctl`, `run install -D`, `run dconf update`.
#
# push_dconf_environment/unpush_dconf_environment are the two that do not
# (reviewer aff9b0d603bacaf5f, CHECKPOINT row 7), which is why this test exists.
#
# THE WHOLE INVOCATION IS THE BOUNDARY HERE, unlike its sibling
# test_configure_no_idle_lock_gates_only_dconf_update_behind_run (lines 1292-1318)
# where only `dconf update` is gated: that function's four writes land in
# fixture-overridable paths (DC_DCONF_DIR, <home>) that are always safe in a test,
# and this pair has no fixture equivalent — `sudo -u <name> ... systemctl --user
# set-environment` reaches a real account's real running manager, exactly like
# slice 4's useradd/userdel, where every invocation is gated.
#
# WHAT IS ASSERTED, and where each expected value comes from:
#   * exit 0 — run()'s own dry-mode shape, `echo "DRY: $*"` as its last statement,
#     pinned by test_run_suppresses_execution_when_dry (lines 88-96). A dry run is
#     not a failure, and install.sh's push call site warns on non-zero.
#   * an EMPTY shim call log — the only place "the binary did not run" is
#     observable, and the same assertion the guard tests above use.
#   * the announcement names the command and what it would have done — contract D
#     again: "The emitted command must name the destination path, so a dry run is
#     auditable" (line 655). The model test asserts "DRY: dconf update", not a
#     bare "DRY:", for the same reason. The verbs and the DCONF_PROFILE forms are
#     read off the slice 1 / slice 4 contracts above (lines 1386-1397, 1611-1620),
#     not off any implementation.
#
# One (name, uid) pair only, deliberately: argument derivation is already pinned
# by the two-pair non-dry tests above, and re-pinning it here would duplicate that
# coverage rather than add any.
test_push_and_unpush_dconf_environment_gate_the_invocation_behind_run() {
  local shims log out rc
  require_push_dconf_environment "push dry-run boundary" || return 0
  require_unpush_dconf_environment "unpush dry-run boundary" || return 0

  shims="$TMP/shims-push-dry"; log="$(make_push_env_shims "$shims" 0)"
  out="$(DC_DRY_RUN=1 PATH="$shims:$PATH" \
         push_dconf_environment dreamconnect-host 1234 2>&1)"; rc=$?
  assert_not_contains "$out" "command not found" \
    "dry push: the shims are on PATH, so an empty call log means gated — not missing"
  assert_eq "$rc" "0" "dry push: exits 0, as run() does when it announces (out: $out)"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "DC_DRY_RUN=1: push_dconf_environment executes neither sudo nor systemctl"
  assert_contains "$out" "DRY: sudo" \
    "dry push: the WHOLE invocation is announced, from sudo onwards"
  assert_contains "$out" "set-environment DCONF_PROFILE=dreamconnect-host" \
    "dry push: the announcement names what would have been pushed (auditable)"

  shims="$TMP/shims-unpush-dry"; log="$(make_push_env_shims "$shims" 0)"
  out="$(DC_DRY_RUN=1 PATH="$shims:$PATH" \
         unpush_dconf_environment dreamconnect-host 1234 2>&1)"; rc=$?
  assert_not_contains "$out" "command not found" \
    "dry unpush: the shims are on PATH, so an empty call log means gated — not missing"
  assert_eq "$rc" "0" "dry unpush: exits 0, as run() does when it announces (out: $out)"
  assert_eq "$(cat "$log" 2>/dev/null || true)" "" \
    "DC_DRY_RUN=1: unpush_dconf_environment executes neither sudo nor systemctl"
  assert_contains "$out" "DRY: sudo" \
    "dry unpush: the WHOLE invocation is announced, from sudo onwards"
  assert_contains "$out" "unset-environment DCONF_PROFILE" \
    "dry unpush: the announcement names the variable that would have been cleared (auditable)"
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

  write_install_state "$resolved" 987 "$ACCOUNT_WAS_CREATED" 1

  local HOST_ACCOUNT HOST_UID CREATED_ACCOUNT AUTOLOGIN_SET
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

# A real /etc/gdm/custom.conf: the stock Fedora/Debian shape, with the [daemon]
# section enable_autologin edits and a neighbouring section it must not touch.
plant_gdm_conf() {  # path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
# GDM configuration storage

[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
# Uncomment the line below to turn on debugging
#Enable=true
EOF
}

# The same file on a box where the ADMIN had already configured GDM autologin
# for one of their own accounts, by hand, before this installer ever ran: the
# two keys under [daemon] in the spelling GNOME's own "log in automatically"
# documentation gives, sitting beside the commented hint lines Debian's gdm3
# ships in that same section.
#
# A separate fixture rather than a change to plant_gdm_conf, because the
# enable_autologin tests above assert on the ABSENCE of AutomaticLogin keys
# after a refusal and that premise must not move. Nothing in the suite planted
# a pre-existing pair before this, which is why the whole class of behaviour
# below — a config we overwrite on install and owe back on uninstall — was
# invisible to it.
plant_gdm_conf_with_autologin() {  # path account
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
# GDM configuration storage

[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false
AutomaticLoginEnable=true
AutomaticLogin=$2

# Enabling timed login
#  TimedLoginEnable = true
#  TimedLogin = user1
#  TimedLoginDelay = 10

[security]

[xdmcp]

[chooser]

[debug]
# Uncomment the line below to turn on debugging
#Enable=true
EOF
}

# The same file as Debian's gdm3 actually ships it: the autologin keys present
# but COMMENTED OUT, as documentation of how to switch them on. CHECKPOINT row 5
# quotes the line this fixture turns on verbatim — "Debian gdm3's
# `#  AutomaticLogin = user1`".
#
# It matters because BOTH of this library's regexes over that section match `#?`
# on install: enable_autologin's strip eats these lines out of the live conf
# (install-lib.sh:96), so after an install they exist only in the backup, and
# disable_autologin's collect takes them into the restore set
# (install-lib.sh:133) — the CHECKPOINT row 2 resolution, "restore whatever was
# in the backup's [daemon] section verbatim (comment or live), no special-casing".
#
# A third fixture rather than an edit to either above, for the reason the second
# one gives: the tests there assert on the ABSENCE of the substring
# "AutomaticLogin" after a strip, and a commented hint line carries it.
plant_gdm_conf_with_commented_autologin_hints() {  # path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
# GDM configuration storage

[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false

# Enabling automatic login
#  AutomaticLoginEnable = true
#  AutomaticLogin = user1

# Enabling timed login
#  TimedLoginEnable = true
#  TimedLogin = user1
#  TimedLoginDelay = 10

[security]

[xdmcp]

[chooser]

[debug]
# Uncomment the line below to turn on debugging
#Enable=true
EOF
}

# The lines of one INI section, so a test can say WHERE a key landed. GDM only
# honours AutomaticLogin* under [daemon]; the same keys written into [security]
# or appended past the end of the last section are dead text, so "the key is
# back in the file" is not the same claim as "autologin is configured again".
gdm_daemon_section() {  # path
  awk '/^\[.*\]$/ { in_daemon = ($0 == "[daemon]"); next } in_daemon { print }' "$1"
}

# HOW MANY lines of [daemon] carry a string. "Restored" and "restored twice" are
# both assert_contains-true and assert_not_contains-false; only a count tells
# them apart, which is the whole of CHECKPOINT row 5. `|| true` because grep -c
# exits 1 on a count of zero, having already printed the 0 this wants.
gdm_daemon_line_count() {  # path string
  gdm_daemon_section "$1" | grep -Fc -- "$2" || true
}

# An edit the admin made AFTER the install, and therefore one that exists only
# in the live conf and not in enable_autologin's backup: one real GDM key inside
# [daemon] (the section being rewritten) and one outside it. This is what
# separates the surgical revert the CHECKPOINT specifies from a wholesale
# `mv -f "$conf.dreamconnect.bak" "$conf"`, which would restore the autologin
# and silently drop both of these.
edit_gdm_conf_after_install() {  # path scratch
  awk '{ print }
       /^\[daemon\]$/   { print "InitialSetupEnable=false" }
       /^\[security\]$/ { print "DisallowTCP=true" }' "$1" > "$2" && cat "$2" > "$1"
}

RUN_AUTOLOGIN_OUT=""
RUN_AUTOLOGIN_RC=0
run_enable_autologin() {  # conf name
  RUN_AUTOLOGIN_OUT="$(enable_autologin "$1" "$2" 2>&1)"
  RUN_AUTOLOGIN_RC=$?
  return 0
}

RUN_DISABLE_OUT=""
RUN_DISABLE_RC=0
run_disable_autologin() {  # conf
  RUN_DISABLE_OUT="$(disable_autologin "$1" 2>&1)"
  RUN_DISABLE_RC=$?
  return 0
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
test_enable_autologin_refuses_only_root_and_names_that_corrupt_the_conf() {
  local conf name tag i=0 before
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — refusal not demonstrated"; return 0; }

  for name in root "" $'dc\nAutomaticLoginEnable=true' $'dc\rx'; do
    tag="gdm-refuse-$i"; i=$((i + 1))
    conf="$TMP/$tag/custom.conf"
    plant_gdm_conf "$conf"
    before="$(cat "$conf")"

    run_enable_autologin "$conf" "$name"
    [ "$RUN_AUTOLOGIN_RC" -ne 127 ] || { fail "autologin '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$RUN_AUTOLOGIN_OUT" "command not found" \
      "autologin '$name': the refusal came from the guard, not the shell"
    [ "$RUN_AUTOLOGIN_RC" -ne 0 ] || \
      fail "autologin '$name': expected non-zero exit, got $RUN_AUTOLOGIN_RC"
    [ -n "$RUN_AUTOLOGIN_OUT" ] || \
      fail "autologin '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$conf")" "$before" \
      "autologin '$name': the GDM config is left byte-for-byte alone"
    assert_not_contains "$(cat "$conf")" "AutomaticLogin=" \
      "autologin '$name': no autologin key is written for a refused name"
    assert_file_absent "$conf.dreamconnect.bak" \
      "autologin '$name': a refusal backs nothing up either"
  done
}

# The other half of call site 5, so the guard above cannot be satisfied by
# refusing everything: an ordinary account still gets autologin configured, and
# the backup enable_autologin's own comment promises. This documents today's
# behaviour (it passes before the guard exists) and pins it afterwards.
test_enable_autologin_still_configures_an_ordinary_account() {
  local conf
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined"; return 0; }
  conf="$TMP/gdm-ordinary/custom.conf"
  plant_gdm_conf "$conf"

  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "a well-formed account is configured (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_contains "$(cat "$conf")" "AutomaticLogin=dreamconnect-host" \
    "the autologin key names the display-host account"
  assert_contains "$(cat "$conf")" "AutomaticLoginEnable=true" \
    "autologin is enabled"
  assert_file_exists "$conf.dreamconnect.bak" "the original GDM config is backed up"
}

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
test_enable_autologin_accepts_an_existing_account_that_is_not_new_account_shaped() {
  local conf name tag i=0 long
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined"; return 0; }

  long="averylongdomainaccountname.for.a.joined.box"   # 43 chars, has dots
  for name in john.doe user local "$long" _svc-desk; do
    tag="gdm-classic-$i"; i=$((i + 1))
    conf="$TMP/$tag/custom.conf"
    plant_gdm_conf "$conf"

    run_enable_autologin "$conf" "$name"
    [ "$RUN_AUTOLOGIN_RC" -ne 127 ] || { fail "autologin '$name': exit 127"; continue; }
    assert_eq "$RUN_AUTOLOGIN_RC" "0" \
      "autologin '$name': a pre-existing desktop account is configured, not refused (stderr: $RUN_AUTOLOGIN_OUT)"
    assert_contains "$(cat "$conf")" "AutomaticLogin=$name" \
      "autologin '$name': the account name is written verbatim into [daemon]"
    assert_contains "$(cat "$conf")" "AutomaticLoginEnable=true" \
      "autologin '$name': autologin is enabled"
    assert_file_exists "$conf.dreamconnect.bak" \
      "autologin '$name': the original GDM config is backed up"
  done
}

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
test_enable_autologin_refuses_a_name_whose_backslash_awk_would_expand() {
  local conf name tag i=0 before
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined"; return 0; }

  for name in 'DOMAIN\nick' 'dc\tx' 'dc\\x'; do
    tag="gdm-backslash-$i"; i=$((i + 1))
    conf="$TMP/$tag/custom.conf"
    plant_gdm_conf "$conf"
    before="$(cat "$conf")"

    # The premise: these are ORDINARY shell strings. If one of them carried a
    # real newline/CR the existing rail would already catch it and this test
    # would prove nothing about the backslash.
    case "$name" in
      *$'\n'*|*$'\r'*) fail "autologin '$name': fixture carries a real newline/CR — tests the wrong rail"; continue ;;
    esac

    run_enable_autologin "$conf" "$name"
    [ "$RUN_AUTOLOGIN_RC" -ne 127 ] || { fail "autologin '$name': exit 127, not a refusal"; continue; }
    assert_not_contains "$RUN_AUTOLOGIN_OUT" "command not found" \
      "autologin '$name': the refusal came from the guard, not the shell"
    [ "$RUN_AUTOLOGIN_RC" -ne 0 ] || \
      fail "autologin '$name': expected non-zero exit, got $RUN_AUTOLOGIN_RC"
    [ -n "$RUN_AUTOLOGIN_OUT" ] || \
      fail "autologin '$name': expected a stderr line explaining the refusal"
    assert_eq "$(cat "$conf")" "$before" \
      "autologin '$name': the GDM config is left byte-for-byte alone"
    assert_not_contains "$(cat "$conf")" "AutomaticLogin=" \
      "autologin '$name': no autologin key is written for a refused name"
    assert_file_absent "$conf.dreamconnect.bak" \
      "autologin '$name': a refusal backs nothing up either"
  done
}

# --- issue #22: disable_autologin's own backup lifecycle ----------------------
#
# WHAT IS WRONG TODAY. enable_autologin copies the GDM config to
# <conf>.dreamconnect.bak before it edits (install-lib.sh:87). disable_autologin
# reverts by stripping the two keys back out and never touches that backup, so
# the file survives every uninstall — issue #22, verbatim: "The backup is
# therefore never cleaned up; it's orphaned on disk after every uninstall."
# disable_autologin had no tests at all before this pair, which is how a return
# value that means nothing (it is `rm -f "$tmp"`'s — the awk scratch file's
# cleanup, install-lib.sh:110) went unnoticed alongside it.
#
# WHAT THE FIX IS — factory/CHECKPOINT.md, issue #22 seams, verbatim:
#
#   "install-lib.sh :: disable_autologin(conf) — keeps its surgical strip
#    (custom.conf is a shared, admin-editable file ... wholesale restore risks
#    eating unrelated admin edits made since install), but now deletes its own
#    .bak once the strip has actually succeeded, and returns a meaningful exit
#    code (previously always rm -f's, i.e. meaningless) so a failed strip
#    preserves the backup instead of discarding it silently."
#
# Three behaviours, all three read off that sentence and issue #22's own
# question ("is a stale backup ever useful to leave behind for manual recovery,
# or should it always be cleaned up once disable_autologin has run
# successfully?" — the owner's answer, recorded above: cleaned up, but only on
# success). None of them is derived from what the current body happens to do:
# today it deletes nothing and exits 0 either way, which is what makes the pair
# below red. The suffix and the once-only backup are enable_autologin's own
# convention, asserted the same way as this file's other .dreamconnect.bak
# pairs (test_ensure_host_account_backs_up_a_preexisting_accountsservice_file).
test_disable_autologin_removes_the_backup_on_success() {
  local conf bak
  declare -F disable_autologin >/dev/null || {
    fail "disable_autologin(): not defined"; return 0; }
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — cannot build the .bak fixture"; return 0; }

  conf="$TMP/gdm-undo-ok/custom.conf"; bak="$conf.dreamconnect.bak"
  plant_gdm_conf "$conf"

  # The fixture is the REAL backup — whatever enable_autologin writes, wherever
  # it writes it, is what an uninstall finds on disk. Hand-crafting one would
  # only prove disable_autologin cleans up a file this test invented.
  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "precondition: autologin was configured (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_file_exists "$bak" "precondition: enable_autologin left a backup to clean up"
  [ -e "$bak" ] || return 0

  run_disable_autologin "$conf"

  assert_not_contains "$(cat "$conf")" "AutomaticLogin" \
    "the autologin keys are stripped out of the live config"
  assert_contains "$(cat "$conf")" "[daemon]" \
    "the surgical strip leaves the rest of the file alone (it is not a wholesale restore)"
  assert_file_absent "$bak" \
    "a successful strip removes the backup it owns — after --uninstall nothing of ours is left beside custom.conf (issue #22)"
  assert_eq "$RUN_DISABLE_RC" "0" \
    "a successful strip exits 0 (stderr: $RUN_DISABLE_OUT)"
}

# The other half, and the reason the deletion above may not be unconditional: a
# strip that did NOT happen must keep the backup, because that backup is then
# the only copy of the pre-install config the operator has, and must say so to
# its caller.
#
# THE INJECTION is the write-back, not a contrived path: disable_autologin runs
# `awk ... "$conf" > "$tmp" && cat "$tmp" > "$conf"` (install-lib.sh:106-109),
# so an unwritable $conf lets the awk pass succeed and fails the write-back —
# the same shape as test_configure_no_idle_lock_survives_a_failing_chown, which
# makes the real mechanism fail rather than replacing it. It also pins the
# narrower half of "meaningful exit code": a fix that returns the AWK's status
# would be green on the success test above and still exit 0 here, having left
# the keys in place. This suite never runs as root (line 18), so the mode bits
# genuinely deny the write; the precondition below proves they did.
#
# EXIT CODE: non-zero, value unasserted — the CHECKPOINT requires only that a
# caller can tell the two apart, and this pair is what makes that true (0 on the
# success test, non-zero here). install.sh's uninstall() is that caller, and
# test_install_sh_branches_on_the_disable_autologin_result pins its branch.
test_disable_autologin_preserves_the_backup_if_the_strip_fails() {
  local conf bak
  declare -F disable_autologin >/dev/null || {
    fail "disable_autologin(): not defined"; return 0; }
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — cannot build the .bak fixture"; return 0; }

  conf="$TMP/gdm-undo-fail/custom.conf"; bak="$conf.dreamconnect.bak"
  plant_gdm_conf "$conf"
  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "precondition: autologin was configured (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_file_exists "$bak" "precondition: there is a backup to preserve"
  [ -e "$bak" ] || return 0

  chmod a-w "$conf"
  run_disable_autologin "$conf"
  chmod u+w "$conf"   # restored immediately, so nothing later inherits the mode

  assert_contains "$(cat "$conf")" "AutomaticLogin=dreamconnect-host" \
    "precondition: the write-back really was refused — the keys are still in the live config, so the revert did NOT happen"

  [ "$RUN_DISABLE_RC" -ne 0 ] || \
    fail "a failed strip must exit non-zero, got $RUN_DISABLE_RC — the caller cannot tell a reverted config from an untouched one, and install.sh:135 reports success either way (stderr: $RUN_DISABLE_OUT)"
  assert_file_exists "$bak" \
    "a failed strip keeps the backup — with the autologin keys still live in $conf, that .dreamconnect.bak is the operator's only copy of the pre-install config"
}

# WHAT IS WRONG TODAY (breaker lap 1, defect 1 — CHECKPOINT row 2). The pair
# above only ever ran against a conf with NO autologin configured, so "strip our
# keys out" and "put back what was there" looked like the same thing. They are
# not. enable_autologin's strip regex is `#?[[:space:]]*AutomaticLogin(Enable)?`
# (install-lib.sh:96) — it drops ANY autologin key in [daemon] before writing
# ours, including an admin's live one. disable_autologin then strips ours back
# out to nothing, so the admin's own autologin never comes back; until slice 1
# it was at least still readable in the orphaned .bak, and now that a successful
# revert deletes the .bak, the last copy goes with it. Silent, on every
# uninstall, on exactly the boxes where somebody had already set this up.
#
# WHAT THE FIX IS — factory/CHECKPOINT.md row 2, verbatim (owner-confirmed):
#
#   "disable_autologin now extracts whatever AutomaticLogin*/AutomaticLoginEnable
#    content (or absence) was in the backup's [daemon] section and writes that
#    back in place of ours — surgically, not a wholesale file restore, so
#    unrelated admin edits elsewhere in the file still survive — before
#    deleting .bak."
#
# Every assertion below is one clause of that sentence, checked against the
# fixture's OWN planted bytes (`AutomaticLogin=alice`, above) rather than
# anything computed from the library:
#   - "writes that back"        -> alice's pair is live in the conf again,
#   - "in place of ours"        -> dreamconnect-host is gone,
#   - "surgically ... survive"  -> both post-install admin edits are still there,
#   - "before deleting .bak"    -> and the backup is cleaned up, as in slice 1.
# The section check is GDM's format, not ours: these keys mean nothing outside
# [daemon].
#
# NOT asserted, deliberately: the commented `#  AutomaticLogin = user1` hint
# lines the fixture also plants. enable_autologin's `#?` eats those too, and
# whether "content ... in the backup's [daemon] section" is meant to cover a
# distro's documentation comments is not something the CHECKPOINT settles — see
# the gap noted in the run record. Their loss is cosmetic; alice's is not.
test_disable_autologin_restores_an_autologin_configured_before_the_install() {
  local conf bak daemon
  declare -F disable_autologin >/dev/null || {
    fail "disable_autologin(): not defined"; return 0; }
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — cannot build the .bak fixture"; return 0; }

  conf="$TMP/gdm-undo-preexisting/custom.conf"; bak="$conf.dreamconnect.bak"
  plant_gdm_conf_with_autologin "$conf" alice

  # The .bak under test is the REAL one, written by the real enable_autologin —
  # a hand-built backup would only prove disable_autologin can read a file this
  # test invented.
  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "precondition: autologin was retargeted (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_file_exists "$bak" "precondition: enable_autologin backed the admin's config up"
  [ -e "$bak" ] || return 0
  assert_not_contains "$(cat "$conf")" "AutomaticLogin=alice" \
    "precondition: enable_autologin really did overwrite the admin's pre-existing autologin — that is the config this test is owed back"
  assert_contains "$(cat "$bak")" "AutomaticLogin=alice" \
    "precondition: the backup holds it, so the revert has a source to restore from"

  edit_gdm_conf_after_install "$conf" "$TMP/gdm-undo-preexisting-edit"

  run_disable_autologin "$conf"
  daemon="$(gdm_daemon_section "$conf")"

  assert_contains "$daemon" "AutomaticLogin=alice" \
    "the admin's own autologin is live under [daemon] again — uninstalling DreamConnect must not silently log a machine out of the account it logged in to before we arrived"
  assert_contains "$daemon" "AutomaticLoginEnable=true" \
    "and it is enabled — AutomaticLogin without AutomaticLoginEnable configures nothing"
  assert_not_contains "$(cat "$conf")" "AutomaticLogin=dreamconnect-host" \
    "our account is out of the file: restored in place of ours, not alongside"
  assert_contains "$daemon" "InitialSetupEnable=false" \
    "an admin edit made inside [daemon] since the install survives — the revert is surgical, not a wholesale restore of the backup"
  assert_contains "$(cat "$conf")" "DisallowTCP=true" \
    "an admin edit made outside [daemon] since the install survives too"
  assert_file_absent "$bak" \
    "the backup is removed once its content has actually been put back (issue #22)"
  assert_eq "$RUN_DISABLE_RC" "0" \
    "a successful revert exits 0 (stderr: $RUN_DISABLE_OUT)"
}

# WHAT IS WRONG TODAY (breaker lap 1, defect 2 — CHECKPOINT row 3). Slice 1 put
# the .bak cleanup at the END of disable_autologin, so on the success path the
# function's exit status is that `rm -f`'s, not the revert's — contradicting the
# doc comment it was written under (install-lib.sh:107-109, verbatim: "Returns
# the status of the strip itself (the awk pass and its write-back), not of the
# scratch-file cleanup"). A .bak that cannot be unlinked therefore reports a
# revert that DID happen as a failure, and install.sh's uninstall() — which
# slice 1 taught to branch on this value — prints the failure message and tells
# the operator their autologin is still live when it is not.
#
# THE INJECTION is the same shape as the strip-failure test above: make the real
# mechanism fail rather than replace it. Unlinking a file needs write permission
# on its DIRECTORY, so `chmod a-w` on the directory holding custom.conf denies
# the .bak deletion while leaving the revert itself untouched — the write-back
# opens an existing file, which needs write permission on the file only. That is
# also why this works without root, which this suite never has (line 18). The
# two preconditions below prove the injection landed where it was aimed: the
# .bak really did survive, and the revert really did happen.
#
# EXPECTED VALUE: 0, from the doc comment quoted above and CHECKPOINT row 3's
# "Fix: explicit `return 0` after cleanup". A leftover .bak is not a failed
# revert — the keys are out of the live config either way.
test_disable_autologin_reports_success_when_the_backup_cannot_be_removed() {
  local conf bak dir
  declare -F disable_autologin >/dev/null || {
    fail "disable_autologin(): not defined"; return 0; }
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — cannot build the .bak fixture"; return 0; }

  dir="$TMP/gdm-undo-stuck-bak"; conf="$dir/custom.conf"; bak="$conf.dreamconnect.bak"
  plant_gdm_conf "$conf"
  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "precondition: autologin was configured (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_file_exists "$bak" "precondition: there is a backup for the cleanup to trip over"
  [ -e "$bak" ] || return 0

  chmod a-w "$dir"
  run_disable_autologin "$conf"
  chmod u+w "$dir"   # restored immediately, so the suite's own cleanup still works

  assert_file_exists "$bak" \
    "precondition: the .bak deletion really was denied — otherwise this test proves nothing about the return code"
  assert_not_contains "$(cat "$conf")" "AutomaticLogin" \
    "precondition: the revert itself succeeded — the autologin keys are out of the live config"
  assert_eq "$RUN_DISABLE_RC" "0" \
    "a revert that happened reports success even though its backup could not be unlinked — the return value is the revert's, not the cleanup's (stderr: $RUN_DISABLE_OUT)"
}

# WHAT IS WRONG TODAY (breaker lap 2, defect 1 — CHECKPOINT row 4, verbatim):
#
#   "`getline line < bak` returns -1 on an unreadable/unopenable backup, and the
#    current code treats that identically to a clean EOF (n=0, "no prior
#    autologin keys") -- so a `.bak` that can't be read (permission error, disk
#    error, or truncated/corrupted by a crash mid-cp during enable_autologin's
#    non-atomic `cp -a`) silently discards whatever it held, reports success, and
#    deletes it. Fix: detect getline's -1 (read failure) distinctly from EOF; on
#    a read failure, fail closed -- do not strip, preserve .bak, return non-zero
#    -- matching the function's own already-established principle that a failure
#    preserves the operator's only copy."
#
# The three assertions below are that fix's three clauses, in order: do not
# strip, preserve .bak, return non-zero. None is read off the current body,
# which does the opposite of all three.
#
# THE INJECTION breaks the read of the BACKUP and nothing else — mode 000 on
# $conf.dreamconnect.bak, leaving $conf itself readable and writable, so the awk
# pass and its write-back would both still succeed and the strip would still
# happen. That is the point: the fail-closed behaviour has to come from noticing
# the failed read, not from the write path falling over on its own. This suite
# never runs as root (line 18), so mode 000 genuinely denies the read; the guard
# below proves it did on this box rather than assuming it.
#
# WHY THIS IS DATA LOSS and not a cosmetic error path: the fixture is the same
# admin-configured box as the restore test above (a real prior
# AutomaticLogin=alice), so a call that strips to nothing and then deletes the
# backup destroys the last copy of alice's config — the exact loss slice 2 was
# written to prevent, reached through a different door.
test_disable_autologin_fails_closed_when_the_backup_cannot_be_read() {
  local conf bak
  declare -F disable_autologin >/dev/null || {
    fail "disable_autologin(): not defined"; return 0; }
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — cannot build the .bak fixture"; return 0; }

  conf="$TMP/gdm-undo-unreadable-bak/custom.conf"; bak="$conf.dreamconnect.bak"
  plant_gdm_conf_with_autologin "$conf" alice

  # The real backup again, written by the real enable_autologin — an unreadable
  # file this test created from scratch would prove nothing about the one an
  # uninstall actually finds.
  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "precondition: autologin was retargeted (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_file_exists "$bak" "precondition: enable_autologin backed the admin's config up"
  [ -e "$bak" ] || return 0
  assert_contains "$(cat "$bak")" "AutomaticLogin=alice" \
    "precondition: that backup holds the admin's own autologin, and after the install it is the only copy left"

  chmod 000 "$bak"
  if cat "$bak" >/dev/null 2>&1; then
    chmod u+rw "$bak"
    skip "disable_autologin fail-closed on an unreadable backup: mode 000 still readable on this box (filesystem or capability), so the read failure under test cannot be produced here"
    return 0
  fi

  run_disable_autologin "$conf"
  chmod u+rw "$bak" 2>/dev/null || true   # only if it survived; restored at once

  assert_contains "$(cat "$conf")" "AutomaticLogin=dreamconnect-host" \
    "a backup that cannot be read leaves the live config alone — with no way to see what it owes back, a strip-to-nothing is indistinguishable from 'the backup held no autologin', and one of those two is silent data loss"
  assert_file_exists "$bak" \
    "and the backup stays: unreadable by this call is not the same as worthless — it is still the operator's only copy of the pre-install autologin (CHECKPOINT row 4)"
  [ "$RUN_DISABLE_RC" -ne 0 ] || \
    fail "an unreadable backup must exit non-zero, got $RUN_DISABLE_RC — install.sh:137 branches on this value and would announce a completed revert over a config it never read (stderr: $RUN_DISABLE_OUT)"
}

# WHAT IS WRONG TODAY (breaker lap 2, defect 2 — CHECKPOINT row 5, verbatim):
#
#   "the collect regex (line ~133) includes `#?` (matching enable_autologin's own
#    strip regex, so a backup's commented AutomaticLogin hint lines, e.g. Debian
#    gdm3's `#  AutomaticLogin = user1`, are captured for restore) but the
#    LIVE-conf strip regex (line ~142) omits `#?`, so restored commented lines are
#    re-collected on every subsequent disable_autologin call (reachable via
#    install.sh:136's retry-on-still-present-.bak path, which slice 3 deliberately
#    made non-fatal) but never stripped -- duplicating without bound across
#    repeated uninstall attempts."
#
# EXPECTED VALUE — one, from CHECKPOINT row 2's owner-confirmed sentence: the
# revert writes back "whatever ... was in the backup's [daemon] section" "in
# place of ours". The backup holds that hint line once, so the config holds it
# once, however many times the revert runs. A second call has nothing new to
# restore.
#
# THE TWO-CALL SCENARIO IS THE REAL ONE, not a contrived loop. install.sh:136
# gates the call on `[ -f "$conf.dreamconnect.bak" ]`, so a second --uninstall
# reaches disable_autologin again exactly when the first left the backup behind.
# The first call here does that the way the test above already establishes: a-w
# on the directory denies the unlink while the revert itself succeeds (row 3 —
# a leftover .bak is not a failed revert). The operator then fixes the
# permission and re-runs --uninstall, which is the second call. Nothing about
# defect 1 is involved: the backup is readable throughout.
#
# WHAT IT DISCRIMINATES. The count after the FIRST call is asserted too, at 1,
# so this cannot go green by dropping the hint lines from the collect regex
# instead — that would restore nothing and contradict row 2's resolved "restore
# whatever was in the backup's [daemon] section verbatim (comment or live), no
# special-casing".
test_disable_autologin_does_not_duplicate_a_restored_comment_hint_on_a_second_call() {
  local conf bak dir hint enable_hint
  declare -F disable_autologin >/dev/null || {
    fail "disable_autologin(): not defined"; return 0; }
  declare -F enable_autologin >/dev/null || {
    fail "enable_autologin(): not defined — cannot build the .bak fixture"; return 0; }

  dir="$TMP/gdm-undo-twice"; conf="$dir/custom.conf"; bak="$conf.dreamconnect.bak"
  hint="#  AutomaticLogin = user1"
  enable_hint="#  AutomaticLoginEnable = true"
  plant_gdm_conf_with_commented_autologin_hints "$conf"
  assert_eq "$(gdm_daemon_line_count "$conf" "$hint")" "1" \
    "precondition: the stock Debian gdm3 conf carries that commented hint once"

  run_enable_autologin "$conf" dreamconnect-host
  assert_eq "$RUN_AUTOLOGIN_RC" "0" \
    "precondition: autologin was configured (stderr: $RUN_AUTOLOGIN_OUT)"
  assert_file_exists "$bak" "precondition: there is a backup to restore from"
  [ -e "$bak" ] || return 0
  assert_eq "$(gdm_daemon_line_count "$conf" "$hint")" "0" \
    "precondition: enable_autologin's strip ate the commented hint (its regex matches #?), so after the install it lives only in the backup"

  # First --uninstall: the revert runs, the .bak deletion is denied, so the
  # backup survives — which is the state install.sh:136 gates its retry on.
  chmod a-w "$dir"
  run_disable_autologin "$conf"
  chmod u+w "$dir"

  if [ ! -e "$bak" ]; then
    skip "disable_autologin duplication on a repeat call: the .bak was removed despite a read-only directory on this box, so the two-call path cannot be produced here"
    return 0
  fi
  assert_eq "$(gdm_daemon_line_count "$conf" "$hint")" "1" \
    "precondition: the first call put the backup's commented hint back, once (slice 2's restore)"

  # Second --uninstall, over the config the first one just restored.
  run_disable_autologin "$conf"

  assert_eq "$(gdm_daemon_line_count "$conf" "$hint")" "1" \
    "a repeated revert restores the backup's commented hint ONCE, not once per call — the live-strip pass has to recognise the line the collect pass puts back, or every retried --uninstall grows [daemon] by another copy, without bound"
  assert_eq "$(gdm_daemon_line_count "$conf" "$enable_hint")" "1" \
    "and the same for its companion — GDM reads the pair together, so a duplicated AutomaticLoginEnable hint is the same defect"
  assert_not_contains "$(cat "$conf")" "AutomaticLogin=dreamconnect-host" \
    "our own keys are still gone after the second call — the repeat must not put anything of ours back either"
}

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

# --- issue #26, slice 2: the push_dconf_environment CALL SITE -----------------
#
# Slice 1's two tests (lines 1375-1523) can be green with the function orphaned,
# and today they are: install.sh never mentions push_dconf_environment, so every
# install still leaves DCONF_PROFILE out of the live user manager — the whole of
# issue #26 ("DCONF_PROFILE was absent from both the gnome-shell process env and
# `systemctl --user show-environment`"). install.sh cannot be executed here (it
# demands root, a real GDM and a real systemd, and does top-level work on
# sourcing), so the wiring is asserted by line ordering, the same technique the
# wait_for_user_bus call-order tests (e)/(e2) above use.
#
# WHERE THE ORDER COMES FROM — factory/CHECKPOINT.md, issue #26 seams, verbatim:
#   "install.sh call site: push_dconf_environment "$USER_NAME" "$USER_UID"
#    immediately after configure_no_idle_lock, before enable_autologin."
# Both bounds are load-bearing, not layout preference:
#   * AFTER configure_no_idle_lock — that is what writes the profile the pushed
#     value names (issue #26: "/etc/dconf/db/<name>.d/00-display-host (+ compiled
#     db) and ~/.config/environment.d/dconf-profile.conf"). Pushing first points
#     the live session at a profile that does not exist yet.
#   * BEFORE enable_autologin — the plan's ordering for the host-account branch;
#     enable_autologin is the last step of session setup for that account.
# The argument check is from the same line of the plan: the second argument is
# the UID, and $USER_HOME is one slip away in a block that reads
# `configure_no_idle_lock "$USER_NAME" "$USER_HOME"` two lines up. Handing the
# home path over would build XDG_RUNTIME_DIR=/run/user//home/<name>, which no
# other test in this suite can see.
test_install_sh_pushes_dconf_environment_after_configure_no_idle_lock_and_before_autologin() {
  local sh idle pushed auto stmt
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  idle="$(first_code_line "$sh" 'configure_no_idle_lock')"
  [ -n "$idle" ] || { fail "call site: no 'configure_no_idle_lock' line in install.sh"; return 0; }
  auto="$(first_code_line "$sh" 'enable_autologin' "$idle")"
  [ -n "$auto" ] || { fail "call site: no 'enable_autologin' line after configure_no_idle_lock"; return 0; }

  # Searched from the top of the file, not from $idle, so that a call placed too
  # EARLY is reported as too early rather than as missing. Anchored on a
  # non-identifier character so it cannot match the uninstall path's
  # `unpush_dconf_environment`, which appears EARLIER in the file (install.sh:127
  # region) and would otherwise be reported here as a push placed before
  # configure_no_idle_lock.
  pushed="$(first_code_line "$sh" '(^|[^[:alnum:]_])push_dconf_environment')"
  [ -n "$pushed" ] || {
    fail "call site: install.sh never calls push_dconf_environment (configure_no_idle_lock at line $idle, enable_autologin at line $auto) — the helper is orphaned and issue #26 is not fixed: DCONF_PROFILE reaches the drop-in on disk and never the running user manager"
    return 0; }

  [ "$idle" -lt "$pushed" ] || \
    fail "call site: push_dconf_environment (line $pushed) must come AFTER configure_no_idle_lock (line $idle) — before it, the dconf profile it names has not been written or compiled yet"
  [ "$pushed" -lt "$auto" ] || \
    fail "call site: push_dconf_environment (line $pushed) must come BEFORE enable_autologin (line $auto)"

  stmt="$(logical_statement_at "$sh" "$pushed")"
  [ -n "$stmt" ] || { fail "call site: could not read the statement at install.sh:$pushed"; return 0; }
  [[ "$stmt" == *USER_NAME* && "$stmt" == *USER_UID* ]] || \
    fail "call site: install.sh:$pushed must call push_dconf_environment with the account name and its UID — the UID is what builds XDG_RUNTIME_DIR=/run/user/<uid> for the running manager. Statement was: [$stmt]"
}

# --- issue #26, slice 3: that call's FAILURE HANDLING -------------------------
#
# The ordering test above is green against the bare
# `push_dconf_environment "$USER_NAME" "$USER_UID"` install.sh carries today, and
# so is every other test here — but install.sh runs under `set -euo pipefail`
# (line 34), so ANY non-zero exit from that call aborts the whole install at the
# last host-account step, after /opt, the user unit and the SC drop-in are all
# already in place. push_dconf_environment can exit non-zero for reasons that are
# not install-fatal at all: a reserved or invalid account name (install-lib.sh
# returns 1 before invoking anything) or a live user manager that refuses
# set-environment.
#
# WHERE THE REQUIRED FORM COMES FROM — factory/CHECKPOINT.md, issue #26, slice 3
# row, verbatim: "failure handling: a failed set-environment warns (non-fatal),
# never silently swallowed (no `|| true`)"; the plan spells that same form as
# `|| echo "!! ..."`, never `|| true` / `|| :`. Both halves are load-bearing:
#   * NON-FATAL — this push is a belt on top of the braces. The
#     ~/.config/environment.d/dconf-profile.conf that configure_no_idle_lock
#     wrote one line above is still on disk and still takes effect at the next
#     full manager start (a reboot — which host-account mode does anyway, being
#     autologin by construction). Losing an otherwise-complete install over the
#     redundant half is strictly the worse outcome.
#   * NEVER SWALLOWED — with `|| true` the push is gone AND silent, so the
#     session runs with DCONF_PROFILE unset until the next reboot and nothing in
#     the install log ever said so. That invisible state is precisely what issue
#     #26 was filed about; a warning is what makes it diagnosable.
# The `!!` marker is install.sh's own convention for a warning the operator has
# to read (lines 345, 390 and 402 today), not this test's preference — the
# message wording is deliberately NOT asserted and may be rewritten freely. No
# `>&2` is required either: install.sh's top-level warnings, including the
# enable_autologin non-fatal path at line 390, all go to stdout.
test_install_sh_warns_but_does_not_swallow_a_failed_dconf_environment_push() {
  local sh pushed stmt
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  # Same non-identifier anchor as the ordering test above: `unpush_dconf_
  # environment` in the uninstall path must not be mistaken for this call.
  pushed="$(first_code_line "$sh" '(^|[^[:alnum:]_])push_dconf_environment')"
  [ -n "$pushed" ] || {
    fail "failure handling: install.sh never calls push_dconf_environment at all"
    return 0; }

  stmt="$(logical_statement_at "$sh" "$pushed")"
  [ -n "$stmt" ] || { fail "failure handling: could not read the statement at install.sh:$pushed"; return 0; }

  # (1) Handled at all, and visibly: `|| echo <something>`.
  [[ "$stmt" =~ \|\|[[:space:]]*echo[[:space:]]+[^[:space:]] ]] || \
    fail "failure handling: install.sh:$pushed must handle a push_dconf_environment failure with '|| echo <warning>' — unhandled, set -euo pipefail (install.sh:34) aborts the entire install over a push that is redundant to the environment.d drop-in written one line above. Statement was: [$stmt]"

  # (2) Recognisable as a warning, by install.sh's own marker.
  assert_contains "$stmt" '!!' \
    "failure handling: install.sh:$pushed must mark the warning with install.sh's '!!' operator-warning prefix (lines 345/390/402). Statement was: [$stmt]"

  # (3) Never silently swallowed.
  assert_not_contains "$stmt" "|| true" \
    "failure handling: install.sh:$pushed swallows a failed DCONF_PROFILE push — the live session keeps an unset DCONF_PROFILE and the log never says so"
  assert_not_contains "$stmt" "|| :" \
    "failure handling: install.sh:$pushed swallows a failed DCONF_PROFILE push — the live session keeps an unset DCONF_PROFILE and the log never says so"

  # (4) ...and never fatal: aborting here is the outcome the non-fatal
  # requirement exists to prevent, whether spelled `|| die` or `|| { ...; exit; }`.
  [[ "$stmt" =~ (^|[^[:alnum:]_])(die|exit)([^[:alnum:]_]|$) ]] && \
    fail "failure handling: install.sh:$pushed must NOT abort the install when the push fails — the environment.d drop-in still applies at the next manager start, so a warning is the correct response. Statement was: [$stmt]"

  return 0
}

# --- issue #26, breaker lap 1: the unpush_dconf_environment CALL SITE ----------
#
# The two unpush tests at lines 1541+ can be green with the function orphaned,
# and today they would be: install.sh's uninstall path never mentions it, so
# every uninstall still leaves the account's live manager holding
# DCONF_PROFILE=<name> after remove_no_idle_lock has deleted the profile file
# that name points at. install.sh cannot be executed here (root, real GDM, real
# systemd, top-level work on sourcing), so the wiring is asserted by line
# ordering and statement text, the technique the push call-site tests above and
# the wait_for_user_bus tests before them already use.
#
# THE THREE BOUNDS, each load-bearing:
#
#   * INSIDE uninstall() — the call must sit between `uninstall()` and the
#     `remove_no_idle_lock` call, which is itself inside that function's
#     `if [ -n "$HOST_ACCOUNT" ]` block (install.sh:124-128). Anywhere else and
#     the uninstall path does not run it.
#   * BEFORE remove_no_idle_lock — the reverse of the install order (write the
#     profile, then push; unset, then delete the profile). The other way round
#     the live manager spends the rest of the uninstall — the AccountsService
#     revert, userdel, the state file — naming a profile that is already gone,
#     which is the dconf null configuration this fix exists to prevent, not a
#     layout preference.
#   * WITH THE UID — $target_uid (install.sh:74, `target_uid="$HOST_UID"`, read
#     off install.state) is what builds XDG_RUNTIME_DIR=/run/user/<uid> for the
#     running manager. $target_home is one slip away in a block whose previous
#     line reads `remove_no_idle_lock "$HOST_ACCOUNT" "$target_home"`, and
#     handing the home path over would build /run/user//home/<name>, which no
#     other test in this suite can see.
#
# AND NON-FATAL, for the reason install.sh already gives at its neighbour
# (install.sh:125-128, verbatim): "Never fatal: a refusal here (a reserved name
# in a tampered state file) must not stop the account deletion below, which is
# the whole point." install.sh runs under `set -euo pipefail` (line 34), and
# unpush_dconf_environment returns non-zero for a guard refusal or a manager that
# is simply not running any more — neither of which may abort an uninstall
# before userdel and the state file. Wording is deliberately not asserted; `||
# true` and `|| :` are refused because a silently swallowed failure leaves the
# operator with no record that the account's dconf is still pointing at nothing.
test_install_sh_unpushes_dconf_environment_on_uninstall() {
  local sh ustart removed unpushed stmt
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  ustart="$(first_code_line "$sh" '^uninstall[(][)]')"
  [ -n "$ustart" ] || { fail "uninstall call site: no 'uninstall()' definition in install.sh"; return 0; }
  removed="$(first_code_line "$sh" '(^|[^[:alnum:]_])remove_no_idle_lock' "$ustart")"
  [ -n "$removed" ] || { fail "uninstall call site: no 'remove_no_idle_lock' call inside uninstall()"; return 0; }

  unpushed="$(first_code_line "$sh" 'unpush_dconf_environment')"
  [ -n "$unpushed" ] || {
    fail "uninstall call site: install.sh never calls unpush_dconf_environment (uninstall() at line $ustart, remove_no_idle_lock at line $removed) — the helper is orphaned and the defect stands: --uninstall deletes /etc/dconf/profile/<name> and leaves DCONF_PROFILE=<name> set in the account's live user manager, so dconf falls to the null configuration and that account can neither read nor write any gsettings key until it logs out"
    return 0; }

  [ "$ustart" -lt "$unpushed" ] || \
    fail "uninstall call site: unpush_dconf_environment (line $unpushed) is above uninstall() (line $ustart) — it must be called from the uninstall path, not the install path"
  [ "$unpushed" -lt "$removed" ] || \
    fail "uninstall call site: unpush_dconf_environment (line $unpushed) must come BEFORE remove_no_idle_lock (line $removed) — deleting /etc/dconf/profile/<name> first leaves the live manager pointing at an absent profile for the rest of the uninstall, which is the null-configuration state this call exists to prevent"

  stmt="$(logical_statement_at "$sh" "$unpushed")"
  [ -n "$stmt" ] || { fail "uninstall call site: could not read the statement at install.sh:$unpushed"; return 0; }

  [[ "$stmt" == *HOST_ACCOUNT* || "$stmt" == *target_name* ]] || \
    fail "uninstall call site: install.sh:$unpushed must pass the recorded account name (\$HOST_ACCOUNT/\$target_name). Statement was: [$stmt]"
  [[ "$stmt" == *HOST_UID* || "$stmt" == *target_uid* ]] || \
    fail "uninstall call site: install.sh:$unpushed must pass that account's UID (\$target_uid, install.sh:74) — the UID is what builds XDG_RUNTIME_DIR=/run/user/<uid> for the running manager, and \$target_home one line up would build /run/user//home/<name>. Statement was: [$stmt]"

  [[ "$stmt" =~ \|\|[[:space:]]*echo[[:space:]]+[^[:space:]] ]] || \
    fail "uninstall call site: install.sh:$unpushed must handle an unpush_dconf_environment failure with '|| echo <warning>' — unhandled, set -euo pipefail (install.sh:34) aborts the uninstall before the AccountsService revert, userdel and the state file, exactly what install.sh:125-128 already says must not happen. Statement was: [$stmt]"
  assert_not_contains "$stmt" "|| true" \
    "uninstall call site: install.sh:$unpushed swallows a failed unpush — the account's manager keeps a dangling DCONF_PROFILE and the log never says so"
  assert_not_contains "$stmt" "|| :" \
    "uninstall call site: install.sh:$unpushed swallows a failed unpush — the account's manager keeps a dangling DCONF_PROFILE and the log never says so"
  [[ "$stmt" =~ (^|[^[:alnum:]_])(die|exit)([^[:alnum:]_]|$) ]] && \
    fail "uninstall call site: install.sh:$unpushed must NOT abort the uninstall when the unpush fails — the account deletion and state-file cleanup below are the whole point of --uninstall. Statement was: [$stmt]"

  return 0
}

# --- issue #26, breaker lap 2: the unpush must beat disable-linger ------------
#
# The test above pins the unpush to BEFORE remove_no_idle_lock, and that bound
# holds either way — so it stays green while the call sits (install.sh:132) AFTER
# `loginctl disable-linger` (install.sh:122), which is the defect. From
# factory/CHECKPOINT.md row 6, verbatim:
#
#   "`unpush_dconf_environment` call (install.sh:132) sits AFTER `loginctl
#    disable-linger` (install.sh:122) — in the exact reused-account/same-boot/
#    no-graphical-session case the fix targets, disable-linger is the only thing
#    keeping user@uid.service up and is NOT gated on CREATED_ACCOUNT, so the
#    manager (and /run/user/<uid>) is already gone by line 132: the unpush either
#    fails with a false-alarm warning on a normal uninstall, or races a dying
#    manager. Move the unpush call to before disable-linger (near the other
#    user-manager calls at lines 87-100)."
#
# Why that is a mechanism and not a preference: with CREATED_ACCOUNT=0 the
# account-deleting branch (install.sh:146) never runs, so
# uninstall_host_account's own `loginctl terminate-user` (install-lib.sh:934) is
# never reached — uninstall()'s unconditional disable-linger is the one and only
# thing that stops user@<uid>.service, and systemd tears /run/user/<uid> down
# with it. unpush_dconf_environment talks to that manager over
# XDG_RUNTIME_DIR=/run/user/<uid> (install-lib.sh:811), so after the linger drop
# there is nothing left to unset.
#
# WHICH disable-linger: the one in install.sh's own uninstall(), found from the
# `uninstall()` definition and required to be above that function's closing
# brace. install-lib.sh:930 has its own `run loginctl disable-linger` inside
# uninstall_host_account — a different file, never scanned here, and gated behind
# CREATED_ACCOUNT=1 anyway, so it is deliberately NOT the anchor.
#
# The lower bound (after $target_uid is assigned) is here because the fix moves
# this call EARLIER: past install.sh:74/81 it would expand to
# XDG_RUNTIME_DIR=/run/user/ against an empty account name. Only enforced when
# the statement actually names those locals, so a rewrite onto $HOST_ACCOUNT/
# $HOST_UID is not falsely failed.
test_install_sh_unpushes_dconf_environment_before_disabling_linger() {
  local sh ustart uend linger unpushed stmt uidset
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  ustart="$(first_code_line "$sh" '^uninstall[(][)]')"
  [ -n "$ustart" ] || { fail "linger ordering: no 'uninstall()' definition in install.sh"; return 0; }
  uend="$(first_code_line "$sh" '^[}]' "$ustart")"
  [ -n "$uend" ] || { fail "linger ordering: could not find the end of uninstall() in install.sh"; return 0; }

  linger="$(first_code_line "$sh" 'loginctl disable-linger' "$ustart")"
  [ -n "$linger" ] || { fail "linger ordering: no 'loginctl disable-linger' call after uninstall() (line $ustart) in install.sh"; return 0; }
  [ "$linger" -lt "$uend" ] || {
    fail "linger ordering: the 'loginctl disable-linger' found at line $linger is outside uninstall() (which ends at line $uend) — this test anchors on the one uninstall() runs itself, not install-lib.sh's"
    return 0; }

  # From the top of the file, so a call placed too early reads as too early
  # rather than as missing.
  unpushed="$(first_code_line "$sh" '(^|[^[:alnum:]_])unpush_dconf_environment')"
  [ -n "$unpushed" ] || {
    fail "linger ordering: install.sh never calls unpush_dconf_environment (uninstall() at line $ustart, disable-linger at line $linger)"
    return 0; }

  [ "$ustart" -lt "$unpushed" ] || {
    fail "linger ordering: unpush_dconf_environment (line $unpushed) is above uninstall() (line $ustart) — it must be called from the uninstall path"
    return 0; }

  [ "$unpushed" -lt "$linger" ] || \
    fail "linger ordering: unpush_dconf_environment (line $unpushed) must come BEFORE 'loginctl disable-linger' (line $linger), and today it comes after. On a reused account (CREATED_ACCOUNT=0, uninstalled in the same boot with no session ever started) that disable-linger is the only thing stopping user@<uid>.service — uninstall_host_account's terminate-user never runs — so by line $unpushed the manager and /run/user/<uid> are gone and the unpush can only warn about a normal uninstall or race a dying manager"

  stmt="$(logical_statement_at "$sh" "$unpushed")"
  [ -n "$stmt" ] || { fail "linger ordering: could not read the statement at install.sh:$unpushed"; return 0; }

  # The last `target_uid=` assignment inside uninstall() above the linger drop
  # (install.sh:74 and :81 today — the two branches of the HOST_ACCOUNT test).
  uidset="$(awk -v start="$ustart" -v end="$linger" \
    'NR > start && NR < end && /target_uid=/ && $0 !~ /^[[:space:]]*#/ { n = NR } END { if (n) print n }' "$sh")"
  if [ -n "$uidset" ] && { [[ "$stmt" == *target_uid* ]] || [[ "$stmt" == *target_name* ]]; }; then
    [ "$uidset" -lt "$unpushed" ] || \
      fail "linger ordering: unpush_dconf_environment (line $unpushed) uses \$target_uid/\$target_name but is above the last assignment of \$target_uid (line $uidset) — moving the call up past install.sh:74/81 makes it run as XDG_RUNTIME_DIR=/run/user/ for an empty account name. Statement was: [$stmt]"
  fi

  return 0
}

# --- issue #22: the uninstall() call site -------------------------------------
#
# The two disable_autologin tests above can be fully green while install.sh
# still calls it bare (`disable_autologin "$conf"`, install.sh:134), and a bare
# call is strictly worse once the return code becomes meaningful: install.sh
# runs under `set -euo pipefail` (line 34) and uninstall() is invoked as the
# command after the final `&&` (`[ "$ACTION" = "--uninstall" ] && uninstall`,
# line 187), where set -e still applies — so a failed strip would abort the
# whole uninstall at line 134, before disable-linger, the AccountsService
# revert, userdel and the state file. That is the outcome install.sh's own
# neighbouring comment already forbids (lines 142-144: "Never fatal ... must not
# stop the account deletion below, which is the whole point").
#
# WHAT IS REQUIRED — factory/CHECKPOINT.md, issue #22 seams, verbatim:
#   "install.sh call site (uninstall(), ~line 128-136): branches on
#    disable_autologin's now-meaningful return code"
# So: handled, and handled non-fatally. `&&` alone does not qualify — the status
# of `disable_autologin ... && echo ...` is the function's own when it fails, so
# set -e still kills the uninstall; only an `if` or a `||` branch absorbs it.
# Structure only, exactly as the unpush/wait_for_user_bus call-site tests above:
# the message wording is NOT asserted here. The CHECKPOINT records that the
# "(backup: $conf.dreamconnect.bak)" text at install.sh:135 "must change" once
# the file is deleted on success, but not what it must become, and the same
# substring is legitimate in a FAILURE branch (where the backup really is still
# there) — so pinning it textually would fail correct implementations. Left to
# the builder deliberately.
test_install_sh_branches_on_the_disable_autologin_result() {
  local sh ustart uend disabled stmt
  sh="$HERE/install.sh"
  assert_file_exists "$sh" "install.sh is present"
  [ -f "$sh" ] || return 0

  ustart="$(first_code_line "$sh" '^uninstall[(][)]')"
  [ -n "$ustart" ] || { fail "autologin revert: no 'uninstall()' definition in install.sh"; return 0; }
  uend="$(first_code_line "$sh" '^[}]' "$ustart")"
  [ -n "$uend" ] || { fail "autologin revert: could not find the end of uninstall() in install.sh"; return 0; }

  disabled="$(first_code_line "$sh" '(^|[^[:alnum:]_])disable_autologin' "$ustart")"
  [ -n "$disabled" ] || {
    fail "autologin revert: uninstall() (line $ustart) never calls disable_autologin — the autologin we configured is never reverted"
    return 0; }
  [ "$disabled" -lt "$uend" ] || {
    fail "autologin revert: the disable_autologin call at line $disabled is outside uninstall() (which ends at line $uend)"
    return 0; }

  stmt="$(logical_statement_at "$sh" "$disabled")"
  [ -n "$stmt" ] || { fail "autologin revert: could not read the statement at install.sh:$disabled"; return 0; }

  { [[ "$stmt" =~ (^|[[:space:]])if[[:space:]] ]] || [[ "$stmt" == *"||"* ]]; } || \
    fail "autologin revert: install.sh:$disabled must branch on disable_autologin's result with 'if' or '||' — bare (or '&&' alone) the failure is either announced as a success or, under set -euo pipefail (install.sh:34), aborts the uninstall before disable-linger, the AccountsService revert, userdel and the state file. Statement was: [$stmt]"

  assert_not_contains "$stmt" "|| true" \
    "autologin revert: install.sh:$disabled swallows a failed strip — the operator is told the autologin was reverted while AutomaticLogin=<account> is still live in the GDM config"
  assert_not_contains "$stmt" "|| :" \
    "autologin revert: install.sh:$disabled swallows a failed strip — the operator is told the autologin was reverted while AutomaticLogin=<account> is still live in the GDM config"
  [[ "$stmt" =~ (^|[^[:alnum:]_])(die|exit)([^[:alnum:]_]|$) ]] && \
    fail "autologin revert: install.sh:$disabled must NOT abort the uninstall when the strip fails — the account deletion and state-file cleanup below are the whole point of --uninstall. Statement was: [$stmt]"

  return 0
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
  test_configure_no_idle_lock_points_the_session_at_the_profile \
  test_configure_no_idle_lock_skips_gnome_initial_setup \
  test_configure_no_idle_lock_refuses_reserved_dconf_names \
  test_push_dconf_environment_invokes_set_environment_with_the_profile_name \
  test_push_dconf_environment_refuses_reserved_dconf_names \
  test_push_dconf_environment_refuses_malformed_account_names \
  test_unpush_dconf_environment_unsets_the_profile_from_the_running_manager \
  test_unpush_dconf_environment_refuses_reserved_and_malformed_names \
  test_push_and_unpush_dconf_environment_gate_the_invocation_behind_run \
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
  test_enable_autologin_refuses_only_root_and_names_that_corrupt_the_conf \
  test_enable_autologin_refuses_a_name_whose_backslash_awk_would_expand \
  test_enable_autologin_accepts_an_existing_account_that_is_not_new_account_shaped \
  test_enable_autologin_still_configures_an_ordinary_account \
  test_disable_autologin_removes_the_backup_on_success \
  test_disable_autologin_preserves_the_backup_if_the_strip_fails \
  test_disable_autologin_restores_an_autologin_configured_before_the_install \
  test_disable_autologin_reports_success_when_the_backup_cannot_be_removed \
  test_disable_autologin_fails_closed_when_the_backup_cannot_be_read \
  test_disable_autologin_does_not_duplicate_a_restored_comment_hint_on_a_second_call \
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
  test_install_sh_pushes_dconf_environment_after_configure_no_idle_lock_and_before_autologin \
  test_install_sh_warns_but_does_not_swallow_a_failed_dconf_environment_push \
  test_install_sh_unpushes_dconf_environment_on_uninstall \
  test_install_sh_unpushes_dconf_environment_before_disabling_linger \
  test_install_sh_branches_on_the_disable_autologin_result
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
