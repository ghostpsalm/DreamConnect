package dreamconnect.agent;

import net.bytebuddy.asm.Advice;

/**
 * Hooks ScreenConnect's {@code com.screenconnect.OSToolkit} wake-lock methods,
 * which are a no-op on Linux (only macOS/Windows implement them). Driven by the
 * operator's AcquireWakeLock command via {@code Client}:
 *
 *   acquireWakeLock()    -> tell the daemon to inhibit idle+suspend
 *   releaseWakeLock(...) -> tell the daemon to drop the inhibit
 *   canAcquireWakeLock() -> report true so ScreenConnect offers the command
 *
 * All inlined into OSToolkit (app classloader) and delegate to the
 * bootstrap-resident {@link dreamconnect.boot.Bridge}. Failures are swallowed so
 * ScreenConnect is never affected.
 */
public final class WakeLockAdvice {

    public static final class Acquire {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit() {
            dreamconnect.boot.Bridge.setWakeLock(true);
        }
    }

    public static final class Release {
        @Advice.OnMethodEnter(suppress = Throwable.class)
        public static void onEnter() {
            dreamconnect.boot.Bridge.setWakeLock(false);
        }
    }

    public static final class CanAcquire {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(@Advice.Return(readOnly = false) boolean canAcquire) {
            canAcquire = true;
        }
    }

    private WakeLockAdvice() {}
}
