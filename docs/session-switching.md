# Session switching — backstage and on-demand user sessions on one box

## The problem

Today an install is **either** backstage (a headless admin desktop under a
service account) **or** attended (the daemon follows a human's login). A fleet of
headless/VM devices that "log in and out" wants **both**: a backstage admin
desktop when nobody is working, and a *specific user's* real session (their home,
their files, their apps) on demand — all reachable through the one ScreenConnect
client, with no greeter and no autologin.

Spiked and proven (2026-08-14): a genuine logged-in session for any account can
be started headless over SSH —
`systemd-run --user gnome-shell --headless --wayland-display=<name>` — with that
account's `HOME`/environment and `RecordVirtual` working, exactly like backstage
but for a real user. So "a session" generalises: **(account) + (headless shell) +
(daemon capturing it)**. Backstage is just that with the service account.

## The insight that makes this cheap

Every "session" is the backstage machinery pointed at a different account. The
daemon, the display-env publisher and the agent drop-in are already
account-parameterised (uid-scoped shm `/dev/shm/dreamconnect.frame.<uid>`, socket
`/run/user/<uid>/dreamconnect.sock`, `EnvironmentFile=…/<uid>/…`). So switching
"which session ScreenConnect shows" is: bring up that account's session, then
point the SC client at that account's shm/socket/display.

## Design — repoint + reconnect (MVP)

A root CLI, `dreamconnect-session`, orchestrates it:

- `dreamconnect-session to <user>` — ensure `<user>` has a lingering manager, a
  headless shell, a published display env and a running daemon; then re-render
  the SC agent drop-in for `<user>`'s uid/shm/socket and restart the SC client.
  Backstage keeps running underneath as the fallback.
- `dreamconnect-session backstage` — repoint the drop-in back to the backstage
  account and restart SC.
- `dreamconnect-session stop <user>` — tear down a spawned user session (shell +
  daemon + published env); if it was active, switch back to backstage first.
- `dreamconnect-session status` — the active account and the available sessions.

Switching costs a brief (~2–5 s) SC reconnect, which is right for a deliberate,
occasional context switch (log a user in, work, log back out) rather than a
continuous stream. A seamless (no-reconnect) switch — the agent following a
`/run/dreamconnect/active` pointer and re-`mmap`ing on change — is a **v2**
optimisation; it touches the live capture path and is not worth the risk until
the coarse switch is proven.

## What a "user session" is here

Headless and **fresh** — a new desktop for that account, not a mirror of a
physical screen (Wayland forbids attaching to someone's on-console session; that
is the greeter/lock-screen inhibition). On a headless box or VM, where nobody is
at a physical display, this spawned session simply **is** "the user logged in".
Tearing it down is "logging out". No greeter, no autologin, no unlocked console.

## Security

`dreamconnect-session` is **root-only** — it starts sessions as arbitrary
accounts, which is a root capability. The operator drives it through
ScreenConnect's existing root Commands channel or over SSH. Each session's
shm/socket keep their `0600` owner-only permissions (the root SC JVM reads them
via DAC override, exactly as today). Spawning a user's session exposes that
user's files to whoever holds the SC connection — the same trust boundary as any
remote-admin tool, and narrower than autologin (no console is ever unlocked).

## Reuse / new

- **Reuse**: `dreamconnect_daemon.py` (`--virtual`), `dreamconnect-backstage-env.sh`
  (display publisher), the agent drop-in template, the uid-scoping.
- **New**: `dreamconnect-session` (the orchestrator), a per-account session
  bring-up path (generalised from the backstage unit), and the install wiring to
  ship the CLI.

## Non-goals (MVP)

- Mirroring a physically-attended session (impossible on Wayland).
- Seamless no-reconnect switching (v2, pointer-follow).
- Multiple concurrent *visible* sessions (one active at a time; others can stay
  warm but only the active one is shown).
