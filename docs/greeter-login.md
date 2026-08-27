# Greeter mode — logging the box in from ScreenConnect

Attended and backstage mode both need a session to already exist. Neither can
show the **login screen**, so an operator has never been able to log a box in
from ScreenConnect: Mutter refuses capture and input to anything running against
the GDM greeter, and no amount of privilege changes that. Backstage sidesteps
the problem by not needing a login; it does not solve it.

Greeter mode solves it, without fighting Mutter.

## The idea

GNOME already ships exactly one sanctioned bridge into the greeter:
`gnome-remote-desktop` running in **system mode** (GNOME calls the feature
*Remote Login*). A client that authenticates to it is handed a **separate
headless Wayland GDM greeter** — its own session, its own dynamically allocated
`gdm-greeter-N` user, `Seat=` empty and `Remote=yes`. Authenticating there runs
the normal PAM stack and produces a real Wayland user session.

So DreamConnect does not try to capture the greeter. It becomes an RDP *client*
of that local service and republishes the view through the seam it already has:

```
  gnome-remote-desktop --system   (127.0.0.1 only, dropped at the firewall)
        │ RDP/TLS, transport credential
        ▼
   xfreerdp ──draws──► private Xvfb ──ximagesrc──► /dev/shm frame buffer
                            ▲                            │
                          XTEST                          ▼
                            │                    DreamConnect agent
                  control socket (input)         (unmodified) → ScreenConnect
```

The shm frame layout, the control-socket grammar and the agent are **unchanged**.
`ControlServer` talks to whichever session object it was handed, so greeter mode
is a second implementation of that interface, not a second protocol.

## The operator flow

1. Pick the greeter entry in ScreenConnect's session picker.
2. The real GDM login screen appears — the same one a person at the keyboard sees.
3. Log in as any account.
4. That account's session comes up and registers itself in the picker.
5. Switch to it.

## Enabling it

Greeter mode is **opt-in**. It runs a local RDP listener, which is a deployment
decision, not a default.

```sh
sudo runtime/dreamconnect-greeter-provision.sh enable        # default port 3389
```

That generates the TLS key/cert as the `gnome-remote-desktop` user, generates a
random transport credential into `/etc/dreamconnect/greeter-rdp.pw` (0600, owned
by the daemon account), and adds **explicit firewalld drop rules** for the port.

The drop rules are load-bearing. Fedora Workstation's default zone opens
`1025-65535/tcp`, so simply not opening the port still leaves it reachable from
the LAN. `gnome-remote-desktop` has no bind-address option — the firewall is the
only control.

Then run the daemon in greeter mode:

```sh
dreamconnect_daemon.py --greeter \
    --rdp-password-file /etc/dreamconnect/greeter-rdp.pw \
    --greeter-size 1920x1080
```

To remove it entirely: `sudo runtime/dreamconnect-greeter-provision.sh disable`.

## Session lifecycle — measured, not assumed

All of the following was observed on Fedora 44 / GNOME 50 by driving greeter
mode through its own control socket and reading `loginctl`.

**One greeter at a time, and it is consumed by the login.** A running greeter
daemon holds exactly one greeter session open. Logging in *consumes* it: after a
successful authentication there are zero greeter sessions and one user session.
Greeters do not accumulate across reconnects either — GDM reaps the old one, and
only a transient second appears during the handover itself.

**The session you get is seatless.** `Class=user`, `Type=wayland`, `Seat=` empty,
`Remote=yes`, `Service=gdm-password`. No monitor, no seat, entirely independent
of seat0.

**Whether a second login reuses or duplicates depends on direction**, because
GDM only migrates a session it can activate on the requesting seat:

| Second login as the same user | What GDM does | Result |
|---|---|---|
| Remote → remote | Remote displays have no seat, so activation is skipped and `session_unlock()` runs | **Reuses** the session — verified, same leader PID |
| **Physical console → a user who has a greeter-mode session** | `ActivateSessionOnSeat(<seatless session>, seat0)` **fails** — a seatless session cannot be activated on a seat — so `switch_to_compatible_user_session()` returns FALSE and GDM starts a fresh one | **Two live sessions for one user** |
| Remote → a user with a *locked seat0* session | Activation skipped (no seat on the remote side), `session_unlock()` runs against the seat0 session | **Unlocks the physical console** |

Verified directly against logind:

```console
$ busctl call org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager ActivateSessionOnSeat ss "34" "seat0"
Call failed: Session 34 not on seat seat0
```

That is the exact call `gdm_activate_session_by_id()` makes (`common/gdm-common.c`).

### The rule this produces

**Log in through greeter mode only as an account nobody uses at the console.**

A dedicated support account is not merely tidier — it is what keeps rows two and
three of that table from ever happening. Sharing an account between greeter mode
and a human at the keyboard gets you duplicate sessions in one direction and an
unlocked console in the other.

## Security — read before enabling

### Logging in as the console user unlocks the console

This is the sharp edge, and it is a property of GDM, not of DreamConnect.

GDM's existing-session lookup (`find_session_for_user`, `daemon/gdm-manager.c`)
matches on **username only**. It reads the candidate session's seat ID purely to
print a debug line — it does not filter on it. When a match is found,
`switch_to_compatible_user_session()` calls `session_unlock()` on it.

So authenticating through the remote greeter as a user who already holds a
**locked seat0 session** appears to drop the screen lock on the physical
machine, with nobody in front of it. The VT switch is skipped for a remote
display, so the screen does not visibly change *inputs* — but the lock is gone.

**Therefore: log in as an account that has no console session.** A dedicated
support account is the right answer, and it is also the better operational
choice — it gives a clean session rather than landing in someone's desktop.

> Status: this behaviour is **source-verified but not yet reproduced** against a
> real seat0 session. It was reproduced in miniature against a seatless remote
> session, where `LockedHint` went `yes → no` on successful authentication.
> Confirm on a disposable VM before relying on any policy around it.

### Two credentials, not one

- **Transport credential** (`/etc/dreamconnect/greeter-rdp.pw`) — gets you to the
  login screen. It is *not* an OS credential and must never be treated as one.
- **OS credential** — typed into GDM, verified by PAM. This gate is always in the
  path; greeter mode does not and cannot bypass it.

### Credential handling

The transport password is never passed as an argument, to anything. It is
generated by `openssl` into a 0600 file, handed to `grdctl` on stdin, and handed
to `xfreerdp` on stdin via `/from-stdin:force`. Nothing puts it in `argv`, and so
nothing puts it in `/proc`, `ps` output, or an audit log.

Two `grdctl` bugs are worked around in the provisioning script, both of which
fail silently if you hit them:

- Piping `username\npassword` does **not** work. `grdctl` opens a fresh buffered
  stream per prompt, so the username read swallows the password line and the
  password read hits EOF — then it **segfaults**, dumping the credential into a
  coredump. Pass the username as an argument instead.
- `sudo grdctl --system rdp set-credentials` writes to *root's* credential store,
  not the daemon's. The daemon runs as `gnome-remote-desktop` and never sees it;
  every connection is then refused with `Credentials are not set, denying
  client`. Credentials must be set **as** that account.

Consider `Storage=none` in `coredump.conf` on endpoints, so a crash in a
credential-handling tool cannot leave one on disk.

## Limits

- **Requires `gnome-remote-desktop` with system mode**, i.e. GNOME 46+. Present
  and complete on Fedora 40+; other distros vary.
- **`/cert:ignore` is used for the RDP hop.** Correct here — the peer is on
  loopback with a locally generated self-signed certificate, and there is no MITM
  position on `127.0.0.1`. Do not copy that flag anywhere else.
- **Costs a decode and a re-encode.** Pixels go RDP → Xvfb → `ximagesrc` → shm,
  where the native modes go PipeWire → shm. Greeter mode is for getting logged
  in; switch to the real session's entry once it appears.
- **Does not show seat0's greeter.** It is a *separate* headless greeter. That is
  a feature — the physical console keeps its own independent lock — but it means
  you are not looking at the physical screen.
