package dreamconnect.boot;

import java.awt.GraphicsDevice;
import java.awt.peer.RobotPeer;

/**
 * Bootstrap-resident entry point the instrumented java.awt.Robot.init calls.
 * Holds process-wide config + the shared DaemonClient / FrameReader, and hands
 * back a DreamConnectRobotPeer to replace the X11 peer.
 *
 * Everything here is defensive: if anything goes wrong we return the original
 * X11 peer so ScreenConnect keeps functioning (degraded to black frames)
 * rather than crashing the support session.
 */
public final class Bridge {
    private static volatile String shmPath = defaultShm();
    private static volatile String socketPath = defaultSocket();
    private static volatile boolean debug = false;

    private static volatile DaemonClient daemon;
    private static volatile FrameReader frame;

    private static String defaultShm() {
        String e = System.getenv("DREAMCONNECT_SHM");
        return e != null ? e : "/dev/shm/dreamconnect.frame";
    }

    private static String defaultSocket() {
        String e = System.getenv("DREAMCONNECT_SOCKET");
        if (e != null) return e;
        String xdg = System.getenv("XDG_RUNTIME_DIR");
        if (xdg != null) return xdg + "/dreamconnect.sock";
        // Last resort. The agent runs as root, so it can't derive the desktop
        // user's uid itself; install.sh always passes an explicit socket=. If
        // this fires, the socket is unconfigured — warn loudly instead of
        // silently guessing wrong on a host where the user isn't uid 1000.
        log("WARN: no socket=, DREAMCONNECT_SOCKET, or XDG_RUNTIME_DIR set; "
                + "guessing /run/user/1000/dreamconnect.sock — set socket= if the desktop user isn't uid 1000");
        return "/run/user/1000/dreamconnect.sock";
    }

    /** Parse agent args: comma-separated key=value (shm=…, socket=…, debug=true). */
    public static void configure(String args) {
        if (args == null || args.isEmpty()) { logConfig(); return; }
        for (String kv : args.split(",")) {
            int eq = kv.indexOf('=');
            if (eq < 0) continue;
            String k = kv.substring(0, eq).trim();
            String v = kv.substring(eq + 1).trim();
            switch (k) {
                case "shm" -> shmPath = v;
                case "socket" -> socketPath = v;
                case "debug" -> debug = Boolean.parseBoolean(v);
                default -> {}
            }
        }
        logConfig();
    }

    private static void logConfig() {
        log("configured shm=" + shmPath + " socket=" + socketPath);
    }

    static void log(String msg) {
        System.err.println("[dreamconnect-agent] " + msg);
    }

    static boolean debug() { return debug; }

    private static synchronized void init() {
        if (daemon == null) daemon = new DaemonClient(socketPath);
        if (frame == null) frame = new FrameReader(shmPath);
    }

    /**
     * Called from the instrumented Robot.init exit. Returns our peer, or the
     * original on any failure.
     */
    public static RobotPeer wrapPeer(GraphicsDevice screen, RobotPeer original) {
        try {
            init();
            String pong = daemon.send("PING");
            if (!"PONG".equals(pong)) {
                log("daemon not answering (PING=" + pong + "); keeping original peer");
                return original;
            }
            String geom = daemon.send("GEOM");
            log("attached to daemon; geometry " + geom + "; replacing X11 Robot peer");
            return new DreamConnectRobotPeer(daemon, frame);
        } catch (Throwable t) {
            log("wrapPeer failed (" + t + "); keeping original peer");
            return original;
        }
    }

    private Bridge() {}
}
