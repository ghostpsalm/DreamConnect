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
# Where the expected hash comes from (independent of any implementation): the
# pin lives once, in agent/build.sh's own BYTEBUDDY_VERSION/BB_SHA256/BB_URL
# constants -- Maven Central's own .sha256 sidecar, byte for byte identical to
# `sha256sum` of the jar today's builds already link against -- and this suite
# reads it live via agent/fixture-lib.sh (issue #46) rather than transcribing
# a second copy that could drift from the one build.sh actually enforces.
#
# Safety rails:
#   * every case runs against a copy of agent/ in a mktemp -d, so the real
#     agent/lib cache is only ever read, never written (asserted at the end);
#   * a `curl` stub is prepended to PATH, so the suite is hermetic: it cannot
#     reach the network, and an implementation that tried to re-fetch instead of
#     failing would be caught rather than silently going online in CI.
#
# Run:  bash agent/test_build.sh      (also wired into ./run-tests.sh, after
#       agent/fetch-fixture.sh has warmed agent/lib/ -- see run-tests.sh)
set -uo pipefail

[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"          # the real agent/ directory
BUILD_SH="$HERE/build.sh"
source "$HERE/fixture-lib.sh"
BB_VERSION="$(bb_version "$BUILD_SH")" || exit 1
BB_SHA256="$(bb_sha256 "$BUILD_SH")" || exit 1
BB_JAR_NAME="byte-buddy-$BB_VERSION.jar"
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
#
# The optional parent argument exists only for Case E: the sandbox path is the
# variable under test there, so everything else about the sandbox must stay
# byte-for-byte what Case A gets, or a difference in outcome would not be
# attributable to the path.
make_sandbox() {  # [parent_dir] -> prints the sandbox path
  local sb parent="${1:-$TMP}"
  sb="$(mktemp -d "$parent/sandbox.XXXXXX")"
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
# LC_ALL=C because several assertions below are about diagnostics coreutils
# emits ("FAILED open or read", "improperly formatted"). Those strings are
# translated, so under a localised box the negative assertions would silently
# stop discriminating -- they would pass against the broken implementation for
# the wrong reason. Pinning the locale makes the absence mean something.
run_build() {  # sandbox -- sets OUT (stdout+stderr) and RC
  OUT="$(cd "$1" && PATH="$1/bin:$PATH" LC_ALL=C timeout 600 bash "$1/build.sh" 2>&1)"
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

# Case E -- issue #49. The verify step must not route $BB_JAR through
# `sha256sum -c`'s *line format*, because that format is a parser: it reads the
# filename back out of "<hash>  <path>" using its own escaping rules, and a path
# it cannot parse exits 1 in exactly the way a genuine mismatch does.
#
# Where the trigger comes from (independent of build.sh -- reproduced against
# GNU coreutils 9.10 before this test was written):
#
#     $ echo "$h  /tmp/we<newline>ird/f.jar" | sha256sum -c -
#     sha256sum: /tmp/we: No such file or directory
#     /tmp/we: FAILED open or read
#     sha256sum: WARNING: 1 line is improperly formatted
#     sha256sum: WARNING: 1 listed file could not be read
#     ; echo $?  ->  1
#
# Note what that output does *not* contain: the jar. The line was split at the
# newline, so the check ran against a truncated path, the jar was never hashed,
# and nothing downstream can tell that apart from "the bytes are wrong".
#
# The issue's stated backslash trigger does NOT reproduce on coreutils 9.10 (GNU
# unescapes only when the line *starts* with a backslash, so a mid-path one is
# passed through and the check succeeds); a test written to the issue's literal
# wording would pass before the fix and prove nothing. The newline is the real
# trigger, so that is what this case uses.
#
# Asserted here is the observable consequence of the contract's "avoid the parse
# entirely", not any particular way of avoiding it: whatever build.sh does, a
# poisoned jar in an awkward path must be rejected *as a checksum failure naming
# the jar*, with none of the parser's own diagnostics leaking out. The name is
# the load-bearing assertion -- the parse cannot produce it, and any
# hash-the-file-directly implementation gets it for free.
awkward_parent() {  # -> prints a dir whose name contains a newline, or fails
  local p
  p="$TMP/awk
ward"
  mkdir -p "$p" 2>/dev/null || return 1
  [ -d "$p" ] || return 1
  printf '%s\n' "$p"
}

test_a_path_the_checksum_line_format_cannot_parse_is_still_a_real_verification() {
  local sb parent
  parent="$(awkward_parent)" || {
    skip "this filesystem will not hold a directory name containing a newline"
    return 0
  }
  sb="$(make_sandbox "$parent")"
  printf 'this is not a jar, it is a payload\n' > "$sb/lib/$BB_JAR_NAME"

  run_build "$sb"

  assert_ne "$RC" "0" "unparseable path: a poisoned jar must still fail the build"
  assert_not_contains "$OUT" ">> compile" \
    "unparseable path: the build must stop at verification, before compiling"

  # The discriminators. Today's `echo ... | sha256sum -c -` cannot satisfy these:
  # it names the truncated path instead of the jar, and leaks the parser's
  # complaint about a line it could not read.
  assert_contains "$OUT" "$BB_JAR_NAME" \
    "unparseable path: the failure must name the jar it actually hashed and rejected"
  assert_not_contains "$OUT" "FAILED open or read" \
    "unparseable path: the jar was readable -- an open/read failure means the path was misparsed, not the bytes checked"
  assert_not_contains "$OUT" "improperly formatted" \
    "unparseable path: nothing may be parsing a checksum line format at all"
  assert_not_contains "$OUT" "No such file or directory" \
    "unparseable path: the jar exists; a not-found diagnostic means a truncated path was hashed"

  reads_like_an_integrity_failure "$OUT" \
    || fail "unparseable path: output must say the checksum did not match, got [$OUT]"
  assert_file_absent "$sb/lib/$BB_JAR_NAME" \
    "unparseable path: the jar really was verified and really was bad, so Case C's removal still applies"
  assert_not_contains "$OUT" "$NET_MARKER" \
    "unparseable path: a mismatch fails the build, it does not re-fetch"
}

# Case F -- the other half of #49, and the branch the fix newly creates. Hashing
# the file directly can fail for reasons that say nothing about its contents:
# unreadable file, I/O error. That is the same shape as Case D's missing
# sha256sum, and it must land on the same answer, for the same reason -- build.sh
# has learned nothing about the jar, so it must fail closed without deleting it
# and without claiming to have rejected anything.
#
# Without this case, the obvious fix to Case E ("|| { rm -f; echo rejected; }"
# around the hash) re-introduces #43's defect one line further down.
#
# chmod 000 is a no-op for root, which is why the suite refuses to run as root
# (line 38) -- and it is still skipped rather than asserted if the file stays
# readable, so a box with CAP_DAC_OVERRIDE reports no coverage instead of a
# hollow pass.
test_a_jar_that_cannot_be_hashed_is_not_reported_as_rejected() {
  local sb lower
  sb="$(make_sandbox)"
  printf 'cached jar bytes that build.sh must not touch\n' > "$sb/lib/$BB_JAR_NAME"
  chmod 000 "$sb/lib/$BB_JAR_NAME" 2>/dev/null || true
  if [ -r "$sb/lib/$BB_JAR_NAME" ] && head -c1 "$sb/lib/$BB_JAR_NAME" >/dev/null 2>&1; then
    skip "chmod 000 did not make the jar unreadable here; the unhashable branch is unreachable"
    return 0
  fi

  run_build "$sb"

  assert_ne "$RC" "0" \
    "unhashable jar: build.sh must fail closed when it cannot hash the file"
  assert_not_contains "$OUT" ">> compile" \
    "unhashable jar: nothing may be compiled from a jar that was never verified"
  assert_file_exists "$sb/lib/$BB_JAR_NAME" \
    "unhashable jar: the jar was never hashed, so it must not be deleted"

  lower="$(printf '%s' "$OUT" | tr '[:upper:]' '[:lower:]')"
  assert_not_contains "$lower" "rejected jar" \
    "unhashable jar: nothing was rejected -- the hash was never computed"
  reads_like_an_unrunnable_verifier "$OUT" \
    || fail "unhashable jar: output must say the check could not be performed, got [$OUT]"
  assert_not_contains "$OUT" "$NET_MARKER" \
    "unhashable jar: an unreadable cache entry is not a cache miss; build.sh must not re-fetch"
}

# Case B -- the same check must not reject a jar that is what it claims to be.
# Guards the degenerate 'fix' of always failing, and a mistyped pinned hash.
#
# This is the happy-path case issue #46 is about: on a clean checkout with no
# pre-populated cache, an unmet fixture dependency must never be a silent
# SKIP -- run-tests.sh warms this cache with agent/fetch-fixture.sh precisely
# so this case always runs, and a build.sh that can never succeed has nowhere
# left to hide.
test_a_correctly_hashed_cached_jar_still_builds() {
  local sb src t
  src="$(fixture_jar)" || {
    fail "correctly hashed cached jar: no locally available byte-buddy-$BB_VERSION.jar matching the pinned hash" \
         "(run agent/fetch-fixture.sh, or set DC_BYTEBUDDY_JAR=/path/to/$BB_JAR_NAME)"
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
  test_a_path_the_checksum_line_format_cannot_parse_is_still_a_real_verification \
  test_a_jar_that_cannot_be_hashed_is_not_reported_as_rejected \
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
