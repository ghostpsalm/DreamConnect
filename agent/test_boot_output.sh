#!/usr/bin/env bash
#
# Tests for the SHAPE of BootTests' output (issues #78 and #69), not for what it
# asserts.
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
# #69 is here for the same reason: whether the suite can decline coverage without
# the gate noticing is a property of a whole run's stdout and exit status, and of
# a run made with the recursion guard already set -- none of which is visible from
# inside the JVM that produces it.
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

# One run of the suite's stdout, under any extra environment given, returning
# the suite's exit status.
#
# The format cases below discard that status at the call site with `|| true` -- a
# failing suite is still a suite whose lines must parse and whose identities must
# match, and `|| true` rather than an `if` because the status is not wanted at
# all, not even to report. It is returned rather than swallowed here because the
# fork-guard case (#69) is about the status, and one invocation of the suite is
# better than two that can disagree about how it is launched.
run_suite() {  # outfile [NAME=VALUE ...] -> the suite's exit status
  local out="$1"
  shift
  env "$@" java "${EXPORTS[@]}" -cp "$DC_BOOT_CLASSES" dreamconnect.boot.BootTests >"$out" 2>/dev/null
}

# A `static final String` of BootTests, read off the very classes this script
# runs (javap -constants), never transcribed here.
#
# The same rule fixture-lib.sh follows for the ByteBuddy pins: a second copy of
# the text can disagree with BootTests' own, and this file's whole value is that
# it asserts the line the suite really prints. Read from the compiled class
# rather than the .java so it cannot drift from what ran, and so no assumption
# is made about source formatting.
boot_constant() {  # NAME -> its value
  local name="$1" value
  value="$(javap -p -constants -cp "$DC_BOOT_CLASSES" dreamconnect.boot.BootTests \
             | sed -n "s/.*String ${name} = \"\(.*\)\";\$/\1/p")"
  value="${value%%$'\n'*}"   # first match wins
  # Empty is a failure, not a value: an assertion against the empty string would
  # match any FAIL line at all and look like it had checked something.
  if [ -z "$value" ]; then
    echo "FAIL: could not read $name out of the compiled BootTests" >&2
    return 1
  fi
  printf '%s\n' "$value"
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
  run_suite "$FIRST" || true
fi
SECOND="$WORK/second.out"
run_suite "$SECOND" || true

# A third run, with the fork self-test's recursion guard already set. Cheaper
# than either of the two above, not dearer: the guarded run declines before it
# forks a child, and forking one is the most expensive thing the suite does.
FORK_GUARD="$(boot_constant FAULT_SELFTEST_FORK_GUARD)" || exit 1
FORK_REFUSED="$(boot_constant FAULT_SELFTEST_FORK_REFUSED)" || exit 1
GUARDED="$WORK/guarded.out"
GUARDED_STATUS=0
run_suite "$GUARDED" "$FORK_GUARD=1" || GUARDED_STATUS=$?

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

# #69: a skip that nothing counts. BootTests has no skip counter, and a `skip:`
# line matches neither `ok  : ` nor `FAIL  : `, so it is invisible to the leg
# parser above as well -- the suite declines coverage and still prints ALL PASS.
# The fork self-test's own guard is now a counted failure, so this is the rail
# that keeps the next one from being written as a skip instead.
#
# Anchored at the line start: a check whose identity says something "is skipped"
# (the logon-probe TTL cases do) is a counted check and unaffected. Sees stdout
# only, which is all run_suite keeps and all the gate tees -- the suite prints
# nothing to stderr.
#
# Over the guarded run as well as the normal one, because the normal run never
# reaches the branch the issue is about: a `skip:` put back where the counted
# failure now is would print on no run this file looked at.
test_no_line_announces_a_skip() {
  local out skips
  for out in "$FIRST" "$GUARDED"; do
    skips="$(grep -a -E '^[Ss][Kk][Ii][Pp]' "$out" || true)"
    if [ -n "$skips" ]; then
      fail "$(printf '%s\n' "$skips" | wc -l) line(s) of $(basename "$out") announce a skip that no counter sees"
      printf '%s\n' "$skips" | head -5 | sed 's/^/    /'
    fi
  done
}

# #69's wiring, which no in-JVM test can reach. BootTests' own
# testFaultSelfTestForkGuardFailsRatherThanSkips proves the predicate that
# declines and the line the decision renders as, but not that the branch uses
# either: restore the old `System.out.println("skip: ...")` in its place and
# every in-JVM check still passes. What catches that is a whole run made with the
# guard set -- the only condition under which the branch executes at all.
#
# Asserts the failure is counted (exit 1, no ALL PASS) and is the fork guard's
# and nothing else, so an unrelated failure cannot make this case pass for the
# wrong reason. A box that exports the guard globally gets a red gate here; that
# is intended, and it is the failure mode the issue is about.
test_the_fork_guard_declines_as_a_counted_failure() {
  assert_eq "$GUARDED_STATUS" "1" "the suite's exit status with $FORK_GUARD set"
  assert_eq "$(identities "$GUARDED" | grep -a -c '^FAIL' || true)" "1" \
            "failed check(s) in the guarded run"
  assert_eq "$(identities "$GUARDED" | grep -a '^FAIL' || true)" "FAIL  : $FORK_REFUSED" \
            "the guarded run's failed check"
  if grep -q -a '^ALL PASS' "$GUARDED"; then
    fail "the guarded run declined the fork self-test and still reported ALL PASS"
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
  test_no_identity_repeats_within_a_run \
  test_no_line_announces_a_skip \
  test_the_fork_guard_declines_as_a_counted_failure
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
