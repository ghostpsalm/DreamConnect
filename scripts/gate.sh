#!/usr/bin/env bash
# DreamConnect's gate: the check that must be green before anything is committed.
#
# This is a delegator, deliberately. ./run-tests.sh is already this repo's gate --
# .github/workflows/ci.yml calls it that in its own words -- and it already runs every
# suite: the Java boot tests, the Python daemon/discovery/supervisor/greeter tests, and
# the installer shell tests in test_install.sh. A second inventory of suites here would
# be a list that can disagree with the one that actually runs, so there isn't one.
#
# Everything the Factory needs from a gate, run-tests.sh already provides: it is
# `set -euo pipefail`, a failing suite always ends the run non-zero, and it prints
# "ALL TESTS PASSED" only on the path where all of them passed. The Java section is
# the one that defers rather than aborts (#41) -- it still fails the run, from the
# bottom of the script, so that the suites after it are reported rather than cut off.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

exec "$HERE/run-tests.sh"
