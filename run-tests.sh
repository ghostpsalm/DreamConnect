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
echo "== Agent fixture pin tests =="
bash "$HERE/agent/test_fixture_fetch.sh"

echo
echo "== Agent build shell tests =="
# The one line in this repo's tests allowed to reach the network, and only on a
# box that has never done it before (#46). agent/test_build.sh is hermetic -- it
# stubs curl -- but its one case proving build.sh can *succeed* needs a real jar
# hashing to the pinned constant, and agent/lib/ is gitignored. Without this it
# skipped on every clean checkout, so a permanently broken build.sh, or the
# mistyped BB_SHA256 that #43 defends against, still printed ALL TESTS PASSED.
#
# Outside the suite on purpose: the fetch is visible here rather than buried in
# a test helper, the suite keeps its stub, and the fixture is verified against
# agent/build.sh's own BB_SHA256 before this ever returns a path. A box with no
# network sets DC_BYTEBUDDY_JAR itself; the fetcher then verifies that and makes
# no network call. Second and later runs are cache hits and never go online.
if ! DC_BYTEBUDDY_JAR="$("$HERE/scripts/fetch-test-fixtures.sh")"; then
  echo "FAILED: could not obtain the ByteBuddy test fixture -- see the lines above" >&2
  exit 1
fi
export DC_BYTEBUDDY_JAR
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
