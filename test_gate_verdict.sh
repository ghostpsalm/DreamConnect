#!/usr/bin/env bash
#
# Tests for gate-lib.sh -- the suite headers and suite verdicts run-tests.sh
# prints (issue #80).
#
# Seam: gate-lib.sh holds definitions only and is sourced, so the boundary is
# "write a scratch script that sources it, run that script, and look at its
# stdout, its stderr and its exit code". Scratch scripts rather than direct
# calls, because what is under test is what a *failing gate* prints and then
# exits with, and a function that ends in `exit` cannot be called from a test
# harness that expects to keep running.
#
# Contract under test (issue #80):
#   * A failed suite prints `FAILED (exit N) <suite>` -- the generic
#     suite-verdict form -- where <suite> is the name in that suite's own
#     `== <suite> ==` header, alone on one line of stdout.
#   * The old free-text `FAILED: ...` forms are gone: a verdict a parser cannot
#     read let a run whose Java leg failed record that leg as passed.
#   * Every section emits a verdict when it fails, not just the two that used
#     to try, and the verdict names the section that failed rather than the
#     last one that started.
#   * A hint for the human is allowed, on its own line after the verdict.
#   * The exit status is the failing suite's, unchanged.
#
# Nothing here runs a real suite: these cases assert the shape of the gate's
# own output, which is producible from a three-line scratch script. What the
# real run-tests.sh does with that shape is covered by the static rails at the
# bottom, which read the script rather than execute it (executing it from
# inside itself would recurse).
#
# Run:  bash test_gate_verdict.sh      (also wired into ./run-tests.sh)
set -uo pipefail

# The same rail test_install.sh and test_fixture_fetch.sh carry. Nothing here
# touches the real system, but a suite that grows a case which does must not be
# able to do it as root.
[ "$(id -u)" -eq 0 ] && { echo "refusing to run as root"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE_LIB="$HERE/gate-lib.sh"
RUN_TESTS="$HERE/run-tests.sh"

# The form the verdict has to take, written out once. Anchored at both ends:
# the defect was a line that *contained* the word FAILED and some of the right
# words, so "contains" is exactly the assertion that would have passed then.
verdict_re() {  # suite -> an ERE matching its verdict line and nothing else
  printf '^FAILED \\(exit [0-9]+\\) %s$\n' "$1"
}

# --- tiny assert harness (same shape as agent/test_fixture_fetch.sh) ----------
FAILURES=0
CURRENT="<none>"

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq() {  # actual expected label
  [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"
}

assert_contains() {  # haystack needle label
  case "$1" in
    *"$2"*) ;;
    *) fail "$3: expected output to contain [$2], got [$1]" ;;
  esac
}

assert_not_contains() {  # haystack needle label
  case "$1" in
    *"$2"*) fail "$3: expected output NOT to contain [$2], got [$1]" ;;
  esac
}

count_matching() {  # text ere -> how many of its lines match
  printf '%s\n' "$1" | grep -cE "$2" || true
}

assert_matches_once() {  # text ere label
  local n
  n="$(count_matching "$1" "$2")"
  [ "$n" = "1" ] || fail "$3: expected exactly one line matching /$2/, got $n in [$1]"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$GATE_LIB" ] || { echo "FAIL: gate-lib.sh not found at $GATE_LIB"; exit 1; }
[ -f "$RUN_TESTS" ] || { echo "FAIL: run-tests.sh not found at $RUN_TESTS"; exit 1; }

# --- the seam ----------------------------------------------------------------

OUT=""; ERR=""; RC=0
run_script() {  # preamble body -- sets OUT, ERR, RC
  local d
  d="$(mktemp -d "$TMP/script.XXXXXX")"
  {
    # The same flags run-tests.sh itself runs under. -E is what puts the trap
    # inside a subshell, which is the condition Case E is about.
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n. %q\n' "$GATE_LIB"
    printf '%s\n' "$1" "$2"
  } > "$d/scratch.sh"
  # LC_ALL=C for the same reason test_build.sh pins it: several assertions
  # below are about diagnostic text.
  OUT="$(cd "$d" && LC_ALL=C bash ./scratch.sh 2>"$d/stderr")"
  RC=$?
  ERR="$(cat "$d/stderr")"
}

guarded() { run_script 'gate_verdict_trap' "$1"; }   # a gate-shaped script
plain()   { run_script ''                  "$1"; }   # ... without the trap

# --- tests -------------------------------------------------------------------

# Case A -- the header still reads exactly as it did, and the name it printed is
# now available to whatever prints the verdict. Both halves matter: run-tests.sh
# is parsed section by section off that `== ... ==` line.
test_section_prints_the_header_and_records_the_name() {
  plain 'section "Sample suite"
printf "DC_SUITE=[%s]\n" "$DC_SUITE"'

  assert_eq "$RC" "0" "section: a well-formed call succeeds"
  assert_eq "$OUT" "== Sample suite ==
DC_SUITE=[Sample suite]" "section: prints the header and records the name behind it"
}

# Case B -- a section with no name would print `==  ==` and then a verdict
# naming nothing, which is the unparseable line this issue is about wearing a
# different hat. Refused in the function's own voice (CLAUDE.md, "Shell").
test_a_section_with_no_name_is_refused() {
  plain 'section "" || echo "refused with $?"'

  assert_eq "$RC" "0" "nameless section: the scratch script handled the refusal"
  assert_eq "$OUT" "refused with 1" "nameless section: returns 1, prints no header"
  assert_contains "$ERR" "section needs a suite name" \
    "nameless section: says what was wrong, in gate-lib.sh's own voice"
}

# Case C -- the defect itself. A suite that fails must leave a line a parser can
# read: the recognised form, the suite's own name, nothing else on the line.
test_a_failing_suite_prints_the_recognised_verdict_form() {
  guarded 'section "Sample suite"
false
echo "ALL TESTS PASSED"'

  assert_eq "$RC" "1" "failing suite: the gate exits with the suite's status"
  assert_matches_once "$OUT" "$(verdict_re "Sample suite")" \
    "failing suite: one verdict line, in the form a suite verdict is recognised by"
  assert_not_contains "$OUT" "FAILED:" \
    "failing suite: the free-text form is what nothing could parse"
  assert_not_contains "$OUT" "ALL TESTS PASSED" \
    "failing suite: a red run must not reach the green line"
}

# Case D -- the verdict names the section that failed. Before this, only two
# sites printed anything at all and the rest aborted silently under `set -e`;
# a verdict naming the wrong suite would be no better, since the name is how
# the leg is matched to its header.
test_the_verdict_names_the_section_that_failed_not_an_earlier_one() {
  guarded 'section "First suite"
true
echo
section "Second suite"
false'

  assert_eq "$RC" "1" "second section: exits non-zero"
  assert_matches_once "$OUT" "$(verdict_re "Second suite")" \
    "second section: the verdict names the suite that failed"
  assert_eq "$(count_matching "$OUT" "$(verdict_re "First suite")")" "0" \
    "second section: and not the one that passed"
}

# Case E -- a failure inside a subshell. `set -E` is what carries the trap into
# one, and it has to: without it the subshell's failure is the last thing that
# happens and no verdict is printed at all. But the subshell's failure also
# fails the enclosing command, so a handler that prints unconditionally prints
# the same suite's verdict twice, which reads as two failed suites.
test_a_failure_inside_a_subshell_yields_exactly_one_verdict() {
  guarded 'section "Sample suite"
( false )
echo "unreachable"'

  assert_eq "$RC" "1" "subshell: exits non-zero"
  assert_matches_once "$OUT" "$(verdict_re "Sample suite")" \
    "subshell: one failed suite is one verdict line, not two"
  assert_not_contains "$OUT" "unreachable" \
    "subshell: the section still aborts"
}

# Case F -- the human's half. The hint that used to be crammed into the verdict
# line ("-- see '== X ==' above") is what made it unparseable; it is kept, on
# the next line, where it costs the verdict nothing.
test_an_explicit_failure_carries_its_status_and_its_hint() {
  guarded 'section "Sample suite"
suite_failed 3 "could not obtain the thing -- see the lines above"'

  assert_eq "$RC" "3" "explicit failure: exits with the status it was given"
  assert_eq "$OUT" "== Sample suite ==
FAILED (exit 3) Sample suite
could not obtain the thing -- see the lines above" \
    "explicit failure: verdict alone on its line, hint on the next"
}

# Case G -- the deferred verdict's shape, which is the Java leg's (#41): the
# status is kept, the sections after it run, and the verdict is printed at the
# bottom naming the suite it was deferred from rather than the last one to
# start. Exercised here as a scratch script because the real thing needs a JDK
# and a red BootTests; the acceptance run covers that on a throwaway copy.
test_a_deferred_verdict_names_the_suite_it_was_deferred_from() {
  guarded 'section "Deferred suite"
deferred_suite="$DC_SUITE"
status=0
( exit 4 ) || status=$?
echo
section "Later suite"
true
echo
if [ "$status" -ne 0 ]; then
  DC_SUITE="$deferred_suite"
  suite_failed "$status" "see the == $deferred_suite == section above"
fi
echo "ALL TESTS PASSED"'

  assert_eq "$RC" "4" "deferred verdict: exits with the deferred status"
  assert_matches_once "$OUT" "$(verdict_re "Deferred suite")" \
    "deferred verdict: names the suite whose failure it is"
  assert_eq "$(count_matching "$OUT" "$(verdict_re "Later suite")")" "0" \
    "deferred verdict: not the section that happened to run last"
  assert_contains "$OUT" "== Later suite ==" \
    "deferred verdict: the sections after the failure still ran -- that is why it is deferred"
  assert_not_contains "$OUT" "ALL TESTS PASSED" "deferred verdict: the run is still red"
}

# Case H -- a status that is not a number. suite_failed cannot refuse and
# return, the way the rest of this repo's shell does: control would go back to a
# script that may then print ALL TESTS PASSED, and a bare `exit "$status"` would
# lose the verdict to bash's own "numeric argument required". It fails as 1.
test_an_unusable_status_still_fails_and_still_parses() {
  guarded 'section "Sample suite"
suite_failed "not-a-number"'

  assert_eq "$RC" "1" "unusable status: a failure with an unreadable status is still a failure"
  assert_matches_once "$OUT" "$(verdict_re "Sample suite")" \
    "unusable status: the verdict is still in the recognised form"

  guarded 'section "Sample suite"
suite_failed 0'

  assert_eq "$RC" "1" "zero status: a verdict of failure must not exit 0"
  assert_matches_once "$OUT" "$(verdict_re "Sample suite")" "zero status: still parseable"
}

# --- static rails on the real runner -----------------------------------------
#
# run-tests.sh cannot be executed from inside itself, so these read it. They are
# the guard on the next section somebody adds: the reason this is a library and
# a trap rather than a `|| echo FAILED` per suite is that the tenth site is the
# one that forgets, and a forgotten site is silent.

test_the_runner_prints_every_header_through_section() {
  local stray
  stray="$(grep -n 'echo "== ' "$RUN_TESTS" || true)"
  assert_eq "$stray" "" \
    "runner: a header printed by a bare echo has no verdict behind it -- use section"

  local n
  n="$(grep -c '^section "' "$RUN_TESTS" || true)"
  [ "$n" -ge 9 ] || fail "runner: expected the runner's sections to go through section(), found $n"
}

test_the_runner_has_no_unparseable_verdict_left() {
  local stray
  stray="$(grep -n 'FAILED:' "$RUN_TESTS" || true)"
  assert_eq "$stray" "" \
    "runner: 'FAILED: ...' is the free-text form no parser recognises (#80)"
}

test_the_runner_arms_the_verdict_trap() {
  local body
  body="$(cat "$RUN_TESTS")"
  assert_contains "$body" "set -Eeuo pipefail" \
    "runner: -E is what gives the ERR trap the same reach inside subshells and functions"
  assert_contains "$body" 'gate-lib.sh' "runner: sources the library that prints the verdicts"
  assert_contains "$body" "gate_verdict_trap" \
    "runner: arms the trap -- without it a red section aborts with no verdict at all"
}

for CURRENT in \
  test_section_prints_the_header_and_records_the_name \
  test_a_section_with_no_name_is_refused \
  test_a_failing_suite_prints_the_recognised_verdict_form \
  test_the_verdict_names_the_section_that_failed_not_an_earlier_one \
  test_a_failure_inside_a_subshell_yields_exactly_one_verdict \
  test_an_explicit_failure_carries_its_status_and_its_hint \
  test_a_deferred_verdict_names_the_suite_it_was_deferred_from \
  test_an_unusable_status_still_fails_and_still_parses \
  test_the_runner_prints_every_header_through_section \
  test_the_runner_has_no_unparseable_verdict_left \
  test_the_runner_arms_the_verdict_trap
do
  before=$FAILURES
  "$CURRENT"
  if [ "$FAILURES" -eq "$before" ]; then echo "PASS: $CURRENT"; else echo "FAILED: $CURRENT"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES assertion failure(s)"
  exit 1
fi
