package dreamconnect.agent;

import net.bytebuddy.asm.Advice;
import net.bytebuddy.implementation.bytecode.assign.Assigner;

/**
 * Hooks ScreenConnect's monitor-blanking methods on
 * {@code com.screenconnect.client.ClientOSToolkit} — the client side of the
 * operator's "Blank guest monitor" (BlankGuestMonitor) command. On the Linux
 * client these are hard no-ops ({@code isBlankingMonitorsSupported()} → false,
 * {@code blankMonitorsOrWallpapers()} → null), so we:
 *
 *   isBlankingMonitorsSupported()          -> report true so SC offers the command
 *   blankMonitorsOrWallpapers(id, flag)    -> tell the daemon to blank (zero the
 *                                             CRTC gamma), return a non-null handle
 *   unblankMonitorsOrWallpapers(handle)    -> tell the daemon to restore gamma
 *
 * The daemon blanks the *physical* panel while the ScreenCast (pre-gamma) keeps
 * showing the operator the real desktop. Failures are suppressed so
 * ScreenConnect is never disrupted.
 */
public final class BlankMonitorAdvice {

    /** A non-null token SC stores and hands back to unblank. */
    static final String HANDLE = "dreamconnect-blank";

    public static final class Supported {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(@Advice.Return(readOnly = false) boolean supported) {
            supported = true;
        }
    }

    public static final class Blank {
        // Original is a no-op returning null; run it, then blank and hand back a
        // non-null handle so SC will later call unblank with it.
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(
                @Advice.Return(readOnly = false, typing = Assigner.Typing.DYNAMIC) Object ret) {
            dreamconnect.boot.Bridge.setBlank(true);
            if (ret == null) ret = HANDLE;
        }
    }

    public static final class Unblank {
        @Advice.OnMethodEnter(suppress = Throwable.class)
        public static void onEnter() {
            dreamconnect.boot.Bridge.setBlank(false);
        }
    }

    private BlankMonitorAdvice() {}
}
