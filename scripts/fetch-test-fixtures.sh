#!/usr/bin/env bash
# Put a verified ByteBuddy jar in a per-box cache, once, and print its path (#46).
#
# This is the single sanctioned network access in the whole test estate, and it
# lives here rather than inside a suite on purpose: agent/test_build.sh keeps its
# curl stub and stays hermetic, and the one line that may reach the internet is
# visible in ./run-tests.sh instead of buried in a test helper.
#
# Why it has to exist at all: the only case proving build.sh can *succeed*
# (test_a_correctly_hashed_cached_jar_still_builds) needs a real jar hashing to
# the pinned constant, agent/lib/ is gitignored, and that case used to SKIP on
# every clean checkout -- so a permanently broken build.sh, or the mistyped
# BB_SHA256 that #43 exists to catch, still passed the gate.
#
# Contract, because run-tests.sh consumes it:
#   stdout  the verified jar's path, and nothing else
#   stderr  every diagnostic and progress line
#   status  0 only when the path printed has been hashed and matched
#
# Usage:  DC_BYTEBUDDY_JAR="$(scripts/fetch-test-fixtures.sh)"
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/agent/fixture-lib.sh"

die() { echo "fetch-test-fixtures.sh: $*" >&2; exit 1; }

# Hash the file directly rather than through `sha256sum -c`'s "<hash>  <path>"
# line format, for the reason #49 records in agent/build.sh: that format is a
# parser, and a path it cannot read back out exits 1 in exactly the way a real
# mismatch does. Redirecting the file in hands sha256sum no path to parse.
#
# A failure here is "not hashed", never "did not match" -- an unreadable file
# says nothing about its bytes, so callers below fail closed and leave it alone.
hash_file() {  # path -> prints its sha256, or returns 1 having printed nothing
  local h
  h="$(sha256sum < "$1")" || return 1
  h="${h%% *}"
  [ -n "$h" ] || return 1
  printf '%s\n' "$h"
}

report_mismatch() {  # path expected actual
  echo "fetch-test-fixtures.sh: SHA-256 mismatch for $1" >&2
  echo "  expected $2" >&2
  echo "  actual   $3" >&2
}

# The pins come from agent/build.sh, never from here. A second transcription of
# the hash could disagree with the product's, and a fixture verified against the
# wrong constant would prove the build works against a jar no install uses.
# Unreadable is fatal and silent on stdout: a fallback would be that second copy.
BB_VERSION="$(bb_version)" || die "could not read the ByteBuddy version from agent/build.sh"
BB_SHA256="$(bb_sha256)"   || die "could not read the pinned SHA-256 from agent/build.sh"
BB_URL="$(bb_url)"         || die "could not read the ByteBuddy URL from agent/build.sh"

JAR_NAME="byte-buddy-$BB_VERSION.jar"
# Outside the worktree, so it survives a clean checkout and worktree recreation
# -- "once per box" is the requirement, not once per clone. DC_FIXTURE_CACHE_DIR
# is the fixture override, matching the repo's DC_* convention (see CLAUDE.md).
CACHE_DIR="${DC_FIXTURE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dreamconnect/fixtures}"
JAR="$CACHE_DIR/$JAR_NAME"

# Checked before anything is hashed, for the distinction build.sh already draws:
# without this, a missing sha256sum is indistinguishable from a real mismatch,
# and a perfectly good cached jar gets deleted and reported as rejected.
command -v sha256sum >/dev/null 2>&1 \
  || die "sha256sum not found, cannot verify $JAR_NAME"

# The offline box's way through, and the only one. The file is the operator's,
# so it is verified but never touched: a mismatch fails loudly here rather than
# quietly fetching over the top, because an operator who pointed at the wrong
# jar wants to hear about it, not to have the answer substituted.
if [ -n "${DC_BYTEBUDDY_JAR:-}" ]; then
  [ -f "$DC_BYTEBUDDY_JAR" ] \
    || die "DC_BYTEBUDDY_JAR is set to $DC_BYTEBUDDY_JAR, which is not a file"
  actual="$(hash_file "$DC_BYTEBUDDY_JAR")" \
    || die "could not read $DC_BYTEBUDDY_JAR, cannot verify it"
  if [ "$actual" != "$BB_SHA256" ]; then
    report_mismatch "$DC_BYTEBUDDY_JAR" "$BB_SHA256" "$actual"
    echo "  DC_BYTEBUDDY_JAR must point at $JAR_NAME; it was left where it is" >&2
    exit 1
  fi
  printf '%s\n' "$DC_BYTEBUDDY_JAR"
  exit 0
fi

# The steady state on every box after the first run: verified, no network.
if [ -f "$JAR" ]; then
  actual="$(hash_file "$JAR")" || die "could not read $JAR, cannot verify it"
  if [ "$actual" = "$BB_SHA256" ]; then
    printf '%s\n' "$JAR"
    exit 0
  fi
  # Dropped as well as rejected, for the reason build.sh drops its own: the
  # cache is keyed on the file merely existing, so a truncated or poisoned copy
  # left here would make every later run reject that same stale file forever.
  report_mismatch "$JAR" "$BB_SHA256" "$actual"
  rm -f "$JAR"
  echo "  removed the rejected fixture; re-run to fetch it again" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR" || die "could not create the fixture cache at $CACHE_DIR"

# Downloaded beside the cache entry and moved into place only once it has
# verified, so an unverified byte is never visible at the path a later run
# trusts. Same directory, so the mv is a rename and cannot be seen half-done;
# two gate runs racing duplicate the download, never a torn file.
tmp="$(mktemp "$CACHE_DIR/$JAR_NAME.XXXXXX")" \
  || die "could not create a temporary file in $CACHE_DIR"
trap 'rm -f "$tmp"' EXIT

echo ">> fetching $JAR_NAME into $CACHE_DIR (once per box)" >&2
curl -fsSL "$BB_URL" -o "$tmp" || die "could not fetch $BB_URL"

actual="$(hash_file "$tmp")" || die "could not read the downloaded $JAR_NAME, cannot verify it"
if [ "$actual" != "$BB_SHA256" ]; then
  report_mismatch "$BB_URL" "$BB_SHA256" "$actual"
  echo "  nothing was cached; the pin in agent/build.sh and the artifact disagree" >&2
  exit 1
fi

mv "$tmp" "$JAR" || die "could not move the verified $JAR_NAME into $CACHE_DIR"
printf '%s\n' "$JAR"
