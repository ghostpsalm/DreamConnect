# Factory ledger

One line per trip through the production line. Full records in `runs/`.

**Regenerated from `runs/*.json` — do not hand-edit.** Two production lines running in parallel both
append here, so an append-only file conflicts on every merge. Rebuild instead of resolving:

    ~/.claude/scripts/factory_record.py --rebuild-ledger --go

Cache reads are shown separately from output because they are billed differently; summing them into one
number would misrepresent cost.

| when (UTC) | run | status | issue | commits | CI | elapsed | tokens | outcome |
|---|---|---|---|---|---|---|---|---|
| 2026-07-28T03:49:45Z | issue-18 | unknown - predates the status field | #18 | 1 commits | - | 932m | out 691,600 - cache-read 98,813,678 - agents 3,319,294 total across 56 spawns | - |
| 2026-07-28T04:02:24Z | issue-18 | unknown - predates the status field | #18 | 2 commits | - | 944m | out 727,673 - cache-read 122,236,864 - agents 3,319,294 total across 56 spawns | - |
| 2026-07-28T12:12:53Z | issue-24 | unknown - predates the status field | #24 | 1 commits | - | 154m | out 104,398 - cache-read 12,908,721 - agents 588,473 total across 13 spawns | - |
| 2026-07-28T13:27:58Z | issue-21 | unknown - predates the status field | #21 | 1 commits | - | 325m | out 348,895 - cache-read 65,838,011 - agents 2,151,585 total across 44 spawns | - |
| 2026-07-28T13:49:10Z | issue-24 | unknown | #24 | 8 commits | - | 250m | out 151,022 - cache-read 29,005,776 - agents 588,473 total across 13 spawns | - |
| 2026-07-28T22:44:50Z | issue-21 | done | #21 | 6 commits | - | 882m | out 441,519 - cache-read 130,449,420 - agents 2,151,585 total across 44 spawns | - |
| 2026-07-29T09:42:46Z | issue-19 | done | #19 | 2 commits | - | 1794m | out 123,937 - cache-read 11,881,704 - agents 522,162 total across 12 spawns | bounces=1 breaker_verdict=defect-found findings_deferred=4 findings_fixed=5 guard_tests=2 laps=4 reviewer_blocking=0 seraph_unsure=0 slices=3 tests_added=8 |
| 2026-07-31T13:15:58Z | issue-36 | done | #36 | 1 commits | - | 76m | out 157,769 - cache-read 20,265,007 - agents 921,988 total across 16 spawns | bounces=0 guard_tests=0 |
