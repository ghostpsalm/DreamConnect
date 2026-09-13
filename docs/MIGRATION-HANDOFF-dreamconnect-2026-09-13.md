# Migration handoff — DreamConnect — 2026-09-13

State: **DRAINED — SAFE TO MIGRATE**, with one gap noted at the end.

This file is the handoff. It is committed to the repository on purpose: the target
VM should be able to resume from Git and GitHub alone. **`factory/` run state is
NOT migrating** — everything a reader needs is in Git, in an issue body, or in a
PR body.

---

## Project

| | |
|---|---|
| Name | DreamConnect — a javaagent that hooks AWT `Robot` so an unmodified ScreenConnect Linux client drives a Wayland GNOME desktop through Mutter's D-Bus capture/input API |
| Repository | `ghostpsalm/DreamConnect` |
| Primary checkout on old host | `/home/kogies/dreamconnect` |
| Factory repo (separate, also touched) | `ghostpsalm/AI-Factory` at `/home/kogies/ars-aifactory` |

---

## Canonical state

```
Canonical branch:   main
HEAD (local+remote) 87a9450  Merge: agent build integrity — hash the jar directly (#49), stop one test aborting the gate (#41)
Remote:             https://github.com/ghostpsalm/DreamConnect.git
Ahead of origin:    0
Behind origin:      0
Dirty tracked:      0
Untracked:          .github/workflows/ci.yml  (deliberate — see "Parked, not lost")
```

There is **no remote CI**. The gate is local only: `.githooks/pre-commit` and
`.githooks/pre-merge-commit` run `./scripts/gate.sh` before every commit and
every merge and refuse a red one. `core.hooksPath` is local git config and is
**not** inherited by a clone — run `./scripts/install-hooks.sh` once on the new
box or the repo is ungated.

---

## Landed during the drain

All through PRs, merged into `main`.

| PR | Issues | What |
|---|---|---|
| [#70](https://github.com/ghostpsalm/DreamConnect/pull/70) | #49, #41 | `agent/build.sh` hashes the jar directly instead of parsing `sha256sum -c`; each boot test catches `Throwable` and defers the gate failure so one method cannot silently truncate the suite |
| [#71](https://github.com/ghostpsalm/DreamConnect/pull/71) | #33, #30 | `install.state` whitespace trimmed with an actionable refusal; `passwd_entry` gains a three-way status so a failed lookup is no longer read as account absence |

Landed earlier the same week, before the drain, by local merge: #40, #43, #45,
#54, #57, #62, #64. Those predate the PR-only rule and are already on `main`.

---

## Open PRs

All three are **DRAFT** and none should be merged as-is.

| PR | Branch | Issue | Gate | Remaining |
|---|---|---|---|---|
| [#72](https://github.com/ghostpsalm/DreamConnect/pull/72) | `runtime/virtual-monitors` | #55 | green at `ab7e940` | Crash path. A `SIGKILL`ed daemon still leaks its virtual monitor — session creation sits outside the guarded region. Branch is **behind `main`**. |
| [#73](https://github.com/ghostpsalm/DreamConnect/pull/73) | `agent/fixture-fetch` | #46 | green at `2de36e2` | **Slice 3 first.** Two copies of a pinned SHA-256 exist until it replaces the hardcoded hash with a `bb_sha256` call read from `agent/build.sh`. REQ-011 is violated until then. Do not merge before it. |
| [#74](https://github.com/ghostpsalm/DreamConnect/pull/74) | `backstage/attended-display` | #63 | green at `e47f8ee` | Slice 1 only. Never reached seraph, review, or a terminal state. |

Each PR body carries: state, completed work, tests run, findings, remaining
steps, source branch, target branch, and originating run id.

---

## Parked runs

`factory/` is not migrating, so each run's restart instruction lives in its
**issue body**, under `## Resume notes (migration drain, 2026-09-13)`.

| Issue | Run id | Branch | Stopped in | Next action |
|---|---|---|---|---|
| #32 | `impl-32-88a9eab8` | `install/state-file` | architect/oracle, nine requirements, no source changes yet | Recreate the worktree, `/implement 32`. Scope includes `uninstall()` — the lock must cover `useradd`, not just the state read/write. |
| #46 | `impl-46-447c5d41` | `agent/fixture-fetch` | slice 1 of 4 done | Slice 3 first (remove the duplicate constant), then 2 and 4, then seraph. |
| #55 | stopped deliberately | `runtime/virtual-monitors` | clean-restart half done | Fresh single-slice run for the crash path: move session creation inside the guarded region. |
| #63 | `impl-63-3d89ff85` | `backstage/attended-display` | slice 1 | Resume from slice 2. |

### Lost with the old host, deliberately

- `/tmp/claude-1000/repro55.py` — a working repro for #55's crash path. What it
  demonstrated is written into #55's resume notes; the file itself does not survive.
- `factory/invocations/`, `factory/context-packs/`, role transcripts, receipts,
  and the authorship ledgers for every run above. Archived under
  `~/.factory/archives/dreamconnect/` on the old host if anyone wants them before
  it is wiped, but nothing downstream depends on them.

---

## Current backlog head

16 issues open. In the order they should be picked up:

1. **#32** — in flight, branch exists, requirements agreed. Finish it first.
2. **#46 slice 3** — closes a live REQ-011 violation on a pushed branch.
3. **#55 crash path** and **#63 slice 2** — both have a green checkpoint to build on.
4. **#65** — `passwd_entry`'s `root` probe is per-key, not per-source; a dead SSSD
   with healthy `files` still reads an LDAP account as absent. Ships with a
   numbered first requirement: refuse the absence short-circuit when
   `CREATED_ACCOUNT=0`, before the larger per-source work.
5. **#59** — two tests budget wall-clock across process startup and fail the
   pre-commit gate at random under load. Worth doing early: it is the one that
   teaches people to use `--no-verify`.
6. Then #22, #34, #47, #60, #66, #67, #68, #69.

**#56** cannot be closed from a desk. Its acceptance is a human logging in at a
real console and appearing in the operator's picker. It needs the Fedora box.

---

## Machine dependencies (non-secret)

Verified present on the old host:

| | version |
|---|---|
| Python | 3.14.5 |
| JDK | OpenJDK 25.0.3 — **a full JDK, not a JRE**: `BootTests` needs `java.desktop` internals via `--add-exports` |
| bash | 5.3.9 |
| `flock` | util-linux 2.41.5 — **#32's design refuses the install if `flock` is missing**; check it on the new box |
| git | 2.54.0 |
| `gh` | 2.94.0, authenticated |

Also required: `javac`, `awk`, `sed`, `getent`, `loginctl`, `systemctl`,
`dconf`, `useradd`/`userdel`, and a GNOME/Wayland session with Mutter and
PipeWire for anything beyond the unit tests.

Distro assumption is Fedora with GNOME 49+. Other distros and desktops are
untested; KDE and wlroots are out of scope by design.

---

## Secret / credential setup required

Names and purposes only.

| What | Purpose |
|---|---|
| GitHub credential for `gh` | pushing branches, opening and merging PRs, filing issues |
| GitHub token with `workflow` scope | **only** needed to land `.github/workflows/ci.yml`; the automation credential does not have it, which is why that file is still untracked |
| ScreenConnect relay/launch parameters | `ClientLaunchParameters.txt` and `*.key` are gitignored and must be reinstalled out of band |
| OS keyring / login keyring | dconf and user-session work expect an unlocked session keyring |

No secret values appear in this file or in the repository.

---

## Factory state

Nothing from `dreamconnect`'s `factory/` needs to move. What does matter:

- **`ghostpsalm/AI-Factory` carries a live patch made from this host** for
  [AI-Factory#605](https://github.com/ghostpsalm/AI-Factory/issues/605):
  `RESERVED_DETERMINATIONS` entries now take an optional `issue_id` and
  `reverification_obligations()` skips one scoped to another issue. It is applied
  **identically** to `~/.claude/scripts/` and to
  `/home/kogies/ars-aifactory/.claude-proposed/scripts/`, plus three test
  updates. **It is committed nowhere.** If `~/.claude` is rebuilt on the new box
  from the published deployment, the patch is lost and every run in every repo is
  injected with an unsatisfiable breaker obligation again.
- That patch is **tested but not gate-verified**: 15 targeted suites green
  (`test_factory_finding_evidence.py` 102 cases 0 wrong, plus 14 related), the
  full 136-suite gate was killed by the kernel for low memory and never ran.
- `~/.factory/queue/dreamconnect.json` holds `agent/build-integrity-2: [48]` and
  `install/state-file: [34, 65]`. Those are the enqueued-but-unstarted issues.
  Left queued for the target VM on purpose.

Five open factory issues were filed from this project and are worth reading
before restarting production: **#586** (a finished run's state blocks the next
issue and only the owner can clear it), **#587** (the seraph is never told to
emit `proof_type`), **#588** (two tools record a finding ruling, one writes what
the driver reads), **#597** (a run reaches `COMPLETE` before its findings can be
acted on), **#601** (`REMEDIATE` on a verification obligation re-issues the
verifier forever). Together they are why several rulings this week had to be
downgraded and written down instead of acted on.

---

## Deployment / generated state

There is a **live install on the old host** and it has drifted from `main`:

```
/opt/dreamconnect            root-owned, last written 2026-08-17
/opt/dreamconnect/install-lib.sh   DIFFERS from main — older
/etc/systemd/system/dreamconnect-attach@.service
/etc/systemd/system/dreamconnect-register@.service
/etc/systemd/system/dreamconnect-sessiond.service
```

Do **not** copy `/opt/dreamconnect` to the new box. It is reproducible from
source: run `install.sh` from a checkout of `main`. Nothing in it is unique
except the ScreenConnect launch parameters, which are secret material handled
above.

### Parked, not lost

`.github/workflows/ci.yml` (1170 bytes, untracked) runs `./run-tests.sh` on every
PR and push. It has never been committed because pushing it needs a token with
`workflow` scope. **Copy this file to the new host manually** — it is the only
untracked artefact worth carrying, and landing it would finally give the repo
remote CI.

---

## Services / processes to start on the target VM

Nothing starts automatically. In order:

1. `./scripts/install-hooks.sh` — without it the repo is ungated.
2. `sudo ./install.sh` (add `DREAMCONNECT_BACKSTAGE=1` for an unattended box)
   only if this VM is meant to run the bridge rather than just build it.
3. Factory production lines are started per-issue with
   `~/.claude/scripts/factory_dispatch.py start <area>/<slug> --issue N --go`.
   **Do not start any until the migration health check below passes.**

---

## Verification — run these on the target VM

```bash
# 1. repository identity
git clone https://github.com/ghostpsalm/DreamConnect.git && cd DreamConnect
git rev-parse HEAD            # expect 87a9450 or a descendant
git status --short             # expect empty

# 2. gate the baseline
./scripts/install-hooks.sh
./scripts/gate.sh; echo "exit=$?"        # expect exit 0, "ALL TESTS PASSED"

# 3. toolchain
python3 -V; java -version; javac -version; flock --version; bash --version

# 4. the branches the drafts live on
git fetch origin
git log --oneline origin/agent/fixture-fetch -1        # 2de36e2
git log --oneline origin/runtime/virtual-monitors -1   # ab7e940
git log --oneline origin/backstage/attended-display -1 # e47f8ee
git log --oneline origin/install/state-file -1         # merged into main

# 5. remote auth
gh auth status && gh pr list --state open              # expect #72, #73, #74 as drafts

# 6. factory deployment integrity — the one that is easy to miss
grep -n 'issue_id' ~/.claude/scripts/factory_finding_evidence.py
#   must show the RESERVED_DETERMINATIONS scoping from AI-Factory#605.
#   If it is absent, re-apply it before starting any line.
python3 ~/ars-aifactory/scripts/test_factory_finding_evidence.py   # 102 cases, 0 wrong

# 7. factory drift, from the ars-aifactory checkout
./scripts/publish.py --drift
```

Known flake: `test_xprobe_wrapper_short_circuits_a_display_already_known_dead`
and `test_wait_for_user_bus_reports_an_unrunnable_python3_instead_of_a_timeout`
budget wall-clock across process startup and fail at random on a loaded box
(#59). If the gate is red only on one of those, re-run before believing it.

---

## Old host final state

Stopped:

- the 30-minute babysit loop (session cron `3d465078`) — **cancelled**, no
  further dispatch;
- all four production-line sessions — idle, then their tmux windows closed;
- no agent process is expected to be mutating state.

Safe to delete later, once the new box passes verification:

- `~/.factory/worktrees/dreamconnect/*` — every branch is pushed;
- `~/.factory/archives/dreamconnect/*` — archived run state, nothing depends on it;
- `/tmp/claude-1000/*` — includes `repro55.py`, whose content is captured in #55;
- `/opt/dreamconnect` and the three `dreamconnect-*` systemd units — reproducible
  from `install.sh`.

Do **not** delete before copying: `.github/workflows/ci.yml`, and the
`AI-Factory#605` patch in `~/.claude/scripts/` if `~/.claude` is not being
rebuilt from source.

---

## The one gap

The instruction that started this drain named the target as `<TARGET_VM>` — the
placeholder was never filled in, so **this handoff does not know where it is
going**. Everything above is host-independent, but three things need the real
target before they can be finished:

1. whether `flock`, a full JDK 25, and GNOME 49+ are actually present there;
2. whether `~/.claude` will be rebuilt from the published factory deployment —
   which decides whether the AI-Factory#605 patch has to be re-applied by hand;
3. where `.github/workflows/ci.yml` and the ScreenConnect launch parameters get
   installed.

Nothing about the old host's shutdown waits on that. It is the first thing to
settle on arrival.
