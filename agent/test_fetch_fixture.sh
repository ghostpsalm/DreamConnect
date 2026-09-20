#!/usr/bin/env bash
#
# Tests for agent/fetch-fixture.sh (issue #46).
#
# Seam: fetch-fixture.sh has no internal seam once it is fetching a real
# fixture -- it reads its pin from a real, adjacent build.sh via BASH_SOURCE.
# To exercise the fetch/verify/mismatch branches hermetically (no network, and
# without the real ByteBuddy jar's actual bytes on hand) every case here runs
# against a sandbox holding its own synthetic build.sh with a sentinel pin and
# its own curl stub, the same shape agent/test_build.sh already uses for
# build.sh. Success against the sandbox's sentinel pin -- which no real
# ByteBuddy jar could satisfy -- is itself proof the pin was read from this
# sandbox's build.sh and not hardcoded or read from the real one.
#
# Run:  bash agent/test_fetch_fixture.sh      (also wired into ./run-tests.sh)
set -uo pipefail

[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"          # the real agent/ directory
FETCH_SH="$HERE/fetch-fixture.sh"
LIB_SH="$HERE/fixture-lib.sh"
NET_MARKER="NETWORK-BLOCKED-BY-TEST"

# --- tiny assert harness -----------------------------------------------------
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

assert_file_exists() { [ -e "$1" ] || fail "$2: expected file to exist: $1"; }
assert_file_absent() { [ -e "$1" ] && fail "$2: expected file NOT to exist: $1"; return 0; }

[ -f "$FETCH_SH" ] || { echo "FAIL: fetch-fixture.sh not found at $FETCH_SH"; exit 1; }
[ -f "$LIB_SH" ] || { echo "FAIL: fixture-lib.sh not found at $LIB_SH"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SENTINEL_VERSION="7.7.7-fixturetest"
GOOD_CONTENT="pretend-bytebuddy-bytes-fixture-content"
GOOD_SHA256="$(printf '%s' "$GOOD_CONTENT" | sha256sum | cut -d' ' -f1)"
JAR_NAME="byte-buddy-$SENTINEL_VERSION.jar"

# A sandbox with its own build.sh (sentinel pin, so success proves the pin was
# read from here and not the real agent/build.sh) and its own fetch-fixture.sh
# + fixture-lib.sh, so HERE inside the script resolves into the sandbox.
make_sandbox() {  # -> prints the sandbox path
  local sb
  sb="$(mktemp -d "$TMP/sandbox.XXXXXX")"
  cp -a "$FETCH_SH" "$sb/fetch-fixture.sh"
  cp -a "$LIB_SH" "$sb/fixture-lib.sh"
  mkdir -p "$sb/lib" "$sb/bin"
  cat > "$sb/build.sh" <<EOF
#!/usr/bin/env bash
BYTEBUDDY_VERSION="$SENTINEL_VERSION"
BB_SHA256="$GOOD_SHA256"
BB_URL="https://example.invalid/net/bytebuddy/byte-buddy/\$BYTEBUDDY_VERSION/byte-buddy-\$BYTEBUDDY_VERSION.jar"
EOF
  printf '%s\n' "$sb"
}

# curl stub that must never run: proves the case it guards makes no network call.
stub_curl_blocked() {  # sandbox
  cat > "$1/bin/curl" <<EOF
#!/usr/bin/env bash
echo "$NET_MARKER: fetch-fixture.sh invoked curl \$*" >&2
exit 7
EOF
  chmod +x "$1/bin/curl"
}

# curl stub that writes fixed bytes to whatever -o path it is given.
stub_curl_writes() {  # sandbox content
  cat > "$1/bin/curl" <<EOF
#!/usr/bin/env bash
out=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  prev="\$a"
done
printf '%s' '$2' > "\$out"
EOF
  chmod +x "$1/bin/curl"
}

# curl stub that fails without writing anything -- a dropped connection, a 404.
stub_curl_fails() {  # sandbox
  cat > "$1/bin/curl" <<EOF
#!/usr/bin/env bash
exit 22
EOF
  chmod +x "$1/bin/curl"
}

OUT=""; ERR=""; RC=0
run_fetch() {  # sandbox -- sets OUT (stdout), ERR (stderr), RC
  local sb="$1" errfile
  errfile="$(mktemp -p "$TMP")"
  OUT="$(cd "$sb" && PATH="$sb/bin:$PATH" DC_BYTEBUDDY_JAR="${DC_BYTEBUDDY_JAR:-}" \
        bash "$sb/fetch-fixture.sh" 2>"$errfile")"
  RC=$?
  ERR="$(cat "$errfile")"
  rm -f "$errfile"
}

test_a_cache_hit_with_a_matching_hash_needs_no_network() {
  local sb jar
  sb="$(make_sandbox)"
  jar="$sb/lib/$JAR_NAME"
  printf '%s' "$GOOD_CONTENT" > "$jar"
  stub_curl_blocked "$sb"

  DC_BYTEBUDDY_JAR="" run_fetch "$sb"

  assert_eq "$RC" "0" "cache hit: fetch-fixture.sh must succeed"
  assert_eq "$OUT" "$jar" "cache hit: must print the cached jar's path"
  assert_not_contains "$ERR" "$NET_MARKER" "cache hit: a matching cache needs no network"
  assert_file_exists "$jar" "cache hit: the verified jar must still be there"
}

test_a_mismatched_cached_jar_is_removed_and_fails_loudly() {
  local sb jar wrong_sha
  sb="$(make_sandbox)"
  jar="$sb/lib/$JAR_NAME"
  printf '%s' "wrong bytes entirely" > "$jar"
  wrong_sha="$(printf '%s' "wrong bytes entirely" | sha256sum | cut -d' ' -f1)"
  stub_curl_blocked "$sb"

  DC_BYTEBUDDY_JAR="" run_fetch "$sb"

  assert_ne "$RC" "0" "mismatched cache: fetch-fixture.sh must fail, not paper over it"
  assert_file_absent "$jar" "mismatched cache: the bad file must be removed"
  assert_contains "$ERR" "$jar" "mismatched cache: the failure must name the fixture"
  assert_contains "$ERR" "$GOOD_SHA256" "mismatched cache: the failure must name the expected hash"
  assert_contains "$ERR" "$wrong_sha" "mismatched cache: the failure must name the actual hash"
  assert_not_contains "$ERR" "$NET_MARKER" \
    "mismatched cache: a mismatch fails the run, it does not silently refetch"
}

test_an_absent_jar_is_fetched_and_verified() {
  local sb jar
  sb="$(make_sandbox)"
  jar="$sb/lib/$JAR_NAME"
  stub_curl_writes "$sb" "$GOOD_CONTENT"

  DC_BYTEBUDDY_JAR="" run_fetch "$sb"

  assert_eq "$RC" "0" "absent jar: fetch-fixture.sh must fetch and succeed"
  assert_eq "$OUT" "$jar" "absent jar: must print the freshly fetched jar's path"
  assert_file_exists "$jar" "absent jar: the fetched jar must be cached"
  assert_eq "$(sha256sum < "$jar" | cut -d' ' -f1)" "$GOOD_SHA256" \
    "absent jar: the cached jar must be the verified bytes"
}

test_a_fetch_failure_leaves_nothing_cached() {
  local sb jar
  sb="$(make_sandbox)"
  jar="$sb/lib/$JAR_NAME"
  stub_curl_fails "$sb"

  DC_BYTEBUDDY_JAR="" run_fetch "$sb"

  assert_ne "$RC" "0" "fetch failure: fetch-fixture.sh must fail"
  assert_file_absent "$jar" "fetch failure: nothing must be cached"
  assert_contains "$ERR" "fetch" "fetch failure: the failure must say fetching failed"
}

test_a_post_fetch_mismatch_is_not_cached() {
  local sb jar
  sb="$(make_sandbox)"
  jar="$sb/lib/$JAR_NAME"
  stub_curl_writes "$sb" "bytes that do not match the pin"

  DC_BYTEBUDDY_JAR="" run_fetch "$sb"

  assert_ne "$RC" "0" "post-fetch mismatch: fetch-fixture.sh must fail"
  assert_file_absent "$jar" "post-fetch mismatch: the bad download must not be left cached"
  assert_contains "$ERR" "$GOOD_SHA256" "post-fetch mismatch: the failure must name the expected hash"
}

test_dc_byteBuddy_jar_overrides_the_cache_path() {
  local sb override
  sb="$(make_sandbox)"
  override="$sb/elsewhere.jar"
  printf '%s' "$GOOD_CONTENT" > "$override"
  stub_curl_blocked "$sb"

  DC_BYTEBUDDY_JAR="$override" run_fetch "$sb"

  assert_eq "$RC" "0" "DC_BYTEBUDDY_JAR: fetch-fixture.sh must honour the override"
  assert_eq "$OUT" "$override" "DC_BYTEBUDDY_JAR: must print the overridden path, not lib/"
  assert_file_absent "$sb/lib/$JAR_NAME" \
    "DC_BYTEBUDDY_JAR: the default lib/ path must not be touched when overridden"
}

for CURRENT in \
  test_a_cache_hit_with_a_matching_hash_needs_no_network \
  test_a_mismatched_cached_jar_is_removed_and_fails_loudly \
  test_an_absent_jar_is_fetched_and_verified \
  test_a_fetch_failure_leaves_nothing_cached \
  test_a_post_fetch_mismatch_is_not_cached \
  test_dc_byteBuddy_jar_overrides_the_cache_path
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
echo "agent fixture fetch tests passed"
