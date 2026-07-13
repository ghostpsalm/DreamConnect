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
    private static volatile boolean socketExplicit;  // set by env or socket= arg
    private static volatile String shmPath = defaultShm();
    private static volatile String socketPath = defaultSocket();
    private static volatile boolean debug = false;
    private static volatile String labelOverride;    // label= arg, wins over WHO
    private static volatile String logonLabel;        // cached daemon WHO reply

    private static volatile DaemonClient daemon;
    private static volatile FrameReader frame;

    private static String defaultShm() {
        String e = System.getenv("DREAMCONNECT_SHM");
        return e != null ? e : "/dev/shm/dreamconnect.frame";
    }

    private static final String FALLBACK_SOCKET = "/run/user/1000/dreamconnect.sock";

    private static String defaultSocket() {
        String e = System.getenv("DREAMCONNECT_SOCKET");
        if (e != null) { socketExplicit = true; return e; }
        String xdg = System.getenv("XDG_RUNTIME_DIR");
        if (xdg != null) { socketExplicit = true; return xdg + "/dreamconnect.sock"; }
        // Last resort (the agent runs as root and can't derive the desktop uid).
        // Warn from logConfig() only if nothing ever set the socket explicitly —
        // note the socket= arg value may legitimately equal this fallback string,
        // so we track explicitness rather than comparing values.
        return FALLBACK_SOCKET;
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
                case "socket" -> { socketPath = v; socketExplicit = true; }
                case "debug" -> debug = Boolean.parseBoolean(v);
                case "label" -> labelOverride = v;
                default -> {}
            }
        }
        logConfig();
    }

    private static void logConfig() {
        log("configured shm=" + shmPath + " socket=" + socketPath);
        if (!socketExplicit) {
            log("WARN: socket unconfigured; guessing " + FALLBACK_SOCKET
                    + " — pass socket= if the desktop user isn't uid 1000");
        }
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
     * Driven by the agent's hook on ScreenConnect's
     * OSToolkit.acquireWakeLock/releaseWakeLock — i.e. the operator's
     * AcquireWakeLock command. Forwards to the daemon, which holds a GNOME
     * idle+suspend inhibit for the duration. Best-effort; never throws into SC.
     */
    public static void setWakeLock(boolean on) {
        try {
            init();
            daemon.input("WAKELOCK " + (on ? "1" : "0"));
            log("wake lock " + (on ? "acquire" : "release") + " forwarded (operator command)");
        } catch (Throwable t) {
            log("setWakeLock failed: " + t);
        }
    }

    /**
     * Driven by the agent's hook on ScreenConnect's
     * OSToolkit.sendStringAsKeystrokes — the operator's "insert clipboard text"
     * (SendClipboardKeystrokes) command, whose native path doesn't work under
     * Wayland. Forwards the text (base64 UTF-8) to the daemon, which types it.
     */
    public static void typeString(String text) {
        try {
            if (text == null || text.isEmpty()) return;
            init();
            String b64 = java.util.Base64.getEncoder()
                    .encodeToString(text.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            daemon.input("TYPE " + b64);
            log("clipboard keystrokes forwarded (" + text.length() + " chars)");
        } catch (Throwable t) {
            log("typeString failed: " + t);
        }
    }

    /**
     * Driven by the agent's hook on ScreenConnect's
     * ClientOSToolkit.blankMonitorsOrWallpapers / unblankMonitorsOrWallpapers —
     * the operator's BlankGuestMonitor command, a no-op on the Linux client.
     * Forwards to the daemon, which blanks the physical panel by zeroing the
     * CRTC gamma (the ScreenCast is pre-gamma, so the operator keeps seeing the
     * desktop). Best-effort; never throws into SC.
     */
    public static void setBlank(boolean on) {
        try {
            init();
            daemon.input("BLANK " + (on ? "1" : "0"));
            log("blank monitor " + (on ? "on" : "off") + " forwarded (operator command)");
        } catch (Throwable t) {
            log("setBlank failed: " + t);
        }
    }

    /**
     * The friendly name shown for the local logon session in the operator's
     * ScreenConnect session picker, replacing the bare X display name (":0").
     * Prefers a label= agent arg; otherwise asks the daemon (which runs as the
     * desktop user) for the login name via WHO and caches it. Returns null if
     * neither is available, in which case the original name is left untouched.
     */
    private static String logonLabel() {
        String o = labelOverride;
        if (o != null && !o.isEmpty()) return o;
        String cached = logonLabel;
        if (cached != null) return cached;
        try {
            init();
            String who = daemon.send("WHO");
            if (who != null) {
                who = who.trim();
                if (!who.isEmpty() && !who.startsWith("ERR")) {
                    logonLabel = who;
                    return who;
                }
            }
        } catch (Throwable t) {
            log("logon label fetch failed: " + t);
        }
        return null;
    }

    /**
     * Driven by the agent's hook on ScreenConnect's
     * LinuxClientToolkit.getAvailableLogonSession*(): rewrites the visible name
     * of each returned Messages$LogonSessionInfo(2) — a bare display like ":0"
     * or a framebuffer path — to the logged-in user's name, so the Linux
     * session doesn't show up as a cryptic ":0" in the picker. The
     * logonSessionID (used to actually select the session) is left untouched.
     * Reflection, because the boot module can't compile against SC's classes.
     * Best-effort; never throws into SC.
     */
    public static void relabelLogonSessions(Object ret) {
        try {
            if (ret == null) return;
            String label = logonLabel();
            if (label == null || label.isEmpty()) return;
            if (ret instanceof Object[]) {
                Object[] arr = (Object[]) ret;
                boolean many = arr.length > 1;
                for (Object e : arr) relabelOne(e, label, many);
            } else {
                relabelOne(ret, label, false);
            }
        } catch (Throwable t) {
            log("relabelLogonSessions failed: " + t);
        }
    }

    private static void relabelOne(Object e, String label, boolean disambiguate) throws Exception {
        if (e == null) return;
        java.lang.reflect.Field f = e.getClass().getField("logonSessionName");
        Object orig = f.get(e);
        String cur = orig == null ? null : orig.toString();
        // Only rewrite machine-y names (a display like ":0" or a device path),
        // never a name that's already human-readable.
        boolean machineName = cur == null || cur.isEmpty()
                || cur.startsWith(":") || cur.contains("/");
        if (!machineName) return;
        // With multiple sessions, keep them distinguishable by appending the
        // original display so operators can still tell them apart.
        f.set(e, disambiguate && cur != null && !cur.isEmpty()
                ? label + " (" + cur + ")" : label);
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
