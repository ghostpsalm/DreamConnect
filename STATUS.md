---
progress: 81
updated: 2026-09-13
stage: Active
status: draining for migration
next: Migration drain, 2026-09-13. Merged: #57 and #62 (area origin + its doc rename), #45 (control-socket bind umask), #54 (registry refresh on a moved display), #40, #43, #49, #41, #33, #30. Parked as DRAFT PRs for the target VM: #46 (PR 73, slice 1 of 4 - do NOT merge before slice 3 removes the duplicate pinned hash), #55 (PR 72, clean-restart half only, crash path outstanding), #63 (PR 74, slice 1, never reviewed). In flight and unfinished: #32 on this branch. Next work after migration: #32, then #34, then #65.
flags:
  - Verified end to end on exactly one configuration — Fedora, GNOME 49+, one live ScreenConnect session. Other distros and desktops are untested, and KDE/wlroots are out of scope by design.
  - There is no remote CI. `.github/workflows/ci.yml` exists in the working tree but is untracked and on no branch, so a push to GitHub still triggers nothing. Verification is local only: `.githooks/pre-commit` runs `./scripts/gate.sh` before every commit and every merge, and refuses the commit when it is red.
  - `core.hooksPath` is local git config, so a fresh clone is ungated until somebody runs `./scripts/install-hooks.sh`.
  - The physical GDM login screen cannot be bridged (mutter inhibits capture and input at the greeter). Autologin or grd Remote Login are the only reboot-reachability options.
  - The control-socket bind umask (#45) is fixture-proven only. The race it closes — a hostile local user connecting in the instant between `bind()` and `chmod` on a hand-launched daemon — was never reproduced against a live session, and under the shipped unit's `UMask=0077` it was never reachable anyway. Its `finally`-restore comment argued from a mechanism not in play; corrected on main in 79f35b2 (#64).
  - The supervisor's display refresh (#54) is fixture-proven only. That restarting `dreamconnect-register@<uid>` on a moved display actually clears the REFUSED black screen was never executed against a real `systemctl`; only a backstage shell restart on the Fedora box settles it.
  - `VK_SEPARATOR`'s keysym routing (#40) is fixture-proven only. That `KS 65452` lands a separator on a `us`/`pc` guest depends on Mutter finding a keycode for `XK_KP_Separator`, which no test can observe; a live key-logger run by the ROADMAP H1 method would settle it.
---

The bridge itself is done and works: unmodified ScreenConnect drives a Wayland
GNOME desktop through Mutter's capture and input D-Bus API, in both attended and
backstage (headless, no-login) modes. Capture, mouse, keyboard, clipboard and the
operator command set are shipped and proven against a real operator session.

What is left is hardening, not capability. The open issues are almost entirely
robustness defects found by review rather than missing features — non-atomic
reads across threads, installer failure paths that were never executed against a
real `useradd`, build-script verification gaps. None of them block normal use;
each of them is a way the thing can misbehave at the edges.

The 80 is that split: feature-complete and live-verified on one machine, with a
long defect backlog and no remote CI to catch regressions.
