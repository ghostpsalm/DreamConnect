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
| 2026-07-31T13:17:24Z | issue-26 | done | #26 | 1 commits | - | 122m | out 167,400 - cache-read 23,691,916 - agents 1,018,890 total across 20 spawns | bounces=0 guard_tests=0 |
| 2026-07-31T23:05:22Z | issue-22 | done | #22 | 1 commits | - | 587m | out 140,486 - cache-read 25,202,034 - agents 652,505 total across 13 spawns | bounces=0 guard_tests=0 |
| 2026-08-01T01:11:33Z | issue-25 | done | #25 | 1 commits | - | 125m | out 136,163 - cache-read 34,497,835 - agents 1,176,052 total across 16 spawns | bounces=0 guard_tests=2 |
| 2026-08-01T02:31:10Z | issue-28 | done | #28 | 1 commits | - | 79m | out 72,912 - cache-read 32,982,713 - agents 336,833 total across 7 spawns | bounces=0 guard_tests=0 |
