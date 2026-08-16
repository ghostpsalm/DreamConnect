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

1. **Discovery — a root-owned registry, not a filesystem scan.**
   `/run/dreamconnect/sessions/<uid>` is written by root (the same root that
   starts sessions: `dreamconnect-session`, and the installer for backstage) and
   names, per session: `uid`, `user`, `display`, `shm`, `socket`, `label`. The
   agent reads only this. Two levels of trust, deliberately different:
   - **The directory.** If `/run/dreamconnect/sessions` is not root-owned, or is
     writable by group or other, there is *no registry at all* — every entry is
     ignored and the agent falls back to today's single-session behaviour.
     Someone who can write the directory can write any entry, so nothing in it
     means anything.
   - **An entry.** Within a trusted directory, an entry that is not root-owned,
     is writable by others, is unreadable, or does not parse drops *only itself*
     and is logged. Only root can put a file there, so a bad one is a writer's
     bug rather than an attack, and letting a single malformed file disable
     every other session would be the worse failure.

   **Revised 2026-08-16 (owner decision), superseding "enumerate by scanning
   `/dev/shm/dreamconnect.frame.<uid>`":** the scan was removed after two
   red-team passes. The reason is structural, not a bug that could be patched:
   the filesystem can prove *a file belongs to uid N*, but nothing in it proves
   *uid N may serve display `:0`*. `/dev/shm` is world-writable, so any local
   user could publish a frame and a socket, claim another session's display,
   and either take that session over (sole claimant) or black it out (ambiguous
   claim). Each patch closed one shape of that and left another. A root-written
   registry removes the question: an account cannot register itself, cannot
   claim a display, and cannot make itself discoverable.

   Every connection is then authenticated with `SO_PEERCRED`: the peer's user
   must equal the entry's `user`. This is what defeats a redirect — a symlink
   pointing at another session's socket still reports the *listener's* identity,
   not the link's owner. Verified on this box, from the bootstrap classloader
   the agent actually runs in (`UnixDomainPrincipal[user=kogies, …]` read
   identically through a direct path and through a symlink). Note the principal
   must be read through the `UserPrincipal` interface; its implementation class
   lives in the unexported `sun.nio.fs`.

   The `shm` file is additionally required to be a regular file (not a symlink)
   owned by the entry's `uid`, since a stale registry entry could otherwise be
   met by a frame planted after the real daemon died.
2. **Curation, multi-daemon** — keep every picker entry backed by a live
   daemon, relabelled with that daemon's name; drop unbacked entries (greeter);
   order the backstage/default entry first so SC's auto-pick lands on it.
   Fallback when discovery finds nothing: today's single-session behaviour from
   the static args.
3. **Per-child endpoint resolution** — at `wrapPeer` time, map the child's own
   `DISPLAY` to that daemon's `(shm, socket)` and attach frames *and* input
   there. The static `shm=`/`socket=` args are the fallback only when there is
   nothing to resolve: nothing discovered, or a child that cannot say which
   display it is.

   **Revised 2026-08-16 (owner decision), superseding "the static args become
   the fallback when the map has no entry":** when live daemons exist but none
   owns this child's display — or when more than one claims it — resolution
   *refuses* and the bridge attaches to nothing, keeping ScreenConnect's own
   X11 peer. The operator sees black rather than another session's desktop.

   **Refined 2026-08-16 after a further red-team pass — refusal keys on whether
   the registry *describes* this display, not on whether it happens to be
   non-empty:**
   - the registry names no session for this display → **fall back** to the
     static args, *unless the fallback is known to be wrong* (below). The
     registry does not claim to be complete: while #53 is unwritten, or for any
     session root has not registered, the operator's own configuration is still
     the best statement of intent. Without this rule the first registered user
     session blacks out backstage, which was demonstrated live.
   - **known-wrong fallback → refuse.** If a registry entry claims the
     fallback's own `shm` *or* `socket` for some *other* display, falling back
     would show that session under this one's name. Either half alone is
     disqualifying: a shared frame shows the wrong screen, a shared socket types
     into the wrong session. This case is not exotic — the installer points the
     static args at backstage, so once backstage is registered (#53) every
     unregistered session would otherwise fall back onto it. Demonstrated
     live, added 2026-08-16 after a third red-team pass.
   - the registry names exactly one session for this display, and it is live →
     **attach** to it.
   - the registry names a session for this display but it is not usable (daemon
     down, frame not the account's, peer would not authenticate) → **refuse**.
     This is the anti-lie case and must never fall back: falling back here shows
     backstage under the selected user's name, which was also demonstrated.
   - the registry names more than one session for this display → **refuse**.

   Why the reversal: a red-team pass showed the original rule failing *open*.
   A session whose daemon answered `UNKNOWN` fell through to the configured
   args and showed **backstage** under that user's name — the precise lie in
   this document's Problem section, now reachable by accident rather than by a
   debug knob. Refusing on ambiguity likewise replaces a first-match-wins rule
   that a local user could win by owning a lower-sorting uid.

   Accepted risks of the reversal, both judged better than the alternative:
   - **Denial replaces impersonation.** A local user who stands up a daemon
     claiming another session's display now blacks that session out instead of
     hijacking it. Losing a session beats handing an attacker the operator's
     screen and keystrokes.
   - **Mixed-version window.** A daemon too old to answer `DISPLAY` is excluded;
     if a newer daemon exists elsewhere, discovery is non-empty and the old
     daemon's session refuses where it previously fell back and worked. The
     installer upgrades agent and daemons together, so the window is narrow —
     but it is real, and a refusal must be legible in the log rather than
     appearing as an unexplained black screen.

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
  - endpoint resolution — given a child `DISPLAY` and the registry's entries:
    correct endpoint chosen; fallback to the static args only when there is
    nothing to resolve; refusal (attach nothing) on no-match or ambiguity.
  - registry trust — parsing an entry; rejecting a registry directory or entry
    file that is not root-owned or is group/other-writable; rejecting an entry
    whose `shm` is a symlink or is not owned by the entry's `uid`.
- **Daemon control protocol** (`runtime/test_daemon.py`, existing seam): the
  `DISPLAY` command replies the daemon's display; the `--display`/`$DISPLAY`
  resolution order; the label override answering `WHO`.

The trust checks are tested against real files in a temp directory rather than
mocked — the earlier "pure cores only" seam is what let two exploitable defects
through, since the whole I/O surface was where they lived. `SO_PEERCRED`
verification is proven live (a same-account symlink shows the credential
follows the listener, not the path); a genuine cross-account impersonation
needs a second local account and is out of reach of the gate.

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
