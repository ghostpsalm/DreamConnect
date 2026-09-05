#!/usr/bin/env python3
"""Unit tests for the session-discovery reconciler.

Pure decisions only: no logind, no systemd, no filesystem. What is asserted here
is the part that decides whose desktop an operator is shown, so the rules that
keep it from being the wrong one get the most tests.
Run: python3 -m unittest runtime.test_discovery  (or: python3 runtime/test_discovery.py)
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_discovery as disc  # noqa: E402


def sess(sid, uid, user="alice", klass="user", type="wayland",  # noqa: A002
         state="active", seat="seat0"):
    return disc.Session(sid, uid, user, klass, type, state, seat)


class TestAttachable(unittest.TestCase):
    def test_a_graphical_user_session_is_attachable(self):
        self.assertTrue(disc.is_attachable(sess("18", 1000)))

    def test_x11_counts_too(self):
        self.assertTrue(disc.is_attachable(sess("18", 1000, type="x11")))

    def test_the_systemd_manager_session_is_not_a_desktop(self):
        # Every login also gets a `manager` session. Attaching to it would mean
        # a second, bogus picker entry for every real user.
        self.assertFalse(disc.is_attachable(sess("1", 1000, klass="manager")))

    def test_greeter_sessions_are_not_offered(self):
        self.assertFalse(disc.is_attachable(
            sess("c1", 60581, user="gdm-greeter", klass="greeter")))

    def test_a_tty_login_has_no_desktop_to_serve(self):
        self.assertFalse(disc.is_attachable(sess("7", 1000, type="tty")))

    def test_a_closing_session_is_left_alone(self):
        # Attaching here races the scope teardown.
        self.assertFalse(disc.is_attachable(sess("18", 1000, state="closing")))

    def test_an_online_but_inactive_session_still_counts(self):
        # Switch-user makes the previous session inactive; it is still a real
        # desktop an operator may need to reach.
        self.assertTrue(disc.is_attachable(sess("18", 1000, state="online")))

    def test_a_seatless_session_is_attachable(self):
        # Greeter-mode and backstage sessions have no seat and are exactly the
        # ones worth reaching.
        self.assertTrue(disc.is_attachable(sess("34", 1000, seat="")))


class TestPlanAttach(unittest.TestCase):
    def test_an_unregistered_live_session_is_attached(self):
        p = disc.plan([sess("18", 1000)], registered_uids=[])
        self.assertEqual([s.uid for s in p.attach], [1000])
        self.assertEqual(p.release, [])

    def test_an_already_registered_session_is_left_alone(self):
        p = disc.plan([sess("18", 1000)], registered_uids=[1000])
        self.assertTrue(p.is_empty())

    def test_non_desktop_sessions_never_produce_an_attach(self):
        sessions = [sess("1", 1000, klass="manager"),
                    sess("c1", 60581, klass="greeter"),
                    sess("7", 1001, type="tty")]
        self.assertEqual(disc.plan(sessions, registered_uids=[]).attach, [])

    def test_several_users_each_get_one(self):
        p = disc.plan([sess("18", 1000), sess("22", 1001, user="bob")],
                      registered_uids=[])
        self.assertEqual(sorted(s.uid for s in p.attach), [1000, 1001])


class TestPlanRelease(unittest.TestCase):
    def test_a_registered_uid_with_no_session_is_released(self):
        p = disc.plan([], registered_uids=[1000])
        self.assertEqual(p.release, [1000])

    def test_logging_out_releases_only_that_user(self):
        p = disc.plan([sess("18", 1000)], registered_uids=[1000, 1001])
        self.assertEqual(p.release, [1001])

    def test_a_session_that_went_non_graphical_is_released(self):
        p = disc.plan([sess("18", 1000, type="tty")], registered_uids=[1000])
        self.assertEqual(p.release, [1000])


class TestReservedUids(unittest.TestCase):
    """The installer owns some uids; fighting it for a registry slot is a bug."""

    def test_a_reserved_uid_is_never_attached(self):
        p = disc.plan([sess("40", 995, user="backstage")],
                      registered_uids=[], reserved_uids=[995])
        self.assertEqual(p.attach, [])

    def test_a_reserved_uid_is_never_released_even_if_it_has_no_session(self):
        # The installer's entry outlives any session we can see; removing it
        # would delete a picker entry we do not own.
        p = disc.plan([], registered_uids=[995], reserved_uids=[995])
        self.assertEqual(p.release, [])


class TestConflicts(unittest.TestCase):
    """One uid, two desktops — the registry cannot say which."""

    def test_two_graphical_sessions_for_one_uid_is_a_conflict(self):
        p = disc.plan([sess("18", 1000), sess("34", 1000)], registered_uids=[])
        self.assertEqual(p.conflicts, [(1000, ["18", "34"])])

    def test_a_conflicted_uid_is_not_attached(self):
        # Picking one would be a coin flip on whose desktop the operator sees.
        p = disc.plan([sess("18", 1000), sess("34", 1000)], registered_uids=[])
        self.assertEqual(p.attach, [])

    def test_a_conflicted_uid_keeps_the_entry_it_already_has(self):
        # That entry may still be correct, and revoking access mid-support call
        # to punish an ambiguity we cannot resolve is worse than leaving it.
        p = disc.plan([sess("18", 1000), sess("34", 1000)],
                      registered_uids=[1000])
        self.assertEqual(p.release, [])

    def test_a_conflict_does_not_disturb_other_users(self):
        sessions = [sess("18", 1000), sess("34", 1000),
                    sess("22", 1001, user="bob")]
        p = disc.plan(sessions, registered_uids=[])
        self.assertEqual([s.uid for s in p.attach], [1001])
        self.assertEqual(p.conflicts, [(1000, ["18", "34"])])

    def test_the_manager_session_does_not_manufacture_a_conflict(self):
        # Every logged-in user has `user` + `manager`. Counting both would
        # report every single normal login as a conflict.
        p = disc.plan([sess("18", 1000), sess("1", 1000, klass="manager")],
                      registered_uids=[])
        self.assertEqual(p.conflicts, [])
        self.assertEqual([s.uid for s in p.attach], [1000])


class TestIdempotence(unittest.TestCase):
    """The runner reconciles on a timer as well as on signals."""

    def test_replanning_after_acting_yields_nothing(self):
        sessions = [sess("18", 1000)]
        first = disc.plan(sessions, registered_uids=[])
        registered = [s.uid for s in first.attach]
        self.assertTrue(disc.plan(sessions, registered_uids=registered).is_empty())

    def test_replanning_after_a_release_yields_nothing(self):
        first = disc.plan([], registered_uids=[1000])
        self.assertEqual(first.release, [1000])
        self.assertTrue(disc.plan([], registered_uids=[]).is_empty())


if __name__ == "__main__":
    unittest.main(verbosity=2)
