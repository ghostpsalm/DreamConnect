# shellcheck shell=bash
#
# The one place the shell test harnesses decide what a case's result line looks
# like (#81). Sourced by test_install.sh, agent/test_fixture_fetch.sh,
# agent/test_build.sh and agent/test_boot_output.sh. Definitions only, like
# install-lib.sh: sourcing it must do nothing.
#
# The form is BootTests' (#78), byte for byte:
#
#   ok  : <case>
#   FAIL  : <case> # <diagnostic>
#
# Whoever reads this output beyond the terminal -- the Factory's run comparison
# -- parses a check as `<word><whitespace><name>` and treats the text before the
# first " # " as the check's identity and the rest as evidence. The harnesses
# used to print `PASS: <case>` / `FAILED: <case>`, where the word is followed by
# a colon, so not one of their ~320 cases was a check to that reader: a failing
# installer case was visible only as its suite's exit code.
#
# One formatter rather than four copies of it, because four copies are four
# things that can drift apart, and the reader that parses them never sees which
# one drifted -- the case simply stops being a check.

# The same prefixes and separator as BootTests.OK_PREFIX / FAIL_PREFIX / DIAG.
CASE_OK_PREFIX="ok  : "
CASE_FAIL_PREFIX="FAIL  : "
CASE_DIAG=" # "

# case_line NAME FAIL_DELTA [FIRST_FAILURE]
#
# NAME is the case's identity and must be the same on every run and every box:
# the harnesses pass the test function's name, which is. It is refused if it
# carries the separator, because the check would then be silently renamed to the
# part before it -- the defect this form exists to fix -- and refused if empty,
# because an empty identity is not a check.
#
# FAIL_DELTA is how many assertions the case failed; 0 is a pass. Everything
# that varies between runs -- the count, and the first failure's own text, which
# routinely quotes temp directories and captured output -- goes after the
# separator, so a failing case keeps the identity its passing form had.
#
# The first failure is flattened onto the line and cut short: a diagnostic that
# spans lines would leave its continuation lines for the parser to misread, and
# assertion text often embeds a whole captured stderr. The full text is still in
# the `assertion failed:` lines printed above the case line.
case_line() {  # name fail_delta [first_failure]
  local name="${1-}" delta="${2-}" first="${3-}"
  if [ -z "$name" ]; then
    echo "case_line: a case needs a name" >&2
    return 1
  fi
  case "$name" in
    *"$CASE_DIAG"*)
      echo "case_line: case name [$name] contains the diagnostic separator [$CASE_DIAG]" >&2
      return 1 ;;
  esac
  # Checked before any comparison: `[ x -eq 0 ]` on a non-number is an error
  # that `[` reports as false, which would print a pass for a case whose result
  # was never known.
  case "$delta" in
    ''|*[!0-9]*)
      echo "case_line: failure count for $name is not a number: [$delta]" >&2
      return 1 ;;
  esac
  if [ "$delta" -eq 0 ]; then
    printf '%s%s\n' "$CASE_OK_PREFIX" "$name"
    return 0
  fi
  # \r, \v and \f as well as \n: a line-oriented reader such as Python's
  # splitlines() breaks on all of them.
  first="${first//[$'\n\r\v\f']/ }"
  [ "${#first}" -le 200 ] || first="${first:0:200}..."
  printf '%s%s%s%s assertion failure(s)%s\n' "$CASE_FAIL_PREFIX" "$name" "$CASE_DIAG" \
    "$delta" "${first:+; first: $first}"
}

# assertion_failed MESSAGE -- the detail line fail() prints above a case line.
#
# Every line of it is prefixed, not only the first. Assertions embed the whole
# value they compared (`got [$1]`), and when that value is itself test output --
# as it is in the tests of this file's own formatter -- a bare continuation line
# can begin `ok  : ...` at column 0 and be read as a check that does not exist.
# Found by review of #81 by making those very tests fail.
assertion_failed() {  # message
  local first=1 line
  # The other breaks splitlines() honours become real ones first, so they get a
  # prefix too rather than hiding a column-0 line inside what bash sees as one.
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      printf '  assertion failed: %s\n' "$line"
      first=0
    else
      printf '    | %s\n' "$line"
    fi
  done <<<"${1//[$'\r\v\f']/$'\n'}"
}
