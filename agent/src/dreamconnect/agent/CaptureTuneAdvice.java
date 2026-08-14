package dreamconnect.agent;

import net.bytebuddy.asm.Advice;

/**
 * Hooks the constructor of ScreenConnect's
 * {@code com.screenconnect.client.ClientScreenCapturer}, which is built with a
 * fixed 50 ms minimum frame interval — a hard 20 fps ceiling on any >=4-core box,
 * regardless of how fast capture is (see spikes/SPIKE_ENCODER_KNOBS.md). On exit
 * we hand the freshly built instance to {@link dreamconnect.boot.Bridge#tuneCapturer},
 * which overrides the frame-interval fields on the IncrementalScreenCapturer
 * superclass when the operator configured tuning (maxfps=/mininterval= agent args).
 *
 * Best-effort: with no tuning configured it does nothing, and any failure is
 * suppressed so ScreenConnect is never disrupted.
 */
public final class CaptureTuneAdvice {

    @Advice.OnMethodExit(suppress = Throwable.class)
    public static void onExit(@Advice.This Object capturer) {
        dreamconnect.boot.Bridge.tuneCapturer(capturer);
    }

    private CaptureTuneAdvice() {}
}
