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


# The backstage account's uid in the agent's own registry fixtures
# (agent/test/dreamconnect/boot/BootTests.java:1833).
BACKSTAGE_UID = 992


def entry_text(uid, display, user="backstage", label="backstage"):
    """Exactly what install-lib.sh's render_registry_entry emits (:1177-1185).

    Written out in full rather than reduced to the one line under test: the
    reader has to find `display=` among the other keys, which is the part a
    substring search gets wrong.
    """
    return (f"uid={uid}\nuser={user}\ndisplay={display}\n"
            f"shm=/dev/shm/dreamconnect.frame.{uid}\n"
            f"socket=/run/user/{uid}/dreamconnect.sock\n"
            f"label={label}\n")


def write_entry(registry_dir, uid, display, **kw):
    write_entry_text(registry_dir, uid, entry_text(uid, display, **kw))


def write_entry_text(registry_dir, uid, text):
    """An entry written verbatim, for shapes `render_registry_entry` cannot
    emit -- a key with leading whitespace, or two `display=` lines (#66)."""
    with open(os.path.join(registry_dir, str(uid)), "w") as f:
        f.write(text)


def envfile_text(display, uid=BACKSTAGE_UID):
    """Exactly what dreamconnect-backstage-env.sh publishes (:51)."""
    return f"DISPLAY={display}\nXAUTHORITY=/run/user/{uid}/dreamconnect.Xauthority\n"


def write_envfile(runtime_root, uid, text):
    """<runtime_root>/<uid>/dreamconnect-display.env -- the path the register
    unit reads (runtime/dreamconnect-register.sh:97) and the drop-in sources
    (systemd/dreamconnect-agent.conf:23)."""
    d = os.path.join(runtime_root, str(uid))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "dreamconnect-display.env"), "w") as f:
        f.write(text)


def backstage_block(uid=BACKSTAGE_UID):
    """A backstage session as logind reports it: manager-early, not attachable."""
    return block("11", uid, user="backstage", klass="manager-early",
                 type="unspecified", seat="")


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


class TestEntryDisplay(unittest.TestCase):
    """What the registry entry currently claims (issue #54).

    `display=<v>` is written once, at register-unit start
    (install-lib.sh:1182 via dreamconnect-register.sh:118).
    """

    def test_reads_the_display_line_of_a_full_entry(self):
        with tempfile.TemporaryDirectory() as d:
            write_entry(d, BACKSTAGE_UID, ":1")
            self.assertEqual(sd.entry_display(d, BACKSTAGE_UID), ":1")

    def test_a_label_that_looks_like_a_display_is_still_a_label(self):
        # An entry's key is only what precedes the first `=` on the line
        # (Bridge.java:228-231), and the label is free text that may contain one
        # (BootTests.java:1735 uses `label=a=b`). The agent's own parser is a
        # last-wins loop, so a reader that copies it but tests keys by substring
        # would read :9 off the label and restart register@ every 30s for a
        # session that never moved.
        with tempfile.TemporaryDirectory() as d:
            write_entry(d, BACKSTAGE_UID, ":1", label="display=:9")
            self.assertEqual(sd.entry_display(d, BACKSTAGE_UID), ":1")

    def test_a_blank_display_is_unset_not_a_value(self):
        # "blank is unset, as in #50" -- Bridge.java:232. Reporting "" as a
        # display would make it differ from every published value forever.
        with tempfile.TemporaryDirectory() as d:
            write_entry(d, BACKSTAGE_UID, "")
            self.assertFalse(sd.entry_display(d, BACKSTAGE_UID))

    def test_a_key_is_trimmed_before_it_is_compared(self):
        # Bridge.java:230 trims the key, so ` display=:2` is a display to the
        # agent; before #66 it was not one to the supervisor. render_registry_entry
        # is the sole writer and emits `display=%s`, so no shipped entry has a
        # leading space -- the entry is built inline here because `entry_text`
        # cannot express a shape its writer cannot produce.
        with tempfile.TemporaryDirectory() as d:
            write_entry_text(d, BACKSTAGE_UID,
                             f"uid={BACKSTAGE_UID}\n display=:2\n")
            self.assertEqual(sd.entry_display(d, BACKSTAGE_UID), ":2")

    def test_a_later_blank_display_leaves_the_earlier_one_standing(self):
        # Bridge.java:232 `continue`s on a blank value, so the last *non-blank*
        # wins; before #66 this read "" and the two parsers disagreed about the
        # same text. An entry holds one `display=` line, so again the writer
        # cannot produce this shape.
        with tempfile.TemporaryDirectory() as d:
            write_entry_text(d, BACKSTAGE_UID, "display=:1\ndisplay=\n")
            self.assertEqual(sd.entry_display(d, BACKSTAGE_UID), ":1")

    def test_a_missing_entry_is_none_not_an_error(self):
        # register@'s ExecStop removes the entry, so it can vanish between the
        # listdir and the read. On a 30s timer that race is routine, and an
        # exception here would take every other account's reconcile with it.
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(sd.entry_display(d, BACKSTAGE_UID))


class TestPublishedDisplay(unittest.TestCase):
    """What the session publishes now -- install-lib.sh's session_display
    (`sed -n 's/^DISPLAY=//p' | head -n 1`, :1214-1222) in Python."""

    def test_reads_the_display_the_session_published(self):
        with tempfile.TemporaryDirectory() as d:
            write_envfile(d, BACKSTAGE_UID, envfile_text(":2"))
            self.assertEqual(sd.published_display(BACKSTAGE_UID, d), ":2")

    def test_an_xdisplay_line_is_not_a_display(self):
        # session_display's own stated reason for anchoring: "an `XDISPLAY=`
        # line is not a DISPLAY" (install-lib.sh:1216). Both halves read the
        # same file, so they have to agree about which line is the answer.
        with tempfile.TemporaryDirectory() as d:
            write_envfile(d, BACKSTAGE_UID,
                          "XDISPLAY=:9\n" + envfile_text(":2"))
            self.assertEqual(sd.published_display(BACKSTAGE_UID, d), ":2")

    def test_a_missing_envfile_is_none_not_an_error(self):
        # Anyone who simply logged in has no envfile at all; register_session
        # falls back to the user manager's display for them
        # (dreamconnect-register.sh:104-112).
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(sd.published_display(1000, d))


class TestRefreshArgv(unittest.TestCase):
    def test_refresh_restarts_the_register_instance(self):
        self.assertEqual(sd.refresh_argv(BACKSTAGE_UID),
                         ["systemctl", "restart",
                          "dreamconnect-register@992.service"])

    def test_refresh_leaves_the_attach_unit_alone(self):
        # Only the entry is wrong; the daemon is fine. Restarting
        # dreamconnect-attach@ as well would drop a live operator mid-call to
        # fix a label they cannot see.
        self.assertNotIn("dreamconnect-attach@992.service",
                         sd.refresh_argv(BACKSTAGE_UID))


class TestReconcileRefresh(unittest.TestCase):
    """Issue #54: the backstage shell restarts, its Xwayland picks a different
    number, the envfile is rewritten and nothing re-runs registration -- so the
    entry still names the old display and the agent REFUSES the session."""

    def _sup(self, sessions_text, registry_dir, runtime_root, runner,
             reserved_users=("backstage",)):
        s = sd.Supervisor(registry_dir=registry_dir,
                          reserved_users=reserved_users, runner=runner,
                          runtime_root=runtime_root)
        s.list_sessions = lambda: sd.parse_sessions(sessions_text)
        return s

    def test_a_republished_display_restarts_the_register_instance(self):
        # The whole issue, end to end at the supervisor seam: entry says :1,
        # the shell that came back publishes :2.
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            write_entry(reg, BACKSTAGE_UID, ":1")
            write_envfile(run, BACKSTAGE_UID, envfile_text(":2"))
            p = self._sup(backstage_block(), reg, run, r).reconcile()
        self.assertEqual(list(p.refresh), [BACKSTAGE_UID])
        self.assertEqual(r.calls, [sd.refresh_argv(BACKSTAGE_UID)])

    def test_a_matching_display_restarts_nothing(self):
        # The reconcile runs on a 30s timer as well as on logind signals, so an
        # entry that is still right must stay untouched -- otherwise every
        # backstage session is deregistered and rebuilt twice a minute.
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            write_entry(reg, BACKSTAGE_UID, ":1")
            write_envfile(run, BACKSTAGE_UID, envfile_text(":1"))
            p = self._sup(backstage_block(), reg, run, r).reconcile()
        self.assertEqual(list(p.refresh), [])
        self.assertEqual(r.calls, [])

    def test_a_session_that_publishes_no_envfile_is_left_alone(self):
        # The manager_display fallback registers without ever writing an
        # envfile. Nothing to compare against is not drift, and treating it as
        # drift is a restart every pass, forever.
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            write_entry(reg, BACKSTAGE_UID, ":1")
            p = self._sup(backstage_block(), reg, run, r).reconcile()
        self.assertEqual(list(p.refresh), [])
        self.assertEqual(r.calls, [])

    def test_a_half_written_envfile_is_left_alone(self):
        # backstage-env.sh writes to `.tmp` and renames, but a truncated or
        # cleared file must not read as "published nothing, therefore moved".
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            write_entry(reg, BACKSTAGE_UID, ":1")
            write_envfile(run, BACKSTAGE_UID, "DISPLAY=\n")
            p = self._sup(backstage_block(), reg, run, r).reconcile()
        self.assertEqual(r.calls, [])

    def test_attaches_then_releases_then_refreshes(self):
        # Order decided in the plan for #54. A refresh's ExecStop deregisters
        # before ExecStart rewrites, so the entry is briefly absent; running it
        # last keeps that gap out of the way of the attach and release decisions
        # this same pass already made from the registry.
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            open(os.path.join(reg, "1001"), "w").close()   # session gone
            write_entry(reg, 1002, ":1", user="alice", label="alice")
            write_envfile(run, 1002, envfile_text(":2", uid=1002))
            text = (block("18", 1000) + "\n"               # new desktop
                    + block("34", 1002, user="alice"))     # display drifted
            p = self._sup(text, reg, run, r, reserved_users=()).reconcile()
        self.assertEqual([s.uid for s in p.attach], [1000])
        self.assertEqual(p.release, [1001])
        self.assertEqual(list(p.refresh), [1002])
        self.assertEqual(r.calls, [sd.start_argv(1000), sd.stop_argv(1001),
                                   sd.refresh_argv(1002)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
