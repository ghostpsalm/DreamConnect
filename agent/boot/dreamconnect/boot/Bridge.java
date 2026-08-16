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
    private static volatile String sessionLabel;     // label of the attached registry session
    private static volatile String logonLabel;        // cached daemon WHO reply
    // curate=off: spike/observation mode — keep every logon session in the
    // picker (relabel only ours) and log each entry, so we can watch what the
    // SC client does when the operator selects a foreign session. Not for
    // production: foreign entries still show OUR frame when selected.
    private static volatile boolean curateEnabled = true;

    // Capture-loop tuning. ScreenConnect's ClientScreenCapturer is built with a
    // fixed 50 ms min frame interval — a 20 fps ceiling on any >=4-core box, no
    // matter how fast capture is (see spikes/SPIKE_ENCODER_KNOBS.md). These
    // override the private frame-interval fields on the IncrementalScreenCapturer
    // superclass at construction. 0 = leave the stock value untouched.
    private static volatile int capMinIntervalMs = 0;
    private static volatile int capMaxIntervalMs = 0;
    private static volatile int capFrameMultiple = 0;   // matters on <4-core boxes

    // Achieved-fps meter: SC captures each frame through our peer, so counting
    // getRGBPixels calls is the real session frame rate. Logged ~every 2s.
    private static final java.util.concurrent.atomic.AtomicLong captureCount =
            new java.util.concurrent.atomic.AtomicLong();
    private static volatile long captureWindowStartMs = 0;

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
                case "curate" -> curateEnabled = !"off".equalsIgnoreCase(v);
                case "label" -> labelOverride = v;
                // maxfps=N is the friendly form of mininterval=1000/N (the frame
                // rate ceiling); mininterval/maxinterval/framemultiple are the raw
                // knobs for fine control. All best-effort: a bad number is ignored.
                case "maxfps" -> capMinIntervalMs = perFrameMs(v);
                case "mininterval" -> capMinIntervalMs = parseIntOr(v, capMinIntervalMs);
                case "maxinterval" -> capMaxIntervalMs = parseIntOr(v, capMaxIntervalMs);
                case "framemultiple" -> capFrameMultiple = parseIntOr(v, capFrameMultiple);
                // seconds between real display re-probes; 0 = probe every heartbeat.
                case "logonttl" -> logonTtlMs = Math.max(0, parseIntOr(v, 30)) * 1000;
                default -> {}
            }
        }
        logConfig();
    }

    private static void logConfig() {
        log("configured shm=" + shmPath + " socket=" + socketPath);
        if (capMinIntervalMs > 0 || capMaxIntervalMs > 0 || capFrameMultiple > 0) {
            log("capture tuning: minInterval=" + capMinIntervalMs + "ms maxInterval="
                    + capMaxIntervalMs + "ms frameMultiple=" + capFrameMultiple
                    + " (0 = stock)");
        }
        if (!socketExplicit) {
            log("WARN: socket unconfigured; guessing " + FALLBACK_SOCKET
                    + " — pass socket= if the desktop user isn't uid 1000");
        }
    }

    static int parseIntOr(String v, int fallback) {
        try { return Integer.parseInt(v.trim()); } catch (Exception e) { return fallback; }
    }

    /** maxfps -> milliseconds per frame (the min frame interval). 0/invalid -> 0. */
    static int perFrameMs(String fps) {
        int n = parseIntOr(fps, 0);
        return n > 0 ? Math.max(1, 1000 / n) : 0;
    }

    /**
     * Override ScreenConnect's fixed frame-interval fields on a freshly built
     * capturer, so the 50 ms/20 fps ceiling doesn't cap a session whose capture
     * is now cheap. Called from the ClientScreenCapturer constructor hook with
     * the instance; the fields live on the IncrementalScreenCapturer superclass,
     * so setIntField walks the hierarchy. Best-effort and never throws into SC.
     */
    public static void tuneCapturer(Object capturer) {
        try {
            if (capturer == null) return;
            boolean any = false;
            if (capMinIntervalMs > 0) any |= setIntField(capturer, "minFrameIntervalMilliseconds", capMinIntervalMs);
            if (capMaxIntervalMs > 0) any |= setIntField(capturer, "maxFrameIntervalMilliseconds", capMaxIntervalMs);
            if (capFrameMultiple > 0) any |= setIntField(capturer, "frameDelayMultiple", capFrameMultiple);
            if (any) {
                log("tuned capturer " + capturer.getClass().getSimpleName()
                        + ": minInterval=" + capMinIntervalMs + " maxInterval=" + capMaxIntervalMs
                        + " frameMultiple=" + capFrameMultiple + " (0 = left stock)");
            }
        } catch (Throwable t) {
            log("tuneCapturer failed: " + t);
        }
    }

    /** Set an int field by name, searching the class and its superclasses. */
    static boolean setIntField(Object o, String name, int value) {
        for (Class<?> c = o.getClass(); c != null; c = c.getSuperclass()) {
            try {
                java.lang.reflect.Field f = c.getDeclaredField(name);
                f.setAccessible(true);
                f.setInt(o, value);
                return true;
            } catch (NoSuchFieldException ignored) {
                // keep walking up
            } catch (Exception e) {
                log("setIntField " + name + " failed: " + e);
                return false;
            }
        }
        return false;
    }

    /** Called per captured frame from the Robot peer; logs achieved fps ~every 2s. */
    public static void noteCapture() {
        long now = System.currentTimeMillis();
        long start = captureWindowStartMs;
        if (start == 0) { captureWindowStartMs = now; captureCount.set(0); return; }
        long n = captureCount.incrementAndGet();
        long elapsed = now - start;
        if (elapsed >= 2000) {
            // Reset first so a slow log line doesn't skew the next window.
            captureWindowStartMs = now;
            captureCount.set(0);
            log(String.format("session capture rate: %.1f fps (%d frames / %d ms)",
                    n * 1000.0 / elapsed, n, elapsed));
        }
    }

    static void log(String msg) {
        System.err.println("[dreamconnect-agent] " + msg);
    }

    static boolean debug() { return debug; }

    /**
     * Resolve which daemon this JVM belongs to and build the client/reader for
     * it. False means resolution refused to name one, and every caller must
     * then do nothing at all: no frames read, no input forwarded. Fail closed.
     */
    private static synchronized boolean attach() {
        resolveForThisChild();          // attaches a resolved session itself
        if (attachRefused) return false;
        if (daemon == null) {
            daemon = clientFor(new SessionEndpoint(
                    -1, null, null, shmPath, socketPath, labelOverride));
        }
        if (frame == null) frame = new FrameReader(shmPath);
        return true;
    }

    /**
     * Root's statement of which sessions exist. One file per session, named for
     * its uid, written by root (dreamconnect-session, and the installer for
     * backstage — issue #53). Nothing here is inferred from a directory any
     * account can write to: an account cannot register itself, cannot claim a
     * display, and cannot make itself discoverable.
     */
    static final String REGISTRY_DIR = "/run/dreamconnect/sessions";
    /** Registry entries must belong to root; anything else is not a registry. */
    private static final long ROOT_UID = 0;

    private static volatile boolean resolvedForChild;
    // Set when resolution refused: this JVM then talks to no daemon at all —
    // no frames, no input — rather than route either to a session that is not
    // the one the operator selected.
    private static volatile boolean attachRefused;

    /**
     * One registry entry's text as a session, or null if it does not describe
     * one. `key=value` per line; the first `=` splits, so a value may contain
     * one. Unknown keys are ignored rather than fatal, so a later field added by
     * the writer does not break an older agent. uid/user/display/shm/socket are
     * required and a blank value is a missing value; label is cosmetic and
     * optional.
     */
    static SessionEndpoint parseRegistryEntry(String text) {
        if (text == null) return null;
        String user = null, display = null, shm = null, socket = null, label = null;
        long uid = -1;
        for (String line : text.split("\n")) {
            int eq = line.indexOf('=');
            if (eq < 0) continue;
            String k = line.substring(0, eq).trim();
            String v = line.substring(eq + 1).trim();
            if (v.isEmpty()) continue;              // blank is unset, as in #50
            switch (k) {
                case "uid" -> {
                    try {
                        uid = Long.parseLong(v);
                    } catch (NumberFormatException notAUid) {
                        return null;                // uid is a value everywhere downstream
                    }
                }
                case "user" -> user = v;
                case "display" -> display = v;
                case "shm" -> shm = v;
                case "socket" -> socket = v;
                case "label" -> label = sanitizeLabel(v);
                default -> { }
            }
        }
        if (uid < 0 || user == null || display == null || shm == null || socket == null) {
            return null;
        }
        return new SessionEndpoint(uid, user, display, shm, socket, label);
    }

    /**
     * Whether a path is one only {@code requiredOwnerUid} could have written:
     * owned by it, and writable by nobody else. Group- or other-writable means
     * some other account can rewrite the file, which makes its contents that
     * account's claim rather than root's. Symlinks are not followed — the
     * link's owner is not the target's.
     *
     * Parameterised on the owner rather than hardcoding root so the rule can be
     * exercised honestly by a test running as an ordinary user; production
     * passes 0.
     */
    static boolean trustedFile(java.nio.file.Path path, long requiredOwnerUid) {
        if (path == null) return false;
        try {
            java.nio.file.attribute.PosixFileAttributes a =
                    java.nio.file.Files.readAttributes(path,
                            java.nio.file.attribute.PosixFileAttributes.class,
                            java.nio.file.LinkOption.NOFOLLOW_LINKS);
            Object owner = java.nio.file.Files.getAttribute(path, "unix:uid",
                    java.nio.file.LinkOption.NOFOLLOW_LINKS);
            if (!(owner instanceof Number) || ((Number) owner).longValue() != requiredOwnerUid) {
                return false;
            }
            java.util.Set<java.nio.file.attribute.PosixFilePermission> p = a.permissions();
            return !p.contains(java.nio.file.attribute.PosixFilePermission.GROUP_WRITE)
                    && !p.contains(java.nio.file.attribute.PosixFilePermission.OTHERS_WRITE);
        } catch (Exception missingOrUnreadable) {
            return false;
        }
    }

    /**
     * Whether a registered shm path is a frame this session's account really
     * owns: a regular file, not a symlink, owned by {@code uid}. A registry
     * entry can outlive its daemon, and /dev/shm is world-writable, so a frame
     * planted after the real one died must not be read as that session's screen.
     * Whoever plants a symlink chooses its target, so a link is never usable
     * however it is owned.
     */
    static boolean usableShm(java.nio.file.Path path, long uid) {
        if (path == null) return false;
        try {
            java.nio.file.attribute.PosixFileAttributes a =
                    java.nio.file.Files.readAttributes(path,
                            java.nio.file.attribute.PosixFileAttributes.class,
                            java.nio.file.LinkOption.NOFOLLOW_LINKS);
            if (!a.isRegularFile()) return false;
            Object owner = java.nio.file.Files.getAttribute(path, "unix:uid",
                    java.nio.file.LinkOption.NOFOLLOW_LINKS);
            return owner instanceof Number && ((Number) owner).longValue() == uid;
        } catch (Exception missingOrUnreadable) {
            return false;
        }
    }

    /**
     * The sessions root says exist. An untrusted directory is not a registry at
     * all — every entry is ignored, which falls back to the static agent args,
     * i.e. today's single-session behaviour. Within a trusted directory a
     * single unreadable or malformed entry drops only itself: only root can put
     * a file there, so a bad one is a writer's bug, and letting it disable every
     * other session would be the worse failure.
     */
    static java.util.List<SessionEndpoint> readRegistry(java.nio.file.Path dir,
                                                        long requiredOwnerUid) {
        java.util.List<SessionEndpoint> found = new java.util.ArrayList<>();
        if (!trustedFile(dir, requiredOwnerUid)) {
            return found;
        }
        String[] names = dir.toFile().list();
        if (names == null) return found;
        java.util.Arrays.sort(names);               // deterministic order
        for (String n : names) {
            // Entries live at <uid>, so anything else is not one. A `1000.bak`
            // or `1000.tmp` left beside `1000` would otherwise parse as a second
            // session for the same display and refuse it permanently — a stray
            // editor or writer temp file must not black out a session.
            if (!allDigits(n)) continue;
            java.nio.file.Path entry = dir.resolve(n);
            if (!trustedFile(entry, requiredOwnerUid)) {
                log("registry: ignoring " + entry + " (not owned by uid "
                        + requiredOwnerUid + ", or writable by others)");
                continue;
            }
            SessionEndpoint e;
            try {
                e = parseRegistryEntry(java.nio.file.Files.readString(entry));
            } catch (Exception unreadable) {
                log("registry: ignoring " + entry + " (" + unreadable + ")");
                continue;
            }
            if (e == null) {
                log("registry: ignoring " + entry + " (not a usable session entry)");
                continue;
            }
            found.add(e);
        }
        return found;
    }

    /**
     * The registered sessions actually usable right now: the frame really is
     * this account's, and the socket is answered by that account. Thin
     * composition, no policy of its own — the display comes from the registry,
     * so a daemon too old to report one is no longer excluded for it.
     */
    static java.util.List<SessionEndpoint> liveSessions(
            java.util.List<SessionEndpoint> registered) {
        java.util.List<SessionEndpoint> live = new java.util.ArrayList<>();
        for (SessionEndpoint e : registered) {
            if (e == null) continue;
            // Per entry, because one bad entry must cost only itself: a path
            // with a NUL byte throws out of Path.of, and letting that escape
            // took every session down with it.
            try {
                if (!usableShm(java.nio.file.Path.of(e.shm()), e.uid())) {
                    log("registry: skipping " + e.socket() + " — " + e.shm()
                            + " is not a regular frame owned by uid " + e.uid());
                    continue;
                }
                DaemonClient probe = clientFor(e);
                try {
                    if (!"PONG".equals(probe.send("PING"))) {
                        log("registry: skipping " + e.socket()
                                + " — no answer authenticated as " + e.user());
                        continue;
                    }
                    live.add(e);
                } finally {
                    probe.close();
                }
            } catch (Exception bad) {
                // Exception, not Throwable: one entry's bad path must not cost
                // the others, but an Error is not this loop's to absorb.
                log("registry: skipping " + e.display() + " (" + bad + ")");
            }
        }
        return live;
    }

    /**
     * Point this JVM at the daemon owning the display ScreenConnect gave it.
     *
     * ScreenConnect spawns a fresh child JVM per selected logon session with
     * that session's DISPLAY in its environment, and builds the Robot inside
     * it — so a child process's own DISPLAY names the session the operator
     * picked. (The service process runs this too, on whatever DISPLAY its
     * environment carries; it is not exclusively a child-side path.) Runs once,
     * before the DaemonClient/FrameReader singletons are built.
     *
     * A discovery failure leaves the configured shm=/socket= args in place: a
     * box with one daemon, or a discovery that throws, behaves as it always did.
     * A refusal (see resolveEndpoint) instead attaches to nothing at all.
     */
    private static synchronized void resolveForThisChild() {
        if (resolvedForChild) return;
        resolvedForChild = true;
        String childDisplay = System.getenv("DISPLAY");
        // uid -1 / user null: the operator's own shm=/socket= configuration is
        // not a registry entry, so it has nothing to authenticate against.
        SessionEndpoint configured = new SessionEndpoint(
                -1, null, null, shmPath, socketPath, labelOverride);
        SessionEndpoint chosen;
        try {
            java.util.List<SessionEndpoint> registered =
                    readRegistry(java.nio.file.Path.of(REGISTRY_DIR), ROOT_UID);
            chosen = resolveEndpoint(childDisplay, registered,
                    liveSessions(registered), configured);
        } catch (Throwable t) {
            log("registry read failed (" + t + "); keeping configured endpoints");
            return;
        }
        if (chosen == null) {
            attachRefused = true;
            log("REFUSING to attach: the registry describes DISPLAY=" + childDisplay
                    + " but nothing usable serves it (or more than one claims it). "
                    + "Showing nothing beats showing another session's desktop "
                    + "under this session's name.");
            return;
        }
        if (chosen == configured) {
            log("DISPLAY=" + childDisplay + " is not described by the registry; "
                    + "keeping configured shm=" + shmPath + " socket=" + socketPath);
            return;
        }
        attachTo(chosen);               // authenticated client, frame, and name
        log("DISPLAY=" + childDisplay + " resolved to registered session "
                + chosen.user() + " (" + chosen.label() + ") shm=" + shmPath
                + " socket=" + socketPath);
    }

    /**
     * Driven by the agent's hook on ScreenConnect's
     * OSToolkit.acquireWakeLock/releaseWakeLock — i.e. the operator's
     * AcquireWakeLock command. Forwards to the daemon, which holds a GNOME
     * idle+suspend inhibit for the duration. Best-effort; never throws into SC.
     */
    public static void setWakeLock(boolean on) {
        try {
            if (!attach()) return;
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
            if (!attach()) return;
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
            if (!attach()) return;
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
    // Package-private (was private) purely so BootTests can assert the label
    // precedence in testRegistryLabelWinsOverWho. Visibility only; no logic
    // was changed by the test author.
    static String logonLabel() {
        String o = labelOverride;
        if (o != null && !o.isEmpty()) return o;   // the operator's own label= wins
        try {
            // Attach FIRST: this is usually the call that resolves the session,
            // and resolution is what learns the registered name. Checking the
            // cache before attaching would fall through to WHO on the very
            // first call, and the picker caches that answer for logonTtlMs —
            // so the operator would see the login name for 30s before it
            // flipped to the registered label.
            if (!attach()) return null;
            String registered = sanitizeLabel(sessionLabel);
            if (registered != null) return registered;
            String cached = logonLabel;
            if (cached != null) return cached;
            String who = sanitizeLabel(daemon.send("WHO"));
            if (who != null) {
                logonLabel = who;
                return who;
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
    public static Object curateLogonSessions(Object ret) {
        return curateLogonSessions(ret, System.getenv("DISPLAY"), logonLabel());
    }

    // --- logon-probe rate limiting -----------------------------------------
    // ScreenConnect re-runs getAvailableLogonSessionInfosAsClientService on every
    // server heartbeat (~6 s). On Linux that fires getDisplayInfos, a shell script
    // that wraps xauth/xdpyinfo in runuser (full PAM setup) per display — ~1-2 s
    // of work on the message thread that also carries input, so clicks stall
    // periodically. A backstage display never changes, so we cache the curated
    // result and skip the probe until the cache expires. logonTtlMs = 0 disables.
    private static volatile Object cachedLogon;      // last curated Object[]
    private static volatile long cachedLogonAtMs;
    private static volatile int logonTtlMs = 30000;

    /** OnMethodEnter skip signal: true => skip the expensive probe, use the cache. */
    public static boolean logonProbeSkip() {
        return logonTtlMs > 0 && cachedLogon != null
                && (System.currentTimeMillis() - cachedLogonAtMs) < logonTtlMs;
    }

    /**
     * OnMethodExit for the array probe. `ret` is the fresh probe result when the
     * body ran, or null when it was skipped. Curate + cache a real result;
     * otherwise serve the cache. Only non-empty results are cached, so a
     * transient empty probe never poisons a good cache.
     */
    public static Object curateLogonSessionsCached(Object ret) {
        try {
            if (ret != null) {                       // probe ran
                Object curated = curateLogonSessions(ret);
                if (curated instanceof Object[] && ((Object[]) curated).length > 0) {
                    cachedLogon = curated;
                    cachedLogonAtMs = System.currentTimeMillis();
                }
                return curated;
            }
            return cachedLogon;                      // probe skipped
        } catch (Throwable t) {
            log("curateLogonSessionsCached failed: " + t);
            return ret != null ? ret : cachedLogon;
        }
    }

    /**
     * Pure core, for testing. The bridge only ever presents ONE display — the
     * one the daemon captures — so any other session in the picker (most often
     * the GDM greeter's ":1024", present whenever nobody is logged in) is
     * misleading: selecting it still shows our frame. So keep only the entries
     * whose display matches ours, relabel them (to "[Backstage]" via the label=
     * arg, or the user's name), and return an array of just those — which also
     * puts our session first because it is then the only one.
     *
     * Falls back to relabelling everything in place, and returning the original
     * array, when nothing matches our display: an unexpected DISPLAY must never
     * empty the picker and leave the operator unable to connect.
     */
    static Object curateLogonSessions(Object ret, String display, String label) {
        try {
            if (ret == null) return ret;
            if (!ret.getClass().isArray()) {   // single-session variant: just relabel
                if (label != null && !label.isEmpty()) relabelOne(ret, label, false);
                return ret;
            }
            Object[] arr = (Object[]) ret;
            if (!curateEnabled) {          // spike: show everything, observe
                for (Object e : arr) {
                    if (e == null) continue;
                    String d = sessionDisplay(e);
                    boolean ours = display != null && display.equals(d);
                    log("SPIKE logon entry display=" + d + " id=" + sessionId(e)
                            + (ours ? " (ours)" : ""));
                    if (ours && label != null && !label.isEmpty()) {
                        relabelOne(e, label, true);
                    }
                }
                return arr;
            }
            java.util.List<Object> keep = new java.util.ArrayList<>();
            for (Object e : arr) {
                if (e != null && display != null && display.equals(sessionDisplay(e))) {
                    keep.add(e);
                }
            }
            if (keep.isEmpty()) {              // no confident match — change nothing structural
                if (label != null && !label.isEmpty()) {
                    for (Object e : arr) relabelOne(e, label, arr.length > 1);
                }
                return arr;
            }
            if (label != null && !label.isEmpty()) {
                for (Object e : keep) relabelOne(e, label, false);
            }
            Object out = java.lang.reflect.Array.newInstance(
                    arr.getClass().getComponentType(), keep.size());
            for (int i = 0; i < keep.size(); i++) {
                java.lang.reflect.Array.set(out, i, keep.get(i));
            }
            return out;
        } catch (Throwable t) {
            log("curateLogonSessions failed: " + t);
            return ret;
        }
    }

    private static String sessionDisplay(Object e) throws Exception {
        Object v = e.getClass().getField("logonSessionName").get(e);
        return v == null ? null : v.toString();
    }

    /** Best-effort read of the selection key, for spike logging only. */
    private static String sessionId(Object e) {
        for (String name : new String[]{"logonSessionID", "logonSessionId", "sessionID"}) {
            try {
                Object v = e.getClass().getField(name).get(e);
                if (v != null) return name + "=" + v;
            } catch (Throwable ignored) { }
        }
        return "?";
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
     * The comparable identity of an X display, or null when the value names no
     * display at all.
     *
     * The two sides of a match come from different producers — the child JVM's
     * DISPLAY, baked in by ScreenConnect from its logon probe, and the daemon's
     * own --display/$DISPLAY — so either may carry the `.screen` suffix of the
     * X display grammar ([host]:number[.screen]). The screen selects a monitor
     * within one display, never a different session, so it is dropped before
     * matching. A value that is not display-shaped is left alone: an opaque
     * token then matches only itself and can never alias another session.
     *
     * Null, blank, and the daemon's literal UNKNOWN all mean "no display" — a
     * daemon that cannot tell which session it owns must never be selectable.
     */
    static String normalizeDisplay(String display) {
        if (display == null) return null;
        String d = display.trim();
        if (d.isEmpty() || "UNKNOWN".equals(d) || isErrorLine(d)) return null;
        int colon = d.lastIndexOf(':');
        if (colon >= 0) {
            int dot = d.indexOf('.', colon);
            if (dot > colon && allDigits(d.substring(colon + 1, dot))
                    && allDigits(d.substring(dot + 1))) {
                return d.substring(0, dot);
            }
        }
        return d;
    }

    /**
     * True for the daemon protocol's error replies, `ERR <text>` — including a
     * bare `ERR`. A daemon older than a command answers with one, and the
     * daemon and the agent are deployed separately, so a new agent meets an old
     * daemon during any rolling upgrade. Keyed on the ERR *token* rather than
     * an "ERR" prefix, so a legal hostname:display like `ERRBOX:0`, or a login
     * name like `errol`, is not mistaken for an error.
     */
    private static boolean isErrorLine(String trimmed) {
        return "ERR".equals(trimmed.split("\\s+", 2)[0]);
    }

    /**
     * A daemon-supplied name fit to show an operator, or null if it is no name
     * at all. The label reaches ScreenConnect's session picker, so an error
     * line or blank must never arrive there as if it were a session.
     */
    static String sanitizeLabel(String label) {
        if (label == null) return null;
        String s = label.trim();
        if (s.isEmpty() || isErrorLine(s)) return null;
        return s;
    }

    private static boolean allDigits(String s) {
        if (s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) {
            if (!Character.isDigit(s.charAt(i))) return false;
        }
        return true;
    }

    /**
     * Which daemon this child JVM attaches to: the one owning the display
     * ScreenConnect baked into *this* process's environment, not whichever pair
     * the agent args named.
     *
     * Falls back to the static shm=/socket= args only when there is nothing to
     * resolve at all — nothing discovered, or a child that cannot say which
     * display it is. That fallback is the promise to every existing install: a
     * box running only the backstage daemon behaves exactly as it did before
     * this feature existed.
     *
     * Returns null — meaning DO NOT ATTACH — when live daemons exist but none
     * owns this child's display, or when more than one claims it. Showing the
     * operator another session's desktop while naming it as theirs is the exact
     * failure this feature exists to remove, so black is the safer answer; and
     * an ambiguous claim is a misconfiguration or a hijack attempt, where
     * guessing deterministically is still guessing.
     */
    /**
     * Which session this JVM attaches to, or null meaning attach to NOTHING.
     *
     * Refusal keys on whether the registry DESCRIBES this display, never on
     * whether the live list happens to be non-empty — the two are different
     * questions and conflating them broke both directions in practice:
     * registering the first user session blacked out backstage, and a
     * momentarily-dead session fell back to the configured args and showed
     * backstage under that user's name.
     *
     *   child display unusable          -> fallback (the old world)
     *   registry describes it: no       -> fallback. The registry does not claim
     *                                      to be complete, so an unregistered
     *                                      session keeps the operator's own
     *                                      configuration.
     *   describes exactly one, live     -> that session
     *   describes exactly one, not live -> refuse. Never fall back: that is the
     *                                      lie this feature exists to remove.
     *   describes more than one         -> refuse; root registered two sessions
     *                                      for one display and guessing is wrong.
     */
    static SessionEndpoint resolveEndpoint(String childDisplay,
                                           java.util.List<SessionEndpoint> registered,
                                           java.util.List<SessionEndpoint> live,
                                           SessionEndpoint fallback) {
        String want = normalizeDisplay(childDisplay);
        if (want == null) return fallback;
        SessionEndpoint described = null;
        int describedCount = 0;
        if (registered != null) {
            for (SessionEndpoint e : registered) {
                if (e == null) continue;
                if (want.equals(normalizeDisplay(e.display()))) {
                    describedCount++;
                    described = e;
                }
            }
        }
        if (describedCount == 0) return knownWrong(fallback, registered, want) ? null : fallback;
        if (describedCount > 1) return null;
        if (live != null) {
            for (SessionEndpoint e : live) {
                if (e == null) continue;
                if (want.equals(normalizeDisplay(e.display()))) return e;
            }
        }
        return null;                    // described, but nothing usable serves it
    }

    /**
     * Whether the registry contradicts the fallback: some entry claims the
     * fallback's own frame or socket for a display other than this child's.
     *
     * Falling back is a statement that we have no evidence about this display,
     * so the operator's configuration is the best guess. When the registry
     * names the very endpoint that configuration points at, and names it as a
     * *different* session, that guess is known wrong — using it would show
     * backstage under the selected session's name, the failure this whole
     * feature exists to remove.
     *
     * Either half is disqualifying on its own: a shared frame shows the wrong
     * screen, a shared socket types into the wrong session.
     */
    private static boolean knownWrong(SessionEndpoint fallback,
                                      java.util.List<SessionEndpoint> registered,
                                      String wantedDisplay) {
        if (fallback == null || registered == null) return false;
        for (SessionEndpoint e : registered) {
            if (e == null) continue;
            if (wantedDisplay.equals(normalizeDisplay(e.display()))) continue;
            boolean sameShm = e.shm() != null && e.shm().equals(fallback.shm());
            boolean sameSocket = e.socket() != null && e.socket().equals(fallback.socket());
            if (sameShm || sameSocket) {
                log("REFUSING to fall back: the registry names " + fallback.shm() + " / "
                        + fallback.socket() + " as display " + e.display()
                        + " (" + e.user() + "), not " + wantedDisplay);
                return true;
            }
        }
        return false;
    }

    /**
     * The client for one endpoint, demanding the account the registry says
     * serves it. The fallback endpoint carries no user — it is the operator's
     * own shm=/socket= configuration and answers to no registry entry.
     */
    static DaemonClient clientFor(SessionEndpoint chosen) {
        return new DaemonClient(chosen.socket(), chosen.user());
    }

    /**
     * Point this JVM's client and frame reader at one endpoint, replacing
     * whatever was there. Unconditional replacement is the point: the picker
     * path relabels sessions before any session is resolved, so an
     * unauthenticated client on the static socket already exists by then, and a
     * `if (daemon == null)` guard would silently keep it — wrong socket and no
     * peer check on every keystroke thereafter.
     */
    static synchronized DaemonClient attachTo(SessionEndpoint chosen) {
        if (chosen == null) return null;
        if (daemon != null) daemon.close();
        daemon = clientFor(chosen);
        frame = new FrameReader(chosen.shm());
        shmPath = chosen.shm();
        socketPath = chosen.socket();
        // The name travels with the session: adopting it here (rather than in
        // the resolver) means it is set before anything can ask for a label,
        // and a stale WHO cached for a previous session cannot outrank it.
        sessionLabel = chosen.label();
        logonLabel = null;
        return daemon;
    }

    /**
     * Called from the instrumented Robot.init exit. Returns our peer, or the
     * original on any failure.
     */
    public static RobotPeer wrapPeer(GraphicsDevice screen, RobotPeer original) {
        try {
            log("wrapPeer: Robot built for device="
                    + (screen == null ? "null" : screen.getIDstring())
                    + " DISPLAY=" + System.getenv("DISPLAY"));
            if (!attach()) {
                log("keeping the original X11 Robot peer: no daemon was resolved "
                        + "for this session (see the refusal above)");
                return original;
            }
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
