# ScreenConnect command coverage

Which ScreenConnect operator commands do something on a **Linux/Wayland** guest,
and how DreamConnect handles each. Background for the roadmap's feature entries;
for architecture see [design.md](design.md).

The client `Command` enum (`com.screenconnect.client.Command`) has **58 values**,
but most are the operator's *own* window UI and never reach the guest. Categorised
from decompiling `ScreenConnect.Client.jar` / `ScreenConnect.Core.jar`:

## Host-side only — no effect on the guest (~35)

Operator-window UI: `SelectQuality`, `ZoomToScale`, `Dock/UndockControlPanel`,
`ToggleAlwaysOnTop`, `ToggleBeepOnConnect`, `Hide`, `Show/ShowChat/ShowStatus`,
`Exit`, `PutSelectedClientWindowOnTop`, `Open/ChangeFolder`; all `*Annotation*`
(4); all audio (`SelectMicrophone/Speakers/SoundCaptureMode`, `MuteMicrophone`,
`SetSpeakerVolume`); `Video*` (records on the operator side); all participant /
`*Share*` (4); `NotifyIsTyping`; `ManageCredentials`; `ManageSharedToolbox`.

## Guest-affecting — working

| Command | How |
|---|---|
| `SendClipboardKeystrokes` | Agent hook → daemon `TYPE` (keysym, or `wl-copy`+Ctrl-V fallback). See design.md. |
| `AcquireWakeLock` | Agent hook → daemon GNOME idle+suspend inhibit. |
| `ShareClipboard` | Works via ScreenConnect's own clipboard sharing. |
| `BlockGuestInput` | Works as-is through the client (no bridge changes needed). |
| `BlankGuestMonitor` | Agent hook forces support on + routes to daemon, which zeroes the CRTC gamma to black the physical panel; the ScreenCast is pre-gamma so the operator keeps seeing the desktop. See [`../spikes/SPIKE1_RESULTS.md`](../spikes/SPIKE1_RESULTS.md). |
| `SelectLogonSession` | Works; the picker's bare `:0` label is rewritten to the logged-in user's name (agent hook on `getAvailableLogonSession*` → daemon `WHO`). |

## Guest-affecting — work as-is (verified by mechanism, 2026-07-14)

Spot-checked by inspecting each Linux handler in the jars — all ride a mechanism
we know works under the bridge, none go through a broken native path:

| Command | Linux mechanism | How verified |
|---|---|---|
| `TakeScreenshotTo{File,Clipboard}` | `ClientScreenCapturer$AwtMonitorManager` builds a `java.awt.Robot` → `createScreenCapture` → our peer's shm frames; `canCaptureScreen()` → `true` | code path (same as the live view) |
| `OpenUrl` | `LinuxClientToolkit`: `xdg-open "<url>" &` | code + `xdg-open` present on host |
| `Reboot` | root process action (SC runs as root) | code; not live-triggered |
| `RunTool` | toolbox item run as root via shell (same class as the Commands `/bin/sh -c` path) | code |
| `Send/Receive Files & Folders` | client file I/O as root | code (root FS access) |

Screenshot and OpenUrl are strongest-verified (peer path + `xdg-open` confirmed);
Reboot/RunTool/file-transfer are verified by code, not a live operator click.

## Guest-affecting — investigated, not doing

- **`SendSystemKeyCode`** — a fixed **Ctrl-Alt-Del** (the message carries no
  payload), handled in SC's generic dispatch with no clean toolkit seam. GNOME
  Wayland has no meaningful binding for it, so injecting it is an almost-certain
  no-op. Not worth building; true SAS keys would need direct evdev/`uinput`.
- **Through-the-lock-screen** — capture would show the GNOME screen shield;
  driving a locked session needs a separate path.
