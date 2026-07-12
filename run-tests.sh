#!/usr/bin/env bash
# Run DreamConnect's unit tests: the Java bootstrap classes and the Python
# daemon command parser. No external test frameworks required.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
EXPORTS=(--add-exports java.desktop/java.awt.peer=ALL-UNNAMED
         --add-exports java.desktop/sun.awt=ALL-UNNAMED)

echo "== Java boot tests =="
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
javac "${EXPORTS[@]}" -d "$out" \
  $(find "$HERE/agent/boot" "$HERE/agent/test" -name '*.java')
java "${EXPORTS[@]}" -cp "$out" dreamconnect.boot.BootTests

echo
echo "== Python daemon tests =="
python3 -m unittest -v "$HERE/runtime/test_daemon.py" 2>&1 | tail -20 \
  || python3 "$HERE/runtime/test_daemon.py"

echo
echo "ALL TESTS PASSED"
