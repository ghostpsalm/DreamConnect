# Factory ledger

One line per trip through the production line. Full records in `runs/`.

Cache reads are shown separately from output because they are billed differently; summing them into one number would misrepresent cost.

**Token figures cover the parent thread only.** Sub-agent turns are not recorded in any accessible transcript, so a run that spawns agents cost more than its line shows — by an amount not measurable here. The spawn count is given so the gap is visible rather than silent.

`elapsed` is wall-clock across the run, not summed agent time — agents run inside it, and the time the owner spends deciding is real.

`outcome` holds what only the run knows: laps taken, what each stage found, what was deferred. Those are the figures that say whether the chain earned its cost; the token columns only say what it cost.

| when (UTC) | run | issue | commits | CI | elapsed | tokens | outcome |
|---|---|---|---|---|---|---|---|
| 2026-07-28T03:49:45Z | issue-18 | #18 | 1 commits | — | 932m | out 691,600 · cache-read 98,813,678 · agents 3,319,294 total across 56 spawns | — |
| 2026-07-28T04:02:24Z | issue-18 | #18 | 2 commits | — | 944m | out 727,673 · cache-read 122,236,864 · agents 3,319,294 total across 56 spawns | — |
