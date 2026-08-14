# Spike — ScreenConnect Linux encoder/throughput knobs

Decompiled `ScreenConnect.Core.jar` / `.Client.jar` (CFR) on 2026-08-14 to find why the
Linux session is slow and what is tunable. This is the map; the override + measurement
work builds on it.

## The frame loop (the dominant limit)

`ClientScreenCapturer extends IncrementalScreenCapturer`, constructed at
`ClientScreenCapturer.java:81`:

```java
super(messagePreparerListener, waitChecker, 50, 250, 3);
//   minFrameIntervalMs=50, maxFrameIntervalMs=250, frameDelayMultiple=3
```

Between frames (`IncrementalScreenCapturer.waitUnlessStoppingBetweenFrames`):

```java
ticksBetweenFrames = (frameProductionMs) * frameDelayMultiple;   // 3x the work
int cores = availableProcessors();
ticksBetweenFrames = cores >= 4 ? 0 : ticksBetweenFrames / cores;
wait( bound(minFrameInterval=50, ticksBetweenFrames, maxFrameInterval=250) );
```

**On a >=4-core box the multiple is bypassed and the wait clamps to `minFrameInterval` =
50 ms — a hard 20 fps ceiling**, no matter how fast capture is. This box has 6 cores, so
20 fps is the binding limit. On <4-core boxes the `*3` multiple bites instead (each slow
frame is followed by 3x its own time of idle).

Effective fps ≈ `1000 / (frameProductionMs + 50)`. That is why:
- pure SC @1080p: 61ms capture + ~55ms encode + 50 = ~166ms → ~6 fps
- shim @1080p: ~2 + ~55 + 50 = ~107ms → ~9 fps  (capture fixed, encode+wait remain)
- shim @720p:  ~2 + ~28 + 50 = ~80ms  → ~12 fps
- shim @540p:  ~2 + ~13 + 50 = ~65ms  → ~15 fps

**Knob #1 (biggest, this box): `minFrameIntervalMilliseconds` 50 → e.g. 16 lifts the
ceiling 20 → 60 fps, and only then does the shim's fast capture translate into frame
rate.** Cost: more guest CPU (more frames encoded/sec) — fine on a dedicated backstage
box, which is exactly why the stock 50 ms (tuned for not hogging a *human's* machine) is
too conservative here.

**Knob #3 (only <4-core boxes): `frameDelayMultiple` 3 → 1.**

## The codec (colour depth + compression = encode cost and bandwidth)

`Messages.ScreenCodecID` — name is `ColorSpace_Compression`:

- Colour space, ascending data volume: **Grayscale < WebColor < Yuv/WebP < TrueColor(Ex)**
  (this is the operator's "16 million colours"; Grayscale is "black and white").
- Compression, ascending CPU / descending size: **Raw < DeflateHighSpeed < ZStandard <
  DeflateDefault < Lzma**.
- Only `WebP` is `isPhotographic()`; everything else is "flat" (UI). The encoder keeps a
  primary flat codec + an alternate (usually WebP) and switches per-region on
  `usePhotoOrFlat` (driven by a running `compressionAverage`).

The codec is **pushed by the operator side** (`Client.java:664`,
`setCodecIDs(GetScreenCodecIDs(newEndPointStatusMessage.screenCodecID,
…alternateScreenCodecID))`). Each `ScreenDataMessage` is tagged with its `codecID`, and
the viewer decodes per-tag — so a guest-side override to a *faster* codec (e.g.
`WebColor_DeflateHighSpeed` or `Grayscale_ZStandard`) is decodable by the viewer.

**Knob #2: force a low-depth / fast-compression codec via a `setCodecIDs` hook.** Cuts
encode time *and* bandwidth. Higher risk than #1 (changes what the operator sees), so it
is the second experiment, behind #1.

## Quality level (High/Medium/Low)

`ScreenQualityLevel {High, Medium, Low}`, set by the `SelectQuality` command →
`ScreenQualityLevelMessage`, carried in the endpoint status. It rides in messages but does
**not** change `minFrameInterval`/`frameDelayMultiple` (those are the fixed 50/250/3
constants). Its effect is on the operator/relay side (codec + viewport it requests), which
is why "Low helps" — the operator asks for a cheaper codec / smaller viewport, reducing
encode+transfer. We do not control that half directly; we control the guest-side knobs
above.

## Resolution

Already handled: virtual monitor sized by `--virtual` (default 720p). Fewer pixels → less
capture *and* encode. This is the one knob already shipped.

## What is measurable here, and how

SC captures each frame through **our** Robot peer:
`ClientScreenCapturer … RobotPeerPixelCapturer → robotPeer.getRGBPixels(...)`
(`ClientScreenCapturer.java:200`). So instrumenting `DreamConnectRobotPeer.getRGBPixels`
to count calls/sec yields the **real session frame rate** the operator gets — the number
to move. SC only captures while an operator is connected, so the measurement needs a live
viewer session.

## Plan

1. Instrument the peer to log achieved fps (needs a connected operator to read).
2. Override the frame-interval knobs via a `ClientScreenCapturer`-constructor hook,
   agent-arg controlled (default off / conservative), and A/B the fps.
3. Then trial the codec override (#2) the same way.
