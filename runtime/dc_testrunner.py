#!/usr/bin/env python3
"""Run one unittest suite and print each case as a check line (#87).

    python3 runtime/dc_testrunner.py runtime/test_daemon.py

The gate's reader -- the Factory's run comparison -- parses a check as
`<word><whitespace><name>` and treats the text before the first " # " as its
identity, the form BootTests (#78) and the shell harnesses (#81) print:

    ok  : <test id>
    FAIL  : <test id> # <n> failure(s); first: <ExcType: message>
    SKIP  : <test id>

unittest's own `-v` line, `test_x (module.Class.test_x) ... ok`, matches none
of its grammars, and run-tests.sh piped every Python suite through `tail`
besides, so the gate's ~175 Python cases were not one check between them: a
case that was deleted, renamed or weakened left its section as green as before.

One runner for every suite rather than a result class pasted into four
`__main__` blocks, for the reason test-harness-lib.sh gives for case_line: four
copies are four things that can drift, and the reader never sees which one did
-- the case simply stops being a check. The suites themselves are unchanged and
still run on their own with `python3 runtime/test_x.py`.

What a test prints cannot become a check line. fd 1 and fd 2 -- not merely
sys.stdout -- point at a capture file for the whole run, so a print, an
os.write from C, and a child process's output are all caught. Only this
runner's own lines reach the real stdout. A passing case's output is dropped;
a failing case's is shown above its line with every line of it prefixed, the
way assertion_failed does in the shell harnesses, so none can sit at column 0.

Lines are printed once the run is over, in load order, not as each case ends:
a tearDownClass that fails after its cases passed would otherwise leave them
printed `ok` with no way to take it back short of a second line for the same
identity. The price is that a run killed mid-way prints no case lines -- its
exit status is still red.

The exit status is 0 only if no case failed and at least one passed. A suite
that cannot import, raises SkipTest at module level, loads no cases, or skips
every case is red with a `cannot run:` line: each of those used to be a green
section with nothing in it.
"""

import importlib.util
import os
import re
import sys
import tempfile
import traceback
import unittest

OK_PREFIX = "ok  : "
FAIL_PREFIX = "FAIL  : "
SKIP_PREFIX = "SKIP  : "
DIAG = " # "
DIAG_LIMIT = 200

# unittest reports a class or module fixture's failure against an _ErrorHolder
# whose description is `setUpClass (module.Class)` or `setUpModule (module)`.
# That description is not a case and must not become one -- it exists only
# while the fixture fails, so its identity would appear and vanish with the
# failure. It is charged to every case in its scope instead.
_FIXTURE = re.compile(r"^(\w+) \((.+)\)$")


class _Case:
    def __init__(self):
        self.failures = []  # one-line summaries, first one goes on the case line
        self.details = []   # (label, text) shown above a failing case line
        self.skipped = 0
        self.passed = 0
        self.started = False


def _one_line(exc_info):
    """`ExcType: message`, the last line of the exception as Python prints it."""
    return traceback.format_exception_only(exc_info[0], exc_info[1])[-1].strip()


class _CheckResult(unittest.TestResult):
    """Records outcomes per test id; nothing is printed while tests run."""

    def __init__(self, capture):
        super().__init__()
        self.capture = capture
        self.cases = {}
        self.order = []
        self.orphans = []  # fixture errors whose scope holds no case
        self._current = None

    def case(self, test_id):
        if test_id not in self.cases:
            self.cases[test_id] = _Case()
            self.order.append(test_id)
        return self.cases[test_id]

    def _owner(self, test):
        # A subtest folds into the test it belongs to, so a parameter repr
        # never becomes an identity.
        return getattr(test, "test_case", test)

    def startTest(self, test):
        super().startTest(test)
        # Anything written since the last case ended -- a daemon thread's late
        # write, a fixture's print -- belongs to no case; dropped.
        self.capture.drain()
        self._current = self.case(test.id())
        self._current.started = True

    def stopTest(self, test):
        out = self.capture.drain()
        if out and self._current is not None:
            self._current.details.append(("output", out))
        self._current = None
        super().stopTest(test)

    def _fail(self, test, summary, exc_info):
        owner = self._owner(test)
        tb = self._exc_info_to_string(exc_info, owner) if exc_info else ""
        if isinstance(owner, unittest.TestCase):
            if owner is not test:
                summary = "%s %s" % (test._subDescription(), summary)
            case = self.case(owner.id())
            case.failures.append(summary)
            if tb:
                case.details.append(("traceback", tb))
            return
        self._fixture_failure(owner, summary, tb)

    def _fixture_failure(self, holder, summary, tb):
        description = str(holder)
        out = self.capture.drain()
        m = _FIXTURE.match(description)
        scope = m.group(2) if m else description
        fixture = m.group(1) if m else description
        owned = [t for t in self.expected if t.startswith(scope + ".")]
        if not owned:
            self.orphans.append((description, summary, out, tb))
            return
        for test_id in owned:
            case = self.case(test_id)
            case.failures.append("%s failed: %s" % (fixture, summary))
            if out:
                case.details.append(("output", out))
            if tb:
                case.details.append(("traceback", tb))

    def addError(self, test, err):
        super().addError(test, err)
        self._fail(test, _one_line(err), err)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._fail(test, _one_line(err), err)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self._fail(subtest, _one_line(err), err)
        else:
            self.case(test.id()).passed += 1

    def addSuccess(self, test):
        super().addSuccess(test)
        self.case(test.id()).passed += 1

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        owner = self._owner(test)
        if isinstance(owner, unittest.TestCase):
            self.case(owner.id()).skipped += 1
            return
        # setUpModule or setUpClass raised SkipTest: every case in scope
        # skipped without starting.
        m = _FIXTURE.match(str(owner))
        scope = m.group(2) if m else str(owner)
        for test_id in self.expected:
            if test_id.startswith(scope + "."):
                self.case(test_id).skipped += 1

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.case(self._owner(test).id()).passed += 1

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self._fail(test, "unexpected success", None)


class _Capture:
    """fd 1 and fd 2 redirected into one file; drain() returns what is new."""

    def __init__(self):
        sys.stdout.flush()
        sys.stderr.flush()
        self.real_out = os.dup(1)
        self.real_err = os.dup(2)
        # O_APPEND: fd 1, fd 2 and every child process share this one file
        # description, and each write lands at the end whoever makes it.
        fd, self.path = tempfile.mkstemp(prefix="dc_testrunner.")
        os.close(fd)
        self.fd = os.open(self.path, os.O_WRONLY | os.O_APPEND)
        self.read_fd = os.open(self.path, os.O_RDONLY)
        self.mark = 0
        os.dup2(self.fd, 1)
        os.dup2(self.fd, 2)

    def drain(self):
        sys.stdout.flush()
        sys.stderr.flush()
        end = os.fstat(self.fd).st_size
        data = os.pread(self.read_fd, end - self.mark, self.mark) if end > self.mark else b""
        self.mark = end
        return data.decode("utf-8", "replace")

    def close(self):
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except (OSError, ValueError):
            pass
        os.dup2(self.real_out, 1)
        os.dup2(self.real_err, 2)
        for fd in (self.fd, self.read_fd, self.real_out, self.real_err):
            os.close(fd)
        os.unlink(self.path)


def _flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten(item)
        else:
            yield item


def _detail_lines(label, text):
    """Every line prefixed, the first with its label, the rest with `    | `.

    splitlines() rather than split("\\n"): it also breaks on \\r, \\v, \\f and
    the Unicode separators, and a reader that splits on any of them would
    otherwise find an unprefixed line inside what looked like one.
    """
    lines = text.splitlines() or [""]
    yield "  %s: %s" % (label, lines[0])
    for line in lines[1:]:
        yield "    | %s" % line


def _summary(text):
    text = " ".join(text.split())
    return text if len(text) <= DIAG_LIMIT else text[:DIAG_LIMIT] + "..."


def _load(path):
    """The suite as a module named for its file, as `python3 test_x.py` would."""
    name = os.path.splitext(os.path.basename(path))[0]
    sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError("not a loadable Python file: %s" % path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def run(path):
    """Run the suite at PATH with fd 1 and 2 captured; return its outcome."""
    capture = _Capture()
    try:
        try:
            module = _load(path)
        # BaseException: SystemExit and a module-level SkipTest included -- a
        # suite that skips itself at import is a suite that ran nothing.
        except BaseException as e:  # noqa: BLE001
            if isinstance(e, KeyboardInterrupt):
                raise
            out = capture.drain()
            tb = "".join(traceback.format_exception(type(e), e, e.__traceback__))
            return ("cannot", path, _summary(_one_line((type(e), e, None))), out, tb)
        loader = unittest.TestLoader()
        suite = loader.loadTestsFromModule(module)
        if loader.errors:
            return ("cannot", path, "loader error", capture.drain(),
                    "\n".join(loader.errors))
        expected = []
        for test in _flatten(suite):
            if test.id() not in expected:
                expected.append(test.id())
        result = _CheckResult(capture)
        result.expected = expected
        for test_id in expected:
            result.case(test_id)
        capture.drain()
        suite.run(result)
        capture.drain()
        return ("ran", result)
    finally:
        capture.close()


def report(outcome, emit):
    """Print OUTCOME through EMIT, one line at a time; return the exit status."""
    if outcome[0] == "cannot":
        _, path, why, out, tb = outcome
        for label, text in (("output", out), ("traceback", tb)):
            if text:
                for line in _detail_lines(label, text):
                    emit(line)
        emit("cannot run: %s: %s" % (path, why))
        return 1

    result = outcome[1]
    if not result.order:
        emit("cannot run: no test cases loaded")
        return 1
    for test_id in result.order:
        # The separator would silently rename the check to the part before it,
        # and a line break would leave half an identity at column 0.
        if DIAG in test_id or test_id != " ".join(test_id.split()) or not test_id:
            emit("cannot run: a test id is not a usable check identity: %r" % test_id)
            return 1

    counts = {"ok": 0, "failed": 0, "skipped": 0}
    for test_id in result.order:
        case = result.cases[test_id]
        if not case.failures and not case.skipped and not case.passed:
            # Neither started nor charged with a fixture failure: it was
            # loaded and then never run, which is not a pass.
            case.failures.append("never ran" if not case.started else "no outcome recorded")
        if case.failures:
            counts["failed"] += 1
            for label, text in case.details:
                for line in _detail_lines(label, text):
                    emit(line)
            emit("%s%s%s%d failure(s); first: %s" % (
                FAIL_PREFIX, test_id, DIAG, len(case.failures), _summary(case.failures[0])))
        elif case.skipped:
            counts["skipped"] += 1
            emit(SKIP_PREFIX + test_id)
        else:
            counts["ok"] += 1
            emit(OK_PREFIX + test_id)

    for description, summary, out, tb in result.orphans:
        for label, text in (("output", out), ("traceback", tb)):
            if text:
                for line in _detail_lines(label, text):
                    emit(line)
        emit("error outside any case: %s: %s" % (description, _summary(summary)))

    emit("ran %d case(s): %d ok, %d failed, %d skipped" % (
        len(result.order), counts["ok"], counts["failed"], counts["skipped"]))
    if counts["ok"] == 0 and counts["failed"] == 0:
        emit("cannot run: every case was skipped")
        return 1
    if counts["failed"] or result.orphans:
        return 1
    return 0


def main(argv):
    if len(argv) != 2:
        print("usage: dc_testrunner.py SUITE.py", file=sys.stderr)
        return 2
    outcome = run(argv[1])

    def emit(line):
        print(line, flush=True)

    return report(outcome, emit)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
