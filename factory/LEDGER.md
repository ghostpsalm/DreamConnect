# Factory ledger

One line per trip through the production line. Full records in `runs/`.

**Regenerated from `runs/*.json` — do not hand-edit.** Two production lines running in parallel both
append here, so an append-only file conflicts on every merge. Rebuild instead of resolving:

    ~/.claude/scripts/factory_record.py --rebuild-ledger --go

Cache reads are shown separately from output because they are billed differently; summing them into one
number would misrepresent cost.

| when (UTC) | run | status | issue | commits | CI | elapsed | tokens | outcome |
|---|---|---|---|---|---|---|---|---|
| 2026-07-29T09:42:46Z | issue-19 | done | #19 | 2 commits | - | 1794m | out 123,937 - cache-read 11,881,704 - agents 522,162 total across 12 spawns | bounces=1 breaker_verdict=defect-found findings_deferred=4 findings_fixed=5 guard_tests=2 laps=4 reviewer_blocking=0 seraph_unsure=0 slices=3 tests_added=8 |
