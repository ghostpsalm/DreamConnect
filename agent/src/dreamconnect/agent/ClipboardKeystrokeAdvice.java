package dreamconnect.agent;

import net.bytebuddy.asm.Advice;

/**
 * Hooks ScreenConnect's {@code com.screenconnect.OSToolkit.sendStringAsKeystrokes}
 * — the client side of the operator's "insert clipboard text"
 * (SendClipboardKeystrokes) command. Its native implementation
 * ({@code LinuxNative.sendStringAsKeystrokes}) is console-oriented and doesn't
 * type into the Wayland desktop, so:
 *
 *   sendStringAsKeystrokes(text)    -> route the text to the daemon; skip the
 *                                      original (broken) native call
 *   canSendStringAsKeystrokes()     -> report true so ScreenConnect offers it
 *
 * Failures are suppressed so ScreenConnect is never disrupted.
 */
public final class ClipboardKeystrokeAdvice {

    public static final class Send {
        // Return true from the enter advice to SKIP the original method body
        // (the native typing), replacing it with our daemon-routed typing.
        @Advice.OnMethodEnter(skipOn = Advice.OnNonDefaultValue.class, suppress = Throwable.class)
        public static boolean onEnter(@Advice.Argument(0) String text) {
            dreamconnect.boot.Bridge.typeString(text);
            return true;
        }
    }

    public static final class CanSend {
        @Advice.OnMethodExit(suppress = Throwable.class)
        public static void onExit(@Advice.Return(readOnly = false) boolean canSend) {
            canSend = true;
        }
    }

    private ClipboardKeystrokeAdvice() {}
}
