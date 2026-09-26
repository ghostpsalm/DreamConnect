#!/usr/bin/env bash
#
# Tests for the SHAPE of BootTests' output (issue #78), not for what it asserts.
#
# Seam: there isn't an in-process one for this. BootTests.testCheckLineFormat
# covers how one line is rendered, which is all checkLine() can be asked about.
# The two properties #78 is actually about are properties of a whole run, and of
# two runs compared:
#
#   * every check line is parseable as a leg -- `<word><whitespace><name>`. The
#     old "FAIL: " had no whitespace after the word, so a failing boot check was
#     not a failed check to whoever read the output; it vanished from the
#     inventory and the failure was attributed to the gate's exit code instead.
#
#   * the identity -- the text before the first " # " -- is byte-identical
#     between two runs of an unchanged tree. Values that change per run (temp
#     directories, measured milliseconds, queue sizes) or per box (uids, the
#     account the suite runs as) used to sit inside it, so a check was renamed on
#     every run: a baseline and a candidate that ran the very same suite compared
#     as one check missing plus one new, and every DreamConnect gate comparison
#     came back NOT_COMPARABLE.
#
# An in-JVM test cannot see either one. Both need the suite's own stdout, and the
# second needs two of them, so this runs at the same boundary the gate does.
#
# Compared REGARDLESS of exit status. A red suite is exactly when a reader most
# needs the inventory to line up, and a version of this check that only ran on
# green would go quiet at that moment.
#
# Inputs (from run-tests.sh, which has already compiled the classes):
#   DC_BOOT_CLASSES    required -- the classes directory to run BootTests from
#   DC_BOOT_EXPORTS    required -- the --add-exports pair, as one word-split
#                      string. Passed in rather than restated here: a second
#                      copy of the pair is a second thing that can disagree
#                      with the one the gate actually uses.
#   DC_BOOT_FIRST_OUT  optional -- stdout the gate already captured from its own
#                      BootTests run. Given it, the gate pays for one extra JVM
#                      rather than two.
#
# Run:  DC_BOOT_CLASSES=... DC_BOOT_EXPORTS=... bash agent/test_boot_output.sh
#       (wired into ./run-tests.sh)
#
# No network, no root, no writes outside a mktemp -d.
set -uo pipefail

[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

FAILURES=0
CURRENT="<none>"

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq() {  # actual expected label
  [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"
}

[ -n "${DC_BOOT_CLASSES:-}" ] \
  || { echo "FAIL: DC_BOOT_CLASSES is not set -- run this through ./run-tests.sh"; exit 1; }
[ -f "$DC_BOOT_CLASSES/dreamconnect/boot/BootTests.class" ] \
  || { echo "FAIL: no compiled BootTests under $DC_BOOT_CLASSES"; exit 1; }
[ -n "${DC_BOOT_EXPORTS:-}" ] \
  || { echo "FAIL: DC_BOOT_EXPORTS is not set -- run this through ./run-tests.sh"; exit 1; }
read -r -a EXPORTS <<<"$DC_BOOT_EXPORTS"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One run of the suite's stdout. Its exit status is deliberately discarded: a
# failing suite is still a suite whose lines must parse and whose identities must
# match, and `|| true` rather than an `if` because the status is not wanted at
# all, not even to report.
run_suite() {  # outfile
  java "${EXPORTS[@]}" -cp "$DC_BOOT_CLASSES" dreamconnect.boot.BootTests >"$1" 2>/dev/null || true
}

# The lines a leg parser would pick up: anything whose first characters are `ok`
# or `FAIL` and which is therefore claiming to be one. Matched loosely on
# purpose -- a line that begins with the word and then gets the separator wrong
# is the defect, so it has to reach the assertion rather than be filtered out by
# the same pattern being asserted.
leg_lines() {  # outfile
  grep -a -E '^(ok|FAIL)([^A-Za-z]|$)' "$1" || true
}

# A check's identity: everything before the first " # ". `sed` on the first
# occurrence only, since a diagnostic may legitimately quote a separator of its
# own (the runner test reports the very line main() would print).
identities() {  # outfile
  leg_lines "$1" | sed 's/ # .*//'
}

FIRST="$WORK/first.out"
if [ -n "${DC_BOOT_FIRST_OUT:-}" ] && [ -s "$DC_BOOT_FIRST_OUT" ]; then
  cp "$DC_BOOT_FIRST_OUT" "$FIRST"
else
  run_suite "$FIRST"
fi
SECOND="$WORK/second.out"
run_suite "$SECOND"

# --- cases -------------------------------------------------------------------

# Guards every assertion below against passing vacuously on an empty file -- a
# BootTests that died at class load because the exports were not propagated
# produces no legs at all, and "no line is malformed" would be true of it.
test_the_suite_produced_check_lines() {
  local n
  n="$(leg_lines "$FIRST" | wc -l)"
  [ "$n" -ge 300 ] || fail "only $n check line(s) in the suite's output; expected the whole suite"
  assert_eq "$(identities "$SECOND" | wc -l)" "$n" "the second run printed as many check lines"
}

# Defect 2. `<word><whitespace><name>`, which "FAIL: " was not.
test_every_check_line_is_parseable_as_a_leg() {
  local bad
  bad="$(leg_lines "$FIRST" | grep -a -c -v -E '^(ok|FAIL)  : ' || true)"
  assert_eq "$bad" "0" "check lines that are not <word><whitespace><name>"
  leg_lines "$FIRST" | grep -a -v -E '^(ok|FAIL)  : ' | head -3 | while read -r l; do
    echo "    unparseable: $l"
  done
}

# Defect 1, and the issue's acceptance: two consecutive runs on an unchanged
# tree print identical text before " # " on every check line.
test_two_runs_print_the_same_identities_in_the_same_order() {
  identities "$FIRST" >"$WORK/id1"
  identities "$SECOND" >"$WORK/id2"
  if ! cmp -s "$WORK/id1" "$WORK/id2"; then
    fail "the identity sequence differs between two runs of an unchanged tree"
    diff "$WORK/id1" "$WORK/id2" | head -10 | sed 's/^/    /'
  fi
}

# A renamed check and a duplicated one break a comparison the same way: the
# baseline's occurrences and the candidate's cannot be matched up one to one.
# This is the half that stays true however many times the suite is run, so it is
# asserted per run rather than across the pair.
test_no_identity_repeats_within_a_run() {
  local dupes
  dupes="$(identities "$FIRST" | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    fail "$(printf '%s\n' "$dupes" | wc -l) identity(ies) printed more than once in one run"
    printf '%s\n' "$dupes" | head -10 | sed 's/^/    /'
  fi
}

for CURRENT in \
  test_the_suite_produced_check_lines \
  test_every_check_line_is_parseable_as_a_leg \
  test_two_runs_print_the_same_identities_in_the_same_order \
  test_no_identity_repeats_within_a_run
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
echo "boot test output format tests passed"
