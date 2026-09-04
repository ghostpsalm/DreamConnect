---
progress: 80
updated: 2026-09-04
stage: Active
status: building
next: Work down the daemon/installer hardening backlog; #57 (torn area_x/area_y) is the next one in this seam.
flags:
  - Verified end-to-end on exactly one configuration — a live Fedora GNOME box. Other distros are best-effort and untested.
  - There is no CI. `.github/workflows/ci.yml` is untracked and on no branch, so a push triggers nothing. `./scripts/gate.sh` is the only check that exists.
  - The physical GDM login screen cannot be bridged (mutter inhibits capture and input at the greeter). Autologin or grd Remote Login are the only reboot-reachability options.
---

The bridge itself is done and works: unmodified ScreenConnect drives a Wayland
GNOME desktop through Mutter's capture and input D-Bus API, in both attended and
backstage (headless, no-login) modes. Capture, mouse, keyboard, clipboard and the
operator command set are shipped and proven against a real operator session.

What is left is hardening, not capability. The ~29 open issues are almost entirely
robustness defects found by review rather than missing features — non-atomic reads
across threads, installer failure paths that were never executed against a real
`useradd`, build-script verification gaps. None of them block normal use; each of
them is a way the thing can misbehave at the edges.

The 80 is that split: feature-complete and live-verified on one machine, with a
long defect backlog and no CI to catch regressions.
