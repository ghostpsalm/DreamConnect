#!/usr/bin/env python3
"""Unit tests for scripts/gate.sh, the gate entry point.

gate.sh is a delegator and its whole contract is the delegation: find this
repository's real gate next to itself and become it. That contract is testable
without running a single suite, and it has to be tested that way — invoking the
real gate from a test would run the entire test tree from inside itself.

So the subject is a *copy* of gate.sh in a tmp fixture tree, with a recording
stub standing in for the delegate. Nothing here touches the repository's own
delegate script, and no suite is executed.

Run:  python3 scripts/test_gate.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GATE = os.path.join(HERE, "gate.sh")
DELEGATE = "run-tests.sh"  # named once: the fixture and the assertions agree


class TestGateDelegates(unittest.TestCase):
    """gate.sh copied into a fixture tree, with a stub delegate that records
    how it was called and exits with whatever status the test asked for."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dreamconnect-gate-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        os.mkdir(os.path.join(self.tmp, "scripts"))
        self.gate = os.path.join(self.tmp, "scripts", "gate.sh")
        shutil.copy(GATE, self.gate)
        self.log = os.path.join(self.tmp, "calls.log")

    def _stub_delegate(self, exit_status):
        """Write the fixture delegate. It appends one line per invocation, so a
        gate that ran it twice — or that ran a second suite of its own — is
        visible as more than one line rather than as a silent pass."""
        path = os.path.join(self.tmp, DELEGATE)
        with open(path, "w") as f:
            f.write("#!/usr/bin/env bash\n"
                    'echo "invoked cwd=$PWD" >> "%s"\n'
                    "exit %d\n" % (self.log, exit_status))
        os.chmod(path, 0o755)
        return path

    def _run_gate(self, cwd):
        return subprocess.run([self.gate], cwd=cwd, capture_output=True,
                              text=True)

    def _calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def test_runs_the_delegate_beside_it_not_the_one_in_the_cwd(self):
        # The gate is run from a directory that is not the fixture tree and
        # holds a delegate of its own. A gate that resolved the delegate from
        # $PWD would run the wrong repository's tests and still report green.
        self._stub_delegate(0)
        elsewhere = tempfile.mkdtemp(prefix="dreamconnect-gate-cwd-")
        self.addCleanup(shutil.rmtree, elsewhere, True)
        decoy = os.path.join(elsewhere, DELEGATE)
        with open(decoy, "w") as f:
            f.write("#!/usr/bin/env bash\nexit 42\n")
        os.chmod(decoy, 0o755)

        result = self._run_gate(cwd=elsewhere)

        self.assertEqual(result.returncode, 0,
                         "the decoy's exit 42 must not be what the gate reports")
        self.assertEqual(len(self._calls()), 1,
                         "the delegate beside gate.sh runs exactly once: "
                         "gate.sh carries no suite list of its own")

    def test_a_failing_delegate_fails_the_gate(self):
        # The one thing a delegator must never do is swallow the status of what
        # it delegated to.
        self._stub_delegate(3)
        result = self._run_gate(cwd=self.tmp)
        self.assertEqual(result.returncode, 3,
                         "the delegate's exit status is the gate's")

    def test_a_missing_delegate_is_a_failure_not_a_pass(self):
        # No stub written at all. An empty tree must not read as "nothing to
        # run, therefore green" — that is the failure mode a gate exists to
        # prevent.
        result = self._run_gate(cwd=self.tmp)
        self.assertNotEqual(result.returncode, 0,
                            "a gate that cannot find its delegate must fail")


class TestDelegateExists(unittest.TestCase):
    """The delegation above is only meaningful if the real target is there.
    This is the one assertion in this file about the repository itself."""

    def test_the_repository_has_the_delegate_gate_sh_names(self):
        path = os.path.join(ROOT, DELEGATE)
        self.assertTrue(os.access(path, os.X_OK),
                        "%s must exist and be executable: scripts/gate.sh "
                        "execs it and nothing else" % path)


if __name__ == "__main__":
    unittest.main()
