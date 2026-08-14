package dreamconnect.agent;

import net.bytebuddy.asm.Advice;
import net.bytebuddy.implementation.bytecode.assign.Assigner;

/**
 * Hooks ScreenConnect's
 * {@code ClientOSToolkit$LinuxClientToolkit.getAvailableLogonSession*()} — the
 * methods that build the {@code Messages$LogonSessionInfo2} entries shown in the
 * operator's session picker. On Linux these are named after the bare X display
 * (":0") or a framebuffer path. We rewrite the visible name to the logged-in
 * user's name (see {@link dreamconnect.boot.Bridge#relabelLogonSessions}) so the
 * Linux session isn't a cryptic second-class ":0". The selection ID is left
 * intact, so picking the session still works.
 *
 * Failures are suppressed so ScreenConnect is never disrupted.
 */
public final class LogonSessionAdvice {

    /** For getAvailableLogonSessionInfosAsClientService(): returns an array.
     *  This runs the slow getDisplayInfos shell probe, re-fired on every server
     *  heartbeat (~6 s) and stalling input each time — so we skip the body when a
     *  fresh cached result exists (skipOn) and serve the cache. readOnly=false so
     *  we can REPLACE the array with the curated/cached one (also drops the
     *  greeter session we don't bridge). */
    public static final class Infos {
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class)
        public static boolean onEnter() {
            return dreamconnect.boot.Bridge.logonProbeSkip();   // true => skip probe
        }

        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(
                @Advice.Return(readOnly = false, typing = Assigner.Typing.DYNAMIC) Object ret) {
            ret = dreamconnect.boot.Bridge.curateLogonSessionsCached(ret);
        }
    }

    /** For getAvailableLogonSessionAsClient(): returns a single session. */
    public static final class One {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(
                @Advice.Return(readOnly = false, typing = Assigner.Typing.DYNAMIC) Object ret) {
            ret = dreamconnect.boot.Bridge.curateLogonSessions(ret);
        }
    }

    private LogonSessionAdvice() {}
}
