#!/usr/bin/env python3
"""Unit tests for the daemon's control-protocol parser (ControlServer.handle).

No live Wayland/D-Bus needed: a stub session records the calls handle() makes.
Run: python3 -m unittest runtime.test_daemon   (or: python3 runtime/test_daemon.py)
"""
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dreamconnect_daemon as d  # noqa: E402


class StubSession:
    def __init__(self):
        self.calls = []
        self.width, self.height, self.node_id = 1920, 1080, 66

    def motion_abs(self, x, y): self.calls.append(("M", x, y))
    def button(self, b, s): self.calls.append(("B", b, s))
    def axis_discrete(self, a, s): self.calls.append(("W", a, s))
    def key_code(self, k, s): self.calls.append(("K", k, s))
    def key_sym(self, k, s): self.calls.append(("KS", k, s))


class TestHandle(unittest.TestCase):
    def setUp(self):
        self.s = StubSession()
        self.cs = d.ControlServer("/tmp/dreamconnect-test-unused.sock", self.s)

    # control commands reply
    def test_ping(self):
        self.assertEqual(self.cs.handle("PING"), "PONG")

    def test_geom(self):
        self.assertEqual(self.cs.handle("GEOM"), "1920 1080")

    def test_node(self):
        self.assertEqual(self.cs.handle("NODE"), "66")

    def test_empty_is_ignored(self):
        self.assertIsNone(self.cs.handle(""))

    def test_unknown_command_errors(self):
        self.assertTrue(self.cs.handle("BOGUS").startswith("ERR"))

    # input commands are fire-and-forget (return None) and dispatch correctly
    def test_move_returns_none_and_dispatches(self):
        self.assertIsNone(self.cs.handle("M 100 200"))
        self.assertEqual(self.s.calls[-1], ("M", 100.0, 200.0))

    def test_button_press(self):
        self.assertIsNone(self.cs.handle("B 272 1"))
        self.assertEqual(self.s.calls[-1], ("B", 272, True))

    def test_button_release(self):
        self.assertIsNone(self.cs.handle("B 272 0"))
        self.assertEqual(self.s.calls[-1], ("B", 272, False))

    def test_wheel(self):
        self.assertIsNone(self.cs.handle("W 0 -1"))
        self.assertEqual(self.s.calls[-1], ("W", 0, -1))

    def test_key(self):
        self.assertIsNone(self.cs.handle("K 30 0"))
        self.assertEqual(self.s.calls[-1], ("K", 30, False))

    def test_keysym(self):
        self.assertIsNone(self.cs.handle("KS 97 1"))
        self.assertEqual(self.s.calls[-1], ("KS", 97, True))

    # malformed input must not reply (no desync) and must not dispatch
    def test_malformed_input_returns_none_and_stream_stays_aligned(self):
        self.assertIsNone(self.cs.handle("M"))          # missing args
        self.assertIsNone(self.cs.handle("K notanint 1"))
        self.assertEqual(self.s.calls, [])              # nothing dispatched
        # the next control command still replies correctly
        self.assertEqual(self.cs.handle("PING"), "PONG")


class TestFrameBufferEnsure(unittest.TestCase):
    """FrameBuffer.ensure() opens the shm path with O_CREAT|O_RDWR (see
    dreamconnect_daemon.py ~line 95). O_CREAT is a no-op when the path
    already exists, so a file left over from a prior install -- now
    inaccessible because the daemon runs under a different uid (e.g. after
    the host-account migration) -- must not wedge ensure() with the same
    PermissionError forever (issue #27).
    """

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="dreamconnect-test-")
        self.shm_path = os.path.join(self.tmpdir, "dreamconnect.frame")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_ensure_recovers_from_foreign_owned_existing_file(self):
        # Stand-in for "owned by a different uid": chmod 0o000 (can't chown
        # to another uid without root in a test) forces the same failure
        # os.open(O_RDWR|O_CREAT) hits against a pre-existing file this
        # process can no longer write to.
        with open(self.shm_path, "wb") as f:
            f.write(b"\x00" * d.HEADER_SIZE)
        os.chmod(self.shm_path, 0o000)

        fb = d.FrameBuffer(self.shm_path)
        fb.ensure(4, 2, 16)  # width=4 height=2 stride=16: arbitrary small frame

        # ensure() must leave the file owned/writable by this process again
        # (the 0600 contract already documented for a freshly created file,
        # dreamconnect_daemon.py lines 91-96) ...
        mode = stat.S_IMODE(os.stat(self.shm_path).st_mode)
        self.assertEqual(mode, 0o600)
        # ... holding the documented 64-byte header (the "<4sIIIII" layout
        # from the module's own header comment, lines 39-48, which
        # runtime/test_client.py independently parses off the real shm file).
        with open(self.shm_path, "rb") as f:
            header = f.read(d.HEADER_SIZE)
        magic, version, width, height, stride, fmt = struct.unpack_from(
            "<4sIIIII", header, 0)
        self.assertEqual(magic, d.MAGIC)
        self.assertEqual(version, 1)
        self.assertEqual(width, 4)
        self.assertEqual(height, 2)
        self.assertEqual(stride, 16)
        self.assertEqual(fmt, d.FORMAT_BGRX)


class TestFrameBufferEnsureStickyBitUnlink(unittest.TestCase):
    """dreamconnect_daemon.py ensure() (~lines 95-106) catches PermissionError
    around the initial os.open() and recovers by unlinking the leftover file,
    then retrying, once. /dev/shm has the sticky bit (mode 1777, see its own
    `stat`): under the sticky bit, unlink() requires the CALLER to own the
    target file, OR own the containing directory, OR be root -- merely
    having write access to the directory (what the sibling
    TestFrameBufferEnsure's chmod-0o000-in-a-plain-tempdir case exercises)
    is not sufficient. For a genuinely foreign-uid file (e.g. root-owned, as
    after a host-account migration -- the exact scenario issue #27
    describes), the recovery path's own os.unlink() call raises a SECOND
    PermissionError.

    Owner decision (issue #27 re-scope, after a breaker found this case):
    the daemon does NOT attempt privilege escalation (e.g. sudo) to handle
    it -- ensure() lets that second PermissionError propagate uncaught. The
    real fix belongs in install.sh instead, which already runs as root
    during the exact migration this occurs in and can unlink the stale file
    trivially before the daemon ever starts. This is a GUARD test: it
    documents that ensure() correctly refuses to paper over a case it
    cannot actually recover from, rather than hanging, swallowing the
    error, or failing some more confusing way.

    Reproduced with a synthetic directory (not /dev/shm itself, to avoid
    colliding with the live daemon's dreamconnect.frame) chmod+chowned to
    match /dev/shm's real mode and ownership (1777, root:root) -- confirmed
    by hand to fail identically to a real /dev/shm reproduction, since the
    sticky-bit unlink check is a generic VFS check (fs/namei.c may_delete),
    not tmpfs-specific. Note a same-uid-owned sticky tempdir would NOT
    reproduce this: under the sticky bit the DIRECTORY OWNER may unlink any
    file inside regardless of the file's own owner, so the directory itself
    must be foreign-owned too, exactly as /dev/shm (root:root) is.

    Needs passwordless sudo to create the foreign-owned directory/file;
    skipped where that is unavailable rather than failing for the wrong
    reason (SKILL.md "tests that can't run everywhere").
    """

    @classmethod
    def setUpClass(cls):
        r = subprocess.run(["sudo", "-n", "true"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if r.returncode != 0:
            raise unittest.SkipTest(
                "requires passwordless sudo to create a foreign-uid file "
                "under a sticky-bit directory (issue #27 reproduction)")

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="dreamconnect-test-sticky-")
        os.chmod(self.tmpdir, 0o1777)  # matches /dev/shm's real mode
        subprocess.run(["sudo", "-n", "chown", "root:root", self.tmpdir],
                        check=True)  # matches /dev/shm's real ownership
        self.shm_path = os.path.join(self.tmpdir, "dreamconnect.frame")
        subprocess.run(["sudo", "-n", "touch", self.shm_path], check=True)
        subprocess.run(["sudo", "-n", "chown", "root:root", self.shm_path],
                        check=True)
        subprocess.run(["sudo", "-n", "chmod", "600", self.shm_path],
                        check=True)

    def tearDown(self):
        # If ensure() didn't complete (the point of this test before the
        # fix), tmpdir/shm_path are still root-owned; shutil.rmtree can't
        # remove those, so reclaim first.
        subprocess.run(
            ["sudo", "-n", "chown", "-R", f"{os.getuid()}:{os.getgid()}", self.tmpdir],
            check=False)
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_ensure_raises_permission_error_for_a_foreign_owned_file_under_sticky_bit_dir(self):
        # A file genuinely owned by a different uid, sitting under a
        # sticky-bit directory also owned by that uid, cannot be reclaimed
        # by an unprivileged process at all: os.unlink() itself raises EPERM
        # (fs/namei.c may_delete -- the caller must own the file, own the
        # directory, or be root). ensure() must let that PermissionError
        # propagate -- not hang, not swallow it, not fail some other more
        # confusing way -- so the caller (and ultimately install.sh,
        # upstream of the daemon ever starting) can see exactly what went
        # wrong.
        fb = d.FrameBuffer(self.shm_path)
        with self.assertRaises(PermissionError):
            fb.ensure(4, 2, 16)  # width=4 height=2 stride=16: arbitrary small frame

        # Not silently routed around some other way either: the file ensure()
        # could not reclaim is still exactly where it was -- still there,
        # still root-owned, mode unchanged -- not deleted by some fallback
        # that then failed differently, and not left half-modified.
        st = os.stat(self.shm_path)
        self.assertEqual(st.st_uid, 0)
        self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
