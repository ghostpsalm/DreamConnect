#!/usr/bin/env bash
#
# The gate's suite headers and suite verdicts, in one place (#80).
#
# run-tests.sh used to print a failing suite as `FAILED: the Java boot tests
# (exit 1) -- see ...`. That reads fine to a human and parses as nothing: the
# generic suite-verdict form is `FAILED (exit N) <suite>`, where <suite> is the
# name in the `== <suite> ==` header, so a run whose Java leg failed had that
# leg recorded as *passed* and only the gate's own exit code was red. Every
# other section was worse still -- it aborted under `set -e` with no verdict
# line at all.
#
# So the header and the verdict are printed from here, off the same variable:
# the name in `== X ==` and the name in `FAILED (exit N) X` cannot disagree,
# which is the same reason scripts/gate.sh is a delegator rather than a second
# list of suites.
#
# Definitions only: sourcing must have no side effects, the rule install-lib.sh
# and agent/fixture-lib.sh already follow (see CLAUDE.md, "Seams").

section() {  # NAME -- print the suite header and make NAME the current suite
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "gate-lib.sh: section needs a suite name" >&2
    return 1
  fi
  DC_SUITE="$name"
  echo "== $name =="
}

suite_failed() {  # STATUS [hint...] -- print the current suite's verdict and exit
  local status="${1-}"
  shift 2>/dev/null || :

  # First, before anything that could itself fail: a printf onto a closed stdout
  # would otherwise re-enter this function through the ERR trap that called it.
  trap - ERR

  # Coerced, not refused. Everywhere else in this repo bad input earns a `return
  # 1` in the function's own voice (CLAUDE.md, "Shell"), but this function's
  # whole job is to end a red run: returning would hand control back to a script
  # that may well go on to print ALL TESTS PASSED, and `exit "not-a-number"`
  # loses the verdict to bash's own "numeric argument required". A failure whose
  # status cannot be read is still a failure, so it becomes 1.
  case "$status" in
    ''|*[!0-9]*|0) status=1 ;;
  esac

  # Alone on one line, and on stdout beside the headers rather than on stderr:
  # the two streams are separately buffered, so a verdict on stderr can surface
  # anywhere relative to the `== ... ==` header it belongs to, and the whole
  # point of this line is that a reader -- human or parser -- can tie it to one.
  printf 'FAILED (exit %s) %s\n' "$status" "${DC_SUITE:-the gate}"
  [ "$#" -gt 0 ] && printf '%s\n' "$*"

  exit "$status"
}

gate_err_verdict() {  # STATUS -- the ERR trap's handler
  # A subshell inherits this trap -- that is what `set -E` does -- and a failure
  # inside one fails the enclosing command too, so `( false )` would print the
  # same suite's verdict twice: once from the subshell, once from the parent.
  # Two verdict lines read as two failed suites. The subshell therefore carries
  # the status out silently and lets the parent speak. $$ stays the parent's pid
  # inside a subshell; BASHPID does not.
  #
  # Command substitutions are already quiet for a different reason -- their
  # stdout is captured, so a verdict printed there would land in the variable
  # rather than in the output -- but that is a worse place for it, not a better
  # one, and the same check covers both.
  if [ "${BASHPID:-$$}" != "$$" ]; then
    exit "$1"
  fi
  suite_failed "$1"
}

gate_verdict_trap() {  # install the ERR trap; needs `set -E` to reach subshells
  # A trap rather than `|| suite_failed $?` on every suite line: there are nine
  # sections and the tenth one added is the one that forgets. The trap also
  # fires for the ordinary commands inside a section -- a mktemp, a javac --
  # and names that section, which is where the failure happened.
  trap 'gate_err_verdict $?' ERR
}
