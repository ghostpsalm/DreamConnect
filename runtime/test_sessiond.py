#!/usr/bin/env python3
"""Unit tests for the discovery supervisor.

No logind and no systemd: sessions are fed in as property text, and the command
runner is injected so a full reconcile can be driven and asserted without
starting anything.
Run: python3 -m unittest runtime.test_sessiond  (or: python3 runtime/test_sessiond.py)
"""
import os
import pwd
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
    """A user manager with no answer: the reader injected into every Supervisor
    a test builds that is not about the fallback itself (#63).

    Injected rather than left to default because the real reader runs `runuser`
    against whatever uid the fixture names, and this suite's contract is that
    behaviour is reachable "without root, without a live GNOME session, and
    without touching the real system" (CLAUDE.md, Seams). A test whose fixture
    uid happens to exist on the machine running it must not be able to reach
    that account's session.
    """
    return None


class FakeManagerDisplays:
    """The reader a Supervisor is handed: callable(uid) -> display or None.

    A third double, and deliberately neither of the other two. `FakeRunner`
    stands for systemd commands the supervisor *issues*, and `FakeManagerEnv`
    for the subprocess one read is made of; this one stands for the whole
    question "where does the user manager say uid N is?".

    It records who was asked, because who was asked is half the contract here:
    this is root running a subprocess inside a user-owned session, repeated for
    every registered uid on a 30s timer, so a uid whose envfile already answered
    must not be asked at all.
    """

    def __init__(self, displays):
        self.calls = []
        self._displays = {int(uid): d for uid, d in displays.items()}

    def __call__(self, uid):
        self.calls.append(int(uid))
        return self._displays.get(int(uid))


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


# A real `systemctl --user show-environment`, captured 2026-09-13 from the
# GNOME 49 Wayland session on the box this project is verified against. Only the
# account name and the hostname were substituted (`alice`, `example`); key
# order, systemd's `$'...'` quoting and every other value are as the manager
# emitted them.
#
# Kept whole rather than cut down to the one line under test. The confusable
# keys are the point: GNOME_SETUP_DISPLAY, WAYLAND_DISPLAY and XAUTHORITY all
# sit in this output, and the registrar anchors its match at the start of the
# line precisely so that none of them can be read as the display
# (dreamconnect-register.sh:78-79).
MANAGER_ENV_TEXT = """HOME=/home/alice
LANG=en_GB.UTF-8
LOGNAME=alice
PATH=/home/alice/.cargo/bin:/home/alice/.deno/bin:/home/alice/.local/bin:/home/alice/bin:/home/alice/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/home/alice/.composer/vendor/bin
SHELL=/bin/bash
USER=alice
XDG_DATA_DIRS=/home/alice/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share/:/usr/share/:/home/alice/.nix-profile/share:/nix/var/nix/profiles/default/share
XDG_RUNTIME_DIR=/run/user/1000
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
DEBUGINFOD_IMA_CERT_PATH=/etc/keys/ima:
DEBUGINFOD_URLS=$'ima:enforcing https://debuginfod.fedoraproject.org/ ima:ignore '
DESKTOP_SESSION=gnome
DISPLAY=:0
EDITOR=/usr/bin/nano
GDMSESSION=gnome
GDM_LANG=en_GB.UTF-8
GNOME_SETUP_DISPLAY=unix:/tmp/.X11-unix/X1
HISTCONTROL=ignoredups
HISTSIZE=1000
HOSTNAME=example
LESSOPEN=$'||/usr/bin/lesspipe.sh %s'
MAIL=/var/spool/mail/alice
MOZ_GMP_PATH=/usr/lib64/mozilla/plugins/gmp-gmpopenh264/system-installed
NIX_PROFILES=$'/nix/var/nix/profiles/default /home/alice/.nix-profile'
NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
PWD=/home/alice
QT_IM_MODULE=ibus
QT_IM_MODULES=$'wayland;ibus'
SHLVL=0
SSH_AUTH_SOCK=/run/user/1000/gcr/ssh
USERNAME=alice
WAYLAND_DISPLAY=wayland-0
XAUTHORITY=/run/user/1000/.mutter-Xwaylandauth.D1EVU3
XDG_CURRENT_DESKTOP=GNOME
XDG_MENU_PREFIX=gnome-
XDG_SESSION_CLASS=user
XDG_SESSION_DESKTOP=gnome
XDG_SESSION_EXTRA_DEVICE_ACCESS=render:accel
XDG_SESSION_TYPE=wayland
XMODIFIERS=@im=ibus
__ETC_PROFILE_NIX_SOURCED=1
"""

# What the registrar's own rule yields from those exact bytes. Not reasoned
# about and not read off any Python: `sed -n 's/^DISPLAY=//p' | head -n 1`
# (dreamconnect-register.sh:87) was run over this capture and printed `:0`.
MANAGER_ENV_DISPLAY = ":0"

MANAGER_ENV_UID = 1000
MANAGER_ENV_ACCOUNT = "alice"


class FakeManagerEnv:
    """The `run` the reader is handed: callable(argv, timeout).

    Deliberately not `FakeRunner`. That one stands in for systemd commands the
    supervisor *issues*, and its `r.calls == []` assertions mean "nothing was
    done"; a read of a user manager's environment is not an action and must not
    be able to look like one.
    """

    def __init__(self, stdout=MANAGER_ENV_TEXT, returncode=0):
        self.calls = []
        self._stdout, self._rc = stdout, returncode

    def __call__(self, argv, timeout=None):
        self.calls.append((list(argv), timeout))
        return type("R", (), {"returncode": self._rc, "stdout": self._stdout,
                              "stderr": ""})()


def passwd_entry(uid, name=MANAGER_ENV_ACCOUNT):
    """What `pwd.getpwuid` returns -- the reader's `account` lookup, injected so
    the test needs no real account. `runuser -u` takes a name, not a uid."""
    return pwd.struct_passwd((name, "x", uid, uid, "", f"/home/{name}",
                              "/bin/bash"))


class TestManagerDisplay(unittest.TestCase):
    """Issue #63: an attended session registered through the `manager_display`
    fallback (dreamconnect-register.sh:112) publishes no envfile, so the
    supervisor has nothing to compare its entry against and a mid-session
    display change leaves the entry stale. This is the missing second value:
    ask that account's user manager, the same way the registrar does."""

    def test_asks_the_user_manager_the_way_the_registrar_does(self):
        # argv character-for-character from dreamconnect-register.sh:83-86. The
        # two implementations of one rule are the drift-prone part of #63:
        # divergence shows as a restart every 30s, never as an error.
        #
        # One call, bounded: this is root running a subprocess inside a
        # user-owned session on every reconcile pass, so a hung user manager
        # must not stall the loop, and the cost must stay at one read per
        # registered uid per pass.
        run = FakeManagerEnv()
        got = sd.manager_display(MANAGER_ENV_UID, run=run, account=passwd_entry)
        self.assertEqual(got, MANAGER_ENV_DISPLAY)
        self.assertEqual(len(run.calls), 1)
        argv, timeout = run.calls[0]
        self.assertEqual(argv, [
            "runuser", "-u", "alice", "--",
            "env", "XDG_RUNTIME_DIR=/run/user/1000",
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus",
            "systemctl", "--user", "show-environment"])
        self.assertEqual(timeout, 5)


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


def display_supervisor(sessions_text, registry_dir, runtime_root, runner,
                       reserved_users=("backstage",),
                       manager_display_reader=no_manager_display):
    """A Supervisor with every outside edge injected -- logind, systemd, the
    registry, /run/user, and (since #63) the user manager it may ask where a
    session that published no envfile actually is."""
    s = sd.Supervisor(registry_dir=registry_dir, reserved_users=reserved_users,
                      runner=runner, runtime_root=runtime_root,
                      manager_display_reader=manager_display_reader)
    s.list_sessions = lambda: sd.parse_sessions(sessions_text)
    return s


class TestReconcileRefresh(unittest.TestCase):
    """Issue #54: the backstage shell restarts, its Xwayland picks a different
    number, the envfile is rewritten and nothing re-runs registration -- so the
    entry still names the old display and the agent REFUSES the session."""

    def _sup(self, sessions_text, registry_dir, runtime_root, runner,
             reserved_users=("backstage",)):
        return display_supervisor(sessions_text, registry_dir, runtime_root,
                                  runner, reserved_users)

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
        # No envfile and (`no_manager_display`) no answer from the user manager
        # either: both sources failed, and that is still not drift. Treating an
        # absent second value as "moved" is a restart every pass, forever.
        #
        # Named for both sources since #63 -- before it, an absent envfile was
        # the whole of "nothing to compare against"; now the manager fallback is
        # asked as well, and this case is the one where it too says nothing.
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


# The attended account of the captured `systemctl --user show-environment`
# above: uid 1000, `alice`, whose manager holds MANAGER_ENV_DISPLAY.
ATTENDED_UID = MANAGER_ENV_UID


class TestReconcileFromTheUserManager(unittest.TestCase):
    """Issue #63: an attended session registered through the `manager_display`
    fallback (dreamconnect-register.sh:112) publishes no envfile, so #54's rule
    never fires for it. "An attended session whose display changes mid-session
    must not be left with a stale registry entry" -- the entry still names the
    old display, the shm and socket in it still match the client's static args,
    so the agent's known-wrong-fallback rule REFUSES the session and the
    operator gets a black screen instead of a fallback.

    The second value comes from that account's own user manager, which is where
    the registrar got the display it wrote in the first place.
    """

    def test_an_attended_entry_the_manager_contradicts_is_refreshed(self):
        # Two registered uids in one pass, because the order the two sources are
        # consulted in is as much of the contract as the refresh itself, and it
        # is not ours to choose: register_session tries the envfile first and
        # only falls back to the user manager when that yields nothing
        # (dreamconnect-register.sh:101-115). The supervisor compares against
        # whichever value the registrar would have written, so it must ask in
        # the same order.
        #
        #   992 backstage  entry :1, envfile :1        -- placed, and agrees
        #   1000 alice     entry :1, no envfile at all -- the #63 session
        #
        # The manager is given an answer for 992 as well, one that disagrees
        # with its entry. Nothing may come of it: a uid the envfile already
        # placed must not be asked, and must certainly not be re-registered onto
        # a value that overrides what it published.
        r = FakeRunner()
        manager = FakeManagerDisplays({BACKSTAGE_UID: ":7",
                                       ATTENDED_UID: MANAGER_ENV_DISPLAY})
        with tempfile.TemporaryDirectory() as reg, \
                tempfile.TemporaryDirectory() as run:
            write_entry(reg, BACKSTAGE_UID, ":1")
            write_envfile(run, BACKSTAGE_UID, envfile_text(":1"))
            write_entry(reg, ATTENDED_UID, ":1", user=MANAGER_ENV_ACCOUNT,
                        label=MANAGER_ENV_ACCOUNT)
            text = (backstage_block() + "\n"
                    + block("18", ATTENDED_UID, user=MANAGER_ENV_ACCOUNT))
            p = display_supervisor(text, reg, run, r,
                                   manager_display_reader=manager).reconcile()
        self.assertEqual(list(p.refresh), [ATTENDED_UID])
        self.assertEqual(r.calls, [sd.refresh_argv(ATTENDED_UID)])
        # Root ran a subprocess inside a user-owned session exactly once, and
        # only for the uid no envfile could place. #54 stopped at this line
        # rather than extend its rule; the cost of crossing it is bounded here
        # and not in prose.
        self.assertEqual(manager.calls, [ATTENDED_UID])


if __name__ == "__main__":
    unittest.main(verbosity=2)
