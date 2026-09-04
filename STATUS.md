---
progress: 80
updated: 2026-09-04
stage: Active
status: building
next: Work down the install/uninstall hardening issues (#22, #25, #26, #28, #30, #32-#34) on the install seam.
flags:
  - Verified end to end on exactly one configuration — Fedora, GNOME 49+, one live ScreenConnect session. Other distros and desktops are untested, and KDE/wlroots are out of scope by design.
  - There is no CI. `.github/workflows/` holds nothing tracked, so a push triggers nothing; `./scripts/gate.sh` is the only check that exists.
  - `.gitignore` ignores only `/factory/CHECKPOINT.md`, so every other `/implement` run-state file under `factory/` shows up as untracked and must be left unstaged by hand.
---

The bridge itself is done and works: headless capture and input over
`org.gnome.Mutter.{RemoteDesktop,ScreenCast}`, no consent dialog, the operator
command set, the installer, and the backstage headless session. That path has
been driven live through the real ScreenConnect client.

What is left is hardening, not features. 31 open issues, and they are edge
cases around the working path rather than gaps in it — installer failure
modes, uninstall cleanup, torn reads in the daemon, keyboard table coverage,
and build-script supply-chain checks. `progress: 80` is that split: the
product works, the edges do not all fail cleanly yet.

Most recent work: #29, on the `install/bus-probe-diagnostic-2` branch — the
user-bus wait now names a missing `python3` instead of blaming the user
manager.
