#!/usr/bin/env bash
#
# Reads the ByteBuddy fetch pin (version, SHA-256, URL) out of build.sh's own
# constants, so the pin exists in exactly one place. Definitions only, no side
# effects on source -- same rule as install-lib.sh -- sourced by both
# agent/fetch-fixture.sh and agent/test_build.sh.
#
# bb_pin extracts with sed rather than sourcing the target script: sourcing the
# real build.sh would curl and compile. It takes the build-script path as a
# parameter rather than locating it via BASH_SOURCE or $0, so this file stays
# exactly as pure as install-lib.sh and can be pointed at a synthetic build.sh
# in tests -- the only way to prove the value is read, not hardcoded.

# bb_pin NAME FILE -> prints the value of NAME="..." from FILE, or fails.
# Missing or empty is a failure with no fallback: a mistyped or renamed
# constant must be loud, never silently absent.
bb_pin() {
  local name="$1" file="$2" value
  value="$(sed -n "s/^${name}=\"\\(.*\\)\"\$/\\1/p" "$file" 2>/dev/null | head -n1)"
  if [ -z "$value" ]; then
    echo "could not read $name from $file" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

bb_version() { bb_pin BYTEBUDDY_VERSION "$1"; }  # FILE -> version
bb_sha256()  { bb_pin BB_SHA256 "$1"; }          # FILE -> pinned sha256

# bb_url FILE -> prints the pinned download URL, with $BYTEBUDDY_VERSION
# expanded by plain string substitution -- never eval -- so a hostile edit to
# build.sh's constants cannot run code during a fetch.
bb_url() {
  local file="$1" version url
  version="$(bb_version "$file")" || return 1
  url="$(bb_pin BB_URL "$file")" || return 1
  printf '%s\n' "${url//\$BYTEBUDDY_VERSION/$version}"
}
