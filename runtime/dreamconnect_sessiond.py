#!/usr/bin/env python3
"""Supervisor: keep the session registry matching the sessions that exist.

The reconciler (dreamconnect_discovery) decides; this acts. It reads logind,
asks for a plan, and starts or stops the two units that make a session
reachable:

  dreamconnect-attach@<uid>.service    the daemon, running as that user, bound
                                       to that user's manager so it dies with
                                       the session
  dreamconnect-register@<uid>.service  the registry entry, written by root

Both are `BindsTo=user@<uid>.service`, so systemd tears them down when the
session ends whether or not this supervisor is alive to notice. That is the
point of driving units instead of forking daemons directly: the cleanup path
does not depend on us.

Reconciliation runs on logind's SessionNew/SessionRemoved signals *and* on a
timer. The timer is not belt-and-braces — a signal delivered while we are
restarting is simply lost, and a missed SessionRemoved would leave an entry
promising a session that no longer exists. Every reconcile is idempotent, so
the timer costs nothing when nothing changed.

Root only: the registry must stay root-owned or the agent ignores it entirely.
"""
import os
import subprocess
import sys

from dreamconnect_discovery import Session, plan  # noqa: E402

REGISTRY_DIR = "/run/dreamconnect/sessions"
ATTACH_UNIT = "dreamconnect-attach@{uid}.service"
REGISTER_UNIT = "dreamconnect-register@{uid}.service"

# Where a session publishes the display it is actually on: the same file the
# register unit reads (dreamconnect-register.sh:97) and the client drop-in
# sources (systemd/dreamconnect-agent.conf:23).
RUNTIME_ROOT = "/run/user"
DISPLAY_ENVFILE = "dreamconnect-display.env"

# Accounts whose registry slot somebody else owns. gdm and the greeter's
# dynamic users never have a desktop worth offering; the backstage account is
# managed by the installer and is added at runtime from install state.
DEFAULT_RESERVED_USERS = ("gdm", "root")

SESSION_PROPERTIES = ("Id", "User", "Name", "Class", "Type", "State", "Seat")

# Where the installer records which account it provisioned.
INSTALL_STATE = "/etc/dreamconnect/install.state"


def host_account(state_file=INSTALL_STATE):
    """The account the installer manages, or None.

    Read rather than assumed, because getting this wrong is destructive rather
    than merely wrong: a backstage account's session is `manager-early`, which
    is not attachable, so without this the supervisor sees a registry entry with
    no matching desktop and releases it -- deregistering the unattended session
    the whole install exists to provide. Caught by a dry run against a real box
    before it could do that.
    """
    try:
        with open(state_file) as f:
            for line in f:
                key, _, value = line.strip().partition("=")
                if key == "HOST_ACCOUNT" and value:
                    return value
    except OSError:
        pass
    return None


def log(*a):
    print("[dreamconnect-sessiond]", *a, file=sys.stderr, flush=True)


def parse_sessions(text):
    """logind property blocks -> [Session].

    `loginctl show-session` emits Key=Value lines with a blank line between
    sessions. Parsed rather than read from the list-sessions table because that
    table's columns shift with content, and -o json is accepted and silently
    ignored on systemd 258.
    """
    sessions, current = [], {}

    def flush():
        if current.get("Id") and current.get("User", "").isdigit():
            sessions.append(Session(current["Id"], current["User"],
                                    current.get("Name", ""),
                                    current.get("Class", ""),
                                    current.get("Type", ""),
                                    current.get("State", ""),
                                    current.get("Seat", "")))
        current.clear()

    for line in text.splitlines():
        line = line.strip()
        if not line:
            flush()
            continue
        key, _, value = line.partition("=")
        if key in SESSION_PROPERTIES:
            current[key] = value
    flush()
    return sessions


def registered_uids(registry_dir=REGISTRY_DIR):
    """uids currently holding an entry.

    Only bare-numeric names count, matching what the agent will read: a stray
    `.1000.tmp` beside an entry is not an entry, and treating it as one would
    make us think a uid was registered when the agent disagrees.
    """
    try:
        names = os.listdir(registry_dir)
    except OSError:
        return []
    return sorted(int(n) for n in names if n.isdigit())


def entry_display(registry_dir, uid):
    """The display one entry names, "" if it names none, None if there is no
    entry at all.

    Parsed the way the agent parses it (Bridge.java:228-232): a key is only what
    precedes the *first* `=` on the line, and last wins. Both halves matter. The
    label is free text that may itself contain `=` -- BootTests.java:1735 uses
    `label=a=b` -- so a reader that looked for `display=` as a substring would
    read a display off a label and restart register@ every pass for a session
    that never moved.

    A missing entry is None rather than an error because register@'s ExecStop
    removes it, so it can vanish between the listdir and this read; on a 30s
    timer that race is routine, and an exception would take every other
    account's reconcile down with it. Blank is unset, as in #50.
    """
    try:
        with open(os.path.join(registry_dir, str(uid))) as f:
            text = f.read()
    except OSError:
        return None
    display = ""
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key == "display":
            display = value.strip()
    return display


def published_display(uid, runtime_root=RUNTIME_ROOT):
    """The display that session publishes now, or None if it publishes nothing.

    install-lib.sh's `session_display` (:1214-1222) in Python, and deliberately
    the same rule: the first `DISPLAY=` line wins, anchored at the start of the
    line so an `XDISPLAY=` line is not a DISPLAY. The two halves read one file
    and must agree about which line is the answer, or the supervisor decides an
    entry is stale against a value the registrar would never have written.

    Anyone who simply logged in has no envfile; register_session falls back to
    the user manager's display for them (dreamconnect-register.sh:104-112), so
    absent is the normal case and not a fault. `manager_display` below is how
    the supervisor gets a value for those sessions anyway (#63).
    """
    path = os.path.join(runtime_root, str(uid), DISPLAY_ENVFILE)
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("DISPLAY="):
                    return line.partition("=")[2].strip()
    except OSError:
        return None
    return None


# Asking a user manager costs a fork, a privilege drop and a D-Bus round trip
# into a session this supervisor does not control. Bounded well under the 30s
# reconcile interval, and deliberately not on Supervisor._run_command's 60s: one
# wedged user manager must cost this pass one uid's answer, not every other
# account's reconcile.
MANAGER_ENV_TIMEOUT_SECONDS = 5


def _manager_env_command(argv):
    return subprocess.run(argv, capture_output=True, text=True,
                          timeout=MANAGER_ENV_TIMEOUT_SECONDS)


def manager_display(uid, run=None, account=None):
    """The display that uid's systemd user manager holds, or None.

    dreamconnect-register.sh's `manager_display` (:76-87) in Python, argv copied
    character for character from it, because this is one rule with two
    implementations: if they ever disagree the supervisor restarts register@
    every 30 seconds and register@ writes back the display the supervisor just
    rejected, a loop with no error in it anywhere. Change them together.

    Anchored on `^DISPLAY=`, first match -- not `"DISPLAY=" in line`. A session
    whose Xwayland has not come up yet has `GNOME_SETUP_DISPLAY=` and no
    `DISPLAY` at all, which is the very case dreamconnect-register.sh:78-79
    guards; a substring reader would answer with the setup display and register
    the session onto a display nothing serves.

    Root runs `runuser` into a user-owned session here, which is why #54 stopped
    short of it. It grants that account nothing new: root already trusted this
    same source when register@ wrote the entry, so the most a user can provoke
    is a restart of their own register@ unit rewriting their own entry with the
    display they claim.

    Every failure -- unknown uid, non-zero exit, timeout, a runuser that is not
    there -- is None and never an exception. This is called from inside the
    reconcile loop, and a TimeoutExpired escaping here would take every other
    account's pass down along with the one wedged user manager.
    """
    run = run or _manager_env_command
    if account is None:
        try:
            import pwd
            account = pwd.getpwuid(int(uid)).pw_name
        except (KeyError, ValueError, ImportError):
            return None
    argv = ["runuser", "-u", account, "--",
            "env", f"XDG_RUNTIME_DIR={RUNTIME_ROOT}/{uid}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path={RUNTIME_ROOT}/{uid}/bus",
            "systemctl", "--user", "show-environment"]
    try:
        result = run(argv)
    except (OSError, subprocess.SubprocessError):
        return None
    if result is None or getattr(result, "returncode", 0) != 0:
        return None
    for line in (getattr(result, "stdout", "") or "").splitlines():
        if line.startswith("DISPLAY="):
            # First match wins and a blank one is still the answer, matching
            # `sed -n 's/^DISPLAY=//p' | head -n 1` followed by `[ -n "$v" ]`:
            # the shell does not read past a blank first value either.
            return line.partition("=")[2].strip() or None
    return None


def unit_names(uid):
    """The two units that together make one session reachable."""
    return [ATTACH_UNIT.format(uid=uid), REGISTER_UNIT.format(uid=uid)]


def start_argv(uid):
    """systemctl invocation to bring a session up.

    One call for both units so systemd orders and reports them together, and a
    partial start is visible as a single failure rather than two.
    """
    return ["systemctl", "start", *unit_names(uid)]


def stop_argv(uid):
    return ["systemctl", "stop", *unit_names(uid)]


def refresh_argv(uid):
    """systemctl invocation to rewrite one uid's entry onto the display it
    publishes now (#54).

    `register@` only, unlike start and stop. The entry is what is wrong; the
    daemon is running and correct, and restarting `attach@` alongside it would
    drop a live operator mid-call to fix a label they cannot see. Restart rather
    than stop-then-start so systemd holds the two halves together and a uid is
    never left deregistered because the start failed on its own.
    """
    return ["systemctl", "restart", REGISTER_UNIT.format(uid=uid)]


class Supervisor:
    """Applies plans. Split from the reconciler so the rules stay pure."""

    def __init__(self, registry_dir=REGISTRY_DIR, reserved_users=None,
                 runner=None, runtime_root=RUNTIME_ROOT,
                 manager_display_reader=None):
        self.registry_dir = registry_dir
        self.runtime_root = runtime_root
        if reserved_users is None:
            installed = host_account()
            reserved_users = DEFAULT_RESERVED_USERS + (
                (installed,) if installed else ())
        self.reserved_users = tuple(reserved_users)
        # Injected so tests can drive a full reconcile without touching systemd.
        self._run = runner or self._run_command
        # A seam of its own rather than another use of `runner`: tests read
        # `runner.calls == []` as "this pass did nothing", and asking a user
        # manager which display it holds is a read, not an action.
        self._manager_display = manager_display_reader or manager_display

    @staticmethod
    def _run_command(argv):
        return subprocess.run(argv, capture_output=True, text=True, timeout=60)

    def list_sessions(self):
        try:
            listing = subprocess.run(["loginctl", "list-sessions", "--no-legend"],
                                     capture_output=True, text=True, timeout=10,
                                     check=True).stdout
            ids = [line.split()[0] for line in listing.splitlines() if line.split()]
            if not ids:
                return []
            props = ["-p" + p for p in SESSION_PROPERTIES]
            out = subprocess.run(["loginctl", "show-session", *ids, *props],
                                 capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError, IndexError) as e:
            log(f"could not read logind: {e}")
            return []
        return parse_sessions(out)

    def reserved_uids(self, sessions):
        """uids we must not manage, resolved from names we know by name.

        Resolved against the sessions we just read rather than the passwd file:
        an account with no session cannot be attached or released anyway, and
        looking it up would fail closed on a box where it does not exist.
        """
        uids = set()
        for session in sessions:
            if session.user in self.reserved_users:
                uids.add(session.uid)
        for name in self.reserved_users:
            try:
                import pwd
                uids.add(pwd.getpwnam(name).pw_uid)
            except (KeyError, ImportError):
                pass
        return uids

    def display_maps(self, uids):
        """{uid: display} as the entries record it, against what the sessions
        publish now -- the two maps the stale-display rule compares.

        Only uids that already hold an entry are read. A uid with no entry has
        nothing that could have gone stale, and walking every /run/user on the
        box twice a minute to learn that would cost more than the answer.

        An attended session registered through the registrar's manager_display
        fallback publishes no envfile at all, so before #63 it had no second
        value, the stale rule could never fire for it, and a mid-session display
        change left its entry stale for good. Its user manager is asked instead
        -- but only when the envfile placed nothing, because the envfile is what
        the registrar itself preferred, and only when the entry names a display,
        because `stale_registrations` discards a blank entry before it ever looks
        at the published value and an answer bought for one is thrown away.
        """
        recorded, published = {}, {}
        for uid in uids:
            entry = entry_display(self.registry_dir, uid)
            if entry:
                recorded[uid] = entry
            current = published_display(uid, self.runtime_root)
            if not current and entry:
                current = self._manager_display(uid)
            if current:
                published[uid] = current
        return recorded, published

    def reconcile(self):
        """One pass. Returns the plan applied, for logging and for tests."""
        sessions = self.list_sessions()
        current = registered_uids(self.registry_dir)
        recorded_displays, published_displays = self.display_maps(current)
        p = plan(sessions, current, self.reserved_uids(sessions),
                 recorded_displays, published_displays)

        for session in p.attach:
            log(f"attaching {session.user} (uid {session.uid}, session "
                f"{session.session_id}, {session.type})")
            self._apply(start_argv(session.uid), session.uid, "attach")
        for uid in p.release:
            log(f"releasing uid {uid} (no live desktop)")
            self._apply(stop_argv(uid), uid, "release")
        # Last, after the attach and release decisions this pass already made
        # from the registry have been acted on: a refresh's ExecStop
        # deregisters before ExecStart rewrites, so the entry is briefly absent,
        # and running it earlier would put that gap under the reads above.
        for uid in p.refresh:
            # "is on" rather than "publishes": since #63 the second value is
            # either the envfile's or the user manager's, and a log line naming
            # a source the session never wrote is the wrong thing to hand
            # somebody debugging a restart loop.
            log(f"re-registering uid {uid} (entry names "
                f"{recorded_displays.get(uid)}, session is on "
                f"{published_displays.get(uid)})")
            self._apply(refresh_argv(uid), uid, "refresh")
        for uid, ids in p.conflicts:
            # Never resolved automatically: see dreamconnect_discovery.plan.
            log(f"uid {uid} has {len(ids)} desktops ({', '.join(ids)}); "
                f"leaving it alone -- the registry holds one session per account")
        return p

    def _apply(self, argv, uid, what):
        result = self._run(argv)
        if result is not None and getattr(result, "returncode", 0) != 0:
            # Logged, not raised: one account failing must not stop the others
            # being reconciled, and the next pass will retry.
            log(f"{what} for uid {uid} failed ({result.returncode}): "
                f"{(getattr(result, 'stderr', '') or '').strip()}")


# logind's signals tell us the moment something changes; the timer is what makes
# the supervisor correct rather than merely prompt. A signal delivered while we
# were restarting is gone, and a missed SessionRemoved leaves an entry promising
# a session that no longer exists.
RECONCILE_INTERVAL_SECONDS = 30


def main():
    import gi
    from gi.repository import Gio, GLib

    if os.geteuid() != 0:
        log("must run as root: the registry has to stay root-owned or the "
            "agent ignores it entirely")
        return 1

    supervisor = Supervisor()
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    def on_change(*_args):
        supervisor.reconcile()

    for signal_name in ("SessionNew", "SessionRemoved"):
        bus.signal_subscribe("org.freedesktop.login1",
                             "org.freedesktop.login1.Manager",
                             signal_name, "/org/freedesktop/login1",
                             None, Gio.DBusSignalFlags.NONE, on_change)

    def tick():
        supervisor.reconcile()
        return GLib.SOURCE_CONTINUE

    supervisor.reconcile()
    GLib.timeout_add_seconds(RECONCILE_INTERVAL_SECONDS, tick)

    loop = GLib.MainLoop()

    def stop(*_):
        log("shutting down; sessions keep their entries")
        loop.quit()
        return GLib.SOURCE_REMOVE

    # Deliberately does NOT deregister on exit. The entries describe sessions
    # that are still live and still reachable; tearing them down because the
    # supervisor restarted would drop every operator mid-call. systemd's BindsTo
    # is what removes an entry when its session actually ends.
    import signal as signal_module
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal_module.SIGTERM, stop)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal_module.SIGINT, stop)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
