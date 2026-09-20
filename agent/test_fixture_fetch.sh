#!/usr/bin/env bash
#
# Tests for agent/fixture-lib.sh -- the ByteBuddy pins, read out of the
# product's own agent/build.sh -- and for scripts/fetch-test-fixtures.sh, the
# one-time fetch that turns those pins into a verified jar (issue #46).
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
#   * "A fixture that cannot be verified against that constant must fail loudly
#     at fixture time: non-zero exit, naming the fixture and the mismatch. It
#     must never skip, and must never be reported as passing."
#   * "The fetch must happen at most once per machine. A cache already holding a
#     verified fixture must be reused without any network access on every
#     subsequent run."
#   * scripts/fetch-test-fixtures.sh prints the verified path on stdout and
#     nothing else, diagnostics on stderr, non-zero on any failure.
#
# Where the expected values come from (independent of any implementation):
#   Cases A-D drive the library against a *synthetic* build.sh this file writes,
#   holding sentinel pins chosen here -- 9.9.9-oracle and an 0123456789abcdef...
#   hash that is deliberately NOT the real ByteBuddy jar's. Nothing can produce
#   those values except by reading that file, which is the whole point: an
#   implementation carrying a hardcoded ByteBuddy hash passes a test written
#   against the real one and fails these. The expected URL in Case B is the
#   sentinel substituted into the template by hand.
#
#   No real SHA-256 appears anywhere in this file. The repository is required to
#   hold exactly one copy of that constant (agent/build.sh:12); a second one
#   here, even in an assertion, is the transcription the requirement forbids.
#
#   The fetch cases (F onwards) go further and pin their synthetic build.sh to
#   the hash of a few bytes this file wrote a moment earlier. That is what makes
#   them hermetic: the "artifact" the fetcher verifies is producible locally, so
#   the happy path is exercised without a jar, a JDK or the network, and the
#   stub curl is handed a URL at .invalid that could not resolve if it escaped.
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

# The fetcher (slice 2) and its sandbox's furniture. The URL is at .invalid --
# reserved by RFC 2606 and guaranteed never to resolve -- so a case that somehow
# escaped the stub would fail rather than reach the real Maven Central.
FETCH_SH="$(cd "$HERE/.." && pwd)/scripts/fetch-test-fixtures.sh"
S_FETCH_URL="https://example.invalid/byte-buddy-$S_VERSION.jar"
STUB_CURL_REFUSED="STUB-CURL-REFUSED"
FETCH_BYTES="not a jar; the fixture fetcher only ever hashes what it is handed"
# Absolute, because two cases run the fetcher under a PATH of their own making
# and `PATH=x cmd` in bash resolves cmd against the new PATH.
BASH_BIN="$(command -v bash)"
ENV_BIN="$(command -v env)"

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

assert_file_exists()  { [ -e "$1" ] || fail "$2: expected file to exist: $1"; }
assert_file_absent()  { [ -e "$1" ] && fail "$2: expected file NOT to exist: $1"; return 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$FIXTURE_LIB" ] || { echo "FAIL: fixture-lib.sh not found at $FIXTURE_LIB"; exit 1; }
[ -f "$REAL_BUILD_SH" ] || { echo "FAIL: build.sh not found at $REAL_BUILD_SH"; exit 1; }
[ -f "$FETCH_SH" ] || { echo "FAIL: fetch-test-fixtures.sh not found at $FETCH_SH"; exit 1; }

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

# --- the fetcher seam --------------------------------------------------------
#
# scripts/fetch-test-fixtures.sh has no internal seam either: like build.sh it
# is linear and cannot be sourced, so the boundary is "run it as a subprocess
# against a sandboxed copy of the repo and look at stdout, stderr, the exit
# code, and what is left in the cache directory".
#
# The sandbox is a two-directory skeleton -- agent/ and scripts/ -- because the
# fetcher finds fixture-lib.sh at ../agent/ relative to itself and the library
# then finds build.sh as its own sibling. Reproducing that shape is what makes
# a synthetic build.sh reachable at all; a `bash -c` would not exercise it.

write_fetch_build_sh() {  # path sha256
  cat > "$1" <<EOF
#!/usr/bin/env bash
set -euo pipefail

BYTEBUDDY_VERSION="$S_VERSION"
BB_SHA256="$2"
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
BB_URL="https://example.invalid/byte-buddy-\$BYTEBUDDY_VERSION.jar"
echo "$RAN_MARKER"
EOF
}

# Records every call, then serves $sb/curl-payload if the case put one there.
# Two observables, deliberately separate: the *existence* of $sb/curl-calls is
# "the network was reached", which several cases assert must never happen, and
# its contents are the URL, which one case asserts came from build.sh expanded.
write_curl_stub() {  # sandbox
  local sb="$1"
  cat > "$sb/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$sb/curl-calls"
out=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  prev="\$a"
done
if [ -f "$sb/curl-payload" ] && [ -n "\$out" ]; then
  cp "$sb/curl-payload" "\$out"
  exit 0
fi
echo "$STUB_CURL_REFUSED: \$*" >&2
exit 7
EOF
  chmod +x "$sb/bin/curl"
}

# The pin is the hash of bytes written here a moment ago, so "the artifact
# matches the pin" is reproducible on any box with no jar and no network.
make_fetch_sandbox() {  # -> prints a sandbox whose pin is $sb/good-bytes.jar's
  local sb sha
  sb="$(mktemp -d "$TMP/fetch.XXXXXX")"
  mkdir -p "$sb/agent" "$sb/scripts" "$sb/bin" "$sb/cache"
  cp "$FIXTURE_LIB" "$sb/agent/fixture-lib.sh"
  cp "$FETCH_SH" "$sb/scripts/fetch-test-fixtures.sh"
  printf '%s\n' "$FETCH_BYTES" > "$sb/good-bytes.jar"
  sha="$(sha256sum < "$sb/good-bytes.jar" | cut -d' ' -f1)"
  write_fetch_build_sh "$sb/agent/build.sh" "$sha"
  write_curl_stub "$sb"
  printf '%s\n' "$sb"
}

cached_jar() { printf '%s\n' "$1/cache/byte-buddy-$S_VERSION.jar"; }
sha_of()     { sha256sum < "$1" | cut -d' ' -f1; }
cache_count() { find "$1/cache" -mindepth 1 | wc -l; }
curl_ran()   { [ -f "$1/curl-calls" ] && echo yes || echo no; }

FETCH_PATH=""
run_fetch() {  # sandbox [VAR=VAL ...] -- sets OUT, ERR, RC
  local sb="$1"; shift
  OUT="$(cd "$sb" && PATH="${FETCH_PATH:-$sb/bin:$PATH}" LC_ALL=C \
         DC_FIXTURE_CACHE_DIR="$sb/cache" \
         "$ENV_BIN" -u DC_BYTEBUDDY_JAR "$@" \
         "$BASH_BIN" "$sb/scripts/fetch-test-fixtures.sh" 2>"$sb/stderr")"
  RC=$?
  ERR="$(cat "$sb/stderr")"
}

# Same looseness as test_build.sh's helper of the same name, and for the same
# reason: "the check could not be performed" is a category, not a wording.
reads_like_an_unrunnable_verifier() {  # text
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *"cannot verify"*|*"could not verify"*|*"unable to verify"*) return 0 ;;
    *"sha256sum not found"*|*"sha256sum not available"*) return 0 ;;
  esac
  return 1
}

# --- fetcher tests -----------------------------------------------------------

# Case F -- the state every box is in after its first run, and the one the
# requirement "at most once per machine" is really about. A verified cache entry
# is reused, and stdout carries the path and nothing else, because run-tests.sh
# assigns that stdout straight into DC_BYTEBUDDY_JAR.
test_a_verified_cache_entry_is_reused_without_touching_the_network() {
  local sb jar
  sb="$(make_fetch_sandbox)"
  jar="$(cached_jar "$sb")"
  cp "$sb/good-bytes.jar" "$jar"

  run_fetch "$sb"

  assert_eq "$RC" "0" "cache hit: a verified entry is a success"
  assert_eq "$OUT" "$jar" "cache hit: stdout is the jar path, and only that"
  assert_eq "$(curl_ran "$sb")" "no" "cache hit: nothing may reach the network"
  assert_not_contains "$OUT$ERR" "$RAN_MARKER" \
    "cache hit: build.sh must be read, never executed"
}

# Case G -- the fixture-time half of what #46 is for: a fixture that does not
# verify fails loudly, naming what it rejected and both hashes, and never
# reports itself as fine. It is also removed, for build.sh's own reason -- the
# cache is keyed on the file existing, so a bad copy left here would be
# re-rejected forever.
test_a_cache_entry_that_does_not_verify_fails_loudly_and_is_removed() {
  local sb jar bad
  sb="$(make_fetch_sandbox)"
  jar="$(cached_jar "$sb")"
  printf 'truncated download, not the pinned artifact\n' > "$jar"
  bad="$(sha_of "$jar")"

  run_fetch "$sb"

  assert_eq "$RC" "1" "bad cache entry: exit 1"
  assert_eq "$OUT" "" "bad cache entry: stdout is empty -- no path may be offered"
  assert_contains "$ERR" "$jar" "bad cache entry: stderr names the fixture it rejected"
  assert_contains "$ERR" "$(sha_of "$sb/good-bytes.jar")" \
    "bad cache entry: stderr shows the hash it expected"
  assert_contains "$ERR" "$bad" "bad cache entry: stderr shows the hash it got"
  assert_file_absent "$jar" \
    "bad cache entry: the rejected fixture must not be left to poison every later run"
  assert_eq "$(curl_ran "$sb")" "no" \
    "bad cache entry: a mismatch fails, it does not silently fetch over the top"
}

# Case H -- the once-per-box fetch. The URL is not restated here either: it must
# be the one build.sh declares, with $BYTEBUDDY_VERSION expanded, or curl would
# be handed a literal dollar sign and fetch nothing.
test_an_empty_cache_fetches_the_pinned_url_and_verifies_before_caching() {
  local sb jar
  sb="$(make_fetch_sandbox)"
  jar="$(cached_jar "$sb")"
  cp "$sb/good-bytes.jar" "$sb/curl-payload"

  run_fetch "$sb"

  assert_eq "$RC" "0" "empty cache: a verified download is a success"
  assert_eq "$OUT" "$jar" "empty cache: stdout is the cached jar path"
  assert_file_exists "$jar" "empty cache: the verified fixture is cached for next time"
  assert_eq "$(sha_of "$jar")" "$(sha_of "$sb/good-bytes.jar")" \
    "empty cache: the cached bytes are the ones that verified"
  assert_contains "$(cat "$sb/curl-calls")" "$S_FETCH_URL" \
    "empty cache: the URL comes from build.sh, with the version expanded"
  assert_eq "$(cache_count "$sb")" "1" \
    "empty cache: only the verified jar is left -- no temporary download beside it"
}

# Case I -- "the fetch must happen at most once per machine". Case F proves a
# populated cache is reused; this proves the fetcher is what populated it, so
# the second run of the gate on a fresh box is already offline.
test_a_second_run_makes_no_network_call_at_all() {
  local sb jar
  sb="$(make_fetch_sandbox)"
  jar="$(cached_jar "$sb")"
  cp "$sb/good-bytes.jar" "$sb/curl-payload"

  run_fetch "$sb"
  assert_eq "$RC" "0" "second run: the first run must succeed for this to mean anything"
  rm -f "$sb/curl-calls"

  run_fetch "$sb"
  assert_eq "$RC" "0" "second run: succeeds"
  assert_eq "$OUT" "$jar" "second run: prints the same cached path"
  assert_eq "$(curl_ran "$sb")" "no" "second run: the fetch happens once per box, not once per run"
}

# Case J -- a fetch that fails must leave the cache exactly as it found it:
# empty. An aborted download parked at the cache path is precisely the wedged
# cache build.sh's own removal exists to undo, and it must not be creatable here.
test_a_failed_fetch_leaves_nothing_behind_in_the_cache() {
  local sb
  sb="$(make_fetch_sandbox)"          # no curl-payload, so the stub refuses

  run_fetch "$sb"

  assert_ne "$RC" "0" "failed fetch: exit non-zero"
  assert_eq "$OUT" "" "failed fetch: stdout is empty"
  assert_contains "$ERR" "$S_FETCH_URL" "failed fetch: stderr names what it could not fetch"
  assert_eq "$(cache_count "$sb")" "0" \
    "failed fetch: no partial download may be left where a later run would trust it"
}

# Case K -- the mutation check in miniature, and the reason this whole issue
# exists. When the pin and the artifact disagree, the fetcher must say so and
# cache nothing: an unverified byte is never visible at the trusted path.
test_downloaded_bytes_that_do_not_verify_are_never_cached() {
  local sb
  sb="$(make_fetch_sandbox)"
  printf 'the pin and the artifact disagree\n' > "$sb/curl-payload"

  run_fetch "$sb"

  assert_eq "$RC" "1" "bad download: exit 1"
  assert_eq "$OUT" "" "bad download: stdout is empty -- nothing verified, nothing offered"
  assert_contains "$ERR" "$(sha_of "$sb/good-bytes.jar")" \
    "bad download: stderr shows the pinned hash it expected"
  assert_contains "$ERR" "$(sha_of "$sb/curl-payload")" \
    "bad download: stderr shows the hash it actually got"
  assert_eq "$(cache_count "$sb")" "0" \
    "bad download: unverified bytes must never reach the cache"
  assert_file_absent "$(cached_jar "$sb")" \
    "bad download: least of all at the path a later run trusts without asking"
}

# Case L -- the offline box's way through. An operator-supplied jar that
# verifies is used as it stands: no network, and nothing written to the cache,
# because the point of the override is a machine that cannot fetch.
test_a_verified_override_is_used_with_no_network_and_no_cache_write() {
  local sb
  sb="$(make_fetch_sandbox)"

  run_fetch "$sb" DC_BYTEBUDDY_JAR="$sb/good-bytes.jar"

  assert_eq "$RC" "0" "override: a verified override is a success"
  assert_eq "$OUT" "$sb/good-bytes.jar" "override: stdout is the operator's own path"
  assert_eq "$(curl_ran "$sb")" "no" "override: an override never fetches"
  assert_eq "$(cache_count "$sb")" "0" "override: an override is used, not copied into the cache"
}

# Case M -- and if it does not verify, that is the operator's mistake and they
# must hear it. Fetching over the top would answer a question they did not ask;
# deleting their file would be worse still, since it is not ours to remove.
test_an_override_that_does_not_verify_fails_without_deleting_it() {
  local sb marker
  sb="$(make_fetch_sandbox)"
  marker="the operator pointed at the wrong jar"
  printf '%s\n' "$marker" > "$sb/operator.jar"

  run_fetch "$sb" DC_BYTEBUDDY_JAR="$sb/operator.jar"

  assert_eq "$RC" "1" "bad override: exit 1"
  assert_eq "$OUT" "" "bad override: stdout is empty"
  assert_contains "$ERR" "$sb/operator.jar" "bad override: stderr names the file it rejected"
  assert_contains "$ERR" "$(sha_of "$sb/operator.jar")" "bad override: stderr shows the hash it got"
  assert_eq "$(cat "$sb/operator.jar")" "$marker" \
    "bad override: the operator's file is theirs -- verify it, never touch it"
  assert_eq "$(curl_ran "$sb")" "no" \
    "bad override: a rejected override fails loudly, it does not fetch over the top"
}

# Case N -- the requirement's "must never fall back to a hardcoded value",
# enforced one level up from Case C: an unreadable pin has to stop the fetcher
# before it reaches the network, because there is nothing left to verify against.
test_a_pin_that_cannot_be_read_stops_the_fetch_before_any_network_access() {
  local sb
  sb="$(make_fetch_sandbox)"
  cp "$sb/good-bytes.jar" "$sb/curl-payload"      # a fetch would otherwise succeed
  grep -v '^BB_SHA256=' "$sb/agent/build.sh" > "$sb/agent/build.sh.new" \
    && mv "$sb/agent/build.sh.new" "$sb/agent/build.sh"

  run_fetch "$sb"

  assert_ne "$RC" "0" "unreadable pin: exit non-zero"
  assert_eq "$OUT" "" "unreadable pin: stdout is empty -- no path, and so no fallback"
  assert_contains "$ERR" "could not read BB_SHA256" \
    "unreadable pin: stderr names the constant it could not read"
  assert_eq "$(curl_ran "$sb")" "no" \
    "unreadable pin: nothing may be fetched that could not then be verified"
  assert_eq "$(cache_count "$sb")" "0" "unreadable pin: nothing is cached"
}

# Every external command the fetcher runs, minus sha256sum. curl is included so
# that a fetcher wrongly sailing past the verifier check would reach the stub
# and be caught by the last assertion rather than failing on a missing tool.
FETCH_TOOLS="dirname sed mkdir mktemp mv rm cat cut"

toolbox_without_sha256sum() {  # sandbox -> prints a PATH dir
  local sb="$1" box t real
  box="$sb/bin-no-sha256sum"
  mkdir -p "$box"
  cp -a "$sb/bin/curl" "$box/curl"
  for t in $FETCH_TOOLS; do
    real="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$real" "$box/$t"
  done
  printf '%s\n' "$box"
}

# Case O -- the same distinction build.sh draws in its own words: a verifier
# that cannot run has learned nothing about the fixture, so it must fail closed
# without deleting it and without claiming to have rejected anything. Case G's
# removal is only ever justified by an observed mismatch.
#
# Not a skip if the PATH cannot be built: the box is constructed from a fixed
# list of symlinks, so an unmet precondition here is a real defect -- and #46
# exists because a check that skips still lets the gate print ALL TESTS PASSED.
test_a_verifier_that_cannot_run_fails_closed_without_deleting_the_fixture() {
  local sb jar box marker
  sb="$(make_fetch_sandbox)"
  jar="$(cached_jar "$sb")"
  marker="cached fixture bytes the fetcher must not touch"
  printf '%s\n' "$marker" > "$jar"
  box="$(toolbox_without_sha256sum "$sb")"

  ( PATH="$box"; command -v sha256sum >/dev/null 2>&1 ) \
    && fail "unrunnable verifier: could not construct a PATH without sha256sum"
  ( PATH="$box"; command -v rm >/dev/null 2>&1 ) \
    || fail "unrunnable verifier: no rm on the sandboxed PATH; an unwanted delete would be unreachable"

  FETCH_PATH="$box"
  run_fetch "$sb"
  FETCH_PATH=""

  assert_ne "$RC" "0" "unrunnable verifier: fail closed when the check cannot be run"
  assert_eq "$OUT" "" "unrunnable verifier: stdout is empty -- nothing was verified"
  assert_file_exists "$jar" "unrunnable verifier: the fixture was never checked, so it must not be deleted"
  assert_eq "$(cat "$jar" 2>/dev/null)" "$marker" \
    "unrunnable verifier: the fixture must be left byte-for-byte alone"
  assert_not_contains "$ERR" "rejected" \
    "unrunnable verifier: nothing was rejected -- the verifier never ran"
  reads_like_an_unrunnable_verifier "$ERR" \
    || fail "unrunnable verifier: stderr must say the check could not be performed, got [$ERR]"
  assert_eq "$(curl_ran "$sb")" "no" \
    "unrunnable verifier: an uncheckable cache entry is not a cache miss"
}

for CURRENT in \
  test_the_sha256_is_read_from_the_build_script_not_restated \
  test_the_url_is_read_with_the_version_expanded \
  test_a_missing_constant_fails_loudly_with_no_fallback \
  test_an_empty_constant_fails_the_same_way \
  test_the_real_build_script_is_still_readable_from_elsewhere \
  test_a_verified_cache_entry_is_reused_without_touching_the_network \
  test_a_cache_entry_that_does_not_verify_fails_loudly_and_is_removed \
  test_an_empty_cache_fetches_the_pinned_url_and_verifies_before_caching \
  test_a_second_run_makes_no_network_call_at_all \
  test_a_failed_fetch_leaves_nothing_behind_in_the_cache \
  test_downloaded_bytes_that_do_not_verify_are_never_cached \
  test_a_verified_override_is_used_with_no_network_and_no_cache_write \
  test_an_override_that_does_not_verify_fails_without_deleting_it \
  test_a_pin_that_cannot_be_read_stops_the_fetch_before_any_network_access \
  test_a_verifier_that_cannot_run_fails_closed_without_deleting_the_fixture
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
