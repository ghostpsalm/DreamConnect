#!/usr/bin/env bash
# DreamConnect's gate: the check that must be green before anything is committed.
#
# This is a delegator, deliberately. ./run-tests.sh is already this repo's gate --
# .github/workflows/ci.yml calls it that in its own words -- and it already runs every
# suite: the Java boot tests, the Python daemon/discovery/supervisor/greeter tests, and
# the installer shell tests in test_install.sh. A second inventory of suites here would
# be a list that can disagree with the one that actually runs, so there isn't one.
#
# Everything the Factory needs from a gate, run-tests.sh already provides: a failing
# suite always ends the run non-zero and prints `FAILED (exit N) <suite>` (#80), and
# it prints "ALL TESTS PASSED" only on the path where all of them passed. Its shell
# flags are not restated here: #80 added -E, which carries its ERR trap into
# functions and subshells, and the copy this comment used to hold went stale.
#
# The Java section is the one that carries on rather than aborts (#41): it prints
# its verdict where it fails and still fails the run, from the bottom of the
# script, so that the suites after it are reported rather than cut off.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

exec "$HERE/run-tests.sh"
