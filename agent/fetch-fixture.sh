#!/usr/bin/env bash
#
# Fetches and pin-verifies the real ByteBuddy jar into agent/lib/ -- the same
# cache build.sh itself reads and writes -- so agent/test_build.sh's
# happy-path case always has a fixture to run against. This is the one
# sanctioned network access in an otherwise hermetic test suite (see
# CLAUDE.md's Seams section): it runs once per box, before the suite, never
# from inside a test.
#
# The pin (version, URL, SHA-256) is read live from agent/build.sh via
# fixture-lib.sh -- never restated here -- so a mistyped pin fails this fetch
# exactly as loudly as it would fail a real build.
#
# On success, prints the verified jar's absolute path on stdout and exits 0.
# A cache hit whose hash already matches makes no network call at all.
#
# Run:  bash agent/fetch-fixture.sh      (also wired into ./run-tests.sh)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./fixture-lib.sh
source "$HERE/fixture-lib.sh"

BUILD_SH="$HERE/build.sh"
VERSION="$(bb_version "$BUILD_SH")"
SHA256="$(bb_sha256 "$BUILD_SH")"
URL="$(bb_url "$BUILD_SH")"

# DC_BYTEBUDDY_JAR exists only for test isolation (agent/test_fetch_fixture.sh
# points it at a scratch file); every real invocation uses the same path
# build.sh itself checks, so a warm fixture cache is also a warm build cache.
JAR="${DC_BYTEBUDDY_JAR:-$HERE/lib/byte-buddy-$VERSION.jar}"
mkdir -p "$(dirname "$JAR")"

# Hash the file directly rather than piping "<hash>  <path>" into
# `sha256sum -c` -- same reasoning as build.sh itself (see its comment on
# issue #49): that line format is a parser, and a path it cannot parse fails
# in a way indistinguishable from a real mismatch.
hash_of() {  # path -> prints sha256, or fails
  sha256sum < "$1" | cut -d' ' -f1
}

if [ -f "$JAR" ]; then
  actual="$(hash_of "$JAR" 2>/dev/null)" || actual=""
  if [ -n "$actual" ] && [ "$actual" = "$SHA256" ]; then
    printf '%s\n' "$JAR"
    exit 0
  fi
  echo "SHA-256 mismatch for cached fixture $JAR" >&2
  echo "  expected $SHA256" >&2
  echo "  actual   ${actual:-<unreadable>}" >&2
  rm -f "$JAR"
  echo "removed the mismatched fixture; re-run to fetch it again" >&2
  exit 1
fi

echo ">> fetch ByteBuddy fixture $VERSION" >&2
if ! curl -fsSL "$URL" -o "$JAR"; then
  echo "could not fetch fixture jar from $URL" >&2
  rm -f "$JAR"
  exit 1
fi

actual="$(hash_of "$JAR" 2>/dev/null)" || {
  echo "could not read $JAR after fetch, cannot verify it" >&2
  rm -f "$JAR"
  exit 1
}
if [ -z "$actual" ] || [ "$actual" != "$SHA256" ]; then
  echo "SHA-256 mismatch for freshly fetched fixture $JAR" >&2
  echo "  expected $SHA256" >&2
  echo "  actual   ${actual:-<unreadable>}" >&2
  rm -f "$JAR"
  exit 1
fi

printf '%s\n' "$JAR"
