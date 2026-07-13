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

    /** For getAvailableLogonSessionInfosAsClientService(): returns an array. */
    public static final class Infos {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(
                @Advice.Return(typing = Assigner.Typing.DYNAMIC) Object ret) {
            dreamconnect.boot.Bridge.relabelLogonSessions(ret);
        }
    }

    /** For getAvailableLogonSessionAsClient(): returns a single session. */
    public static final class One {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(
                @Advice.Return(typing = Assigner.Typing.DYNAMIC) Object ret) {
            dreamconnect.boot.Bridge.relabelLogonSessions(ret);
        }
    }

    private LogonSessionAdvice() {}
}
