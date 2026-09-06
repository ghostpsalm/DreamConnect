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
# `set -euo pipefail`, every suite aborts the run on failure, and it prints
# "ALL TESTS PASSED" only on the path where all of them did.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

exec "$HERE/run-tests.sh"
