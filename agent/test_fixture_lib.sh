#!/usr/bin/env bash
#
# Tests for agent/fixture-lib.sh (issue #46).
#
# Contract under test: bb_version / bb_sha256 / bb_url read the ByteBuddy pin
# live out of a given build.sh, so the pin exists in exactly one place. A
# hardcoded implementation would pass against the real agent/build.sh by
# accident, so every load-bearing case here drives the library against a
# synthetic build.sh holding sentinel values nothing else could produce, and
# a tripwire that fires if the library ever sources it instead of reading it.
#
# Run:  bash agent/test_fixture_lib.sh      (also wired into ./run-tests.sh)
set -uo pipefail

[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"          # the real agent/ directory
LIB_SH="$HERE/fixture-lib.sh"
REAL_BUILD_SH="$HERE/build.sh"

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

assert_matches() {  # value pattern label
  case "$1" in
    $2) ;;
    *) fail "$3: expected [$1] to match pattern [$2]" ;;
  esac
}

[ -f "$LIB_SH" ] || { echo "FAIL: fixture-lib.sh not found at $LIB_SH"; exit 1; }
[ -f "$REAL_BUILD_SH" ] || { echo "FAIL: build.sh not found at $REAL_BUILD_SH"; exit 1; }

source "$LIB_SH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SENTINEL_VERSION="9.9.9-oracle"
SENTINEL_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
export TRIPWIRE_LOG="$TMP/tripwire.log"

# A synthetic build.sh carrying sentinel constants nothing else could produce,
# plus a tripwire that appends to TRIPWIRE_LOG if it is ever executed or
# sourced -- reading NAME="..." with sed must never do either.
make_synthetic_build_sh() {  # [omit_sha256] -> prints the synthetic path
  local f="$TMP/build-$RANDOM.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'echo "SYNTHETIC-BUILD-SH-RAN" >> "$TRIPWIRE_LOG"'
    echo "BYTEBUDDY_VERSION=\"$SENTINEL_VERSION\""
    case "${1:-}" in
      omit_sha256) ;;
      empty_sha256) echo 'BB_SHA256=""' ;;
      *) echo "BB_SHA256=\"$SENTINEL_SHA256\"" ;;
    esac
    echo 'BB_URL="https://repo1.maven.org/maven2/net/bytebuddy/byte-buddy/$BYTEBUDDY_VERSION/byte-buddy-$BYTEBUDDY_VERSION.jar"'
  } > "$f"
  printf '%s\n' "$f"
}

test_the_sha256_is_read_from_the_build_script_not_restated() {
  local synth got
  synth="$(make_synthetic_build_sh)"
  got="$(bb_sha256 "$synth")" || fail "expected bb_sha256 to succeed against a synthetic build.sh"
  assert_eq "$got" "$SENTINEL_SHA256" "bb_sha256 must return the synthetic build.sh's own constant"
  [ -e "$TRIPWIRE_LOG" ] \
    && fail "bb_sha256 must read the constant, not execute or source the file (tripwire fired)"
}

test_the_version_is_read_from_the_build_script_not_restated() {
  local synth got
  synth="$(make_synthetic_build_sh)"
  got="$(bb_version "$synth")" || fail "expected bb_version to succeed against a synthetic build.sh"
  assert_eq "$got" "$SENTINEL_VERSION" "bb_version must return the synthetic build.sh's own constant"
}

test_the_url_is_read_with_the_version_expanded() {
  local synth got expected
  synth="$(make_synthetic_build_sh)"
  expected="https://repo1.maven.org/maven2/net/bytebuddy/byte-buddy/$SENTINEL_VERSION/byte-buddy-$SENTINEL_VERSION.jar"
  got="$(bb_url "$synth")" || fail "expected bb_url to succeed against a synthetic build.sh"
  assert_eq "$got" "$expected" "bb_url must expand \$BYTEBUDDY_VERSION textually, not print it literally"
}

test_a_missing_constant_fails_loudly_with_no_fallback() {
  local synth out rc
  synth="$(make_synthetic_build_sh omit_sha256)"
  out="$(bb_sha256 "$synth" 2>&1 1>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "a missing BB_SHA256 must fail, not silently fall back to anything"
  assert_contains "$out" "BB_SHA256" "the failure must name the constant it could not read"
  assert_contains "$out" "$synth" "the failure must name the file it could not read it from"
  [ -z "$(bb_sha256 "$synth" 2>/dev/null)" ] \
    || fail "a missing constant must print nothing to stdout, never a fallback value"
}

test_an_empty_constant_fails_the_same_way() {
  local synth out rc
  synth="$(make_synthetic_build_sh empty_sha256)"
  out="$(bb_sha256 "$synth" 2>&1 1>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "an empty BB_SHA256=\"\" must fail exactly like a missing one"
  assert_contains "$out" "BB_SHA256" "the failure must name the constant it could not read"
}

test_the_real_build_script_is_still_readable_from_elsewhere() {
  local sha version url
  sha="$(bb_sha256 "$REAL_BUILD_SH")" || fail "bb_sha256 must succeed against the real agent/build.sh"
  version="$(bb_version "$REAL_BUILD_SH")" || fail "bb_version must succeed against the real agent/build.sh"
  url="$(bb_url "$REAL_BUILD_SH")" || fail "bb_url must succeed against the real agent/build.sh"
  # Deliberately not comparing against a hardcoded hash: doing so would be the
  # second transcription issue #46's requirements forbid. Shape-only checks.
  assert_eq "${#sha}" "64" "the real pin must be a 64-character sha256"
  assert_matches "$sha" '[0-9a-f]*' "the real pin must be lowercase hex"
  assert_matches "$version" '[0-9]*.[0-9]*.[0-9]*' "the real pin must look like a version"
  assert_contains "$url" "$version" "the real URL must contain the real version"
  assert_contains "$url" "byte-buddy" "the real URL must point at byte-buddy"
}

for CURRENT in \
  test_the_sha256_is_read_from_the_build_script_not_restated \
  test_the_version_is_read_from_the_build_script_not_restated \
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
echo "agent fixture pin tests passed"
