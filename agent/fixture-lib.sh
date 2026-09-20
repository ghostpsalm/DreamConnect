#!/usr/bin/env bash
# The ByteBuddy pins, read out of agent/build.sh (#46).
#
# The test fixture and the one-time fetch need the same version, URL and
# SHA-256 the product builds against. Transcribing them here would create a
# second constant that can disagree with the first, and a pinned hash that
# disagrees with the one real installs use is exactly the failure #43 exists to
# catch -- so these read agent/build.sh's own assignments instead.
#
# Definitions only: sourcing must have no side effects, the same rule
# install-lib.sh follows (see CLAUDE.md, "Seams").

bb_pin() {  # NAME -> prints the value of NAME="..." in agent/build.sh
  local name="${1:-}" here file value
  if [ -z "$name" ]; then
    echo "fixture-lib.sh: bb_pin needs the name of a constant to read" >&2
    return 1
  fi

  # Located from this file, not from $0 or the cwd: agent/ and scripts/ both
  # source it, from different directories and by absolute path, and build.sh is
  # this file's sibling in every one of those cases. BASH_SOURCE[0] inside a
  # function is the file the function was *defined* in, so this stays correct
  # however the caller was invoked.
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  file="$here/build.sh"

  # Read, never sourced or eval'd. build.sh is a build: sourcing it would curl
  # ByteBuddy and run javac as a side effect of asking what its hash is.
  if [ ! -f "$file" ]; then
    echo "fixture-lib.sh: could not read $name from $file: no such file" >&2
    return 1
  fi

  value="$(sed -n "s/^${name}=\"\(.*\)\"\$/\1/p" "$file")"
  value="${value%%$'\n'*}"   # first assignment wins; no pipe, so no pipefail 141

  # Empty is a failure, not a value. `BB_SHA256=""` would otherwise verify a
  # fixture against the empty string, and a sloppy comparison would call that a
  # match -- worse than the constant being missing outright, because it looks
  # like it was checked.
  if [ -z "$value" ]; then
    echo "fixture-lib.sh: could not read $name from $file" >&2
    return 1
  fi

  printf '%s\n' "$value"
}

bb_version() {  # -> BYTEBUDDY_VERSION
  bb_pin BYTEBUDDY_VERSION
}

bb_sha256() {  # -> BB_SHA256
  bb_pin BB_SHA256
}

bb_url() {  # -> BB_URL, with $BYTEBUDDY_VERSION expanded
  local url version
  url="$(bb_pin BB_URL)" || return 1
  version="$(bb_version)" || return 1
  # Substituted textually rather than by eval: the value is a line lifted out of
  # a script, and eval would execute whatever else that line happened to hold.
  # Only the bare $BYTEBUDDY_VERSION form build.sh actually writes is handled --
  # if the shape ever changes, the URL comes back with a literal `$` in it,
  # which is unfetchable and is asserted against rather than silently shipped.
  printf '%s\n' "${url//\$BYTEBUDDY_VERSION/$version}"
}
