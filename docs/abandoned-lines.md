# Abandoned production lines

A line that was started, produced work, and was retired without that work ever
landing. `factory/LEDGER.md` records the runs that finished; this file records
the ones that did not, so that "why is there no branch for that attempt?" has an
answer in the repo rather than only in somebody's memory.

Each entry names a **tag**, not just a sha. A deleted branch leaves its commits
unreachable, and an unreachable commit is one `git gc` away from gone — so every
commit named here is held by a pushed tag instead. `git show <tag>` reads it and
`git branch <name> <tag>` brings the line back.

Unless an entry says otherwise, nothing here was reviewed and nothing here was
gated — treat it as a starting point, never as a candidate.

## 2026-09-06 — retired after their successors merged

Four lines preserved during the 2026-09-05 stale-line triage. Each had already
been superseded by a later attempt at the same issue, and those successors are
now on `main`, so the attempts they replaced have nothing left to contribute.

| line | tag | what it tried | superseded by |
|---|---|---|---|
| `runtime/geom-atomicity` | `abandoned/geom-atomicity-1` | first attempt at issue #44 — stream geometry read torn across threads. Touched `runtime/dreamconnect_daemon.py` and `runtime/test_daemon.py`, and added a `scripts/test_gate.py` and `TEST-REGISTRY.json` that went nowhere. | `runtime/geom-atomicity-4`, merged as `c1f67eb` |
| `runtime/geom-atomicity-2` | `abandoned/geom-atomicity-2` | second attempt at the same issue, narrower: the daemon and its tests only. | same |
| `runtime/geom-atomicity-3` | `abandoned/geom-atomicity-3` | third attempt, narrower again. Its one lasting contribution — the CLAUDE.md correction that `run-tests.sh` is the authority on the suite list — travelled on `factory/readiness` and is on `main`. | same |
| `install/bus-probe-diagnostic` | `abandoned/bus-probe-diagnostic` | first attempt at issue #29 — `wait_for_user_bus` blaming the user manager for a `python3` that could not run. | `install/bus-probe-diagnostic-2`, merged as `da4bc33` |

None of the four ran a gate. Each was committed only so that retiring its
worktree destroyed nothing.

## Work dropped in a merge, rather than in a line

Not an abandoned line, but the same kind of loss and the same reason to write it
down.

**Issue #22 — `enable_autologin`'s `.dreamconnect.bak` is never removed on
uninstall.** Fixed on `install/host-account-fixes-2`, and *not* merged. Between
that branch being written and it being merged, `main` deleted GDM autologin
outright: backstage creates the headless session directly, so the workaround,
its GDM edit and its unlocked console all went (`install.sh`: "GDM autologin
used to be the answer here"). The fix, its `enable_autologin`/`disable_autologin`
helpers and their ~150 lines of tests were all for a feature that no longer
exists, so the merge kept `main`'s deletion. The branch's other four issues
(#25, #26, #28 and the uid argument) did land.

What that leaves open: a box installed *before* autologin was removed still has
`/etc/gdm/custom.conf.dreamconnect.bak`, still logs in automatically, and
today's `--uninstall` reverts neither. That is an upgrade path, not a defect in
the current installer — decide it on issue #22, rather than by resurrecting the
code.

## 2026-09-07 — the multi-session-picker line

`agent/multi-session-picker` stopped mid-run on **2026-08-15** and nobody came
back to it. Its `factory/CONTROLLER-STATE.json` records where: workflow state
`PRE_REMEDIATION_PROOF`, sub-phase `need_red`, two bounces of three used, seraph
`FAILED` on issue #50 with two `unmet-owner-decision` findings — an owner rider
saying empty or whitespace `--display`/`--label` must read as unset, which the
implementation at the time did not honour.

**That defect is fixed on `main`.** `_unset_if_blank` is applied on both paths,
and the seraph's own live probe (`ControlServer(..., label='  ').handle('WHO')`)
now returns the login name. #50, #51, #52 and #53 are closed against `main`.

What the line still held was 1286 uncommitted lines answering **#56** — the
attended human's session appearing in the picker — the way #56's own text
describes it: `attended_identity`/`attended_wiring` resolving the desktop account
at install time, an `attended.state` file, a user unit publishing that session's
`DISPLAY` at login, and `dreamconnect-register@<uid>` enabled for the account.

Preserved as `preserved/attended-registration`. **Its gate was green** on its own
base — `./run-tests.sh`, exit 0, all suites — so this is not half-finished work.
It is stranded work: ~1900 lines of `test_install.sh` behind `main`, and `main`
has since answered #56 a different way. `runtime/dreamconnect_discovery.py` plus
`runtime/dreamconnect_sessiond.py` attach **every** live session logind reports,
including accounts the installer never touched, and both are in the gate.

The two designs overlap: run both and two mechanisms race to write one registry
entry per uid. **Owner decision, 2026-09-07: the supervisor ships**, because it
reaches accounts the installer never touched — which is what #56's own opening
line asks for. The install-time wiring is retired, kept as the tag above.

The line's own run state — controller state, findings, ledgers, 78 files — is
archived at `~/.factory/archive/dreamconnect-multi-session-picker-20260907/`,
outside the repo, because it is machine-local telemetry for a run that ended.

#56 itself stays open. Its acceptance is a live check on a real box — a human
logs in at the console and appears in the operator's picker by name — and that
has not been run. Everything claimed here is read from code and a green gate.
