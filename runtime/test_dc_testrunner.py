#!/usr/bin/env python3
"""Tests for dc_testrunner.py, the one runner every Python suite goes through (#87).

Each case writes a fixture suite into a temp directory and runs the runner on it
as a separate process, the way run-tests.sh does: what is under test is the
stdout a parser reads and the exit status the gate reads, and neither is
observable from inside the process that produces it.
"""

import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RUNNER = os.path.join(HERE, "dc_testrunner.py")

CHECK = re.compile(r"^(ok|FAIL|SKIP)  : ")
# Every line the runner may print that is not a check line. Anything else at
# all -- above all a test's own output reaching stdout unprefixed -- fails the
# phantom tests below, whatever word it happens to start with.
DETAIL = ("  output: ", "  traceback: ", "    | ", "ran ", "cannot run: ",
          "error outside any case: ")


def checks(stdout):
    """The check lines of STDOUT as (word, identity), identity cut at ' # '."""
    found = []
    for line in stdout.splitlines():
        if CHECK.match(line):
            word, rest = line.split("  : ", 1)
            found.append((word, rest.split(" # ", 1)[0]))
    return found


class RunnerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def run_suite(self, name, source, env=None):
        path = os.path.join(self.tmp.name, name + ".py")
        with open(path, "w") as f:
            f.write(textwrap.dedent(source))
        proc = subprocess.run(
            [sys.executable, RUNNER, path], cwd=self.tmp.name,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=dict(os.environ, **(env or {})), timeout=60)
        return proc.returncode, proc.stdout.decode()

    def assert_only_runner_lines(self, out):
        for line in out.splitlines():
            if not (CHECK.match(line) or line.startswith(DETAIL)):
                self.fail("a line the runner did not write reached stdout: %r\n%s"
                          % (line, out))


MIXED = """
    import unittest

    class Mixed(unittest.TestCase):
        def test_pass(self):
            pass

        def test_fail(self):
            self.assertEqual(1, 2)

        def test_error(self):
            raise RuntimeError("boom")

        @unittest.skip("not here")
        def test_skip(self):
            pass

        def test_subtest(self):
            for i in range(3):
                with self.subTest(i=i):
                    self.assertNotEqual(i, 1)

        @unittest.expectedFailure
        def test_unexpected_success(self):
            pass

        @unittest.expectedFailure
        def test_expected_failure(self):
            self.fail("known")

    class Broken(unittest.TestCase):
        @classmethod
        def setUpClass(cls):
            raise RuntimeError("no fixture")

        def test_a(self):
            pass
"""


class TestCheckLines(RunnerCase):
    def test_each_outcome_prints_its_exact_check_line(self):
        status, out = self.run_suite("fx_mixed", MIXED)
        lines = [l for l in out.splitlines() if CHECK.match(l)]
        self.assertEqual(lines, [
            "FAIL  : fx_mixed.Broken.test_a # 1 failure(s); first: setUpClass failed: RuntimeError: no fixture",
            "FAIL  : fx_mixed.Mixed.test_error # 1 failure(s); first: RuntimeError: boom",
            "ok  : fx_mixed.Mixed.test_expected_failure",
            "FAIL  : fx_mixed.Mixed.test_fail # 1 failure(s); first: AssertionError: 1 != 2",
            "ok  : fx_mixed.Mixed.test_pass",
            "SKIP  : fx_mixed.Mixed.test_skip",
            "FAIL  : fx_mixed.Mixed.test_subtest # 1 failure(s); first: (i=1) AssertionError: 1 == 1",
            "FAIL  : fx_mixed.Mixed.test_unexpected_success # 1 failure(s); first: unexpected success",
        ], out)
        self.assertEqual(status, 1, out)
        self.assertIn("ran 8 case(s): 2 ok, 5 failed, 1 skipped", out)
        self.assert_only_runner_lines(out)

    def test_a_failing_case_shows_its_traceback_above_its_line(self):
        _, out = self.run_suite("fx_mixed", MIXED)
        lines = out.splitlines()
        at = lines.index("FAIL  : fx_mixed.Mixed.test_fail # 1 failure(s); first: AssertionError: 1 != 2")
        self.assertTrue(lines[at - 1].startswith("    | "), out)
        self.assertIn("  traceback: Traceback (most recent call last):", lines[:at])

    def test_a_case_keeps_its_identity_whether_it_passes_or_fails(self):
        src = """
            import os, unittest
            class T(unittest.TestCase):
                def test_toggle(self):
                    self.assertNotEqual(os.environ.get("FX_FAIL"), "1", "made to fail")
        """
        runs = [self.run_suite("fx_toggle", src, {"FX_FAIL": v}) for v in ("0", "0", "1", "1")]
        self.assertEqual([r[0] for r in runs], [0, 0, 1, 1])
        self.assertEqual(runs[0][1], runs[1][1])
        self.assertEqual(checks(runs[0][1]), [("ok", "fx_toggle.T.test_toggle")])
        self.assertEqual(checks(runs[2][1]), [("FAIL", "fx_toggle.T.test_toggle")])
        self.assertEqual(checks(runs[2][1]), checks(runs[3][1]))


PHANTOM = """
    import os, subprocess, sys, unittest

    def emit_phantoms(tag):
        print("ok  : phantom-print-" + tag)
        print("FAIL  : phantom-stderr-" + tag, file=sys.stderr)
        sys.stdout.flush()
        os.write(1, ("ok  : phantom-fd1-" + tag + "\\n").encode())
        os.write(2, ("SKIP  : phantom-fd2-" + tag + "\\n").encode())
        subprocess.run(["sh", "-c", "echo 'ok  : phantom-child-" + tag + "'; "
                        "echo 'ok  : phantom-child-err-" + tag + "' >&2"])
        print("x\\rok  : phantom-cr-" + tag + "\\vok  : phantom-vt-" + tag
              + "\\x0cok  : phantom-ff-" + tag + "\\x85ok  : phantom-nel-" + tag)

    class P(unittest.TestCase):
        def test_pass(self):
            emit_phantoms("pass")

        def test_fail(self):
            emit_phantoms("fail")
            self.fail("ok  : phantom-in-message\\nok  : phantom-message-line")
"""


class TestPhantomLines(RunnerCase):
    def test_nothing_a_test_prints_becomes_a_check_line(self):
        status, out = self.run_suite("fx_phantom", PHANTOM)
        self.assertEqual(status, 1, out)
        self.assertEqual(set(checks(out)),
                         {("ok", "fx_phantom.P.test_pass"), ("FAIL", "fx_phantom.P.test_fail")},
                         out)
        self.assert_only_runner_lines(out)

    def test_a_failing_case_still_shows_what_it_printed(self):
        _, out = self.run_suite("fx_phantom", PHANTOM)
        for kind in ("print", "stderr", "fd1", "fd2", "child", "child-err", "cr", "nel"):
            self.assertIn("phantom-%s-fail" % kind, out)
        self.assertNotIn("phantom-print-pass", out)


class TestExitStatus(RunnerCase):
    def test_all_passing_exits_zero(self):
        status, out = self.run_suite("fx_green", """
            import unittest
            class T(unittest.TestCase):
                def test_a(self): pass
                def test_b(self): pass
        """)
        self.assertEqual(status, 0, out)
        self.assertEqual(out.splitlines()[-1], "ran 2 case(s): 2 ok, 0 failed, 0 skipped")

    def test_one_failure_exits_one(self):
        status, out = self.run_suite("fx_red", """
            import unittest
            class T(unittest.TestCase):
                def test_a(self): pass
                def test_b(self): self.fail("no")
        """)
        self.assertEqual(status, 1, out)

    def test_a_suite_with_no_cases_cannot_run(self):
        status, out = self.run_suite("fx_empty", "import unittest\n")
        self.assertEqual(status, 1, out)
        self.assertIn("cannot run: no test cases loaded", out)
        self.assertEqual(checks(out), [])

    def test_a_module_level_skip_cannot_run(self):
        status, out = self.run_suite("fx_modskip", """
            import unittest
            raise unittest.SkipTest("not on this box")
            class T(unittest.TestCase):
                def test_a(self): pass
        """)
        self.assertEqual(status, 1, out)
        self.assertRegex(out, r"(?m)^cannot run: .*fx_modskip\.py: (unittest\.case\.)?SkipTest: not on this box$")

    def test_an_import_error_cannot_run(self):
        status, out = self.run_suite("fx_import", """
            import unittest
            import no_such_module_anywhere
            print("ok  : phantom-at-import")
        """)
        self.assertEqual(status, 1, out)
        self.assertIn("ModuleNotFoundError", out)
        self.assertEqual(checks(out), [])
        self.assert_only_runner_lines(out)

    def test_every_case_skipped_cannot_run(self):
        status, out = self.run_suite("fx_allskip", """
            import unittest
            class T(unittest.TestCase):
                @unittest.skip("x")
                def test_a(self): pass
                def test_b(self): self.skipTest("y")
        """)
        self.assertEqual(status, 1, out)
        self.assertEqual(checks(out), [("SKIP", "fx_allskip.T.test_a"), ("SKIP", "fx_allskip.T.test_b")])
        self.assertIn("cannot run: every case was skipped", out)

    def test_a_setupmodule_skip_skips_every_case_and_cannot_run(self):
        status, out = self.run_suite("fx_setupskip", """
            import unittest
            def setUpModule():
                raise unittest.SkipTest("no session")
            class T(unittest.TestCase):
                def test_a(self): pass
        """)
        self.assertEqual(status, 1, out)
        self.assertEqual(checks(out), [("SKIP", "fx_setupskip.T.test_a")])

    def test_a_teardownclass_failure_fails_the_cases_it_owns(self):
        status, out = self.run_suite("fx_teardown", """
            import unittest
            class T(unittest.TestCase):
                @classmethod
                def tearDownClass(cls):
                    raise RuntimeError("leak")
                def test_a(self): pass
        """)
        self.assertEqual(status, 1, out)
        self.assertEqual(checks(out), [("FAIL", "fx_teardown.T.test_a")])
        self.assertIn("tearDownClass failed: RuntimeError: leak", out)

    def test_an_id_carrying_the_separator_cannot_run(self):
        status, out = self.run_suite("fx_badid", """
            import unittest
            class T(unittest.TestCase):
                def id(self): return "a # b"
                def test_a(self): pass
        """)
        self.assertEqual(status, 1, out)
        self.assertIn("cannot run: a test id is not a usable check identity", out)
        self.assertEqual(checks(out), [])


def suites_not_run_through_the_runner(gate, suites):
    """The names in SUITES that GATE does not run, alone, through the runner.

    The invocation must be the whole line: indentation, then exactly
    `python3 "$HERE/runtime/dc_testrunner.py" "$HERE/runtime/<suite>"`, then
    nothing. A substring match was satisfied by a commented-out line, which
    runs nothing, and by one ending `|| true` (or `; true`, or `&`), which
    runs the suite but can no longer turn the gate red -- both left this case
    green. Ruling out the whole-line form's neighbours one by one would be a
    list that is never finished; requiring the one form is not.
    """
    return [name for name in suites if not re.search(
        r'(?m)^[ \t]*python3 "\$HERE/runtime/dc_testrunner\.py" "\$HERE/runtime/%s"[ \t]*$'
        % re.escape(name), gate)]


class TestTheGateRunsEverySuiteThroughTheRunner(unittest.TestCase):
    def test_every_python_suite_is_run_through_the_shared_runner(self):
        with open(os.path.join(REPO, "run-tests.sh")) as f:
            gate = f.read()
        suites = sorted(
            name for name in os.listdir(HERE)
            if name.startswith("test_") and name.endswith(".py")
            and re.search(r"(?m)^\s*(import unittest|from unittest\b)",
                          open(os.path.join(HERE, name)).read()))
        self.assertGreaterEqual(len(suites), 5, suites)
        self.assertEqual(suites_not_run_through_the_runner(gate, suites), [],
                         "run-tests.sh does not run these through dc_testrunner.py")
        # Patterns, not the literal text, so that these lines do not describe
        # themselves to a reader scanning this file.
        self.assertNotRegex(gate, r"-m +unittest")
        self.assertNotRegex(gate, r'python3 +"?\$HERE/runtime/test_')
        self.assertNotRegex(gate, r"\| *tail\b")

    def test_a_disabled_or_status_swallowing_invocation_does_not_count(self):
        # The matcher above, against the lines that used to satisfy it. Without
        # this the case could be loosened back to a substring match and stay
        # green, since the real run-tests.sh contains none of these.
        good = 'python3 "$HERE/runtime/dc_testrunner.py" "$HERE/runtime/test_x.py"'
        self.assertEqual(suites_not_run_through_the_runner(good + "\n", ["test_x.py"]), [])
        self.assertEqual(suites_not_run_through_the_runner("  " + good + "\n", ["test_x.py"]), [])
        for line in ("# " + good, "#" + good, good + " || true", good + "|| :",
                     good + "; true", good + " &", "if ! " + good + "; then :; fi",
                     good + " | cat", "true || " + good,
                     good.replace("test_x.py", "test_x.py.bak")):
            self.assertEqual(
                suites_not_run_through_the_runner(line + "\n", ["test_x.py"]),
                ["test_x.py"], line)


if __name__ == "__main__":
    unittest.main(verbosity=2)
