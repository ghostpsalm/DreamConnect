#!/usr/bin/env bash
#
# Tests for agent/fixture-lib.sh -- the ByteBuddy pins, read out of the
# product's own agent/build.sh (issue #46, slice 1).
#
# Seam: fixture-lib.sh holds definitions only and is sourced, so the boundary is
# "source it from a real file at a real path, call one function, look at its
# exit code, its stdout and its stderr separately". Separately, because the
# contract makes stdout load-bearing on failure: it must be *empty*, since
# anything printed there would be a fallback value a caller might then use.
#
# Contract under test (issue #46 "Requirements", as decided by the owner
# 2026-09-12, and the interface the architect fixed for this slice):
#   * "The SHA-256 the fixture is verified against must be the SAME constant the
#     product uses -- BB_SHA256 in agent/build.sh -- read from there, not
#     restated."
#   * "If the shape changes and the constant can no longer be read, the fetcher
#     must fail loudly -- non-zero exit, saying it could not read BB_SHA256 --
#     and must never fall back to a hardcoded value."
#   * bb_pin NAME prints the value of NAME="..." in agent/build.sh; on a missing
#     or empty assignment: exit 1, stdout empty, stderr
#     `could not read NAME from <path>`.
#   * bb_version/bb_sha256/bb_url wrap it; bb_url expands $BYTEBUDDY_VERSION.
#
# Where the expected values come from (independent of any implementation):
#   Cases A-D drive the library against a *synthetic* build.sh this file writes,
#   holding sentinel pins chosen here -- 9.9.9-oracle and an 0123456789abcdef...
#   hash that is deliberately NOT byte-buddy-1.18.11's. Nothing can produce
#   those values except by reading that file, which is the whole point: an
#   implementation carrying a hardcoded ByteBuddy hash passes a test written
#   against the real one and fails these. The expected URL in Case B is the
#   sentinel substituted into the template by hand.
#
#   No real SHA-256 appears anywhere in this file. The repository is required to
#   hold exactly one copy of that constant (agent/build.sh:12); a second one
#   here, even in an assertion, is the transcription the requirement forbids.
#
# Why there is no skip() in this suite: #46 exists because a check that skips
# still lets the gate print ALL TESTS PASSED. Every case here runs on any box --
# it reads files in a mktemp -d and needs no jar, no network and no JDK -- so an
# unmet precondition is a failure, never a skip.
#
# Run:  bash agent/test_fixture_fetch.sh      (also wired into ./run-tests.sh)
set -uo pipefail

# The same rail test_install.sh and test_build.sh carry. Nothing here writes
# outside mktemp -d today, but this suite grows the fixture *fetch* cases next
# (#46 slice 2), and those name a real per-box cache path; a case that forgot
# its DC_FIXTURE_CACHE override must not be able to run as root against the
# real one.
[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"          # the real agent/ directory
FIXTURE_LIB="$HERE/fixture-lib.sh"
REAL_BUILD_SH="$HERE/build.sh"

# Sentinels. Not the real pins, on purpose -- see the header.
S_VERSION="9.9.9-oracle"
S_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
S_URL="https://repo1.maven.org/maven2/net/bytebuddy/byte-buddy/$S_VERSION/byte-buddy-$S_VERSION.jar"
RAN_MARKER="SYNTHETIC-BUILD-SH-RAN"

# --- tiny assert harness (same shape as agent/test_build.sh) ------------------
FAILURES=0
CURRENT="<none>"

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq() {  # actual expected label
  [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"
}

assert_ne() {  # actual notexpected label
  [ "$1" != "$2" ] || fail "$3: expected anything but [$2], got [$1]"
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$FIXTURE_LIB" ] || { echo "FAIL: fixture-lib.sh not found at $FIXTURE_LIB"; exit 1; }
[ -f "$REAL_BUILD_SH" ] || { echo "FAIL: build.sh not found at $REAL_BUILD_SH"; exit 1; }

# --- the seam ----------------------------------------------------------------

# A runner script, not `bash -c`, because the library is sourced from a real
# file at a real path in production too (agent/test_fixture_fetch.sh and
# scripts/fetch-test-fixtures.sh, in different directories) and how it locates
# agent/build.sh from there is part of what is under test.
write_runner() {  # dir lib_path
  cat > "$1/run-pin.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "$2"
"\$@"
EOF
}

# A synthetic build.sh: the three assignments in the shape agent/build.sh uses,
# and a top-level echo. The echo is a tripwire -- a bb_pin that *sources*
# build.sh instead of reading it would run that line here and would run a real
# curl-and-compile against the real file.
write_synthetic_build_sh() {  # path
  cat > "$1" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BYTEBUDDY_VERSION="$S_VERSION"
BB_SHA256="$S_SHA256"
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
BB_URL="https://repo1.maven.org/maven2/net/bytebuddy/byte-buddy/\$BYTEBUDDY_VERSION/byte-buddy-\$BYTEBUDDY_VERSION.jar"
echo "$RAN_MARKER"
EOF
}

make_sandbox() {  # -> prints a dir holding fixture-lib.sh + a synthetic build.sh
  local sb
  sb="$(mktemp -d "$TMP/sandbox.XXXXXX")"
  cp "$FIXTURE_LIB" "$sb/fixture-lib.sh"
  write_synthetic_build_sh "$sb/build.sh"
  write_runner "$sb" "$sb/fixture-lib.sh"
  printf '%s\n' "$sb"
}

OUT=""; ERR=""; RC=0
# LC_ALL=C for the same reason test_build.sh pins it: some assertions below are
# about diagnostic text, and a localised box must not quietly stop discriminating.
run_pin() {  # dir fn [args...] -- sets OUT, ERR, RC
  local d="$1"; shift
  OUT="$(cd "$d" && LC_ALL=C bash ./run-pin.sh "$@" 2>"$d/stderr")"
  RC=$?
  ERR="$(cat "$d/stderr")"
}

# --- tests -------------------------------------------------------------------

# Case A -- the requirement's core: the value comes out of the build.sh in front
# of it, not out of fixture-lib.sh. Asserted against a hash that is not
# ByteBuddy's, so a hardcoded constant cannot pass.
test_the_sha256_is_read_from_the_build_script_not_restated() {
  local sb
  sb="$(make_sandbox)"

  run_pin "$sb" bb_sha256

  assert_eq "$RC" "0" "bb_sha256: reading a well-formed build.sh succeeds"
  assert_eq "$OUT" "$S_SHA256" "bb_sha256: prints the constant declared in that build.sh"
  assert_not_contains "$OUT$ERR" "$RAN_MARKER" \
    "bb_sha256: build.sh must be read, never executed -- the real one fetches and compiles"
}

# Case B -- bb_url expands $BYTEBUDDY_VERSION. A raw `grep` of the assignment
# yields a URL with a literal $BYTEBUDDY_VERSION in it, which curl cannot fetch.
test_the_url_is_read_with_the_version_expanded() {
  local sb
  sb="$(make_sandbox)"

  run_pin "$sb" bb_version
  assert_eq "$RC" "0" "bb_version: reading a well-formed build.sh succeeds"
  assert_eq "$OUT" "$S_VERSION" "bb_version: prints the version declared in that build.sh"

  run_pin "$sb" bb_url
  assert_eq "$RC" "0" "bb_url: reading a well-formed build.sh succeeds"
  assert_eq "$OUT" "$S_URL" "bb_url: prints the URL with the version substituted"
  assert_not_contains "$OUT" '$' "bb_url: nothing may be left unexpanded"
}

# Case C -- "if the constant can no longer be read, fail loudly ... and never
# fall back to a hardcoded value". Empty stdout is the load-bearing half: a
# caller reading a pin cannot tell a fallback from a real read, so there must be
# nothing on stdout to read.
test_a_missing_constant_fails_loudly_with_no_fallback() {
  local sb
  sb="$(make_sandbox)"
  grep -v '^BB_SHA256=' "$sb/build.sh" > "$sb/build.sh.new" && mv "$sb/build.sh.new" "$sb/build.sh"

  run_pin "$sb" bb_sha256

  assert_eq "$RC" "1" "missing constant: exit 1"
  assert_eq "$OUT" "" "missing constant: stdout is empty -- no fallback value may be printed"
  assert_contains "$ERR" "could not read BB_SHA256 from" \
    "missing constant: stderr names the constant it could not read"
  assert_contains "$ERR" "build.sh" "missing constant: stderr names the file it read"
}

# Case D -- the same, for a constant that is present but empty. An empty pin is
# worse than a missing one: it would verify a fixture against "" and could be
# reported as a match by a sloppy comparison.
test_an_empty_constant_fails_the_same_way() {
  local sb
  sb="$(make_sandbox)"
  sed 's/^BB_SHA256=.*/BB_SHA256=""/' "$sb/build.sh" > "$sb/build.sh.new" \
    && mv "$sb/build.sh.new" "$sb/build.sh"

  run_pin "$sb" bb_sha256

  assert_eq "$RC" "1" "empty constant: exit 1"
  assert_eq "$OUT" "" "empty constant: stdout is empty -- no fallback value may be printed"
  assert_contains "$ERR" "could not read BB_SHA256 from" \
    "empty constant: stderr names the constant it could not read"
}

# Case E -- the accepted coupling, against the real file. Sourced by absolute
# path from a directory outside the repository, because scripts/ and agent/ both
# source it and neither cwd nor $0 can be what locates agent/build.sh.
#
# Shape only: that the pinned hash is the *correct* upstream one is not knowable
# without the artifact, and is the fetch's job (slice 2), not this library's.
# 64 lowercase hex digits is SHA-256 itself, not a choice build.sh made.
test_the_real_build_script_is_still_readable_from_elsewhere() {
  local d
  d="$(mktemp -d "$TMP/elsewhere.XXXXXX")"
  write_runner "$d" "$FIXTURE_LIB"

  run_pin "$d" bb_sha256
  assert_eq "$RC" "0" "real build.sh: bb_sha256 must not fail -- the shape it reads is agent/build.sh's"
  case "$OUT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\
[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "real build.sh: bb_sha256 must print 64 lowercase hex digits, got [$OUT]" ;;
  esac

  run_pin "$d" bb_version
  assert_eq "$RC" "0" "real build.sh: bb_version must not fail"
  assert_ne "$OUT" "" "real build.sh: bb_version must not be empty"
  local version="$OUT"

  run_pin "$d" bb_url
  assert_eq "$RC" "0" "real build.sh: bb_url must not fail"
  assert_contains "$OUT" "byte-buddy-$version.jar" \
    "real build.sh: bb_url names the jar for the version bb_version reported"
  assert_not_contains "$OUT" '$' "real build.sh: bb_url leaves nothing unexpanded"
}

for CURRENT in \
  test_the_sha256_is_read_from_the_build_script_not_restated \
  test_the_url_is_read_with_the_version_expanded \
  test_a_missing_constant_fails_loudly_with_no_fallback \
  test_an_empty_constant_fails_the_same_way \
  test_the_real_build_script_is_still_readable_from_elsewhere
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
