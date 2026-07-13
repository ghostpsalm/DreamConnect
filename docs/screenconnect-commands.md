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
| `SelectLogonSession` | Works; the picker's bare `:0` label is rewritten to the logged-in user's name (agent hook on `getAvailableLogonSession*` → daemon `WHO`). |

## Guest-affecting — likely work as root, unverified

`Reboot`, `Send/Receive Files & Folders`, `RunTool`, `TakeScreenshotTo{File,
Clipboard}`, `OpenUrl`. These rely on root filesystem/process access or the Robot
peer, so they should already function — worth a spot-check pass, not a build.

## Guest-affecting — investigated, not doing

- **`BlankGuestMonitor`** — not feasible in the current architecture. The Linux
  client impl is a hard no-op, and no Wayland mechanism blanks the *physical*
  panel while our capture keeps working (we capture the composited physical
  monitor, inseparable from the scanout). Full analysis:
  [`../spikes/SPIKE1_RESULTS.md`](../spikes/SPIKE1_RESULTS.md). Real fix needs
  virtual-framebuffer capture (a v2 direction).
- **`SendSystemKeyCode`** — a fixed **Ctrl-Alt-Del** (the message carries no
  payload), handled in SC's generic dispatch with no clean toolkit seam. GNOME
  Wayland has no meaningful binding for it, so injecting it is an almost-certain
  no-op. Not worth building; true SAS keys would need direct evdev/`uinput`.
- **Through-the-lock-screen** — capture would show the GNOME screen shield;
  driving a locked session needs a separate path.
