---
progress: 81
updated: 2026-09-11
stage: Active
status: building
next: Work down the daemon/installer hardening backlog; #57 (torn area_x/area_y) is done on `runtime/daemon-races` and waiting, so #30/#32-#34 on the install seam are next. #62 is a two-line doc rename left over from #57.
flags:
  - Verified end to end on exactly one configuration — Fedora, GNOME 49+, one live ScreenConnect session. Other distros and desktops are untested, and KDE/wlroots are out of scope by design.
  - There is no remote CI. `.github/workflows/ci.yml` exists in the working tree but is untracked and on no branch, so a push to GitHub still triggers nothing. Verification is local only: `.githooks/pre-commit` runs `./scripts/gate.sh` before every commit and every merge, and refuses the commit when it is red.
  - `core.hooksPath` is local git config, so a fresh clone is ungated until somebody runs `./scripts/install-hooks.sh`.
  - The physical GDM login screen cannot be bridged (mutter inhibits capture and input at the greeter). Autologin or grd Remote Login are the only reboot-reachability options.
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
