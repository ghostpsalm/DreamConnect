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


class Supervisor:
    """Applies plans. Split from the reconciler so the rules stay pure."""

    def __init__(self, registry_dir=REGISTRY_DIR, reserved_users=None,
                 runner=None):
        self.registry_dir = registry_dir
        if reserved_users is None:
            installed = host_account()
            reserved_users = DEFAULT_RESERVED_USERS + (
                (installed,) if installed else ())
        self.reserved_users = tuple(reserved_users)
        # Injected so tests can drive a full reconcile without touching systemd.
        self._run = runner or self._run_command

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

    def reconcile(self):
        """One pass. Returns the plan applied, for logging and for tests."""
        sessions = self.list_sessions()
        current = registered_uids(self.registry_dir)
        p = plan(sessions, current, self.reserved_uids(sessions))

        for session in p.attach:
            log(f"attaching {session.user} (uid {session.uid}, session "
                f"{session.session_id}, {session.type})")
            self._apply(start_argv(session.uid), session.uid, "attach")
        for uid in p.release:
            log(f"releasing uid {uid} (no live desktop)")
            self._apply(stop_argv(uid), uid, "release")
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
