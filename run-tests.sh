#!/usr/bin/env bash
# Run DreamConnect's unit tests: the Java bootstrap classes and the Python
# daemon command parser. No external test frameworks required.
# -E so the ERR trap below is inherited by functions and subshells, which keeps
# its reach uniform rather than dependent on how a suite happens to be invoked.
# In every shape this script uses today the parent would fire the trap anyway --
# a failing subshell fails its caller -- so this is for the next shape somebody
# adds. gate-lib.sh's handler stays quiet inside a subshell so that the two
# cannot both print the same verdict (#80).
set -Eeuo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Headers and verdicts come from one place, off one variable, so the name in
# `== X ==` and the name in `FAILED (exit N) X` cannot disagree (#80).
. "$HERE/gate-lib.sh"
gate_verdict_trap
EXPORTS=(--add-exports java.desktop/java.awt.peer=ALL-UNNAMED
         --add-exports java.desktop/sun.awt=ALL-UNNAMED)

section "Java boot tests"
# This section's verdict is printed from the bottom of the script, by which time
# DC_SUITE names the last section that ran. Remembering the name here, where the
# header was printed, is what keeps the deferred verdict naming this suite.
java_suite="$DC_SUITE"
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
# Tee'd, into the directory the trap above already sweeps: agent/test_boot_output.sh
# compares this run's check lines against a second run's (#78), and handing it the
# output the gate has already produced costs one extra JVM instead of two. With
# pipefail the pipeline's status is java's, since tee's is zero -- and `|| ` still
# keeps `set -e` from firing, exactly as the bare form did.
boot_out="$out/boot-tests.stdout"
java "${EXPORTS[@]}" -cp "$out" dreamconnect.boot.BootTests | tee "$boot_out" || java_status=$?

echo
section "Python daemon tests"
python3 -m unittest -v "$HERE/runtime/test_daemon.py" 2>&1 | tail -20 \
  || python3 "$HERE/runtime/test_daemon.py"

echo
section "Python session-discovery tests"
python3 "$HERE/runtime/test_discovery.py" 2>&1 | tail -6

echo
section "Python supervisor tests"
python3 "$HERE/runtime/test_sessiond.py" 2>&1 | tail -6

echo
section "Python greeter tests"
python3 "$HERE/runtime/test_greeter.py" 2>&1 | tail -6

echo
section "Installer shell tests"
bash "$HERE/test_install.sh"

echo
section "Agent fixture pin tests"
bash "$HERE/agent/test_fixture_fetch.sh"

echo
section "Agent build shell tests"
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
  suite_failed 1 "could not obtain the ByteBuddy test fixture -- see the lines above"
fi
export DC_BYTEBUDDY_JAR
bash "$HERE/agent/test_build.sh"

echo
section "Boot test output format"
# The SHAPE of what the Java leg printed, not what it asserted (#78): every check
# line parseable as `<word><whitespace><name>`, and the identity before " # "
# byte-identical across two runs. It reads the tee'd output above, so it compares
# whatever that leg printed -- a red suite included.
#
# Last rather than immediately after the leg it reads, for the same reason the
# Java leg's status is deferred: this one is not deferred, so under `set -e` a
# failure here ends the script, and from here there is nothing left to cut off.
DC_BOOT_CLASSES="$out" DC_BOOT_EXPORTS="${EXPORTS[*]}" DC_BOOT_FIRST_OUT="$boot_out" \
  bash "$HERE/agent/test_boot_output.sh"

echo
section "Gate verdict tests"
# The verdict lines this script prints (#80): that a failed suite says
# `FAILED (exit N) <the name in its own header>` and nothing else on that line.
bash "$HERE/test_gate_verdict.sh"

echo
# The deferred half of the Java section. Compared with `[ ... ]`, not `(( ))`:
# java_status is only ever assigned from `$?`, but arithmetic under `set -u` aborts
# the shell outright on anything unexpected, which is the one way this line could
# turn a red gate into a differently-shaped red that no longer names the suite.
#
# DC_SUITE is restored rather than read as it stands: suite_failed names the
# current suite, and by here that is the last section above, not the Java one.
if [ "$java_status" -ne 0 ]; then
  DC_SUITE="$java_suite"
  suite_failed "$java_status" "see '== $java_suite ==' above"
fi

echo "ALL TESTS PASSED"
