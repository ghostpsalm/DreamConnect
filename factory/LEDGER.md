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
| 2026-07-31T12:15:34Z | issue-37 | done | #37 | 1 commits | - | 16m | out 42,187 - cache-read 4,086,470 - agents 51,569 total across 2 spawns | - |
| 2026-07-31T13:15:58Z | issue-36 | done | #36 | 1 commits | - | 76m | out 157,769 - cache-read 20,265,007 - agents 921,988 total across 16 spawns | bounces=0 guard_tests=0 |
| 2026-07-31T13:17:24Z | issue-26 | done | #26 | 1 commits | - | 122m | out 167,400 - cache-read 23,691,916 - agents 1,018,890 total across 20 spawns | bounces=0 guard_tests=0 |
| 2026-07-31T13:37:39Z | issue-38 | done | #38 | 1 commits | - | 21m | out 49,459 - cache-read 11,026,051 - agents 282,706 total across 5 spawns | bounces=0 guard_tests=1 |
| 2026-07-31T23:05:22Z | issue-22 | done | #22 | 1 commits | - | 587m | out 140,486 - cache-read 25,202,034 - agents 652,505 total across 13 spawns | bounces=0 guard_tests=0 |
| 2026-07-31T23:16:01Z | issue-43 | done | #43 | 1 commits | - | 67m | out 124,927 - cache-read 15,395,176 - agents 533,012 total across 13 spawns | bounces=0 breaker_verdict=defect-found findings_deferred=4 findings_fixed=2 guard_tests=0 laps=2 reviewer_blocking=0 slices=3 tests_added=5 |
| 2026-08-01T01:11:33Z | issue-25 | done | #25 | 1 commits | - | 125m | out 136,163 - cache-read 34,497,835 - agents 1,176,052 total across 16 spawns | bounces=0 guard_tests=2 |
| 2026-08-01T02:31:10Z | issue-28 | done | #28 | 1 commits | - | 79m | out 72,912 - cache-read 32,982,713 - agents 336,833 total across 7 spawns | bounces=0 guard_tests=0 |
| 2026-08-01T06:15:05Z | issue-27 | done | #27 | 1 commits | - | 257m | out 156,181 - cache-read 13,118,733 - agents 1,052,983 total across 17 spawns | bounces=0 guard_tests=2 |
| 2026-09-04T07:58:02Z | issue-44 | done | #44 | 2 commits | - | 332m | out 110,759 - cache-read 10,060,156 - agents 177,887 total across 4 spawns | bounces=0 guard_tests=0 laps=0 |
| 2026-09-04T10:42:54Z | issue-29 | done | #29 | 1 commits | - | 52m | out 84,930 - cache-read 9,703,725 - agents 277,224 total across 4 spawns | bounces=0 guard_tests=1 |
| 2026-09-10T22:11:17Z | issue-40 | done | #40 | 1 commits | - | 5808m | out 153,427 - cache-read 19,317,031 - agents 234,111 total across 4 spawns | bounces=0 guard_tests=1 |
