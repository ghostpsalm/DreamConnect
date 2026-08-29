#!/usr/bin/env python3
"""Which live sessions should be attached to, and which should be released.

Today a session appears in the operator's picker only if the installer set that
account up: `dreamconnect-register@<uid>` is enabled per account, so a user who
simply logs in is invisible. For a remote support tool that is backwards — the
sessions you most need to reach are the ones nobody provisioned.

This module is the decision half of fixing that. It takes what logind reports
and what is currently registered, and returns what to start and what to stop.
It is deliberately pure: no D-Bus, no systemd, no filesystem. The runner that
acts on a plan is thin and replaceable; the rules are what need to be right, and
they are what the tests exercise.

Two constraints from the registry contract (install-lib.sh, Bridge.java) shape
every rule here:

  * an entry is named for a **uid**, so the registry can hold exactly one
    session per account; and
  * the agent refuses two entries claiming one display, permanently, rather
    than guess.

So a uid with two graphical sessions cannot be represented. That is not
hypothetical — it is what a greeter-mode login followed by a console login
produces, because GDM cannot migrate a seatless session onto a seat and starts
a second one instead. The plan reports it as a conflict and attaches neither,
rather than silently picking one and handing the operator someone else's
desktop.
"""

# logind session classes. Only `user` is a person's desktop: `manager` is the
# systemd user manager every login also gets, `greeter`/`manager-early` belong
# to display-manager plumbing, and `background`/`user-early` have no display.
CLASS_USER = "user"

# A session we can drive has a graphical stack behind it. `tty` logins and
# `unspecified` manager sessions have no Mutter to talk to.
GRAPHICAL_TYPES = frozenset({"wayland", "x11"})

# logind states worth attaching to. `closing` is a session whose leader has gone
# and whose scope is being torn down; attaching would race the teardown.
LIVE_STATES = frozenset({"active", "online"})


class Session:
    """One logind session, reduced to what the decision needs."""

    __slots__ = ("session_id", "uid", "user", "klass", "type", "state", "seat")

    def __init__(self, session_id, uid, user, klass, type, state, seat=""):  # noqa: A002
        self.session_id = session_id
        self.uid = int(uid)
        self.user = user
        self.klass = klass
        self.type = type
        self.state = state
        self.seat = seat

    def __repr__(self):
        return (f"Session({self.session_id!r}, uid={self.uid}, "
                f"user={self.user!r}, class={self.klass!r}, type={self.type!r}, "
                f"state={self.state!r}, seat={self.seat!r})")

    def __eq__(self, other):
        return isinstance(other, Session) and self._key() == other._key()

    def _key(self):
        return (self.session_id, self.uid, self.user, self.klass,
                self.type, self.state, self.seat)


def is_attachable(session):
    """A graphical desktop we could serve to an operator."""
    return (session.klass == CLASS_USER
            and session.type in GRAPHICAL_TYPES
            and session.state in LIVE_STATES)


class Plan:
    """What the runner should do. Empty lists mean nothing to do."""

    __slots__ = ("attach", "release", "conflicts")

    def __init__(self, attach, release, conflicts):
        self.attach = attach        # [Session] to bring up and register
        self.release = release      # [uid] to stop and deregister
        self.conflicts = conflicts  # [(uid, [session_id, ...])] left alone

    def __repr__(self):
        return (f"Plan(attach={[s.uid for s in self.attach]}, "
                f"release={self.release}, conflicts={self.conflicts})")

    def is_empty(self):
        return not self.attach and not self.release


def plan(sessions, registered_uids, reserved_uids=()):
    """Reconcile logind against the registry.

    `sessions`        — every logind session, unfiltered; filtering is our job.
    `registered_uids` — uids currently holding a registry entry.
    `reserved_uids`   — uids this supervisor must not touch, because something
                        else owns them: the backstage account, whose entry the
                        installer manages, and any account whose daemon was
                        provisioned by hand. Managing those here would fight the
                        installer for one registry slot.

    Idempotent: a uid already registered and still live is neither attached nor
    released, so calling this on a timer is safe and re-running it changes
    nothing. That matters because the runner reconciles on a schedule as well as
    on D-Bus signals — the signals can be missed, the timer cannot.
    """
    reserved = {int(u) for u in reserved_uids}
    registered = {int(u) for u in registered_uids}

    by_uid = {}
    for session in sessions:
        if not is_attachable(session) or session.uid in reserved:
            continue
        by_uid.setdefault(session.uid, []).append(session)

    attach, conflicts = [], []
    for uid in sorted(by_uid):
        found = by_uid[uid]
        if len(found) > 1:
            # Cannot be expressed: one entry per uid, and the agent refuses a
            # contested display outright. Report it and leave the uid alone --
            # including any entry it already has, which may still be correct.
            conflicts.append((uid, sorted(s.session_id for s in found)))
            continue
        if uid not in registered:
            attach.append(found[0])

    # Release only a uid with no attachable session at all. `by_uid` still holds
    # the conflicted ones, and that is deliberate: a conflict means we cannot
    # tell which desktop to serve, not that the entry already there is wrong.
    # Revoking it would cut an operator off mid-call to punish an ambiguity.
    release = sorted(uid for uid in registered
                     if uid not in by_uid and uid not in reserved)
    return Plan(attach, release, conflicts)
