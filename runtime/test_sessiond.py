#!/usr/bin/env python3
"""Unit tests for the discovery supervisor.

No logind and no systemd: sessions are fed in as property text, and the command
runner is injected so a full reconcile can be driven and asserted without
starting anything.
Run: python3 -m unittest runtime.test_sessiond  (or: python3 runtime/test_sessiond.py)
"""
import os
import pwd
import subprocess
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


def no_manager_display(uid):
    """A user manager that answers nothing.

    Injected into every Supervisor these tests build, including the ones written
    before #63 that predate the seam. The default reader is the real
    `manager_display`, which forks `runuser`; a test that forgot this would shell
    out on the developer's box, and the suite is hermetic.
    """
    return None


class FakeManagerDisplays:
    """User managers with fixed answers, recording which uids were asked.

    `asked` is the half that matters as much as the answers: several rules here
    are about *not* reaching for a value -- a blank entry, a uid with no entry,
    an envfile that already placed the session -- and only the record of who was
    asked can tell a rule that declined from a rule that asked and ignored.
    """

    def __init__(self, displays=None):
        self.displays = dict(displays or {})
        self.asked = []

    def __call__(self, uid):
        self.asked.append(uid)
        return self.displays.get(uid)


class FakeManagerEnv:
    """One `systemctl --user show-environment` run that runs nothing."""

    def __init__(self, stdout="", rc=0, raises=None):
        self.calls = []
        self._stdout, self._rc, self._raises = stdout, rc, raises

    def __call__(self, argv):
        self.calls.append(argv)
        if self._raises is not None:
            raise self._raises
        return type("R", (), {"returncode": self._rc, "stdout": self._stdout,
                              "stderr": ""})()


# What `systemctl --user show-environment` prints in a logged-in GNOME session,
# keys sorted as systemd sorts them. GNOME_SETUP_DISPLAY is in it on purpose:
# it is the line an unanchored reader mistakes for the answer.
SHOW_ENVIRONMENT = (
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus\n"
    "DISPLAY=:0\n"
    "GNOME_SETUP_DISPLAY=unix:/tmp/.X11-unix/X1\n"
    "HOME=/home/alice\n"
    "LANG=en_GB.UTF-8\n"
    "XDG_RUNTIME_DIR=/run/user/1000\n"
    "XDG_SESSION_TYPE=wayland\n"
)


def _uid_with_no_account(start=65500):
    """A uid this box has no account for, searched for rather than assumed.

    A hard-coded number is an account somebody has on some box, and the test
    that uses this asserts a *lookup failure*; on the box where the number
    resolves it would quietly assert the opposite.
    """
    taken = {p.pw_uid for p in pwd.getpwall()}
    uid = start
    while uid in taken:
        uid += 1
    return uid


NO_SUCH_UID = _uid_with_no_account()


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
    with open(os.path.join(registry_dir, str(uid)), "w") as f:
        f.write(entry_text(uid, display, **kw))


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
                              runner=r,
                              manager_display_reader=no_manager_display)
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
                          runner=runner,
                          manager_display_reader=no_manager_display)
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
                              runner=r,
                              manager_display_reader=no_manager_display)
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
             reserved_users=("backstage",), manager=no_manager_display):
        s = sd.Supervisor(registry_dir=registry_dir,
                          reserved_users=reserved_users, runner=runner,
                          runtime_root=runtime_root,
                          manager_display_reader=manager)
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

    def test_a_session_neither_source_can_place_is_left_alone(self):
        # Renamed at #63: the old name said "publishes no envfile is left
        # alone", which is the opposite of what #63 decided -- an envfile-less
        # session is now placed by its user manager. What survives is the
        # narrower rule this always tested: when *neither* source can place a
        # session, nothing to compare against is not drift, and treating it as
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


class TestManagerDisplay(unittest.TestCase):
    """Issue #63: the second value for a session that publishes no envfile.

    dreamconnect-register.sh's `manager_display` (:76-87) in Python. No test
    here reaches a real `runuser`: the run is injected in every case, and the
    one case that does not inject an account proves the lookup fails before a
    command is ever built.
    """

    def _argv(self, uid=1000, account="alice"):
        return ["runuser", "-u", account, "--",
                "env", f"XDG_RUNTIME_DIR=/run/user/{uid}",
                f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus",
                "systemctl", "--user", "show-environment"]

    def test_the_argv_is_the_registrars_word_for_word(self):
        # The two implementations must ask the same question of the same bus as
        # the same user. If they drift, the supervisor restarts register@ every
        # 30s and register@ writes back the display the supervisor rejected --
        # a loop that logs no error at either end.
        run = FakeManagerEnv(stdout=SHOW_ENVIRONMENT)
        sd.manager_display(1000, run=run, account="alice")
        self.assertEqual(run.calls, [self._argv()])

    def test_reads_the_display_the_user_manager_holds(self):
        run = FakeManagerEnv(stdout=SHOW_ENVIRONMENT)
        self.assertEqual(sd.manager_display(1000, run=run, account="alice"),
                         ":0")

    def test_a_setup_display_is_not_a_display(self):
        # A session whose Xwayland has not started has GNOME_SETUP_DISPLAY and
        # no DISPLAY at all -- the case dreamconnect-register.sh:78-79 guards.
        # A reader matching "DISPLAY=" anywhere in the line answers
        # `unix:/tmp/.X11-unix/X1` here and registers the session onto a display
        # nothing serves. Only an anchored `^DISPLAY=` returns None.
        text = "".join(l + "\n" for l in SHOW_ENVIRONMENT.splitlines()
                       if not l.startswith("DISPLAY="))
        run = FakeManagerEnv(stdout=text)
        self.assertIsNone(sd.manager_display(1000, run=run, account="alice"))

    def test_the_first_display_line_wins(self):
        # `head -n 1`. show-environment should never print two, but the halves
        # have to agree about which one is the answer if it ever does.
        run = FakeManagerEnv(stdout="DISPLAY=:0\nDISPLAY=:9\n")
        self.assertEqual(sd.manager_display(1000, run=run, account="alice"),
                         ":0")

    def test_a_blank_display_is_no_display(self):
        # `[ -n "$v" ] || return 1`. Reporting "" would make the entry differ
        # from it forever and restart register@ every pass.
        run = FakeManagerEnv(stdout="DISPLAY=\nGNOME_SETUP_DISPLAY=:1\n")
        self.assertIsNone(sd.manager_display(1000, run=run, account="alice"))

    def test_a_failed_run_is_none(self):
        # No user manager, no bus, runuser refused: `2>/dev/null` in the shell.
        run = FakeManagerEnv(stdout="DISPLAY=:0\n", rc=1)
        self.assertIsNone(sd.manager_display(1000, run=run, account="alice"))

    def test_a_wedged_user_manager_is_none_not_an_exception(self):
        # The one that matters most: this runs inside the reconcile loop, so a
        # TimeoutExpired escaping here would abandon every other account's pass
        # because one user's manager hung.
        run = FakeManagerEnv(raises=subprocess.TimeoutExpired(
            cmd="systemctl", timeout=sd.MANAGER_ENV_TIMEOUT_SECONDS))
        self.assertIsNone(sd.manager_display(1000, run=run, account="alice"))

    def test_a_missing_runuser_is_none_not_an_exception(self):
        run = FakeManagerEnv(raises=OSError("no such file: runuser"))
        self.assertIsNone(sd.manager_display(1000, run=run, account="alice"))

    def test_an_unknown_uid_is_none_and_runs_nothing(self):
        # The uid comes from a registry entry that may have outlived the
        # account. Nothing may be run for a name we could not resolve.
        run = FakeManagerEnv(stdout=SHOW_ENVIRONMENT)
        self.assertIsNone(sd.manager_display(NO_SUCH_UID, run=run))
        self.assertEqual(run.calls, [])

    def test_the_read_is_bounded_well_under_the_reconcile_interval(self):
        self.assertLess(sd.MANAGER_ENV_TIMEOUT_SECONDS,
                        sd.RECONCILE_INTERVAL_SECONDS)

    def test_the_bound_is_actually_passed_to_the_command(self):
        # Declaring the constant is not applying it. Swapped at module level
        # rather than run for real, because proving a 5s timeout by waiting 5s
        # would cost the suite 5s every run.
        seen = {}

        class FakeSubprocess:
            @staticmethod
            def run(argv, **kwargs):
                seen.update(kwargs)
                return type("R", (), {"returncode": 0, "stdout": ""})()

        real = sd.subprocess
        sd.subprocess = FakeSubprocess
        self.addCleanup(setattr, sd, "subprocess", real)
        sd._manager_env_command(["runuser"])
        self.assertEqual(seen.get("timeout"), sd.MANAGER_ENV_TIMEOUT_SECONDS)


class TestReconcileFromTheUserManager(unittest.TestCase):
    """Issue #63: an attended session registered through the manager_display
    fallback publishes no envfile, so before this there was no second value, the
    stale rule could never fire for it, and a mid-session display change left the
    entry stale -- shm and socket still matching, so the agent's
    known-wrong-fallback rule fires and the session is REFUSED (black)."""

    def _sup(self, sessions_text, registry_dir, runtime_root, runner, manager):
        s = sd.Supervisor(registry_dir=registry_dir, reserved_users=(),
                          runner=runner, runtime_root=runtime_root,
                          manager_display_reader=manager)
        s.list_sessions = lambda: sd.parse_sessions(sessions_text)
        return s

    def _reconcile(self, manager, entry_display=":0", envfile=None,
                   sessions=None, uid=1000):
        r = FakeRunner()
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            if entry_display is not None:
                write_entry(reg, uid, entry_display, user="alice",
                            label="alice")
            if envfile is not None:
                write_envfile(run, uid, envfile_text(envfile, uid=uid))
            text = sessions if sessions is not None else block("18", uid)
            p = self._sup(text, reg, run, r, manager).reconcile()
        return p, r

    def test_an_entry_the_user_manager_contradicts_is_refreshed(self):
        # The whole issue: alice logged in on :0, was registered from her user
        # manager, her Xwayland came back as :1, and no envfile exists to notice
        # it. The user manager did notice.
        m = FakeManagerDisplays({1000: ":1"})
        p, r = self._reconcile(m)
        self.assertEqual(list(p.refresh), [1000])
        self.assertEqual(r.calls, [sd.refresh_argv(1000)])

    def test_an_entry_the_user_manager_confirms_is_left_alone(self):
        # The reconcile runs every 30s: an entry that is still right must cost
        # nothing, or every attended session is rebuilt twice a minute.
        m = FakeManagerDisplays({1000: ":0"})
        p, r = self._reconcile(m)
        self.assertEqual(list(p.refresh), [])
        self.assertEqual(r.calls, [])

    def test_the_envfile_wins_and_the_user_manager_is_never_asked(self):
        # Backstage publishes an envfile, and the registrar prefers it
        # (dreamconnect-register.sh:97-103). The supervisor must prefer the same
        # source or it can judge an entry against a value the registrar would
        # never have written. Asserted as "never asked", not merely "ignored":
        # the fork is the cost being avoided.
        m = FakeManagerDisplays({1000: ":9"})
        p, r = self._reconcile(m, entry_display=":0", envfile=":2")
        self.assertEqual(list(p.refresh), [1000])
        self.assertEqual(m.asked, [])

    def test_a_blank_entry_never_asks_the_user_manager(self):
        # stale_registrations discards a blank entry before it looks at the
        # published value, so an answer bought for one is thrown away unread.
        m = FakeManagerDisplays({1000: ":1"})
        p, r = self._reconcile(m, entry_display="")
        self.assertEqual(m.asked, [])
        self.assertEqual(list(p.refresh), [])
        self.assertEqual(r.calls, [])

    def test_a_uid_with_no_entry_never_asks_the_user_manager(self):
        # A session being attached for the first time has nothing that could
        # have gone stale; register@ is about to read the manager itself.
        m = FakeManagerDisplays({1000: ":1"})
        p, r = self._reconcile(m, entry_display=None)
        self.assertEqual(m.asked, [])
        self.assertEqual([s.uid for s in p.attach], [1000])

    def test_the_default_reader_is_the_real_manager_display(self):
        # Every other test injects, so without this the production wiring --
        # the only wiring that ever runs on a box -- is never asserted at all.
        self.assertIs(sd.Supervisor(registry_dir="/nonexistent",
                                    reserved_users=())._manager_display,
                      sd.manager_display)


if __name__ == "__main__":
    unittest.main(verbosity=2)
