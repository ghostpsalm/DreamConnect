# Abandoned production lines

A line that was started, produced work, and was retired without that work ever
landing. `factory/LEDGER.md` records the runs that finished; this file records
the ones that did not, so that "why is there no branch for that attempt?" has an
answer in the repo rather than only in somebody's memory.

Each entry names the commit the branch pointed at. The branch is gone, the
commit is not: `git show <sha>` still reads it and `git branch <name> <sha>`
brings the line back. Nothing here was reviewed and nothing here was gated —
treat any of it as a starting point, never as a candidate.

## 2026-09-06 — retired after their successors merged

Four lines preserved during the 2026-09-05 stale-line triage. Each had already
been superseded by a later attempt at the same issue, and those successors are
now on `main`, so the attempts they replaced have nothing left to contribute.

| line | commit | what it tried | superseded by |
|---|---|---|---|
| `runtime/geom-atomicity` | `9009e37` | first attempt at issue #44 — stream geometry read torn across threads. Touched `runtime/dreamconnect_daemon.py` and `runtime/test_daemon.py`, and added a `scripts/test_gate.py` and `TEST-REGISTRY.json` that went nowhere. | `runtime/geom-atomicity-4`, merged as `c1f67eb` |
| `runtime/geom-atomicity-2` | `c9489c4` | second attempt at the same issue, narrower: the daemon and its tests only. | same |
| `runtime/geom-atomicity-3` | `b3192f3` | third attempt, narrower again. Its one lasting contribution — the CLAUDE.md correction that `run-tests.sh` is the authority on the suite list — travelled on `factory/readiness` and is on `main`. | same |
| `install/bus-probe-diagnostic` | `e3e011e` | first attempt at issue #29 — `wait_for_user_bus` blaming the user manager for a `python3` that could not run. | `install/bus-probe-diagnostic-2`, merged as `da4bc33` |

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
