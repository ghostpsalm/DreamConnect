# Spike 1 — BlankGuestMonitor under Wayland — **FEASIBLE** ✅ (via CRTC gamma)

Date: 2026-07-13 · Host: GNOME/Wayland workstation (Fedora, GNOME/mutter, Wayland),
capturing physical monitor `HDMI-2`.

## Question

ScreenConnect's **BlankGuestMonitor** darkens the guest's physical screen for
privacy *while the operator keeps seeing the real desktop* (on Windows a mirror
driver decouples the two). Can we do that on Wayland/Mutter — blank the physical
panel while our PipeWire capture keeps delivering real frames? (The Linux client
impl is a hard no-op: `ClientOSToolkit.isBlankingMonitorsSupported()` → false,
`blankMonitorsOrWallpapers()` → null, so we must implement it ourselves.)

## Answer: yes — zero the CRTC gamma ramp

Gamma is applied at **scanout**, per-CRTC, *after* compositing; the Mutter
ScreenCast captures the **composited framebuffer**, *before* gamma. So setting a
CRTC's gamma ramp to all-zero blacks the **physical** output while leaving the
**captured** stream full-colour. Measured with `SetCrtcGamma(serial, crtc, 0…)`:

| Requirement | Result |
|---|---|
| Operator keeps seeing desktop | ✅ **measured** — capture stayed live (`mean=251`, seq advancing) with gamma zeroed |
| Holds through operator input | ✅ **measured** — gamma stayed `0` for 6s under injected motion; nothing (input, `gsd-color`, night-light) restored it |
| Clean restore | ✅ **measured** — original ramp reapplied; detached watchdog backup worked |
| Physical panel dark | ✅ inferred — zero ramps ⇒ black scanout (well-established); on-device eyeball pending |

Repro: [`spike1b_blank_gamma.py`](spike1b_blank_gamma.py) (zeros gamma, samples the
capture, injects motion, restores; a detached watchdog restores after 8s).

## What did NOT work (and a measurement trap)

- **DPMS (`Mutter.DisplayConfig.PowerSaveMode=3`)** — Mutter honours the mode and
  the physical output goes `dpms=Off` (confirmed via `/sys/class/drm/*/dpms`), and
  the capture *does* stay live. **But injected input instantly wakes the panel**
  (`Off`→`On` on the first pointer event), so the blank can't hold during active
  control. Dead end for BlankGuestMonitor.
- **Output-config disable (`ApplyMonitorsConfig` empty layout)** — Mutter rejects
  it: *"Monitors config incomplete"*; it won't disable the only monitor.
- **Overlay window / screensaver** — black the operator's capture too (same
  composited output). **Backlight-off** — eDP-only, n/a on external HDMI.
- **Measurement trap:** the operator's captured view is *pre-gamma* (and, for
  DPMS, is a separate consumer), so it can't reveal the physical panel's state.
  An early misread (watching the SC view, assuming it was the physical screen)
  produced a false "not feasible"; the fix was to measure the physical side
  directly via DRM sysfs (`dpms`) and the gamma readback.

## Implemented

Daemon `BLANK 1|0` command (`Session.set_blank` → `SetCrtcGamma` zero/restore over
all active CRTCs), restoring on unblank, last-client-disconnect, and SIGTERM.
Agent hooks `ClientOSToolkit.isBlankingMonitorsSupported`/`blankMonitorsOrWallpapers`/
`unblankMonitorsOrWallpapers`. Daemon path verified end-to-end; SC operator-command
flow + physical-dark confirmation are the on-device test.
