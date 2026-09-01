# DreamConnect

Makes the **unmodified** ConnectWise ScreenConnect Linux client work under Wayland GNOME, by swapping
the AWT `Robot` peer onto Mutter's own capture/input D-Bus API. A small Java agent plus a Python
helper daemon; the ScreenConnect client is never modified.

`README.md` is the user-facing account and `ROADMAP.md` tracks what has shipped. This file is for
whoever is changing the code.

## What constrains almost every decision here

- **Wayland forbids what the client assumes.** ScreenConnect drives capture and input through AWT
  `Robot`, which the JRE implements over X11. There is no X11 session on GNOME 49+. Everything in
  this repo exists to reroute those calls onto PipeWire ScreenCast and `org.gnome.Mutter.RemoteDesktop`
  without the client noticing.
- **GNOME/Mutter only, Fedora-verified only.** The headless no-consent path is `org.gnome.Mutter.*`.
  KDE/KWin and wlroots are not supported. Other distros are best-effort — say so rather than implying
  coverage that was never tested.
- **Two modes see different things.** *Attended* attaches to a real logged-in session; *backstage*
  (`DREAMCONNECT_BACKSTAGE=1`) runs its own headless GNOME session with no login and no monitor. A
  change that is right for one is frequently wrong for the other, so name which one you mean.

## Layout

| Path | What it is |
|---|---|
| `agent/` | The Java agent: `boot/` bootstrap classes, `src/`, `lib/`, `test/`, and `build.sh` |
| `runtime/` | The Python side — `dreamconnect_daemon.py`, `_discovery.py`, `_sessiond.py`, `_greeter.py`, plus their tests |
| `install.sh`, `install-lib.sh` | The installer, and the library that holds all of its testable logic |
| `test_install.sh` | 224 installer tests, driven against tmp fixtures |
| `systemd/` | Unit templates |
| `docs/` | Design, troubleshooting, and the per-feature specs under `docs/specs/` |
| `factory/` | Factory run records — history, not editable |

## The gate

```bash
./scripts/gate.sh
```

It delegates to `./run-tests.sh`, which is this repo's real gate and runs everything: the Java boot
tests, the Python daemon/discovery/supervisor/greeter suites, and `test_install.sh`. `gate.sh` is a
delegator on purpose — a second list of suites here could disagree with the one that actually runs.

**Green before committing.**

**There is no CI.** `.github/workflows/ci.yml` exists in the working tree but is **untracked and on no
branch**, so GitHub has never run it and a push triggers nothing. The gate above is the only check
that exists. Do not describe a push here as verified by CI; if the workflow is ever committed, correct
this paragraph in the same change.

## Seams

Testable behaviour is reachable without root, without a live GNOME session, and without touching the
real system.

| Seam | Where | Why it is the seam |
|---|---|---|
| `install-lib.sh` | sourced by `test_install.sh` | Holds **definitions only**, so sourcing must stay free of side effects. `install.sh` itself cannot be unit-tested: it demands root and does top-level work before anything is callable. |
| `runtime/*.py` | `runtime/test_*.py` | Command parsing and session logic, separated from D-Bus and PipeWire I/O |
| `agent/boot/` | `agent/test/`, run by `BootTests` | Bootstrap classes compiled with `--add-exports java.desktop/...` |

Two rails in `test_install.sh` that must not be removed: it **refuses to run as root**, because slices
drive `useradd`/`userdel` and `dconf` and a test that forgets a fixture override must not be able to
reach the real machine; and fixtures are overridden through `DC_*` environment variables
(`DC_DRY_RUN`, `DC_RUNTIME_DIR_ROOT`, `DC_BUS_POLL_INTERVAL`, …) rather than by patching paths inline.

## Conventions

**Commits**: `Area: imperative summary`, sentence case after the colon, issue number in parentheses
when there is one. Real examples:

```
Daemon: capture virtually when a session has no monitors
Register: fall back to the user manager's display
Daemon: stop the previous session before replacing it (#55)
Install: functions to write the session registry (#53)
```

The area is the component, not a type — `Daemon`, `Install`, `Register`, `Discovery`, `Greeter`,
`Agent`, `Roadmap`. One logical change per commit. **Never** an AI attribution trailer.

**Comments earn their length by recording the reasoning a diff cannot show.** This codebase already
does it well and it is the local style, not decoration — see `wait_for_user_bus`'s note on why the
timeout regex is `0|[1-9][0-9]*` and not `[0-9]+` (`$(( ))` reads a leading zero as octal, so `08`
aborts the expansion in a way that is not a `return`, and the caller's `|| die` never runs). Match
that: say what was ruled out and why.

**Shell**: `set -euo pipefail`. Refuse bad input in the function's own voice and `return 1` — never let
it reach arithmetic, where `set -u` aborts the shell and the caller's `|| die` never runs.

## Being honest about what was tested

This project is verified end-to-end on exactly one configuration. A change proven against fixtures is
proven against fixtures; a change proven on a live Fedora GNOME box is proven there. Say which. An
installer path that was never executed against a real `useradd` should not be reported as though it
was.
