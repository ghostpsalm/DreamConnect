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

# On mismatch, drop the rejected jar as well as failing: the cache is keyed on
# the file merely existing, so leaving a truncated or poisoned copy in lib/
# would make every later run reject that same stale file forever.
if ! echo "$BB_SHA256  $BB_JAR" | sha256sum -c -; then
  rm -f "$BB_JAR"
  echo "removed the rejected jar; re-run to fetch it again" >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/boot" "$BUILD/agent" "$DIST"

echo ">> compile bootstrap peer classes"
javac "${EXPORTS[@]}" -d "$BUILD/boot" \
  $(find "$HERE/boot" -name '*.java')

echo ">> package dreamconnect-boot.jar"
jar --create --file "$DIST/dreamconnect-boot.jar" -C "$BUILD/boot" .

echo ">> compile agent classes"
javac "${EXPORTS[@]}" -cp "$BB_JAR:$BUILD/boot" -d "$BUILD/agent" \
  $(find "$HERE/src" -name '*.java')

echo ">> assemble dreamconnect-agent.jar (shade ByteBuddy + embed boot jar)"
# shade only net/** from ByteBuddy (skip its module-info / META-INF)
( cd "$BUILD/agent" && unzip -oq "$BB_JAR" 'net/*' )
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
