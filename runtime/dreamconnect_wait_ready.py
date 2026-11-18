#!/usr/bin/env python3
"""Hold ScreenConnect's start until the backstage session can be attached to.

Run as root from the ScreenConnect unit's `ExecStartPre=` (backstage installs
only, systemd/dreamconnect-wait.conf). On boot the ScreenConnect service starts
before the DreamConnect side is up, and in #102 that cost twice over: its JVM
read the display env file before the backstage shell had written it, so it had
no DISPLAY at all, and it resolved its session before the daemon had published
a frame. Waiting here fixes the first -- systemd reads `EnvironmentFile=` when
it spawns each command, so the `ExecStart` that runs after this sees the file
written during the wait -- and makes the second rare; the agent's retry of a
refused resolution covers what is left.

Ready means every one of:
  * the frame is a regular file (not a symlink) owned by the session's uid --
    the agent's own usableShm test, so "ready" here is what the agent accepts;
  * the daemon's socket answers PING with PONG;
  * the backstage shell has published its display env file;
  * root has registered the session (/run/dreamconnect/sessions/<uid>).

This never fails the unit. A daemon that does not come up within --timeout is
logged by name and ScreenConnect starts anyway: a remote-support client held
down by a broken bridge would cost the operator the one channel that can fix
it. The `-` on the ExecStartPre= line says the same thing a second time.

It reads and connects; it writes nothing and grants nothing.
"""
import argparse
import os
import socket
import stat
import sys
import time


def log(*a):
    print("[dreamconnect-wait]", *a, file=sys.stderr, flush=True)


def frame_ok(path, uid):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_uid == uid


def daemon_answers(sock_path, timeout=2.0):
    """True if the socket answers PING with PONG. The control protocol is a
    line per command (ControlServer in dreamconnect_daemon.py)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(sock_path)
        s.sendall(b"PING\n")
        reply = b""
        while not reply.endswith(b"\n") and len(reply) < 64:
            chunk = s.recv(64)
            if not chunk:
                break
            reply += chunk
        return reply.strip() == b"PONG"
    except OSError:
        return False
    finally:
        s.close()


def missing(uid, shm, sock_path, display_env, registry, answers=daemon_answers):
    """What is not ready yet, as short names; empty when everything is."""
    out = []
    if not frame_ok(shm, uid):
        out.append("frame %s" % shm)
    if not answers(sock_path):
        out.append("daemon %s" % sock_path)
    if not os.path.isfile(display_env):
        out.append("display env %s" % display_env)
    if not os.path.isfile(os.path.join(registry, str(uid))):
        out.append("registry entry %s/%d" % (registry, uid))
    return out


def wait_ready(check, timeout, clock=time.monotonic, sleep=time.sleep, interval=1.0):
    """Poll check() until it reports nothing missing or timeout seconds pass.

    Returns what was still missing at the end -- empty means ready. One check
    always runs, even at a zero timeout, so an already-ready box costs nothing.
    """
    deadline = clock() + timeout
    while True:
        left = check()
        if not left or clock() >= deadline:
            return left
        sleep(interval)


def main(argv=None, clock=time.monotonic, sleep=time.sleep, answers=daemon_answers):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--uid", type=int, required=True)
    ap.add_argument("--shm", required=True)
    ap.add_argument("--socket", required=True)
    ap.add_argument("--display-env", required=True)
    ap.add_argument("--registry", default="/run/dreamconnect/sessions")
    ap.add_argument("--timeout", type=float, default=150.0)
    args = ap.parse_args(argv)

    start = clock()
    left = wait_ready(lambda: missing(args.uid, args.shm, args.socket,
                                      args.display_env, args.registry, answers),
                      args.timeout, clock=clock, sleep=sleep)
    waited = clock() - start
    if left:
        log("still not ready after %.0fs, starting ScreenConnect anyway; missing: %s"
            % (waited, "; ".join(left)))
    else:
        log("session uid %d ready after %.0fs" % (args.uid, waited))
    return 0


if __name__ == "__main__":
    sys.exit(main())
