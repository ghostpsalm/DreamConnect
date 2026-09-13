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
# Deferred, not aborted (#41). BootTests counts every failure it sees -- a failed
# check() and, since #41, a test that throws -- and exits 1 once at the end. A bare
# invocation here would meet `set -e` and kill the whole script at this line, so the
# Python and installer sections below would never run and whoever reads the output
# could not tell "one Java test failed" from "two thirds of the gate never executed".
# Capturing the status and failing at the bottom keeps the gate just as red while
# letting it finish reporting. `|| java_status=$?` rather than `if ! java ...`
# because the status itself is wanted, not merely the fact of failure; the `|| `
# form is also what keeps `set -e` from firing on this command.
java_status=0
java "${EXPORTS[@]}" -cp "$out" dreamconnect.boot.BootTests || java_status=$?

echo
echo "== Python daemon tests =="
python3 -m unittest -v "$HERE/runtime/test_daemon.py" 2>&1 | tail -20 \
  || python3 "$HERE/runtime/test_daemon.py"

echo
echo "== Python session-discovery tests =="
python3 "$HERE/runtime/test_discovery.py" 2>&1 | tail -6

echo
echo "== Python supervisor tests =="
python3 "$HERE/runtime/test_sessiond.py" 2>&1 | tail -6

echo
echo "== Python greeter tests =="
python3 "$HERE/runtime/test_greeter.py" 2>&1 | tail -6

echo
echo "== Installer shell tests =="
bash "$HERE/test_install.sh"

echo
echo "== Agent build shell tests =="
bash "$HERE/agent/test_build.sh"

echo
# The deferred half of the Java section. Compared with `[ ... ]`, not `(( ))`:
# java_status is only ever assigned from `$?`, but arithmetic under `set -u` aborts
# the shell outright on anything unexpected, which is the one way this line could
# turn a red gate into a differently-shaped red that no longer names the suite.
if [ "$java_status" -ne 0 ]; then
  echo "FAILED: the Java boot tests (exit $java_status) -- see '== Java boot tests ==' above"
  exit "$java_status"
fi

echo "ALL TESTS PASSED"
