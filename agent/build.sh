#!/usr/bin/env bash
# Build the dreamconnect Java agent without a system Maven/Gradle install.
# Fetches ByteBuddy once (cached, gitignored), compiles the bootstrap peer
# classes and the agent classes, and assembles a single self-contained
# dreamconnect-agent.jar with the boot jar embedded as a resource.
set -euo pipefail

BYTEBUDDY_VERSION="1.18.11"
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
