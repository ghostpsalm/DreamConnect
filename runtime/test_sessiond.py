#!/usr/bin/env python3
"""Unit tests for the discovery supervisor.

No logind and no systemd: sessions are fed in as property text, and the command
runner is injected so a full reconcile can be driven and asserted without
starting anything.
Run: python3 -m unittest runtime.test_sessiond  (or: python3 runtime/test_sessiond.py)
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_sessiond as sd  # noqa: E402

BLOCK = ("Id={id}\nUser={uid}\nName={user}\nClass={klass}\n"
         "Type={type}\nState={state}\nSeat={seat}\n")


def block(id, uid, user="alice", klass="user", type="wayland",  # noqa: A002
          state="active", seat="seat0"):
    return BLOCK.format(id=id, uid=uid, user=user, klass=klass, type=type,
                        state=state, seat=seat)


class FakeRunner:
    def __init__(self, rc=0, stderr=""):
        self.calls = []
        self._rc, self._stderr = rc, stderr

    def __call__(self, argv):
        self.calls.append(argv)
        return type("R", (), {"returncode": self._rc, "stderr": self._stderr})()


class TestParseSessions(unittest.TestCase):
    def test_parses_two_blocks(self):
        s = sd.parse_sessions(block("18", 1000) + "\n" + block("22", 1001, "bob"))
        self.assertEqual([(x.session_id, x.uid, x.user) for x in s],
                         [("18", 1000, "alice"), ("22", 1001, "bob")])

    def test_a_trailing_block_without_a_blank_line_is_kept(self):
        self.assertEqual(len(sd.parse_sessions(block("18", 1000))), 1)

    def test_a_non_numeric_uid_is_dropped_not_crashed(self):
        # logind should never emit this, but int() on it would take the
        # supervisor down and with it every session's reconciliation.
        text = block("18", 1000).replace("User=1000", "User=notanumber")
        self.assertEqual(sd.parse_sessions(text), [])

    def test_unrelated_properties_are_ignored(self):
        s = sd.parse_sessions(block("18", 1000) + "IdleHint=no\nRemote=no\n")
        self.assertEqual(len(s), 1)

    def test_empty_input(self):
        self.assertEqual(sd.parse_sessions(""), [])


class TestRegisteredUids(unittest.TestCase):
    def test_reads_bare_numeric_entries(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ("1000", "1001"):
                open(os.path.join(d, name), "w").close()
            self.assertEqual(sd.registered_uids(d), [1000, 1001])

    def test_a_stray_temp_file_is_not_an_entry(self):
        # The agent reads only bare-uid names. Counting `.1000.tmp` as one would
        # make us believe a uid is registered when the agent disagrees, and the
        # session would never be attached.
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, ".1000.tmp"), "w").close()
            open(os.path.join(d, "1000.bak"), "w").close()
            self.assertEqual(sd.registered_uids(d), [])

    def test_a_missing_registry_is_empty_not_an_error(self):
        self.assertEqual(sd.registered_uids("/nonexistent/registry"), [])


class TestHostAccount(unittest.TestCase):
    """Getting this wrong deregisters the unattended session, not just a name."""

    def _state(self, text):
        f = tempfile.NamedTemporaryFile("w", suffix=".state", delete=False)
        f.write(text); f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_reads_the_installed_account(self):
        path = self._state("HOST_ACCOUNT=backstage\nHOST_UID=960\n")
        self.assertEqual(sd.host_account(path), "backstage")

    def test_a_missing_state_file_is_none_not_an_error(self):
        self.assertIsNone(sd.host_account("/nonexistent/install.state"))

    def test_a_blank_value_is_no_account(self):
        self.assertIsNone(sd.host_account(self._state("HOST_ACCOUNT=\n")))

    def test_the_backstage_account_is_never_released(self):
        # Its session is `manager-early`, which is not attachable, so without
        # reserving it the supervisor sees an entry with no matching desktop
        # and deregisters the unattended session the install exists to provide.
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "960"), "w").close()
            s = sd.Supervisor(registry_dir=d, reserved_users=("backstage",),
                              runner=r)
            s.list_sessions = lambda: sd.parse_sessions(
                block("11", 960, user="backstage", klass="manager-early",
                      type="unspecified"))
            p = s.reconcile()
        self.assertEqual(p.release, [])
        self.assertEqual(r.calls, [])


class TestUnitNames(unittest.TestCase):
    def test_both_units_are_named_for_the_uid(self):
        self.assertEqual(sd.unit_names(1000),
                         ["dreamconnect-attach@1000.service",
                          "dreamconnect-register@1000.service"])

    def test_start_and_stop_cover_both_units(self):
        self.assertEqual(sd.start_argv(1000)[:2], ["systemctl", "start"])
        self.assertEqual(sd.stop_argv(1000)[:2], ["systemctl", "stop"])
        self.assertEqual(len(sd.start_argv(1000)), 4)


class TestReconcile(unittest.TestCase):
    def _sup(self, sessions_text, registry_dir, runner):
        s = sd.Supervisor(registry_dir=registry_dir, reserved_users=(),
                          runner=runner)
        s.list_sessions = lambda: sd.parse_sessions(sessions_text)
        return s

    def test_a_new_desktop_is_started(self):
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as d:
            p = self._sup(block("18", 1000), d, r).reconcile()
        self.assertEqual([s.uid for s in p.attach], [1000])
        self.assertEqual(r.calls, [sd.start_argv(1000)])

    def test_a_vanished_session_is_stopped(self):
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "1000"), "w").close()
            p = self._sup("", d, r).reconcile()
        self.assertEqual(p.release, [1000])
        self.assertEqual(r.calls, [sd.stop_argv(1000)])

    def test_a_steady_state_starts_and_stops_nothing(self):
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "1000"), "w").close()
            self._sup(block("18", 1000), d, r).reconcile()
        self.assertEqual(r.calls, [])

    def test_a_conflicted_uid_is_never_acted_on(self):
        r = FakeRunner()
        text = block("18", 1000) + "\n" + block("34", 1000)
        with tempfile.TemporaryDirectory() as d:
            p = self._sup(text, d, r).reconcile()
        self.assertEqual(p.conflicts, [(1000, ["18", "34"])])
        self.assertEqual(r.calls, [])

    def test_one_account_failing_does_not_stop_the_others(self):
        # A failed start is logged and retried next pass; it must not abort the
        # loop and leave later accounts unreconciled.
        r = FakeRunner(rc=1, stderr="unit not found")
        text = block("18", 1000) + "\n" + block("22", 1001, "bob")
        with tempfile.TemporaryDirectory() as d:
            self._sup(text, d, r).reconcile()
        self.assertEqual(r.calls, [sd.start_argv(1000), sd.start_argv(1001)])

    def test_reserved_accounts_are_not_touched(self):
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as d:
            s = sd.Supervisor(registry_dir=d, reserved_users=("backstage",),
                              runner=r)
            s.list_sessions = lambda: sd.parse_sessions(
                block("40", 995, user="backstage"))
            p = s.reconcile()
        self.assertEqual(p.attach, [])
        self.assertEqual(r.calls, [])

    def test_reconcile_is_idempotent_against_a_real_registry_dir(self):
        # The timer re-runs this constantly; a second pass over unchanged state
        # must issue no commands.
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as d:
            sup = self._sup(block("18", 1000), d, r)
            sup.reconcile()
            open(os.path.join(d, "1000"), "w").close()  # register@ did its job
            r.calls.clear()
            sup.reconcile()
        self.assertEqual(r.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
