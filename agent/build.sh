#!/usr/bin/env bash
# Build the dreamconnect Java agent without a system Maven/Gradle install.
# Fetches ByteBuddy once (cached, gitignored), compiles the bootstrap peer
# classes and the agent classes, and assembles a single self-contained
# dreamconnect-agent.jar with the boot jar embedded as a resource.
set -euo pipefail

BYTEBUDDY_VERSION="1.18.11"
# Pinned SHA-256 of byte-buddy-$BYTEBUDDY_VERSION.jar, from Maven Central's own
# .sha256 sidecar. The jar is shaded into an agent that runs as root inside
# ScreenConnect's JVM, so it is verified on every build -- a cached copy too.
BB_SHA256="e32f454c2c1f4aca982f9ec764ed892d9a6eee7e8a77f435cbdd180f6ffdb821"
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib"
BUILD="$HERE/target"
DIST="$BUILD/dist"
BB_JAR="$LIB/byte-buddy-$BYTEBUDDY_VERSION.jar"
BB_URL="https://repo1.maven.org/maven2/net/bytebuddy/byte-buddy/$BYTEBUDDY_VERSION/byte-buddy-$BYTEBUDDY_VERSION.jar"

EXPORTS=(
  --add-exports java.desktop/java.awt.peer=ALL-UNNAMED
  --add-exports java.desktop/sun.awt=ALL-UNNAMED
)

echo ">> fetch ByteBuddy $BYTEBUDDY_VERSION"
mkdir -p "$LIB"
[ -f "$BB_JAR" ] || curl -fsSL "$BB_URL" -o "$BB_JAR"

echo ">> verify ByteBuddy against pinned hash"
# Check the verifier itself first. Without this, a missing sha256sum (minimal
# container, mangled PATH, macOS) exits non-zero from the pipeline below and is
# indistinguishable from a real mismatch -- so a perfectly good cached jar gets
# deleted and reported as rejected, when in truth nothing was ever checked.
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum not found, cannot verify $BB_JAR" >&2
  exit 1
fi

# Stage first, then hash the staged copy, then consume only that copy (#48).
# Verifying $BB_JAR in place and reading it again for javac and unzip is
# verify-then-reread: anything able to write lib/ in between gets its own
# classes shaded into an agent that runs as root. Hashing the bytes that will
# actually be read closes that outright -- a swap landing during the cp yields
# torn bytes, which fail the hash, and a swap landing after it is simply too
# late.
#
# Deliberately not the reverse (copy *after* a passing check): that still leaves
# a window of exactly the same kind, only shorter.
#
# This does NOT fix the concurrent-build race the issue mentions in passing, and
# it is worth being plain about that rather than letting the staging look like a
# fix it is not: $BUILD is "$HERE/target", per *checkout*, not per run. Two
# builds in one checkout share one $BB_STAGED, and the `rm -rf "$BUILD"` below
# deletes the other process's staged jar and half-built tree outright -- worse
# than the `rm -f` race it replaces, not better. Out of scope for #48; the
# answer is a separate checkout per concurrent build.
rm -rf "$BUILD"
mkdir -p "$BUILD/boot" "$BUILD/agent" "$DIST"
BB_STAGED="$BUILD/byte-buddy-verified.jar"

# A failed copy says nothing about the bytes, so it lands where a missing
# sha256sum lands above -- fail closed, keep the jar, claim nothing about it.
# chmod is hygiene, not a control: a same-uid attacker can undo it, but it stops
# the build's own later steps from writing over what was verified.
if ! cp "$BB_JAR" "$BB_STAGED" || ! chmod 400 "$BB_STAGED"; then
  echo "could not stage $BB_JAR for hashing, cannot verify it" >&2
  exit 1
fi

# Hash the file directly instead of piping "<hash>  <path>" into `sha256sum -c`.
# That line format is a parser: it reads the filename back out using coreutils'
# own escaping rules, so a path holding a newline is split and the check runs
# against a truncated name -- exit 1, identical to a real mismatch, and the jar
# never hashed at all. Redirecting the file in means sha256sum is handed no path
# to parse. (Same idiom agent/test_build.sh already uses for its fixture jar.)
#
# Failing to hash is not a mismatch either, for the same reason as the copy.
if ! BB_ACTUAL="$(sha256sum < "$BB_STAGED" | cut -d' ' -f1)" || [ -z "$BB_ACTUAL" ]; then
  echo "could not read $BB_JAR, cannot verify it" >&2
  exit 1
fi

# On mismatch, drop the rejected jar as well as failing: the cache is keyed on
# the file merely existing, so leaving a truncated or poisoned copy in lib/
# would make every later run reject that same stale file forever.
if [ "$BB_ACTUAL" != "$BB_SHA256" ]; then
  echo "SHA-256 mismatch for $BB_JAR" >&2
  echo "  expected $BB_SHA256" >&2
  echo "  actual   $BB_ACTUAL" >&2
  rm -f "$BB_JAR" "$BB_STAGED"
  echo "removed the rejected jar; re-run to fetch it again" >&2
  exit 1
fi

echo ">> compile bootstrap peer classes"
javac "${EXPORTS[@]}" -d "$BUILD/boot" \
  $(find "$HERE/boot" -name '*.java')

echo ">> package dreamconnect-boot.jar"
jar --create --file "$DIST/dreamconnect-boot.jar" -C "$BUILD/boot" .

echo ">> compile agent classes"
javac "${EXPORTS[@]}" -cp "$BB_STAGED:$BUILD/boot" -d "$BUILD/agent" \
  $(find "$HERE/src" -name '*.java')

echo ">> assemble dreamconnect-agent.jar (shade ByteBuddy + embed boot jar)"
# shade only net/** from ByteBuddy (skip its module-info / META-INF), out of the
# staged copy that was hashed -- never out of lib/, which is the whole of #48
( cd "$BUILD/agent" && unzip -oq "$BB_STAGED" 'net/*' )
cp "$DIST/dreamconnect-boot.jar" "$BUILD/agent/dreamconnect-boot.jar"

cat > "$BUILD/manifest.txt" <<'EOF'
Manifest-Version: 1.0
Premain-Class: dreamconnect.agent.DreamConnectAgent
Can-Retransform-Classes: true
Can-Redefine-Classes: true
EOF

jar --create --file "$DIST/dreamconnect-agent.jar" \
    --manifest "$BUILD/manifest.txt" -C "$BUILD/agent" .

echo ">> done: $DIST/dreamconnect-agent.jar"
ls -l "$DIST"
