package dreamconnect.agent;

import java.awt.GraphicsDevice;
import java.awt.peer.RobotPeer;
import net.bytebuddy.asm.Advice;

/**
 * Inlined into java.awt.Robot.init(GraphicsDevice) at method exit. After the
 * JRE has installed its X11 peer, overwrite the private `peer` field with the
 * dreamconnect peer. suppress=Throwable guarantees that if anything here fails,
 * Robot is left exactly as the JRE built it (X11 peer) — the client degrades,
 * it never crashes.
 */
public final class RobotInitAdvice {

    @Advice.OnMethodExit(suppress = Throwable.class)
    public static void onExit(
            @Advice.Argument(0) GraphicsDevice screen,
            @Advice.FieldValue(value = "peer", readOnly = false) RobotPeer peer) {
        peer = dreamconnect.boot.Bridge.wrapPeer(screen, peer);
    }

    private RobotInitAdvice() {}
}
