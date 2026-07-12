package dreamconnect.boot;

import java.awt.Rectangle;
import java.awt.peer.RobotPeer;

/**
 * The AWT RobotPeer that replaces the X11 one. Every Robot method
 * ScreenConnect calls lands here and is serviced from the Wayland side via the
 * dreamconnect daemon: screen reads come from the shared-memory frame buffer,
 * input goes out over the control socket (translated to evdev by AwtEvdev).
 *
 * ScreenConnect never learns it left X11 — which is the whole point.
 */
public final class DreamConnectRobotPeer implements RobotPeer {
    private final DaemonClient daemon;
    private final FrameReader frame;

    public DreamConnectRobotPeer(DaemonClient daemon, FrameReader frame) {
        this.daemon = daemon;
        this.frame = frame;
    }

    // ---- input -------------------------------------------------------------
    @Override public void mouseMove(int x, int y) {
        daemon.sendNoReply("M " + x + " " + y);
    }

    @Override public void mousePress(int buttons) {
        daemon.sendNoReply("B " + AwtEvdev.button(buttons) + " 1");
    }

    @Override public void mouseRelease(int buttons) {
        daemon.sendNoReply("B " + AwtEvdev.button(buttons) + " 0");
    }

    @Override public void mouseWheel(int wheelAmt) {
        // AWT: positive = scroll toward user (down). Mutter axis 0 = vertical.
        daemon.sendNoReply("W 0 " + wheelAmt);
    }

    @Override public void keyPress(int keycode) {
        int e = AwtEvdev.keycode(keycode);
        if (e >= 0) daemon.sendNoReply("K " + e + " 1");
    }

    @Override public void keyRelease(int keycode) {
        int e = AwtEvdev.keycode(keycode);
        if (e >= 0) daemon.sendNoReply("K " + e + " 0");
    }

    // ---- screen capture ----------------------------------------------------
    @Override public int getRGBPixel(int x, int y) {
        return frame.pixel(x, y);
    }

    @Override public int[] getRGBPixels(Rectangle bounds) {
        return frame.pixels(bounds.x, bounds.y, bounds.width, bounds.height);
    }

    /** We inject absolute coordinates (NotifyPointerMotionAbsolute). */
    @Override public boolean useAbsoluteCoordinates() {
        return true;
    }
}
