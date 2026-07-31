#!/usr/bin/env bash
#
# Tests for agent/build.sh's ByteBuddy integrity check (issue #43).
#
# Seam: build.sh has no internal seam. It is a linear script that does real work
# from top to bottom and cannot be sourced, so the only boundary at which its
# behaviour is observable is "run the whole script as a subprocess against a
# sandboxed copy of agent/, then look at its exit code, its output, and the
# artifacts it did or did not produce".
#
# Contract under test (issue #43, "Fix"):
#     Pin the expected SHA-256 as a constant and verify after download, e.g.
#     `echo "<sha256>  $BB_JAR" | sha256sum -c` (fail the build on mismatch).
# and, from the same issue's "Why it matters", the threat being defended
# against is "a poisoned local Maven cache ... and the payload runs as root on
# every box built from that machine". A cached jar is the case where curl never
# runs, so a check that only fires on the download path defends against nothing
# the issue names: verification has to be unconditional.
#
# Where the expected hash comes from (independent of any implementation):
#     https://repo1.maven.org/maven2/net/bytebuddy/byte-buddy/1.18.11/\
#         byte-buddy-1.18.11.jar.sha256
#     fetched 2026-08-01 -> e32f454c2c1f4aca982f9ec764ed892d9a6eee7e8a77f435\
#         cbdd180f6ffdb821
#     Maven Central's own sidecar, byte for byte identical to `sha256sum` of the
#     jar today's builds already link against.
#
# Safety rails:
#   * every case runs against a copy of agent/ in a mktemp -d, so the real
#     agent/lib cache is only ever read, never written (asserted at the end);
#   * a `curl` stub is prepended to PATH, so the suite is hermetic: it cannot
#     reach the network, and an implementation that tried to re-fetch instead of
#     failing would be caught rather than silently going online in CI.
#
# Run:  bash agent/test_build.sh      (also wired into ./run-tests.sh)
set -uo pipefail

[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"          # the real agent/ directory
BUILD_SH="$HERE/build.sh"
BB_VERSION="1.18.11"
BB_JAR_NAME="byte-buddy-$BB_VERSION.jar"
BB_SHA256="e32f454c2c1f4aca982f9ec764ed892d9a6eee7e8a77f435cbdd180f6ffdb821"
REAL_CACHE="$HERE/lib/$BB_JAR_NAME"
NET_MARKER="NETWORK-BLOCKED-BY-TEST"

# --- tiny assert harness -----------------------------------------------------
FAILURES=0
SKIPPED=0
CURRENT="<none>"

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }
skip() { echo "  SKIP: $*"; SKIPPED=$((SKIPPED + 1)); }

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

[ -f "$BUILD_SH" ] || { echo "FAIL: build.sh not found at $BUILD_SH"; exit 1; }

# --- the seam ----------------------------------------------------------------

# A sandbox is a copy of everything build.sh reads ($HERE/boot, $HERE/src) plus
# build.sh itself, so the HERE it computes from $0 lands inside the sandbox and
# LIB/BUILD/DIST all follow it there. lib/ starts empty; each case populates it.
make_sandbox() {  # -> prints the sandbox path
  local sb
  sb="$(mktemp -d "$TMP/sandbox.XXXXXX")"
  cp -a "$BUILD_SH" "$sb/build.sh"
  cp -a "$HERE/boot" "$HERE/src" "$sb/"
  mkdir -p "$sb/lib" "$sb/bin"
  cat > "$sb/bin/curl" <<EOF
#!/usr/bin/env bash
echo "$NET_MARKER: build.sh invoked curl \$*" >&2
exit 7
EOF
  chmod +x "$sb/bin/curl"
  printf '%s\n' "$sb"
}

OUT=""; RC=0
run_build() {  # sandbox -- sets OUT (stdout+stderr) and RC
  OUT="$(cd "$1" && PATH="$1/bin:$PATH" timeout 600 bash "$1/build.sh" 2>&1)"
  RC=$?
}

# Deliberately loose: the issue suggests `sha256sum -c` (which says "FAILED" and
# "computed checksum did NOT match") but a hand-rolled compare is just as valid,
# so any of the words a rejection could reasonably use counts. This is a
# diagnostic-quality assertion; the load-bearing ones below are the artifacts.
reads_like_an_integrity_failure() {  # text
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *failed*|*mismatch*|*"did not match"*|*checksum*|*sha256*|*sha-256*) return 0 ;;
  esac
  return 1
}

# A stand-in for a legitimately cached jar has to *be* the real jar: the pinned
# hash is byte-buddy-1.18.11.jar's own, and nothing else will hash to it. Look
# for one locally (never downloading one) and verify it before use.
fixture_jar() {  # -> prints a path whose sha256 == BB_SHA256, or fails
  local cand
  for cand in "${DC_BYTEBUDDY_JAR:-}" "$REAL_CACHE"; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    [ "$(sha256sum < "$cand" | cut -d' ' -f1)" = "$BB_SHA256" ] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

cache_fingerprint() {
  if [ -e "$REAL_CACHE" ]; then sha256sum < "$REAL_CACHE"; else echo "<absent>"; fi
  [ -e "$HERE/target" ] && echo "target/ present" || echo "target/ absent"
}
CACHE_BEFORE="$(cache_fingerprint)"

# --- tests -------------------------------------------------------------------

# Case A -- the cache-poisoning case issue #43 is actually about. The jar is
# already present, so curl never runs; verification must still happen, and on
# mismatch the build must stop. "Fail the build on mismatch" means nothing is
# compiled, nothing is packaged, and above all nothing is embedded: the whole
# point is that a poisoned jar must never reach dreamconnect-agent.jar, which
# runs as root inside ScreenConnect's JVM.
test_a_poisoned_cached_jar_fails_the_build_before_anything_is_produced() {
  local sb
  sb="$(make_sandbox)"
  printf 'this is not a jar, it is a payload\n' > "$sb/lib/$BB_JAR_NAME"

  run_build "$sb"

  assert_ne "$RC" "0" "poisoned cached jar: build.sh must exit non-zero"
  assert_file_absent "$sb/target/dist/dreamconnect-agent.jar" \
    "poisoned cached jar: the agent jar must never be assembled"
  assert_file_absent "$sb/target/dist/dreamconnect-boot.jar" \
    "poisoned cached jar: the build must stop at verification, before packaging"
  assert_not_contains "$OUT" ">> compile" \
    "poisoned cached jar: the build must stop at verification, before compiling"
  reads_like_an_integrity_failure "$OUT" \
    || fail "poisoned cached jar: output must say the checksum did not match, got [$OUT]"
  assert_contains "$OUT" "$BB_JAR_NAME" \
    "poisoned cached jar: the failure must name the jar it rejected"
  assert_not_contains "$OUT" "$NET_MARKER" \
    "poisoned cached jar: a mismatch fails the build, it does not re-fetch"
}

# Case C -- rejecting the jar is only half the job; the build must also not wedge
# itself on it. Required behaviour, from the breaker's reproduction recorded in
# factory/CHECKPOINT.md slice 1 ("poisoned cached jar is never removed on
# failure, wedging the cache forever"): an interrupted download (Ctrl-C, dropped
# connection, full disk) leaves a truncated jar in lib/, and because the cache is
# keyed on the file merely existing, every later run -- on a healthy network --
# rejects that same stale file. Recovery must not require the operator to know
# about, and hand-delete, a gitignored path no document mentions.
#
# Not in tension with Case A's "does not re-fetch": that is about one run, which
# must abort rather than retry. This is about the *next* run, which must be free
# to fetch again. Hermetically, "free to fetch again" is observable only as
# build.sh reaching curl -- the stub then fails it, which is fine and expected.
test_a_poisoned_cached_jar_is_removed_so_the_next_run_can_recover() {
  local sb second
  sb="$(make_sandbox)"
  printf 'truncated download, not a jar\n' > "$sb/lib/$BB_JAR_NAME"

  run_build "$sb"
  assert_ne "$RC" "0" "poisoned cached jar: build.sh must exit non-zero"
  assert_file_absent "$sb/lib/$BB_JAR_NAME" \
    "poisoned cached jar: the rejected file must be removed, not left to poison every later run"

  run_build "$sb"
  second="$OUT"
  assert_contains "$second" "$NET_MARKER" \
    "poisoned cached jar: the next run must be free to re-fetch, not re-reject the same stale file"
}

# Deliberately loose, like reads_like_an_integrity_failure: any phrasing saying
# the check could not be *performed* counts. Bash's own "sha256sum: command not
# found" deliberately does not match -- that diagnostic already appears today,
# alongside a message wrongly claiming the jar was rejected and removed.
reads_like_an_unrunnable_verifier() {  # text
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *"cannot verify"*|*"can not verify"*|*"can't verify"*|*"unable to verify"*) return 0 ;;
    *"cannot be verified"*|*"could not verify"*|*"couldn't verify"*) return 0 ;;
    *"sha256sum not found"*|*"sha256sum not available"*) return 0 ;;
    *"sha256sum not installed"*|*"no sha256sum"*) return 0 ;;
    *"sha256sum is required"*|*"sha256sum required"*|*"requires sha256sum"*) return 0 ;;
  esac
  return 1
}

# Every external command build.sh runs, minus sha256sum. dirname is needed for
# its HERE=... line and mkdir/rm for the steps before verification; the compile
# and package tools are included so that a build.sh which wrongly sailed past
# verification would fail on its own merits rather than on a missing tool.
BUILD_SH_TOOLS="dirname mkdir rm cp cat ls find javac jar unzip"

toolbox_without_sha256sum() {  # sandbox -> prints a PATH dir
  local sb="$1" box t real
  box="$sb/bin-no-sha256sum"
  mkdir -p "$box"
  cp -a "$sb/bin/curl" "$box/curl"
  for t in $BUILD_SH_TOOLS; do
    real="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$real" "$box/$t"
  done
  printf '%s\n' "$box"
}

# Case D -- Case C's delete is only ever justified by an *observed* mismatch.
# Required behaviour, from the breaker's finding recorded in
# factory/CHECKPOINT.md ("rm -f fires on ANY sha256sum nonzero exit (incl.
# tool-missing/127), not just genuine mismatch, misleading 'removed the rejected
# jar' message and could delete a good jar"): when the verifier itself cannot
# run, build.sh has learned nothing about the jar, so it must fail closed
# *without* touching it and without claiming to have rejected anything.
#
# Simulated with a PATH holding every external build.sh needs except sha256sum:
# a minimal build container, a mangled PATH, or macOS (shasum, no sha256sum).
# `rm` is deliberately present so the unwanted deletion stays reachable -- if it
# were missing, a surviving jar would prove nothing, so the guard below skips
# rather than reporting a hollow pass.
#
# The cached bytes are a marker, not a real jar, on purpose: build.sh never
# hashes them here, so whether they *would* have verified is precisely what it
# does not know. Unverified is not the same as rejected.
test_an_unrunnable_verifier_fails_closed_without_destroying_the_cached_jar() {
  local sb box tmo bsh marker lower
  sb="$(make_sandbox)"
  marker="cached jar bytes that build.sh must not touch"
  printf '%s\n' "$marker" > "$sb/lib/$BB_JAR_NAME"
  box="$(toolbox_without_sha256sum "$sb")"

  ( PATH="$box"; command -v sha256sum >/dev/null 2>&1 ) \
    && { skip "could not construct a PATH without sha256sum"; return 0; }
  ( PATH="$box"; command -v rm >/dev/null 2>&1 ) \
    || { skip "no rm on the sandboxed PATH; an unwanted delete would be unreachable"; return 0; }

  tmo="$(command -v timeout)"; bsh="$(command -v bash)"
  OUT="$(cd "$sb" && PATH="$box" "$tmo" 600 "$bsh" "$sb/build.sh" 2>&1)"
  RC=$?

  assert_ne "$RC" "0" \
    "unrunnable verifier: build.sh must fail closed when it cannot run the check"
  assert_not_contains "$OUT" ">> compile" \
    "unrunnable verifier: nothing may be compiled from a jar that was never verified"
  assert_file_exists "$sb/lib/$BB_JAR_NAME" \
    "unrunnable verifier: the cached jar was never checked, so it must not be deleted"
  assert_eq "$(cat "$sb/lib/$BB_JAR_NAME" 2>/dev/null)" "$marker" \
    "unrunnable verifier: the cached jar must be left byte-for-byte alone"

  lower="$(printf '%s' "$OUT" | tr '[:upper:]' '[:lower:]')"
  assert_not_contains "$lower" "removed the rejected jar" \
    "unrunnable verifier: build.sh must not claim it removed a jar it never verified"
  assert_not_contains "$lower" "rejected jar" \
    "unrunnable verifier: nothing was rejected -- the verifier never ran"
  reads_like_an_unrunnable_verifier "$OUT" \
    || fail "unrunnable verifier: output must say the check could not be performed (e.g. 'sha256sum not found, cannot verify'), got [$OUT]"
  assert_not_contains "$OUT" "$NET_MARKER" \
    "unrunnable verifier: a missing verifier is not a cache miss; build.sh must not re-fetch"
}

# Case B -- the same check must not reject a jar that is what it claims to be.
# Guards the degenerate 'fix' of always failing, and a mistyped pinned hash.
test_a_correctly_hashed_cached_jar_still_builds() {
  local sb src t
  src="$(fixture_jar)" || {
    skip "no locally available byte-buddy-$BB_VERSION.jar matching the pinned hash" \
         "(set DC_BYTEBUDDY_JAR=/path/to/$BB_JAR_NAME, or build once to populate agent/lib/)"
    return 0
  }
  for t in javac jar unzip; do
    command -v "$t" >/dev/null || { skip "$t not installed; cannot run a full build"; return 0; }
  done

  sb="$(make_sandbox)"
  cp "$src" "$sb/lib/$BB_JAR_NAME"

  run_build "$sb"

  reads_like_an_integrity_failure "$OUT" \
    && fail "correctly hashed cached jar: must not be reported as a checksum failure, got [$OUT]"
  assert_not_contains "$OUT" "$NET_MARKER" \
    "correctly hashed cached jar: a verified cache hit needs no network"
  assert_eq "$RC" "0" "correctly hashed cached jar: build.sh succeeds"
  assert_file_exists "$sb/target/dist/dreamconnect-agent.jar" \
    "correctly hashed cached jar: the agent jar is still assembled"
}

# Safety rail: whatever the two cases above did, they did it in the sandbox.
test_the_real_agent_lib_cache_is_never_written() {
  assert_eq "$(cache_fingerprint)" "$CACHE_BEFORE" \
    "the real agent/lib cache and agent/target are left exactly as they were"
}

for CURRENT in \
  test_a_poisoned_cached_jar_fails_the_build_before_anything_is_produced \
  test_a_poisoned_cached_jar_is_removed_so_the_next_run_can_recover \
  test_an_unrunnable_verifier_fails_closed_without_destroying_the_cached_jar \
  test_a_correctly_hashed_cached_jar_still_builds \
  test_the_real_agent_lib_cache_is_never_written
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
echo "agent build shell tests passed"
