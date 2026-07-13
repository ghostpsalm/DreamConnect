# Spike 1 — BlankGuestMonitor under Wayland — **NOT FEASIBLE** ❌ (current architecture)

Date: 2026-07-13 · Host: GNOME/Wayland workstation (Fedora, GNOME/mutter, Wayland),
capturing physical monitor `HDMI-2`.

## Question

ScreenConnect's **BlankGuestMonitor** command darkens the guest's physical screen
for privacy *while the operator keeps seeing the real desktop*. On Windows a
mirror driver decouples the two. Can we do the same on Wayland/Mutter — blank the
physical panel while our PipeWire capture keeps delivering real frames?

(The Linux client's own implementation is a hard no-op: `ClientOSToolkit`
`isBlankingMonitorsSupported()` → `return false`, `blankMonitorsOrWallpapers()` →
`return null`. So making it work means implementing the blank ourselves.)

## Result — no clean mechanism

The cleanest candidate, **`org.gnome.Mutter.DisplayConfig.PowerSaveMode`** (DPMS),
was set to `3` (OFF) and **held** (read back as `3` for 4–6s, wake-lock inhibit
released first), while the shm capture buffer kept advancing with real content.
**But the physical panel never went dark** (confirmed visually, twice). The active
ScreenCast keeps the CRTC page-flipping, so Mutter reports the power-save mode yet
the scanout stays lit. Even if it *did* blank with capture stopped, that is
mutually exclusive with the operator seeing anything.

Every other mechanism hits the same wall — we capture the **composited physical
monitor**, which is inseparable from the physical scanout:

| Mechanism | Verdict |
|---|---|
| `PowerSaveMode` (DPMS off) | Mode honored, panel stays lit while capturing. ✗ |
| Black fullscreen overlay | Blacks the operator's capture too (same composited output). ✗ |
| `ScreenSaver.SetActive` / lock | Shield shows in capture too; also locks. ✗ |
| `SetBacklight` → 0 | Keeps framebuffer, would blank — but only laptop eDP panels expose it; external HDMI does not. ✗ (this host) |
| `ApplyMonitorsConfig` (disable output) | Mutter stops compositing that monitor → capture dies. ✗ |

## Root cause & the only real path

We capture the **physical monitor's composited output**; on Mutter that content
is inseparable from the physical scanout. The one clean fix is to capture a
**virtual monitor / headless framebuffer** decoupled from the physical output,
then blank (or leave unplugged) the physical panel independently. That is the
**V2-2** architectural direction (portal/virtual-monitor backends), not a small
hook — and this host already has flaky virtual-display (`:1`) behaviour (see B1).

## Recommendation

**Won't do in v1.** Revisit only alongside V2-2 virtual-framebuffer capture.
Low value on Linux anyway (no equivalent privacy-driver expectation).

## Facts learned (reusable)

- `Mutter.DisplayConfig.PowerSaveMode` is writable (`0` on, `3` off) and Mutter
  honours the set, but an active ScreenCast keeps the CRTC lit — DPMS is not a
  usable blank while capturing.
- Injected input via RemoteDesktop is independent of scanout power (would still
  work while blanked, if blanking were possible).
- Repro: `spikes/spike1_blank_monitor.py` (holds a daemon connection to force
  capture, samples the shm seqlock + pixel brightness, toggles PowerSaveMode).
