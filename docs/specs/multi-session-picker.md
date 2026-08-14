# Multi-session picker: backstage + attended sessions, selectable in ScreenConnect

## Problem

An operator connecting to a box today sees exactly one session — whichever one
the installed drop-in hard-wires (backstage, `[Backstage]`). When a human logs
in at the console, their real desktop is invisible to ScreenConnect: the agent
curates the logon-session picker down to the one display its static
`shm=`/`socket=` args point at, so the attended session either doesn't appear
or (with curation off) appears but shows backstage's frames — a lie.

The operator wants both at once: the permanent backstage desktop for admin
work, and the console user's real session when someone is logged in — switchable
from ScreenConnect's own session picker, with no reinstall and no drop-in
editing.

## Solution

Run one daemon per session (already supported — shm/socket are uid-scoped) and
make the agent resolve *which* daemon per selection instead of being hard-wired
to one.

The spike (2026-08-14, this box) proved ScreenConnect's selection model does
the hard part for us:

- The SC **service** process probes logon sessions (`getDisplayInfos`) and
  shows them in the picker.
- Selecting one — by the operator, or SC auto-picking the list's first entry —
  **spawns a fresh child JVM with that session's `DISPLAY` baked into its
  environment**; switching kills the old child and spawns a new one.
- The Robot (and therefore our bridge) is built inside that child, where
  `System.getenv("DISPLAY")` is trustworthy.

So no live re-attach, no pointer-follow: the agent needs only

1. **Discovery** — enumerate live daemons by scanning
   `/dev/shm/dreamconnect.frame.<uid>` and asking each
   `/run/user/<uid>/dreamconnect.sock` which X display its session owns (new
   `DISPLAY` control command) and what to call it (existing `WHO`, plus a
   daemon-side label override so backstage answers `[Backstage]`).
2. **Curation, multi-daemon** — keep every picker entry backed by a live
   daemon, relabelled with that daemon's name; drop unbacked entries (greeter);
   order the backstage/default entry first so SC's auto-pick lands on it.
   Fallback when discovery finds nothing: today's single-session behaviour from
   the static args.
3. **Per-child endpoint resolution** — at `wrapPeer` time, map the child's own
   `DISPLAY` to that daemon's `(shm, socket)` and attach frames *and* input
   there. The static `shm=`/`socket=` args become the fallback when the map has
   no entry for the child's display.

Daemon side: each daemon learns its session's X display at startup — `--display`
arg (backstage: passed by the unit from the existing display publisher) or
`$DISPLAY` env (classic: present under `graphical-session.target`) — and serves
it over the control socket. A daemon that can't learn its display answers
unknown and is simply not offered in the picker.

Physical-monitor quirk, documented by the spike: a `RecordMonitor` stream
delivers no first frame until *input-driven* damage occurs. SC's connect-time
pointer move provides it in practice; the daemon's existing watchdog covers
stalls thereafter.

## User stories

1. As an operator, I want the session picker to list `[Backstage]` and the
   console user's session by name, so that I can tell them apart and pick the
   one I mean.
2. As an operator, I want selecting the console user's entry to show that
   user's real 1080p desktop and route my input to it, so that I can support
   the person at the machine.
3. As an operator, I want switching back to `[Backstage]` to return me to the
   admin desktop, so that one connection serves both purposes.
4. As an operator, I want sessions with no daemon behind them (the GDM greeter)
   hidden, so that the picker never offers a session that cannot work.
5. As an installer/maintainer, I want a box with only the backstage daemon to
   behave exactly as today, so that existing installs are unaffected until a
   second daemon exists.

## Seams under test

- **`Bridge` pure cores** (`agent/test/dreamconnect/boot/BootTests.java`,
  existing seam):
  - multi-daemon curation — given a probe array and a `display → label` map:
    backed entries kept and relabelled, unbacked dropped, default-first
    ordering, empty-map fallback to today's single-display behaviour.
  - endpoint resolution — given a child `DISPLAY` and a
    `display → (shm, socket)` map: correct endpoints chosen, static-args
    fallback when unmapped.
- **Daemon control protocol** (`runtime/test_daemon.py`, existing seam): the
  `DISPLAY` command replies the daemon's display; the `--display`/`$DISPLAY`
  resolution order; the label override answering `WHO`.

Discovery's socket-scanning shim stays thin (enumerate + query, no logic) and
is exercised end-to-end at the gate's integration level, not unit-mocked.

## Cross-repo impact

None — single repo. ScreenConnect itself is external, closed, and untouched;
the feature rides entirely on the existing javaagent/daemon seam. `install.sh`
and the systemd templates in this repo change (daemon `--display`/label
wiring); no sibling repo consumes them.

## Out of scope

- Switching *into* a session with no running daemon (starting daemons on
  demand is `dreamconnect-session`'s job, `docs/session-switching.md`).
- Remotely creating console sessions (autologin manipulation stays manual).
- Concurrent *visible* sessions — one child, one selection at a time, by SC's
  own model.
- Seamless no-reconnect switching (SC's child-respawn reconnect ~2–5 s is the
  accepted cost).
- Greeter capture (proven impossible; greeter entries are hidden, not fixed).
- Restricting what the backstage account may run (future hardening).

## Gate

```
./run-tests.sh
```

Green means: Java `BootTests` (curation + endpoint resolution), Python daemon
tests (protocol + display resolution), installer shell tests all pass.
