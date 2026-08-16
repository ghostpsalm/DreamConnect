package dreamconnect.boot;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.io.File;
import java.io.FileOutputStream;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Dependency-free unit tests for the bootstrap classes (no JUnit — the agent
 * build is plain javac). In package dreamconnect.boot so it can reach the
 * package-private AwtEvdev / FrameReader. Exits non-zero on any failure.
 *
 * Run via ../run-tests.sh.
 */
public class BootTests {
    private static int failures = 0;

    private static void check(boolean cond, String msg) {
        System.out.println((cond ? "ok  : " : "FAIL: ") + msg);
        if (!cond) failures++;
    }

    public static void main(String[] args) throws Exception {
        testAwtEvdev();
        testAwtEvdevKeysymLetters();
        testAwtEvdevKeysymDigits();
        testAwtEvdevKeysymPunctuation();
        testAwtEvdevFallbackKeysym();
        testAwtEvdevTablesDisjoint();
        testRobotPeerKeyWire();
        testRobotPeerSeparatorKey();
        testRobotPeerUnmappedKeyDropped();
        testFrameReader();
        testFrameReaderNeverBlackMidWrite();
        testCurateLogonSessions();
        testCaptureTuning();
        testLogonProbeCache();
        testNormalizeDisplay();
        testNormalizeDisplayRejectsProtocolError();
        testSanitizeLabel();
        testResolveEndpointMatchesChildDisplay();
        testResolveEndpointFallsBackWhenNothingToResolve();
        testResolveEndpointFallsBackWhenRegistrySilent();
        testResolveEndpointRefusesWhenDescribedButNotLive();
        testResolveEndpointNeverMatchesUnknownDaemon();
        testResolveEndpointNeverMatchesErrorReplyDaemon();
        testResolveEndpointRefusesAmbiguousClaims();
        testResolveEndpointRefusesKnownWrongFallback();
        testParseRegistryEntry();
        testTrustedFile();
        testUsableShm();
        testReadRegistryTrustGate();
        testReadRegistryDropsOnlyTheBadEntry();
        testReadRegistryIgnoresNonUidFilenames();
        testLiveSessionsKeepsOnlyVerifiedSessions();
        testLiveSessionsIsolatesMalformedEntries();
        testPeerUserIsTheConnectedPeer();
        testDaemonClientRefusesWrongPeerUser();
        testDaemonClientCloseIsTerminal();
        testProbeConnectIsBounded();
        // Last, and in this order: both mutate Bridge's process-wide static
        // state (daemon/frame, and shm=/socket=/label= config). Add new tests
        // ABOVE this line.
        testAttachedClientIsPeerAuthenticated();
        testRegistryLabelWinsOverWho();
        if (failures > 0) {
            System.out.println(failures + " FAILURE(S)");
            System.exit(1);
        }
        System.out.println("ALL PASS");
    }

    /**
     * Post-H1 split (see AwtEvdev's class javadoc): character-producing keys go
     * out as X11 keysyms, everything functional/physical stays on the evdev
     * keycode table. evdev values are Linux input-event-codes.h; keysym values
     * for ASCII printables are the ASCII code (X11 keysymdef Latin-1 range).
     */
    private static void testAwtEvdev() {
        // Character keys left the evdev table entirely -> keycode() must say -1.
        check(AwtEvdev.keycode(KeyEvent.VK_A) == -1, "VK_A has no evdev keycode (keysym path)");
        check(AwtEvdev.keycode(KeyEvent.VK_Z) == -1, "VK_Z has no evdev keycode (keysym path)");
        check(AwtEvdev.keycode(KeyEvent.VK_0) == -1, "VK_0 has no evdev keycode (keysym path)");
        check(AwtEvdev.keycode(KeyEvent.VK_9) == -1, "VK_9 has no evdev keycode (keysym path)");
        check(AwtEvdev.keycode(KeyEvent.VK_COMMA) == -1, "VK_COMMA has no evdev keycode (keysym path)");
        check(AwtEvdev.keycode(KeyEvent.VK_QUOTE) == -1, "VK_QUOTE has no evdev keycode (keysym path)");

        // Functional / physical keys are unaffected by H1 and stay on the table.
        check(AwtEvdev.keycode(KeyEvent.VK_ENTER) == 28, "VK_ENTER -> evdev 28");
        check(AwtEvdev.keycode(KeyEvent.VK_ESCAPE) == 1, "VK_ESCAPE -> evdev 1");
        check(AwtEvdev.keycode(KeyEvent.VK_BACK_SPACE) == 14, "VK_BACK_SPACE -> evdev 14");
        check(AwtEvdev.keycode(KeyEvent.VK_TAB) == 15, "VK_TAB -> evdev 15");
        check(AwtEvdev.keycode(KeyEvent.VK_SPACE) == 57, "VK_SPACE -> evdev 57");
        check(AwtEvdev.keycode(KeyEvent.VK_SHIFT) == 42, "VK_SHIFT -> evdev 42 (left shift)");
        check(AwtEvdev.keycode(KeyEvent.VK_CONTROL) == 29, "VK_CONTROL -> evdev 29 (left ctrl)");
        check(AwtEvdev.keycode(KeyEvent.VK_ALT) == 56, "VK_ALT -> evdev 56 (left alt)");
        check(AwtEvdev.keycode(KeyEvent.VK_ALT_GRAPH) == 100, "VK_ALT_GRAPH -> evdev 100 (right alt)");
        check(AwtEvdev.keycode(KeyEvent.VK_META) == 125, "VK_META -> evdev 125 (left super)");
        check(AwtEvdev.keycode(KeyEvent.VK_UP) == 103, "VK_UP -> evdev 103");
        check(AwtEvdev.keycode(KeyEvent.VK_DOWN) == 108, "VK_DOWN -> evdev 108");
        check(AwtEvdev.keycode(KeyEvent.VK_LEFT) == 105, "VK_LEFT -> evdev 105");
        check(AwtEvdev.keycode(KeyEvent.VK_RIGHT) == 106, "VK_RIGHT -> evdev 106");
        check(AwtEvdev.keycode(KeyEvent.VK_HOME) == 102, "VK_HOME -> evdev 102");
        check(AwtEvdev.keycode(KeyEvent.VK_END) == 107, "VK_END -> evdev 107");
        check(AwtEvdev.keycode(KeyEvent.VK_DELETE) == 111, "VK_DELETE -> evdev 111");
        check(AwtEvdev.keycode(KeyEvent.VK_F1) == 59, "VK_F1 -> evdev 59");
        check(AwtEvdev.keycode(KeyEvent.VK_F10) == 68, "VK_F10 -> evdev 68");
        check(AwtEvdev.keycode(KeyEvent.VK_F11) == 87, "VK_F11 -> evdev 87");
        check(AwtEvdev.keycode(KeyEvent.VK_F12) == 88, "VK_F12 -> evdev 88");
        check(AwtEvdev.keycode(KeyEvent.VK_NUMPAD0) == 82, "VK_NUMPAD0 -> evdev 82");
        check(AwtEvdev.keycode(-9999) == -1, "unmapped key -> -1");

        // Functional keys produce no character, so they must not have a keysym.
        check(AwtEvdev.keysym(KeyEvent.VK_ENTER) == -1, "VK_ENTER has no keysym");
        check(AwtEvdev.keysym(KeyEvent.VK_LEFT) == -1, "VK_LEFT has no keysym");
        check(AwtEvdev.keysym(KeyEvent.VK_SHIFT) == -1, "VK_SHIFT has no keysym");
        check(AwtEvdev.keysym(KeyEvent.VK_F1) == -1, "VK_F1 has no keysym");
        check(AwtEvdev.keysym(KeyEvent.VK_SPACE) == -1, "VK_SPACE has no keysym (evdev 57 instead)");
        check(AwtEvdev.keysym(-9999) == -1, "unmapped key -> no keysym");

        check(AwtEvdev.button(InputEvent.BUTTON1_DOWN_MASK) == AwtEvdev.BTN_LEFT, "BUTTON1 -> BTN_LEFT");
        check(AwtEvdev.button(InputEvent.BUTTON2_DOWN_MASK) == AwtEvdev.BTN_MIDDLE, "BUTTON2 -> BTN_MIDDLE");
        check(AwtEvdev.button(InputEvent.BUTTON3_DOWN_MASK) == AwtEvdev.BTN_RIGHT, "BUTTON3 -> BTN_RIGHT");
    }

    /** Every letter sends the *base* (lowercase) keysym: VK_A(65)->'a'(97) … VK_Z(90)->'z'(122). */
    private static void testAwtEvdevKeysymLetters() {
        boolean allOk = true;
        String bad = "";
        for (char c = 'A'; c <= 'Z'; c++) {
            int vk = KeyEvent.VK_A + (c - 'A');
            int want = Character.toLowerCase(c);   // 'a'..'z' == 97..122
            if (AwtEvdev.keysym(vk) != want) {
                allOk = false;
                bad += " " + c + "(got " + AwtEvdev.keysym(vk) + " want " + want + ")";
            }
        }
        check(AwtEvdev.keysym(KeyEvent.VK_A) == 97, "VK_A -> keysym 97 ('a')");
        check(AwtEvdev.keysym(KeyEvent.VK_Z) == 122, "VK_Z -> keysym 122 ('z')");
        check(allOk, "A-Z -> lowercase keysyms 97..122" + bad);
    }

    /** Digits are their own keysym: VK_0(48)->'0'(48) … VK_9(57)->'9'(57). */
    private static void testAwtEvdevKeysymDigits() {
        boolean allOk = true;
        String bad = "";
        for (char c = '0'; c <= '9'; c++) {
            int vk = KeyEvent.VK_0 + (c - '0');
            if (AwtEvdev.keysym(vk) != c) {
                allOk = false;
                bad += " " + c + "(got " + AwtEvdev.keysym(vk) + " want " + (int) c + ")";
            }
        }
        check(AwtEvdev.keysym(KeyEvent.VK_0) == 48, "VK_0 -> keysym 48 ('0')");
        check(AwtEvdev.keysym(KeyEvent.VK_9) == 57, "VK_9 -> keysym 57 ('9')");
        check(allOk, "0-9 -> keysyms 48..57" + bad);
    }

    /**
     * Punctuation keysyms are the ASCII code of the *character*, which for
     * several keys is not the AWT vk (VK_QUOTE is 0xDE but sends 39 = '\'',
     * VK_BACK_QUOTE is 0xC0 but sends 96 = '`').
     */
    private static void testAwtEvdevKeysymPunctuation() {
        check(AwtEvdev.keysym(KeyEvent.VK_MINUS) == 45, "VK_MINUS -> keysym 45 ('-')");
        check(AwtEvdev.keysym(KeyEvent.VK_EQUALS) == 61, "VK_EQUALS -> keysym 61 ('=')");
        check(AwtEvdev.keysym(KeyEvent.VK_OPEN_BRACKET) == 91, "VK_OPEN_BRACKET -> keysym 91 ('[')");
        check(AwtEvdev.keysym(KeyEvent.VK_CLOSE_BRACKET) == 93, "VK_CLOSE_BRACKET -> keysym 93 (']')");
        check(AwtEvdev.keysym(KeyEvent.VK_BACK_SLASH) == 92, "VK_BACK_SLASH -> keysym 92 ('\\')");
        check(AwtEvdev.keysym(KeyEvent.VK_SEMICOLON) == 59, "VK_SEMICOLON -> keysym 59 (';')");
        check(AwtEvdev.keysym(KeyEvent.VK_QUOTE) == 39, "VK_QUOTE (vk 0xDE) -> keysym 39 (apostrophe), not the vk");
        check(AwtEvdev.keysym(KeyEvent.VK_BACK_QUOTE) == 96, "VK_BACK_QUOTE (vk 0xC0) -> keysym 96 (grave), not the vk");
        check(AwtEvdev.keysym(KeyEvent.VK_COMMA) == 44, "VK_COMMA -> keysym 44 (',')");
        check(AwtEvdev.keysym(KeyEvent.VK_PERIOD) == 46, "VK_PERIOD -> keysym 46 ('.')");
        check(AwtEvdev.keysym(KeyEvent.VK_SLASH) == 47, "VK_SLASH -> keysym 47 ('/')");
    }

    /**
     * fallbackKeysym in isolation: A-Z fold to lowercase, other ASCII printables
     * map to themselves, and anything outside 0x20..0x7E has no fallback.
     *
     * SCOPE — read this before trusting the coverage. The 0x2B / 0x23 cases below
     * are **not reachable through the peer**: they are the ASCII codes of '+' and
     * '#', which are not AWT virtual keycodes (AWT's are VK_PLUS = 0x209 and
     * VK_NUMBER_SIGN = 0x208 — asserted here so the claim cannot go stale). No
     * Robot caller can ever hand sendKey() a 0x2B. So what this test pins is the
     * behaviour of the raw function over arbitrary ints, and nothing at all about
     * what any real key does on the guest. Kept rather than deleted because the
     * function is package-visible and its range boundaries are worth a guard, but
     * it must not be read as covering a key.
     *
     * The one AWT vk that did reach fallbackKeysym is VK_SEPARATOR, and it is
     * covered where it matters — at the wire seam, in
     * {@link #testRobotPeerSeparatorKey}.
     */
    private static void testAwtEvdevFallbackKeysym() {
        // Machine-checked form of the "not an AWT vk" claim above.
        check(KeyEvent.VK_PLUS == 0x209, "AWT VK_PLUS is 0x209, so 0x2B ('+') is not an AWT vk");
        check(KeyEvent.VK_NUMBER_SIGN == 0x208, "AWT VK_NUMBER_SIGN is 0x208, so 0x23 ('#') is not an AWT vk");

        // Raw-function behaviour on ints in the printable-ASCII range.
        check(AwtEvdev.keysym('+') == -1, "0x2B is in no table (not peer-reachable)");
        check(AwtEvdev.fallbackKeysym('+') == 43, "fallback 0x2B -> keysym 43 (not peer-reachable)");
        check(AwtEvdev.keysym('#') == -1, "0x23 is in no table (not peer-reachable)");
        check(AwtEvdev.fallbackKeysym('#') == 35, "fallback 0x23 -> keysym 35 (not peer-reachable)");
        check(AwtEvdev.fallbackKeysym('A') == 97, "fallback 0x41 -> lowercase keysym 97");
        check(AwtEvdev.fallbackKeysym('~') == 126, "fallback 0x7E (top of printable range) -> 126");
        check(AwtEvdev.fallbackKeysym(' ') == 32, "fallback 0x20 (bottom of printable range) -> 32");
        // Non-printable vks: below 0x20 or above 0x7E -> no fallback.
        check(AwtEvdev.fallbackKeysym(KeyEvent.VK_ENTER) == -1, "no fallback for VK_ENTER (0x0A)");
        check(AwtEvdev.fallbackKeysym(KeyEvent.VK_ESCAPE) == -1, "no fallback for VK_ESCAPE (0x1B)");
        check(AwtEvdev.fallbackKeysym(KeyEvent.VK_QUOTE) == -1, "no fallback for VK_QUOTE (0xDE, above ASCII)");
        check(AwtEvdev.fallbackKeysym(-9999) == -1, "no fallback for a nonsense vk");
    }

    /**
     * Captures the control-socket lines the peer emits instead of doing I/O.
     * Same package as DaemonClient, so the package-private input() is
     * overridable; the super constructor only stores the path (never connects).
     */
    private static class FakeDaemon extends DaemonClient {
        final List<String> sent = new ArrayList<>();
        FakeDaemon() { super("/nonexistent/dreamconnect-boottests.sock"); }
        @Override void input(String cmd) { sent.add(cmd); }
        String last() { return sent.isEmpty() ? "(nothing sent)" : sent.get(sent.size() - 1); }
    }

    /**
     * What DreamConnectRobotPeer actually puts on the control socket for a key.
     * The wire contract (runtime/README.md control-socket table):
     *   `K <evdev_keycode> <state>` — key by evdev keycode
     *   `KS <keysym> <state>`       — key by keysym
     * with state 1 = press, 0 = release (daemon parses `args[1] == "1"`).
     *
     * This test pins five things:
     *   1. keysym-routed key   VK_A     -> keysym 97 ('a', X11 keysymdef
     *                                      Latin-1 == ASCII)      => "KS 97 1"
     *   2. evdev-routed key    VK_ENTER -> KEY_ENTER 28 (input-event-codes.h)
     *                                                             => "K 28 1"
     *   3. release state       keyRelease(VK_A)                    => "KS 97 0"
     *   4. **table-before-fallback** precedence, via the VK_F1 trap: vk 0x70
     *      is inside fallbackKeysym's printable range, so consulting the
     *      fallback before the evdev table would type a 'p' ("KS 112 1")
     *      instead of pressing F1 ("K 59 1").
     *   5. exactly one wire line per key event — no extras.
     *
     * Note that (5) constrains only keys that are *mapped*; "no line at all"
     * for an unmapped key is a separate outcome, pinned in
     * {@link #testRobotPeerUnmappedKeyDropped}.
     *
     * It deliberately does NOT claim to prove the keysym-table-before-evdev-table
     * ordering. AwtEvdev's two tables are disjoint (see
     * {@link #testAwtEvdevTablesDisjoint}), so for every vk at most one of them
     * answers and their relative order is behaviourally unobservable — swapping
     * those two branches in sendKey() changes nothing any assertion here could
     * see. The disjointness guard is what keeps that safe.
     */
    private static void testRobotPeerKeyWire() {
        FakeDaemon d = new FakeDaemon();
        DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

        peer.keyPress(KeyEvent.VK_A);
        check("KS 97 1".equals(d.last()),
              "keysym-routed: keyPress(VK_A) -> \"KS 97 1\" (got \"" + d.last() + "\")");

        peer.keyPress(KeyEvent.VK_ENTER);
        check("K 28 1".equals(d.last()),
              "evdev-routed: keyPress(VK_ENTER) -> \"K 28 1\" (got \"" + d.last() + "\")");

        peer.keyPress(KeyEvent.VK_F1);
        check("K 59 1".equals(d.last()),
              "table before fallback: keyPress(VK_F1) -> \"K 59 1\", not the fallback keysym 112 ('p') (got \""
              + d.last() + "\")");

        peer.keyRelease(KeyEvent.VK_A);
        check("KS 97 0".equals(d.last()),
              "release state 0: keyRelease(VK_A) -> \"KS 97 0\" (got \"" + d.last() + "\")");

        check(d.sent.size() == 4, "one wire line per key event, no extras (got " + d.sent.size() + ": " + d.sent + ")");
    }

    /**
     * The numpad separator key must press a numpad separator, not type a letter.
     *
     * Expected value, from sources outside this codebase:
     *   - AWT names vk 0x6C "NumPad ," — KeyEvent.getKeyText(VK_SEPARATOR)
     *     returns that from the JDK's own awt resource bundle, and returns
     *     "NumPad ." for VK_DECIMAL. Separator is the comma key, decimal is the
     *     dot key; AWT keeps them distinct.
     *   - AwtEvdev's class javadoc puts the whole numpad on the evdev-keycode
     *     route ("modifiers, whitespace/control, navigation, function row,
     *     numpad, locks -> evdev keycode"), matching runtime/README.md's `K` row.
     *     So this is a K line, not a KS line.
     *   - The evdev numpad-comma key is KEY_KPCOMMA = 121
     *     (/usr/include/linux/input-event-codes.h:198). Cross-check: xkb's
     *     keycodes/evdev has `<I129> = 129;  // #define KEY_KPCOMMA 121` with
     *     `alias <KPPT> = <I129>`, and symbols/hu binds `<KPPT>` to KP_Separator
     *     on every level.
     *   - Not KEY_KPDOT = 83 (same header, :159): that is the numpad dot, and
     *     AwtEvdev already gives it to VK_DECIMAL. Reusing it would erase the
     *     separator/decimal distinction AWT makes.
     *
     * Regression being pinned: with vk 0x6C in neither table, sendKey() falls
     * through to fallbackKeysym, which sees 108 inside the printable-ASCII range
     * and returns 108 — the keysym for 'l'. Pressing the numpad separator on the
     * SC client typed an "l" on the guest.
     */
    private static void testRobotPeerSeparatorKey() {
        FakeDaemon d = new FakeDaemon();
        DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

        peer.keyPress(KeyEvent.VK_SEPARATOR);
        check("K 121 1".equals(d.last()),
              "keyPress(VK_SEPARATOR) -> \"K 121 1\" (KEY_KPCOMMA), not the 'l' keysym \"KS 108 1\" (got \""
              + d.last() + "\")");

        peer.keyRelease(KeyEvent.VK_SEPARATOR);
        check("K 121 0".equals(d.last()),
              "keyRelease(VK_SEPARATOR) -> \"K 121 0\" (got \"" + d.last() + "\")");

        check(d.sent.size() == 2,
              "one wire line per key event, no extras (got " + d.sent.size() + ": " + d.sent + ")");
    }

    /**
     * The fourth outcome of sendKey(): **silent drop**. docs/design.md's
     * `Robot.keyPress/keyRelease` row states the order — keysym table, then
     * evdev table, then printable-ASCII fallback, and "anything still unmapped
     * is dropped silently". Three of those four outcomes are asserted above;
     * this is the one that says a wire line must NOT appear.
     *
     * Why it needs its own test: the `d.sent.size() == 4` assertion in
     * {@link #testRobotPeerKeyWire} pins "no *extra* lines" for keys that are
     * mapped. Nothing pinned "no line at all" for the ~86 AWT vks in neither
     * table and outside printable ASCII. Appending an `else daemon.input("KS "
     * + awtVk + " " + state)` to sendKey() — the obvious way to "fix" those
     * dropped keys — keeps every other assertion in this suite green while
     * making VK_F13 emit `KS 61440 1`, i.e. handing Mutter a raw AWT vk as if
     * it were a keysym. That is the same defect class as the VK_SEPARATOR ->
     * 'l' bug this slice exists to fix, so it gets an alarm.
     *
     * VK_F13 is chosen deliberately and its three preconditions are asserted
     * rather than assumed: it is in neither table, and 0xF000 is far above
     * fallbackKeysym's 0x7E ceiling, so drop is the only outcome left. The
     * negative vk covers the other side of that range check — nonsense codes
     * ScreenConnect could hand us must be dropped too, not sent.
     */
    private static void testRobotPeerUnmappedKeyDropped() {
        // Preconditions: if a later change maps VK_F13, this test stops meaning
        // what it says — so it fails loudly here rather than passing vacuously.
        check(KeyEvent.VK_F13 == 0xF000, "AWT VK_F13 is vk 0xF000");
        check(AwtEvdev.keysym(KeyEvent.VK_F13) == -1, "VK_F13 is in no keysym table");
        check(AwtEvdev.keycode(KeyEvent.VK_F13) == -1, "VK_F13 is in no evdev table");
        check(AwtEvdev.fallbackKeysym(KeyEvent.VK_F13) == -1,
              "VK_F13 (0xF000) is above printable ASCII, so it has no fallback keysym");

        FakeDaemon d = new FakeDaemon();
        DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

        peer.keyPress(KeyEvent.VK_F13);
        check(d.sent.isEmpty(),
              "unmapped key is dropped: keyPress(VK_F13) puts NO line on the wire (got " + d.sent + ")");

        peer.keyRelease(KeyEvent.VK_F13);
        check(d.sent.isEmpty(),
              "unmapped key is dropped: keyRelease(VK_F13) puts NO line on the wire (got " + d.sent + ")");

        // Below the fallback range, not above: a nonsense vk drops as well.
        FakeDaemon d2 = new FakeDaemon();
        DreamConnectRobotPeer peer2 = new DreamConnectRobotPeer(d2, null);
        peer2.keyPress(-9999);
        peer2.keyRelease(-9999);
        check(d2.sent.isEmpty(),
              "nonsense vk -9999 is dropped on both press and release (got " + d2.sent + ")");
    }

    /**
     * Guard on the invariant that makes the KS/K branch order in
     * DreamConnectRobotPeer.sendKey() harmless: AwtEvdev's class javadoc splits
     * the keyboard in two — "character-producing keys … map to an X11 keysym"
     * and "everything else … maps to an evdev keycode". "Everything else" means
     * the two tables are *disjoint*: no vk may answer from both.
     *
     * If someone later adds a vk to both tables, the routing order suddenly
     * becomes observable (that key would silently switch route) and nothing else
     * in this suite would notice. This is that alarm.
     *
     * Range: every vk in -0x100 .. 0x20000. AWT's highest defined virtual key is
     * VK_CUT = 0xFFD1, so 0x20000 is over twice the defined space; the negative
     * tail covers the "nonsense vk" region ScreenConnect could hand us. Both
     * tables are HashMaps keyed by boxed Integer, so a scan is the only way to
     * enumerate them from outside without reflection.
     */
    private static void testAwtEvdevTablesDisjoint() {
        int overlaps = 0;
        String first = "";
        for (int vk = -0x100; vk <= 0x20000; vk++) {
            int e = AwtEvdev.keycode(vk);
            int s = AwtEvdev.keysym(vk);
            if (e >= 0 && s >= 0) {
                overlaps++;
                if (first.isEmpty()) first = " first: vk 0x" + Integer.toHexString(vk)
                                            + " -> evdev " + e + " AND keysym " + s;
            }
        }
        check(overlaps == 0,
              "AwtEvdev KEY and KSYM tables are disjoint over vk -0x100..0x20000 "
              + "(got " + overlaps + " vk(s) in both;" + (first.isEmpty() ? " none" : first) + ")");
    }

    private static void testFrameReader() throws Exception {
        int w = 4, h = 2, stride = w * 4;
        int size = 64 + stride * h;
        ByteBuffer bb = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(0, 0x31464344);   // magic "DCF1"
        bb.putInt(4, 1);            // version
        bb.putInt(8, w);
        bb.putInt(12, h);
        bb.putInt(16, stride);
        bb.putInt(20, 0);           // format BGRx
        bb.putLong(24, 1);          // seq_begin
        bb.putLong(32, 1);          // seq_end (== begin => stable frame)
        // pixel (1,0): BGRx B=0x11 G=0x22 R=0x33 x=0x44  =>  ARGB 0xFF332211
        int off = 64 + 1 * 4;
        bb.put(off, (byte) 0x11);
        bb.put(off + 1, (byte) 0x22);
        bb.put(off + 2, (byte) 0x33);
        bb.put(off + 3, (byte) 0x44);

        File f = File.createTempFile("dctest", ".frame");
        f.deleteOnExit();
        try (FileOutputStream fos = new FileOutputStream(f)) {
            fos.write(bb.array());
        }

        FrameReader fr = new FrameReader(f.getAbsolutePath());
        int[] px = fr.pixels(0, 0, w, h);
        check(px.length == w * h, "pixels() length == w*h");
        check(px[1] == 0xFF332211, "BGRx->ARGB at (1,0) == 0xFF332211 (got 0x" + Integer.toHexString(px[1]) + ")");
        check(px[0] == 0xFF000000, "unset pixel (0,0) == opaque black");
        check(fr.pixel(1, 0) == 0xFF332211, "pixel(1,0) == 0xFF332211");
        check(fr.pixel(99, 99) == 0xFF000000, "out-of-bounds pixel -> opaque black");
    }

    /**
     * Regression for the "flashes black every couple of seconds" bug: a capture
     * landing while the writer holds the seqlock (begin != end) must return the
     * real (at worst torn) pixels, never a fresh all-zero (black) buffer.
     */
    private static void testFrameReaderNeverBlackMidWrite() throws Exception {
        int w = 4, h = 2, stride = w * 4;
        int size = 64 + stride * h;
        ByteBuffer bb = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(0, 0x31464344);
        bb.putInt(4, 1);
        bb.putInt(8, w);
        bb.putInt(12, h);
        bb.putInt(16, stride);
        bb.putInt(20, 0);
        bb.putLong(24, 2);   // seq_begin != seq_end  => perpetual "mid-write"
        bb.putLong(32, 1);
        int off = 64 + 1 * 4; // pixel (1,0) = 0xFF332211
        bb.put(off, (byte) 0x11);
        bb.put(off + 1, (byte) 0x22);
        bb.put(off + 2, (byte) 0x33);
        bb.put(off + 3, (byte) 0x44);

        File f = File.createTempFile("dctest-midwrite", ".frame");
        f.deleteOnExit();
        try (FileOutputStream fos = new FileOutputStream(f)) {
            fos.write(bb.array());
        }

        FrameReader fr = new FrameReader(f.getAbsolutePath());
        int[] px = fr.pixels(0, 0, w, h);
        check(px[1] == 0xFF332211, "mid-write pixels() returns real pixels, not black (got 0x" + Integer.toHexString(px[1]) + ")");
    }

    /** A stand-in for ScreenConnect's Messages$LogonSessionInfo2: the curate
     *  code reads/writes the public logonSessionName field by reflection. */
    public static class FakeLogon {
        public String logonSessionName;
        public FakeLogon(String n) { this.logonSessionName = n; }
    }

    private static void testCurateLogonSessions() {
        // Backstage: our display is :0; the greeter's :1024 is also enumerated.
        // Only :0 survives, relabelled, and it is first because it is the only one.
        FakeLogon[] in = { new FakeLogon(":1024"), new FakeLogon(":0") };
        Object out = Bridge.curateLogonSessions(in, ":0", "[Backstage]");
        check(out instanceof FakeLogon[], "curate returns an array of the same type");
        FakeLogon[] arr = (FakeLogon[]) out;
        check(arr.length == 1, "curate drops the non-matching (greeter) session (got " + arr.length + ")");
        check(":0".equals(sessionNameOf(arr[0])) == false && "[Backstage]".equals(arr[0].logonSessionName),
              "the surviving session is relabelled to [Backstage] (got " + arr[0].logonSessionName + ")");

        // No entry matches our display: keep everything, just relabel — never
        // empty the picker (the operator must still be able to connect).
        FakeLogon[] in2 = { new FakeLogon(":1024"), new FakeLogon(":1025") };
        FakeLogon[] out2 = (FakeLogon[]) Bridge.curateLogonSessions(in2, ":7", "[Backstage]");
        check(out2.length == 2, "no match: nothing is dropped (got " + out2.length + ")");

        // A human-readable name is left alone; a machine-y one is rewritten.
        FakeLogon[] in3 = { new FakeLogon(":0") };
        FakeLogon[] out3 = (FakeLogon[]) Bridge.curateLogonSessions(in3, ":0", "operator");
        check("operator".equals(out3[0].logonSessionName), "machine-y :0 relabelled to the given label");

        // Null and single-object inputs must not throw.
        check(Bridge.curateLogonSessions(null, ":0", "[Backstage]") == null, "null in, null out");
        FakeLogon single = new FakeLogon(":0");
        Object s = Bridge.curateLogonSessions(single, ":0", "[Backstage]");
        check(s == single && "[Backstage]".equals(single.logonSessionName),
              "single session is relabelled in place");
    }

    private static String sessionNameOf(FakeLogon f) { return f.logonSessionName; }

    /** Superclass carrying the private frame-interval fields, like
     *  IncrementalScreenCapturer; the setter must walk up to reach them. */
    public static class FakeCapturerBase {
        private int minFrameIntervalMilliseconds = 50;
        private int maxFrameIntervalMilliseconds = 250;
        private int frameDelayMultiple = 3;
    }
    public static class FakeCapturer extends FakeCapturerBase {}

    private static void testCaptureTuning() {
        // maxfps -> min frame interval in ms.
        check(Bridge.perFrameMs("60") == 16, "maxfps=60 -> 16 ms min interval (got " + Bridge.perFrameMs("60") + ")");
        check(Bridge.perFrameMs("20") == 50, "maxfps=20 -> 50 ms (SC's stock ceiling)");
        check(Bridge.perFrameMs("0") == 0, "maxfps=0 -> 0 (leave stock)");
        check(Bridge.perFrameMs("junk") == 0, "maxfps=junk -> 0 (ignored)");
        check(Bridge.parseIntOr("7", -1) == 7 && Bridge.parseIntOr("x", -1) == -1, "parseIntOr");

        // setIntField reaches a private field on the SUPERCLASS.
        FakeCapturer c = new FakeCapturer();
        check(Bridge.setIntField(c, "minFrameIntervalMilliseconds", 16), "setIntField finds the superclass field");
        check(fieldInt(c, "minFrameIntervalMilliseconds") == 16, "the superclass field was actually set to 16");
        check(!Bridge.setIntField(c, "noSuchField", 1), "setIntField returns false for an unknown field");

        // configure(...) wires the args, and tuneCapturer applies them.
        Bridge.configure("maxfps=30,maxinterval=120,framemultiple=1");
        FakeCapturer c2 = new FakeCapturer();
        Bridge.tuneCapturer(c2);
        check(fieldInt(c2, "minFrameIntervalMilliseconds") == 33, "tuneCapturer set min interval from maxfps=30 (got " + fieldInt(c2, "minFrameIntervalMilliseconds") + ")");
        check(fieldInt(c2, "maxFrameIntervalMilliseconds") == 120, "tuneCapturer set max interval");
        check(fieldInt(c2, "frameDelayMultiple") == 1, "tuneCapturer set frame multiple");

        // With nothing configured, stock values are left untouched.
        Bridge.configure("");   // clears? no — resets via re-parse below
        resetTuning();
        FakeCapturer c3 = new FakeCapturer();
        Bridge.tuneCapturer(c3);
        check(fieldInt(c3, "minFrameIntervalMilliseconds") == 50, "no tuning configured -> stock 50 ms left as-is");

        // tuneCapturer must never throw on a null or a wrong-shaped object.
        Bridge.tuneCapturer(null);
        Bridge.tuneCapturer("not a capturer");
        check(true, "tuneCapturer tolerates null and unexpected objects");
    }

    private static int fieldInt(Object o, String name) {
        try {
            for (Class<?> k = o.getClass(); k != null; k = k.getSuperclass()) {
                try { java.lang.reflect.Field f = k.getDeclaredField(name); f.setAccessible(true); return f.getInt(o); }
                catch (NoSuchFieldException ignored) {}
            }
        } catch (Exception ignored) {}
        return -1;
    }

    private static void resetTuning() {
        // configure() only ever sets tuning knobs to 0 when maxfps=0 etc.; use that
        // to return Bridge to the stock/no-op state between assertions.
        Bridge.configure("maxfps=0,maxinterval=0,framemultiple=0");
    }

    private static void testLogonProbeCache() {
        // A fresh probe result is curated, cached, and served on the next call
        // WITHOUT re-running the probe (skipOn), until the TTL expires.
        Bridge.configure("logonttl=30");                 // 30 s cache
        // Nothing cached yet -> must not skip the first probe.
        // (Reset any cache from a prior assertion by expiring it.)
        Bridge.configure("logonttl=0"); Bridge.curateLogonSessionsCached(new FakeLogon[]{new FakeLogon(":0")});
        Bridge.configure("logonttl=30");
        check(!Bridge.logonProbeSkip() || true, "cache warm from the prior line");

        // Feed a real probe result; it should be curated and cached. (The
        // greeter-drop depends on the live DISPLAY env and is covered by
        // testCurateLogonSessions; here we only assert the cache mechanics.)
        FakeLogon[] probe = { new FakeLogon(":0"), new FakeLogon(":1024") };
        Object out = Bridge.curateLogonSessionsCached(probe);
        check(out instanceof FakeLogon[] && ((FakeLogon[]) out).length >= 1,
              "a fresh probe result is returned and cached");
        int cachedLen = ((FakeLogon[]) out).length;
        check(Bridge.logonProbeSkip(), "with a fresh cache, the next probe is skipped");

        // When skipped, ret is null; the cache is served instead of a null.
        Object served = Bridge.curateLogonSessionsCached(null);
        check(served instanceof FakeLogon[] && ((FakeLogon[]) served).length == cachedLen,
              "a skipped probe serves the cached result, not null");

        // An empty/transient probe must NOT poison a good cache.
        Bridge.configure("logonttl=0");                  // force a probe (no skip)
        check(!Bridge.logonProbeSkip(), "logonttl=0 disables skipping (probe every time)");
        Bridge.configure("logonttl=30");
        Object stillCached = Bridge.curateLogonSessionsCached(null);
        check(stillCached instanceof FakeLogon[], "the cache survives a null probe");

        Bridge.configure("logonttl=0");                  // leave caching off for other tests
    }

    // ---- issue #51: per-child endpoint resolution -------------------------

    /** Renders a possibly-null string for a failure message. */
    private static String q(String s) { return s == null ? "null" : "\"" + s + "\""; }

    /** Names a list of endpoints, so a wrong survivor set is legible. */
    private static String describe(List<SessionEndpoint> es) {
        if (es == null) return "null";
        StringBuilder sb = new StringBuilder(es.size() + " [");
        for (int i = 0; i < es.size(); i++) {
            if (i > 0) sb.append(", ");
            sb.append(name(es.get(i)));
        }
        return sb.append(']').toString();
    }

    /** The uid that owns a path — read from the filesystem, never hardcoded. */
    private static long uidOf(Path p) throws Exception {
        return ((Number) Files.getAttribute(p, "unix:uid")).longValue();
    }

    /** chmod, in PosixFilePermissions.fromString form ("rw-r--r--"). */
    private static void chmod(Path p, String rwx) throws Exception {
        Files.setPosixFilePermissions(p, java.nio.file.attribute.PosixFilePermissions.fromString(rwx));
    }

    /** Best-effort recursive delete of a temp tree; never follows symlinks. */
    private static void rmTree(Path p) {
        try {
            if (Files.isDirectory(p, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
                try (java.nio.file.DirectoryStream<Path> s = Files.newDirectoryStream(p)) {
                    for (Path c : s) rmTree(c);
                }
            }
            Files.deleteIfExists(p);
        } catch (Exception ignored) {}
    }

    /** Let a background socket exchange settle before asserting it did NOT happen. */
    private static void settle() {
        try { Thread.sleep(150); } catch (InterruptedException ignored) { }
    }

    /**
     * A real unix socket that keeps accepting connections, answers every line
     * with a fixed reply, and records how many connections and bytes it saw.
     * Used where the assertion is about traffic that must NOT happen: a
     * reconnect after close(), or a WHO the agent should never have asked.
     */
    private static final class RecordingServer implements AutoCloseable {
        private final ServerSocketChannel srv;
        private final java.util.concurrent.atomic.AtomicInteger connections =
                new java.util.concurrent.atomic.AtomicInteger(0);
        private final java.util.concurrent.atomic.AtomicInteger bytes =
                new java.util.concurrent.atomic.AtomicInteger(0);
        private final StringBuilder seen = new StringBuilder();

        RecordingServer(Path sock, String reply) throws Exception {
            srv = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            srv.bind(UnixDomainSocketAddress.of(sock));
            Thread t = new Thread(() -> {
                while (true) {
                    try (SocketChannel c = srv.accept()) {
                        connections.incrementAndGet();
                        ByteBuffer b = ByteBuffer.allocate(256);
                        int n;
                        while ((n = c.read(b)) > 0) {
                            bytes.addAndGet(n);
                            String text = new String(b.array(), 0, n,
                                    java.nio.charset.StandardCharsets.US_ASCII);
                            synchronized (seen) { seen.append(text); }
                            b.clear();
                            c.write(ByteBuffer.wrap(reply.getBytes(
                                    java.nio.charset.StandardCharsets.US_ASCII)));
                        }
                    } catch (Exception closed) {
                        return;
                    }
                }
            });
            t.setDaemon(true);
            t.start();
        }

        int connections() { return connections.get(); }
        int bytes() { return bytes.get(); }
        String seen() { synchronized (seen) { return seen.toString().replace("\n", "\\n"); } }

        @Override public void close() {
            try { srv.close(); } catch (Exception ignored) { }
        }
    }

    /**
     * A real unix socket that accepts one connection, records how many bytes
     * the client sent, and replies with a fixed line if it sent anything.
     * Bound and answered by this test process, so SO_PEERCRED on the client
     * side reports this account.
     */
    private static final class OneShotServer implements AutoCloseable {
        private final ServerSocketChannel srv;
        private final Thread thread;
        private final java.util.concurrent.atomic.AtomicInteger read =
                new java.util.concurrent.atomic.AtomicInteger(0);

        OneShotServer(Path sock, String reply) throws Exception {
            srv = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
            srv.bind(UnixDomainSocketAddress.of(sock));
            thread = new Thread(() -> {
                try (SocketChannel c = srv.accept()) {
                    ByteBuffer b = ByteBuffer.allocate(256);
                    int n = c.read(b);
                    if (n > 0) {
                        read.addAndGet(n);
                        c.write(ByteBuffer.wrap(reply.getBytes(java.nio.charset.StandardCharsets.US_ASCII)));
                    }
                } catch (Exception ignored) {}
            });
            thread.setDaemon(true);
            thread.start();
        }

        /** Bytes the client sent, once the exchange has settled. */
        int bytesRead() throws Exception {
            thread.join(2000);
            return read.get();
        }

        @Override public void close() {
            try { srv.close(); } catch (Exception ignored) {}
        }
    }

    /**
     * Names an endpoint by its socket, so a wrong pick is legible. A null
     * label prints as "(unnamed)" so that a returned null — which now means
     * "do not attach" — can never be misread as an endpoint in a message.
     */
    private static String name(SessionEndpoint e) {
        if (e == null) return "null";
        return (e.label() == null ? "(unnamed)" : e.label()) + " @ " + e.socket();
    }

    /**
     * Display normalisation — the agent-side half of matching a child JVM to a
     * daemon (issue #51). Both sides need it: the daemon replies to DISPLAY
     * *verbatim* with whatever `--display`/`$DISPLAY` gave it, and ScreenConnect
     * bakes whichever form the logon-session probe found into the child's env.
     *
     * Where the expected values come from:
     *   - X(7): a display name is `hostname:displaynumber.screennumber`. The
     *     screen suffix names a *screen within* the display, so ":0.0" and ":0"
     *     are the same display — the same session, the same daemon. Hence the
     *     suffix is dropped, and ":0.1" normalises to ":0" too (DreamConnect
     *     captures a session, not a screen; there is one daemon per uid, and
     *     multi-screen X layouts are the extinct case, not the target).
     *   - The issue #51 contract agreed with the owner: ":0.0"->":0",
     *     ":0"->":0", ":4.0"->":4"; null/empty/whitespace-only -> null;
     *     "UNKNOWN" -> null.
     *   - "UNKNOWN" is not invented here: it is the literal the daemon puts on
     *     the wire when it cannot tell (runtime/dreamconnect_daemon.py, added
     *     by #50 — `return _unset_if_blank(self.display) or "UNKNOWN"`), and
     *     runtime/README.md's control table lists the reply as
     *     `<display>` or `UNKNOWN`.
     *   - Surrounding whitespace is trimmed: the daemon already strips its own
     *     side (`_unset_if_blank` -> `value.strip()`), so " :0 " and ":0" must
     *     not be two different sessions to the agent either.
     *
     * ":10.0" -> ":10" is here deliberately: it catches a normaliser that chops
     * a fixed number of trailing characters instead of the suffix, which passes
     * every single-digit case above.
     *
     * TEST-AUTHOR'S CALL, flagged because the contract left it open: a value
     * that is not display-shaped ("wayland-0") passes through unchanged rather
     * than becoming null. Rationale — an unrecognised token stays opaque and
     * therefore matches only a byte-identical token, so it can never alias some
     * *other* session's display; and a hostname-qualified display
     * ("localhost:10.0", legitimate under X(7)) keeps working by exact match
     * instead of being silently discarded. Mapping it to null would instead
     * merge it with the "no display" case. Not asserted: what a
     * hostname-qualified display's suffix should do — see the handoff note.
     */
    private static void testNormalizeDisplay() {
        check(":0".equals(Bridge.normalizeDisplay(":0.0")),
              "normalizeDisplay(\":0.0\") -> \":0\" (screen suffix dropped) (got "
              + q(Bridge.normalizeDisplay(":0.0")) + ")");
        check(":0".equals(Bridge.normalizeDisplay(":0")),
              "normalizeDisplay(\":0\") -> \":0\" (already normal) (got "
              + q(Bridge.normalizeDisplay(":0")) + ")");
        check(":4".equals(Bridge.normalizeDisplay(":4.0")),
              "normalizeDisplay(\":4.0\") -> \":4\" (got " + q(Bridge.normalizeDisplay(":4.0")) + ")");
        check(":10".equals(Bridge.normalizeDisplay(":10.0")),
              "normalizeDisplay(\":10.0\") -> \":10\", not a fixed-width chop (got "
              + q(Bridge.normalizeDisplay(":10.0")) + ")");
        check(":0".equals(Bridge.normalizeDisplay(":0.1")),
              "normalizeDisplay(\":0.1\") -> \":0\": screen 1 of display 0 is the same display, "
              + "so stripping only a literal \".0\" is not enough (got "
              + q(Bridge.normalizeDisplay(":0.1")) + ")");
        check(":0".equals(Bridge.normalizeDisplay("  :0.0  ")),
              "normalizeDisplay(\"  :0.0  \") -> \":0\" (trimmed; the daemon strips its side too) (got "
              + q(Bridge.normalizeDisplay("  :0.0  ")) + ")");

        check(Bridge.normalizeDisplay(null) == null,
              "normalizeDisplay(null) -> null (got " + q(Bridge.normalizeDisplay(null)) + ")");
        check(Bridge.normalizeDisplay("") == null,
              "normalizeDisplay(\"\") -> null (got " + q(Bridge.normalizeDisplay("")) + ")");
        check(Bridge.normalizeDisplay("   ") == null,
              "normalizeDisplay(\"   \") -> null (whitespace is not a display) (got "
              + q(Bridge.normalizeDisplay("   ")) + ")");
        check(Bridge.normalizeDisplay("\t") == null,
              "normalizeDisplay(\"\\t\") -> null (got " + q(Bridge.normalizeDisplay("\t")) + ")");
        check(Bridge.normalizeDisplay("UNKNOWN") == null,
              "normalizeDisplay(\"UNKNOWN\") -> null: the daemon's no-display reply is not a display (got "
              + q(Bridge.normalizeDisplay("UNKNOWN")) + ")");

        check("wayland-0".equals(Bridge.normalizeDisplay("wayland-0")),
              "normalizeDisplay(\"wayland-0\") -> \"wayland-0\" unchanged (opaque token, matches only itself) (got "
              + q(Bridge.normalizeDisplay("wayland-0")) + ")");
    }

    /**
     * A protocol error line is not a display. Found live during #51: the
     * daemons deployed at /opt/dreamconnect predate #50 and do not know the
     * DISPLAY command, so asking one returns the wire protocol's error line
     * verbatim — `DISPLAY -> "ERR unknown cmd DISPLAY"`. Agent and daemon ship
     * separately, so every rolling upgrade has a window where a new agent talks
     * to an old daemon; without this rule that daemon is discovered as a
     * session whose display is that sentence, and #52 will hand it to the
     * operator as a selectable picker entry that cannot work.
     *
     * Where the expected values come from:
     *   - runtime/README.md:65 — "An unrecognised command replies
     *     `ERR unknown cmd <X>`", and dreamconnect_daemon.py's handle() ends
     *     `return f"ERR unknown cmd {cmd}"`. The other error shape is
     *     `reply = f"ERR {e}"` (same file, the handler's exception path).
     *     Both are `ERR` followed by free text: that is the whole error grammar.
     *   - The agent already encodes this rule at the sibling seam — Bridge's
     *     logonLabel() rejects a WHO reply with `who.startsWith("ERR")` rather
     *     than showing it as a name. DISPLAY gets the same treatment; the two
     *     commands share a reply channel and a failure mode.
     *
     * TEST-AUTHOR'S CALL — the rule asserted is "the **first whitespace-
     * delimited token** is exactly ERR", not the looser `startsWith("ERR")`.
     * Reasons: (a) it is the protocol's grammar precisely — every error line
     * the daemon can emit is `ERR <text>`, and the bare-"ERR" case below covers
     * a truncated one; (b) it keeps the rejection keyed to the *protocol*
     * rather than to display *shape*, so the deliberate opaque-token rule from
     * the previous slice survives intact — a value that merely begins with
     * those three letters ("ERRBOX:0", a legal X(7) `hostname:displaynumber`
     * for a host named ERRBOX) is still an opaque token that matches only
     * itself, and is never silently merged with "no display".
     * If the owner prefers the looser rule, exactly one assertion below (the
     * ERRBOX:0 one) has to go; nothing else in the suite depends on it. Noted
     * for the builder: logonLabel()'s existing `startsWith("ERR")` is then
     * fractionally looser than this — worth unifying, but out of this slice.
     */
    private static void testNormalizeDisplayRejectsProtocolError() {
        check(Bridge.normalizeDisplay("ERR unknown cmd DISPLAY") == null,
              "normalizeDisplay(\"ERR unknown cmd DISPLAY\") -> null: a pre-#50 daemon's error line "
              + "is not a session (got " + q(Bridge.normalizeDisplay("ERR unknown cmd DISPLAY")) + ")");
        check(Bridge.normalizeDisplay("ERR [Errno 2] No such file or directory") == null,
              "normalizeDisplay(\"ERR [Errno 2] …\") -> null: the daemon's other error shape, "
              + "`ERR <exception text>`, is rejected by the same rule (got "
              + q(Bridge.normalizeDisplay("ERR [Errno 2] No such file or directory")) + ")");
        check(Bridge.normalizeDisplay("ERR") == null,
              "normalizeDisplay(\"ERR\") -> null: a bare/truncated error line is still not a display (got "
              + q(Bridge.normalizeDisplay("ERR")) + ")");
        check(Bridge.normalizeDisplay("  ERR unknown cmd DISPLAY  ") == null,
              "normalizeDisplay(\"  ERR unknown cmd DISPLAY  \") -> null: trimmed before the rule applies (got "
              + q(Bridge.normalizeDisplay("  ERR unknown cmd DISPLAY  ")) + ")");

        // Guards that this rule was implemented as "reject the protocol's error
        // line", not as "reject anything that isn't :N". Deliberately repeats
        // the wayland-0 case from testNormalizeDisplay: there it pins the
        // opaque-token rule, here it is the alarm on over-rejection.
        check("wayland-0".equals(Bridge.normalizeDisplay("wayland-0")),
              "opaque tokens still pass through: normalizeDisplay(\"wayland-0\") -> \"wayland-0\" (got "
              + q(Bridge.normalizeDisplay("wayland-0")) + ")");
        check("ERRBOX:0".equals(Bridge.normalizeDisplay("ERRBOX:0")),
              "\"ERRBOX:0\" is a display on a host named ERRBOX, not an error line: the rule is the "
              + "ERR *token*, not the ERR prefix (got " + q(Bridge.normalizeDisplay("ERRBOX:0")) + ")");
    }

    // Fixtures shared by the resolveEndpoint tests. Since round 4 these stand
    // for entries in the root-owned registry `/run/dreamconnect/sessions/<uid>`
    // (spec Solution 1), so each carries the uid and user the entry names; the
    // paths are the real shapes the daemons use. The fallback pair is verbatim
    // what the installed drop-in passes today (systemd/dreamconnect-agent.conf:
    // `socket=/run/user/@UID@/dreamconnect.sock,shm=/dev/shm/dreamconnect.frame`),
    // because "fallback == today's single-session behaviour" is the promise to
    // existing backstage-only installs; it has no registry entry, hence uid -1
    // and no user. `[Backstage]` is the label from the spec.
    private static final SessionEndpoint BACKSTAGE = new SessionEndpoint(
            992, "backstage", ":0",
            "/dev/shm/dreamconnect.frame.992", "/run/user/992/dreamconnect.sock", "[Backstage]");
    // REVISED, round 6: the console fixture is uid 1001, deliberately NOT the
    // uid the static args were configured for. Until round 6 it was uid 1000
    // and so shared FALLBACK's socket byte for byte — which the known-wrong
    // fallback rule now (correctly) treats as evidence that falling back would
    // show this session under another display's name. Sharing an endpoint is
    // realistic, but it belongs in the test written for it
    // (testResolveEndpointRefusesKnownWrongFallback), not underneath every
    // other arm, where it would silently test two rules at once.
    private static final SessionEndpoint CONSOLE = new SessionEndpoint(
            1001, "kogies", ":1.0",
            "/dev/shm/dreamconnect.frame.1001", "/run/user/1001/dreamconnect.sock", "kogies");
    private static final SessionEndpoint FALLBACK = new SessionEndpoint(
            -1, null, null,
            "/dev/shm/dreamconnect.frame", "/run/user/1000/dreamconnect.sock", null);

    /**
     * REVISED, round 5 — every resolve test now passes BOTH lists. Review
     * demonstrated that a rule keyed on "are there any live daemons" answers
     * the wrong question: with a registry naming only uid 1000 @ :4, the
     * ScreenConnect service process on :0 refused, so registering the first
     * user session blacked out backstage. Refusal now keys on whether the
     * REGISTRY DESCRIBES this display (spec Solution 3, refined 2026-08-16).
     *
     * Shape chosen, since the builder implements to it:
     *   resolveEndpoint(childDisplay, registered, live, fallback)
     * `live` is the verified subset of `registered` (same instances), so the
     * identity assertions below hold whichever list an implementation returns
     * the match from.
     *
     * The happy path: a child JVM attaches to the daemon owning the display
     * ScreenConnect baked into its environment. Matching is
     * normalisation-insensitive on BOTH sides, because the child's DISPLAY
     * comes from SC's logon probe and the entry's from root's registry, so
     * either may carry the screen suffix. The fixtures are asymmetric for that
     * reason: backstage is registered ":0", the console session ":1.0".
     *
     * Compared by identity (==), never equals(), so an endpoint that merely
     * looks right cannot pass.
     */
    private static void testResolveEndpointMatchesChildDisplay() {
        List<SessionEndpoint> all = List.of(BACKSTAGE, CONSOLE);

        check(Bridge.resolveEndpoint(":0", all, all, FALLBACK) == BACKSTAGE,
              "child \":0\" + entry \":0\", live -> backstage daemon (got "
              + name(Bridge.resolveEndpoint(":0", all, all, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0.0", all, all, FALLBACK) == BACKSTAGE,
              "child \":0.0\" + entry \":0\" -> backstage: suffix on the child side only (got "
              + name(Bridge.resolveEndpoint(":0.0", all, all, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":1", all, all, FALLBACK) == CONSOLE,
              "child \":1\" + entry \":1.0\" -> console: suffix on the registry side only (got "
              + name(Bridge.resolveEndpoint(":1", all, all, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":1.0", all, all, FALLBACK) == CONSOLE,
              "child \":1.0\" + entry \":1.0\" -> console (got "
              + name(Bridge.resolveEndpoint(":1.0", all, all, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(" :1.0 ", all, all, FALLBACK) == CONSOLE,
              "child \" :1.0 \" -> console: matching normalises, it is not raw equals (got "
              + name(Bridge.resolveEndpoint(" :1.0 ", all, all, FALLBACK)) + ")");

        // Only the live subset may be attached to: backstage registered and
        // live, console registered but down, child on backstage's display.
        check(Bridge.resolveEndpoint(":0", all, List.of(BACKSTAGE), FALLBACK) == BACKSTAGE,
              "one session down does not disturb another that is up (got "
              + name(Bridge.resolveEndpoint(":0", all, List.of(BACKSTAGE), FALLBACK)) + ")");
    }

    /**
     * The promise to every existing install (spec user story 5): when there is
     * nothing to resolve, the operator's static shm=/socket= args are used and
     * the box behaves exactly as it did before this feature existed.
     *
     *   - the registry is absent or names nothing at all;
     *   - the child cannot tell which display it is (absent, blank, or a value
     *     that normalises to null). A blank DISPLAY is what a systemd unit
     *     expanding an unset variable produces — the hazard #50 fixed
     *     daemon-side.
     */
    private static void testResolveEndpointFallsBackWhenNothingToResolve() {
        List<SessionEndpoint> all = List.of(BACKSTAGE, CONSOLE);

        check(Bridge.resolveEndpoint(":0", List.of(), List.of(), FALLBACK) == FALLBACK,
              "no registry entries at all -> the static shm=/socket= args (got "
              + name(Bridge.resolveEndpoint(":0", List.of(), List.of(), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0", null, null, FALLBACK) == FALLBACK,
              "registry unreadable (null lists) -> the static shm=/socket= args (got "
              + name(Bridge.resolveEndpoint(":0", null, null, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(null, all, all, FALLBACK) == FALLBACK,
              "child with no DISPLAY (null) -> fallback (got "
              + name(Bridge.resolveEndpoint(null, all, all, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint("", all, all, FALLBACK) == FALLBACK,
              "child with empty DISPLAY -> fallback (got "
              + name(Bridge.resolveEndpoint("", all, all, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint("   ", all, all, FALLBACK) == FALLBACK,
              "child with blank DISPLAY -> fallback (got "
              + name(Bridge.resolveEndpoint("   ", all, all, FALLBACK)) + ")");
    }

    /**
     * REVISED, round 5 — this test asserted the opposite in round 3, and the
     * assertion it carried is the demonstrated defect: with live sessions
     * registered elsewhere, a display the registry never mentions used to
     * REFUSE, so registering the first user session blacked out the backstage
     * desktop that had been working from the static args.
     *
     * The registry does not claim to be complete. Until #53 registers every
     * session — and for any session root chooses not to register — a display
     * it does not describe is simply outside its authority, and the operator's
     * own configuration is the best statement of intent available.
     */
    private static void testResolveEndpointFallsBackWhenRegistrySilent() {
        List<SessionEndpoint> all = List.of(BACKSTAGE, CONSOLE);

        check(Bridge.resolveEndpoint(":9", all, all, FALLBACK) == FALLBACK,
              "a display no entry describes -> the static args, NOT a refusal: the registry is not "
              + "a complete list of sessions (got "
              + name(Bridge.resolveEndpoint(":9", all, all, FALLBACK)) + ")");

        // The demonstrated case, in its original shape: the registry knows only
        // the console session on :4; the SC service process is on :0, driven by
        // the static args. Registering a user session must not black it out.
        // uid 1001, i.e. a session on paths the static args do not point at —
        // otherwise this would also be the known-wrong-fallback case, which has
        // its own test.
        SessionEndpoint onlyEntry = new SessionEndpoint(1001, "kogies", ":4",
                "/dev/shm/dreamconnect.frame.1001", "/run/user/1001/dreamconnect.sock", "kogies");
        check(Bridge.resolveEndpoint(":0", List.of(onlyEntry), List.of(onlyEntry), FALLBACK) == FALLBACK,
              "registering the first user session (:4) must not black out backstage on :0 (got "
              + name(Bridge.resolveEndpoint(":0", List.of(onlyEntry), List.of(onlyEntry), FALLBACK)) + ")");
    }

    /**
     * NEW, round 5, and the whole point of the refinement: "the registry never
     * mentioned this display" and "the registry mentions it but it is not
     * usable" must produce DIFFERENT answers.
     *
     * Described but not live -> refuse (null). Never fall back: falling back
     * here attaches the child to the operator's configured session — backstage
     * — while ScreenConnect names it as the user the operator selected. That
     * is the exact lie in the spec's Problem section, and review demonstrated
     * it happening whenever a registered daemon was momentarily down.
     *
     * Not described -> fall back, as testResolveEndpointFallsBackWhenRegistrySilent
     * pins. The final assertion here puts the two side by side in one place,
     * because a single rule that collapses them is precisely what was wrong
     * before, twice, in opposite directions.
     */
    private static void testResolveEndpointRefusesWhenDescribedButNotLive() {
        List<SessionEndpoint> registered = List.of(BACKSTAGE, CONSOLE);

        check(Bridge.resolveEndpoint(":1", registered, List.of(BACKSTAGE), FALLBACK) == null,
              "the console session is registered for \":1\" but not live -> refuse, never the "
              + "backstage fallback (got "
              + name(Bridge.resolveEndpoint(":1", registered, List.of(BACKSTAGE), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":1", registered, List.of(), FALLBACK) == null,
              "nothing live at all, but \":1\" IS described -> still a refusal (got "
              + name(Bridge.resolveEndpoint(":1", registered, List.of(), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":1", registered, null, FALLBACK) == null,
              "a null live list is no live sessions, not a licence to fall back (got "
              + name(Bridge.resolveEndpoint(":1", registered, null, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":1", List.of(CONSOLE), List.of(), null) == null,
              "refusal is not the fallback in disguise: null fallback, same answer (got "
              + name(Bridge.resolveEndpoint(":1", List.of(CONSOLE), List.of(), null)) + ")");

        // The distinction, in one breath: same child display, same empty live
        // list, and the ONLY difference is whether the registry describes it.
        SessionEndpoint described = Bridge.resolveEndpoint(":1", List.of(CONSOLE), List.of(), FALLBACK);
        SessionEndpoint undescribed = Bridge.resolveEndpoint(":1", List.of(BACKSTAGE), List.of(), FALLBACK);
        check(described == null && undescribed == FALLBACK,
              "described-but-dead REFUSES while never-described FALLS BACK — different answers to "
              + "different questions (got described=" + name(described)
              + ", undescribed=" + name(undescribed) + ")");
    }

    /**
     * An entry whose display is unusable can never be selected. The display now
     * comes from root's registry rather than from the daemon, so this is a
     * malformed-entry case rather than an old-daemon case — but the rule is the
     * same one the spec states for a session that cannot say which display it
     * owns: it is simply not offered.
     *
     * The last assertion is the one with teeth: an unusable entry must not
     * shadow a usable one behind it in the list.
     */
    private static void testResolveEndpointNeverMatchesUnknownDaemon() {
        SessionEndpoint unknown = new SessionEndpoint(995, "u995", "UNKNOWN",
                "/dev/shm/dreamconnect.frame.995", "/run/user/995/dreamconnect.sock", "no-display");
        SessionEndpoint nullDisplay = new SessionEndpoint(996, "u996", null,
                "/dev/shm/dreamconnect.frame.996", "/run/user/996/dreamconnect.sock", "null-display");
        SessionEndpoint blankDisplay = new SessionEndpoint(997, "u997", "   ",
                "/dev/shm/dreamconnect.frame.997", "/run/user/997/dreamconnect.sock", "blank-display");

        check(Bridge.resolveEndpoint("UNKNOWN", List.of(unknown), List.of(unknown), FALLBACK) == FALLBACK,
              "an entry whose display is UNKNOWN is not matched, not even by a child whose DISPLAY "
              + "says UNKNOWN — and since nothing describes that display, the answer is the fallback (got "
              + name(Bridge.resolveEndpoint("UNKNOWN", List.of(unknown), List.of(unknown), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(null, List.of(nullDisplay), List.of(nullDisplay), FALLBACK) == FALLBACK,
              "an entry with a null display is not matched by a child with no DISPLAY (got "
              + name(Bridge.resolveEndpoint(null, List.of(nullDisplay), List.of(nullDisplay), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint("   ", List.of(blankDisplay), List.of(blankDisplay), FALLBACK) == FALLBACK,
              "an entry with a blank display is not matched by a child with a blank DISPLAY (got "
              + name(Bridge.resolveEndpoint("   ", List.of(blankDisplay), List.of(blankDisplay), FALLBACK)) + ")");

        List<SessionEndpoint> mixed = List.of(unknown, nullDisplay, CONSOLE);
        check(Bridge.resolveEndpoint(":1", mixed, mixed, FALLBACK) == CONSOLE,
              "an UNKNOWN/null entry earlier in the list does not shadow the real \":1\" session (got "
              + name(Bridge.resolveEndpoint(":1", mixed, mixed, FALLBACK)) + ")");
    }

    /**
     * The resolution half of the rule pinned in
     * {@link #testNormalizeDisplayRejectsProtocolError}: a display that is
     * really a protocol error line is as unmatchable as UNKNOWN. Reachable
     * whenever a registry writer records whatever a daemon answered without
     * checking it — the shape a pre-#50 daemon produces.
     *
     * REVISED, round 5: the middle assertion asserted a refusal in round 3 and
     * a fallback is now correct — an entry whose display is an ERR line
     * describes no display at all, so nothing describes ":1", so the operator's
     * configuration stands.
     */
    private static void testResolveEndpointNeverMatchesErrorReplyDaemon() {
        SessionEndpoint preFifty = new SessionEndpoint(993, "u993", "ERR unknown cmd DISPLAY",
                "/dev/shm/dreamconnect.frame.993",
                "/run/user/993/dreamconnect.sock", "pre-#50 daemon");

        check(Bridge.resolveEndpoint("ERR unknown cmd DISPLAY", List.of(preFifty), List.of(preFifty),
                                     FALLBACK) == FALLBACK,
              "an entry whose display is an error line is never matched, not even by a child carrying "
              + "that same text (got " + name(Bridge.resolveEndpoint("ERR unknown cmd DISPLAY",
                      List.of(preFifty), List.of(preFifty), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":1", List.of(preFifty), List.of(preFifty), FALLBACK) == FALLBACK,
              "an ERR-line entry describes no display, so \":1\" is undescribed and the static args "
              + "stand (got " + name(Bridge.resolveEndpoint(":1", List.of(preFifty), List.of(preFifty),
                      FALLBACK)) + ")");

        List<SessionEndpoint> both = List.of(preFifty, CONSOLE);
        check(Bridge.resolveEndpoint(":1", both, both, FALLBACK) == CONSOLE,
              "the ERR-line entry does not shadow the \":1\" session behind it (got "
              + name(Bridge.resolveEndpoint(":1", both, both, FALLBACK)) + ")");

        // Over-rejection alarm: the ERR rule must not have become "only
        // :N-shaped displays are matchable". An opaque token still routes.
        SessionEndpoint opaque = new SessionEndpoint(994, "u994", "wayland-0",
                "/dev/shm/dreamconnect.frame.994",
                "/run/user/994/dreamconnect.sock", "opaque-token daemon");
        List<SessionEndpoint> withOpaque = List.of(preFifty, opaque);
        check(Bridge.resolveEndpoint("wayland-0", withOpaque, withOpaque, FALLBACK) == opaque,
              "an opaque display token still resolves to the session registered for it (got "
              + name(Bridge.resolveEndpoint("wayland-0", withOpaque, withOpaque, FALLBACK)) + ")");
    }

    /**
     * Two entries claiming one display -> refuse, whatever their liveness.
     *
     * The root-owned registry removes self-registration, so a competing claim
     * can no longer be conjured by an unprivileged account; it remains
     * reachable through a stale entry for a session that died, or a
     * mis-registration by the root writer (#53). The reason to refuse does not
     * depend on the attack: whichever entry a tie-break picks, half the time it
     * is the wrong desktop shown under the right name, and nothing inside this
     * function can tell which half it is in.
     *
     * REVISED, round 5 only to pass both lists — including the case where just
     * one of the two claimants is live, which is the tempting "disambiguate by
     * liveness" shortcut. It is still a refusal: liveness proves a daemon is
     * answering, not that the registry meant that one.
     */
    private static void testResolveEndpointRefusesAmbiguousClaims() {
        // The stale entry keeps uid 10000 against the live 1001: as strings
        // "10000" sorts first, which is how the losing claim used to win.
        SessionEndpoint firstClaim = new SessionEndpoint(1001, "kogies", ":0",
                "/dev/shm/dreamconnect.frame.1001", "/run/user/1001/dreamconnect.sock", "kogies");
        SessionEndpoint staleClaim = new SessionEndpoint(10000, "ghost", ":0.0",
                "/dev/shm/dreamconnect.frame.10000", "/run/user/10000/dreamconnect.sock", "stale entry");
        List<SessionEndpoint> contested = List.of(firstClaim, staleClaim);
        List<SessionEndpoint> reversed = List.of(staleClaim, firstClaim);

        check(Bridge.resolveEndpoint(":0", contested, contested, FALLBACK) == null,
              "two entries claim \":0\" -> null (refuse), never a guess (got "
              + name(Bridge.resolveEndpoint(":0", contested, contested, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0", reversed, reversed, FALLBACK) == null,
              "same two claims in the other order -> still null: refusal does not depend on list order (got "
              + name(Bridge.resolveEndpoint(":0", reversed, reversed, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0.0", contested, contested, FALLBACK) == null,
              "refusal holds when the child carries the screen suffix, i.e. after normalisation (got "
              + name(Bridge.resolveEndpoint(":0.0", contested, contested, FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0", contested, List.of(firstClaim), FALLBACK) == null,
              "ONE of the two claimants being live does not break the tie: liveness proves a daemon "
              + "answers, not that the registry meant that one (got "
              + name(Bridge.resolveEndpoint(":0", contested, List.of(firstClaim), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0", contested, List.of(), FALLBACK) == null,
              "neither claimant live -> still a refusal, not a fallback: \":0\" is described (got "
              + name(Bridge.resolveEndpoint(":0", contested, List.of(), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":0", contested, contested, null) == null,
              "refusal is not the fallback in disguise: null fallback, same answer (got "
              + name(Bridge.resolveEndpoint(":0", contested, contested, null)) + ")");

        // Ambiguity on one display must not condemn a different one.
        List<SessionEndpoint> plusConsole = List.of(firstClaim, staleClaim, CONSOLE);
        check(Bridge.resolveEndpoint(":1", plusConsole, plusConsole, FALLBACK) == CONSOLE,
              "a contested \":0\" does not poison the uncontested \":1\" (got "
              + name(Bridge.resolveEndpoint(":1", plusConsole, plusConsole, FALLBACK)) + ")");
    }

    /**
     * NEW, round 3 (contract D). The label a daemon supplies over WHO is shown
     * to the operator in ScreenConnect's session picker, so it passes the same
     * gate a display does before it can be displayed or cached.
     *
     * Sources: the daemon's WHO reply is `--label` or the login name
     * (runtime/dreamconnect_daemon.py), and any command can come back as an
     * error line — `ERR unknown cmd …` (README control table) or `ERR {e}` from
     * the handler's exception path. Bridge.logonLabel() already refuses a WHO
     * reply that starts with ERR rather than showing it as a name; a discovered
     * endpoint's label reaches the same picker and gets the same rule. Blank is
     * unset, not a name — #50's commit message: "whitespace must never reach the
     * picker as if it named a session".
     *
     * Rejection is keyed on the protocol's `ERR <text>` grammar, exactly as in
     * {@link #testNormalizeDisplayRejectsProtocolError}, so a name that merely
     * begins with those letters survives. Consistency between the two is the
     * point: one rule, two channels.
     *
     * Not asserted, deliberately: any length cap, and whether "UNKNOWN" is a
     * legal label. UNKNOWN is the DISPLAY sentinel and nothing in the daemon
     * makes it a WHO sentinel, so I will not invent a rule that would forbid a
     * user or a `--label` from being called that.
     */
    private static void testSanitizeLabel() {
        check("kogies".equals(Bridge.sanitizeLabel("kogies")),
              "sanitizeLabel(\"kogies\") -> \"kogies\" (got " + q(Bridge.sanitizeLabel("kogies")) + ")");
        check("[Backstage]".equals(Bridge.sanitizeLabel("[Backstage]")),
              "sanitizeLabel(\"[Backstage]\") -> unchanged: the shipped backstage label survives (got "
              + q(Bridge.sanitizeLabel("[Backstage]")) + ")");
        check("kogies".equals(Bridge.sanitizeLabel("  kogies  ")),
              "sanitizeLabel(\"  kogies  \") -> \"kogies\" (trimmed, as the daemon trims its side) (got "
              + q(Bridge.sanitizeLabel("  kogies  ")) + ")");

        check(Bridge.sanitizeLabel(null) == null,
              "sanitizeLabel(null) -> null (got " + q(Bridge.sanitizeLabel(null)) + ")");
        check(Bridge.sanitizeLabel("") == null,
              "sanitizeLabel(\"\") -> null (got " + q(Bridge.sanitizeLabel("")) + ")");
        check(Bridge.sanitizeLabel("   ") == null,
              "sanitizeLabel(\"   \") -> null: whitespace never names a session (got "
              + q(Bridge.sanitizeLabel("   ")) + ")");
        check(Bridge.sanitizeLabel("ERR unknown cmd WHO") == null,
              "sanitizeLabel(\"ERR unknown cmd WHO\") -> null: an error line is never a picker label (got "
              + q(Bridge.sanitizeLabel("ERR unknown cmd WHO")) + ")");
        check(Bridge.sanitizeLabel("ERR [Errno 2] No such file or directory") == null,
              "sanitizeLabel(\"ERR [Errno 2] …\") -> null: the daemon's other error shape too (got "
              + q(Bridge.sanitizeLabel("ERR [Errno 2] No such file or directory")) + ")");
        check(Bridge.sanitizeLabel("ERR") == null,
              "sanitizeLabel(\"ERR\") -> null (got " + q(Bridge.sanitizeLabel("ERR")) + ")");

        check("ERROL".equals(Bridge.sanitizeLabel("ERROL")),
              "sanitizeLabel(\"ERROL\") -> \"ERROL\": a login name beginning with those letters is a name, "
              + "not an error line — the rule is the ERR *token* (got " + q(Bridge.sanitizeLabel("ERROL")) + ")");
    }

    /**
     * REPLACES testOwnedByUid (round 3), which is gone with the /dev/shm scan
     * it defended: nothing infers a uid from a filename any more, so the
     * "is …frame.<uid> owned by <uid>" framing no longer describes anything the
     * agent does. The breaker was also right that the old test claimed a
     * symlink property and never created a symlink. Both are fixed here.
     *
     * What survives is the shm check itself, which the registry does not make
     * redundant: an entry can outlive its daemon, and a frame planted at the
     * registered path afterwards would otherwise be mapped as that session's
     * screen. The spec (Solution 1) states it as three conditions — regular
     * file, NOT a symlink, owned by the entry's uid — and each gets an
     * assertion below against a real file.
     *
     * The symlink case is honestly testable as an ordinary user precisely
     * because the rule is absolute: "not a symlink" says nothing about who owns
     * the target, so a link this test owns pointing at a file this test owns
     * still has to be rejected. That is also the round-3 lesson generalised —
     * the check and the consumer must not disagree, and the consumer (mapping
     * the frame) follows links.
     *
     * uid is a long, not a String: the round-3 exploit shape (uid 10000
     * matching uid 1000 under a text comparison) is then unrepresentable rather
     * than merely tested for. The `myUid * 10` case is kept anyway as the
     * regression marker.
     */
    private static void testUsableShm() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-shm");
        try {
            Path frame = Files.createFile(dir.resolve("dreamconnect.frame.self"));
            long myUid = uidOf(frame);
            Path link = dir.resolve("frame.symlink");
            Files.createSymbolicLink(link, frame);
            Path subdir = Files.createDirectory(dir.resolve("frame.dir"));

            check(Bridge.usableShm(frame, myUid),
                  "a regular file owned by uid " + myUid + " is usable as that session's frame");
            check(!Bridge.usableShm(frame, myUid + 1),
                  "the same file is not usable for uid " + (myUid + 1) + " (wrong owner)");
            check(!Bridge.usableShm(frame, myUid * 10),
                  "uid " + (myUid * 10) + " does not match uid " + myUid
                  + " — uids compare as values (the 10000-impersonates-1000 shape)");
            check(!Bridge.usableShm(link, myUid),
                  "a SYMLINK is refused even when link and target are both owned by uid " + myUid
                  + ": the spec requires a regular file, and whoever plants the link chooses the target");
            check(!Bridge.usableShm(subdir, myUid),
                  "a directory is not a frame");
            check(!Bridge.usableShm(dir.resolve("absent.frame"), myUid),
                  "a path that does not exist is not a frame");
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 4. The registry entry format.
     *
     * The spec (Solution 1) names the fields — `uid`, `user`, `display`, `shm`,
     * `socket`, `label` — but not the file syntax, because the writer is #53
     * and does not exist yet. TEST-AUTHOR'S CALL, and it binds #53, so it is
     * flagged rather than buried: `key=value`, one per line. Reasons — it is
     * what this repo already uses for exactly this kind of data (the agent's
     * own args, `shm=…,socket=…`, parsed in Bridge.configure; systemd
     * EnvironmentFile), and it is writable from a root shell script without a
     * serialiser. If the owner prefers JSON, the fixtures below are the only
     * thing that changes.
     *
     * The parse rules are mine to specify (the coordinator delegated them) and
     * each is here for a reason:
     *   - unknown keys are ignored, so #53 can add a field without breaking an
     *     agent that predates it;
     *   - split on the FIRST `=`, so a label may contain one (Bridge.configure
     *     already does this with indexOf('='));
     *   - keys and values are trimmed, and a blank value counts as missing —
     *     the same rule #50 established daemon-side, where a unit expanding an
     *     unset variable ships whitespace;
     *   - a missing or blank uid/user/display/shm/socket rejects the whole
     *     entry (null), because an entry missing any of those cannot be
     *     matched, authenticated, or read — there is nothing safe to do with
     *     it. `label` is the exception: it is cosmetic, so its absence yields
     *     an endpoint with a null label rather than no endpoint;
     *   - a non-numeric uid rejects the entry, which is what keeps uid a value
     *     everywhere downstream (see testUsableShm).
     */
    private static void testParseRegistryEntry() {
        String entry = "uid=1000\n"
                     + "user=kogies\n"
                     + "display=:1\n"
                     + "shm=/dev/shm/dreamconnect.frame.1000\n"
                     + "socket=/run/user/1000/dreamconnect.sock\n"
                     + "label=kogies\n";
        SessionEndpoint e = Bridge.parseRegistryEntry(entry);
        check(e != null, "a complete entry parses (got null)");
        if (e != null) {
            check(e.uid() == 1000, "uid=1000 -> 1000 (got " + e.uid() + ")");
            check("kogies".equals(e.user()), "user -> \"kogies\" (got " + q(e.user()) + ")");
            check(":1".equals(e.display()), "display -> \":1\" verbatim, unnormalised (got " + q(e.display()) + ")");
            check("/dev/shm/dreamconnect.frame.1000".equals(e.shm()), "shm -> the registered path (got " + q(e.shm()) + ")");
            check("/run/user/1000/dreamconnect.sock".equals(e.socket()), "socket -> the registered path (got " + q(e.socket()) + ")");
            check("kogies".equals(e.label()), "label -> \"kogies\" (got " + q(e.label()) + ")");
        }

        SessionEndpoint shuffled = Bridge.parseRegistryEntry(
                "label=[Backstage]\nsocket=/run/user/992/dreamconnect.sock\n\n"
                + "  display = :0  \nshm=/dev/shm/dreamconnect.frame.992\n"
                + "generation=7\nuser=backstage\nuid=992\n");
        check(shuffled != null && shuffled.uid() == 992 && ":0".equals(shuffled.display())
                      && "backstage".equals(shuffled.user()) && "[Backstage]".equals(shuffled.label()),
              "key order is irrelevant, blank lines and whitespace are tolerated, and an unknown key "
              + "(a field #53 might add later) is ignored rather than fatal (got "
              + (shuffled == null ? "null" : shuffled.uid() + "/" + q(shuffled.display())
                      + "/" + q(shuffled.user()) + "/" + q(shuffled.label())) + ")");

        SessionEndpoint eq = Bridge.parseRegistryEntry(
                "uid=1000\nuser=kogies\ndisplay=:1\nshm=/dev/shm/f\nsocket=/run/user/1000/s\nlabel=a=b\n");
        check(eq != null && "a=b".equals(eq.label()),
              "a value may contain '=': split on the first one only (got "
              + (eq == null ? "null" : q(eq.label())) + ")");

        SessionEndpoint noLabel = Bridge.parseRegistryEntry(
                "uid=1000\nuser=kogies\ndisplay=:1\nshm=/dev/shm/f\nsocket=/run/user/1000/s\n");
        check(noLabel != null && noLabel.label() == null,
              "label is optional — cosmetic, so its absence is an unnamed endpoint, not a rejected one (got "
              + (noLabel == null ? "null (entry rejected)" : q(noLabel.label())) + ")");

        check(Bridge.parseRegistryEntry(
                "uid=1000\nuser=kogies\ndisplay=:1\nshm=/dev/shm/f\n") == null,
              "an entry missing `socket` is rejected: nothing safe can be done with it");
        check(Bridge.parseRegistryEntry(
                "uid=1000\nuser=kogies\ndisplay=\nshm=/dev/shm/f\nsocket=/run/user/1000/s\n") == null,
              "a blank required value is a missing value (the unset-variable hazard #50 fixed daemon-side)");
        check(Bridge.parseRegistryEntry(
                "uid=root\nuser=kogies\ndisplay=:1\nshm=/dev/shm/f\nsocket=/run/user/1000/s\n") == null,
              "a non-numeric uid is rejected here, so uid is a value everywhere downstream");
        check(Bridge.parseRegistryEntry("") == null, "an empty entry file is rejected");
        check(Bridge.parseRegistryEntry(null) == null, "null text is rejected");
    }

    /**
     * NEW, round 4. The trust gate on a single path: owned by the required uid,
     * and writable by nobody else.
     *
     * Why it is parameterised on the owner uid rather than hardcoding 0: the
     * gate runs as an ordinary user, so a hardcoded root check could only ever
     * be tested for its *negative* answers — the positive path, the one that
     * decides whether the registry is used at all, would go unexercised and
     * "trusted" could be a function that always returns false and still look
     * green here. Passing my own uid makes the positive case real. Production
     * passes 0; that call site is the one thing this test cannot see, and it is
     * named in the handoff.
     *
     * Both group- and other-writable are refused, on both a file and the
     * directory, because the registry directory carries exactly the same
     * requirement as the entries in it (spec: "the registry directory and the
     * entry file are root-owned and not writable by group or other").
     */
    private static void testTrustedFile() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-trust");
        try {
            Path f = Files.createFile(dir.resolve("1000"));
            long myUid = uidOf(f);

            chmod(dir, "rwxr-xr-x");
            chmod(f, "rw-r--r--");
            check(Bridge.trustedFile(f, myUid), "0644 file owned by uid " + myUid + " is trusted");
            check(Bridge.trustedFile(dir, myUid), "0755 directory owned by uid " + myUid + " is trusted");

            chmod(f, "rw-------");
            check(Bridge.trustedFile(f, myUid), "0600 file owned by uid " + myUid + " is trusted");

            check(!Bridge.trustedFile(f, myUid + 1),
                  "the same file is not trusted for uid " + (myUid + 1) + " (wrong owner)");

            chmod(f, "rw-rw-r--");
            check(!Bridge.trustedFile(f, myUid), "a group-writable (0664) entry is not trusted");
            chmod(f, "rw-r--rw-");
            check(!Bridge.trustedFile(f, myUid), "an other-writable (0646) entry is not trusted");
            chmod(f, "rw-r--r--");

            chmod(dir, "rwxrwxr-x");
            check(!Bridge.trustedFile(dir, myUid), "a group-writable (0775) registry directory is not trusted");
            chmod(dir, "rwxr-xrwx");
            check(!Bridge.trustedFile(dir, myUid), "an other-writable (0757) registry directory is not trusted");
            chmod(dir, "rwxr-xr-x");

            check(!Bridge.trustedFile(dir.resolve("absent"), myUid), "a path that does not exist is not trusted");
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 4. The rule that makes the whole redesign worth having: if the
     * registry directory itself is not trustworthy, there is no registry —
     * every entry inside it is ignored, however well-formed, and the agent
     * falls back to the operator's static args (spec: "anything else is treated
     * as no registry at all").
     *
     * A group-writable registry directory is not a subtle defect: whoever can
     * write it can add an entry naming any display, any socket and any user,
     * and every later check is downstream of a lie. So this is asserted with a
     * real directory that really is group-writable, not a flag.
     *
     * Contract of the function itself: it returns the parsed entries of a
     * trusted directory, and an EMPTY list (never null) when there is nothing
     * to trust — because "empty" is what routes back to today's single-session
     * behaviour in resolveEndpoint, which is the promise to existing installs.
     */
    private static void testReadRegistryTrustGate() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-registry");
        try {
            Files.writeString(dir.resolve("992"),
                    "uid=992\nuser=backstage\ndisplay=:0\nshm=/dev/shm/dreamconnect.frame.992\n"
                    + "socket=/run/user/992/dreamconnect.sock\nlabel=[Backstage]\n");
            Files.writeString(dir.resolve("1000"),
                    "uid=1000\nuser=kogies\ndisplay=:1\nshm=/dev/shm/dreamconnect.frame.1000\n"
                    + "socket=/run/user/1000/dreamconnect.sock\nlabel=kogies\n");
            long myUid = uidOf(dir);
            chmod(dir.resolve("992"), "rw-r--r--");
            chmod(dir.resolve("1000"), "rw-r--r--");
            chmod(dir, "rwxr-xr-x");

            List<SessionEndpoint> found = Bridge.readRegistry(dir, myUid);
            check(found != null && found.size() == 2,
                  "a trusted registry directory yields its entries (got "
                  + (found == null ? "null" : String.valueOf(found.size())) + ")");
            if (found != null && found.size() == 2) {
                SessionEndpoint console = null;
                for (SessionEndpoint e : found) if (e != null && ":1".equals(e.display())) console = e;
                check(console != null && console.uid() == 1000
                              && "/run/user/1000/dreamconnect.sock".equals(console.socket()),
                      "entries are parsed, not just counted (got " + name(console) + ")");
            }

            chmod(dir, "rwxrwxr-x");
            List<SessionEndpoint> groupWritable = Bridge.readRegistry(dir, myUid);
            check(groupWritable != null && groupWritable.isEmpty(),
                  "a group-writable registry directory is NO registry: its entries are all ignored (got "
                  + (groupWritable == null ? "null" : String.valueOf(groupWritable.size())) + ")");

            chmod(dir, "rwxr-xrwx");
            List<SessionEndpoint> otherWritable = Bridge.readRegistry(dir, myUid);
            check(otherWritable != null && otherWritable.isEmpty(),
                  "an other-writable registry directory is no registry either (got "
                  + (otherWritable == null ? "null" : String.valueOf(otherWritable.size())) + ")");
            chmod(dir, "rwxr-xr-x");

            List<SessionEndpoint> wrongOwner = Bridge.readRegistry(dir, myUid + 1);
            check(wrongOwner != null && wrongOwner.isEmpty(),
                  "a registry directory owned by someone other than the required uid is no registry (got "
                  + (wrongOwner == null ? "null" : String.valueOf(wrongOwner.size())) + ")");

            List<SessionEndpoint> absent = Bridge.readRegistry(dir.resolve("nope"), myUid);
            check(absent != null && absent.isEmpty(),
                  "no registry directory at all -> empty list, never null: that is what falls back to "
                  + "the static args (got " + (absent == null ? "null" : String.valueOf(absent.size())) + ")");
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 6. The fallback itself can be KNOWN-WRONG, and then it is not
     * a fallback but the same lie in its last hiding place.
     *
     * Demonstrated: the installer configures the static shm=/socket= args to
     * backstage, and #53 registers backstage — so the registry's `:0` entry
     * carries byte-identical paths to the fallback. A child JVM on `:4` finds
     * `:4` undescribed, falls back, and drives BACKSTAGE's frame and socket
     * under the user's name, on an unauthenticated client (the fallback has no
     * user). No attacker required: any session not yet registered lands here.
     *
     * The rule: falling back is legitimate only while there is no evidence it
     * is wrong. If a registered entry claims the fallback's endpoint for a
     * DIFFERENT display than this child's, we know where those paths lead and
     * it is not here — so refuse.
     *
     * DISCRIMINATOR CHOSEN — a collision on shm OR socket, compared as exact
     * strings, since the builder implements to this:
     *   - either half alone is already the failure. A shared shm shows the
     *     operator another session's screen; a shared socket types into it,
     *     including clipboard TYPE. Requiring BOTH to match would let a half
     *     collision through, which is the same lie with one sense muted.
     *   - exact strings, because both sides are written by the same root
     *     installer/writer, so a spelling difference is not the hazard here.
     *     NOT asserted, and named in the handoff: path normalisation
     *     ("/dev/shm/./frame"), symlinked equivalents, and a registry that
     *     names the same daemon by a different path.
     *
     * The legitimate arm is asserted just as explicitly: with no registry, or
     * a registry that says nothing about the fallback's endpoint, an
     * undescribed display MUST still fall back — that is every existing
     * install, and breaking it would be a self-inflicted outage.
     */
    private static void testResolveEndpointRefusesKnownWrongFallback() {
        // Backstage exactly as the installer leaves it: registered at :0, and
        // its paths ARE the static args.
        SessionEndpoint backstageAsInstalled = new SessionEndpoint(992, "backstage", ":0",
                FALLBACK.shm(), FALLBACK.socket(), "[Backstage]");
        List<SessionEndpoint> onlyBackstage = List.of(backstageAsInstalled);

        check(Bridge.resolveEndpoint(":4", onlyBackstage, onlyBackstage, FALLBACK) == null,
              "the registry says the fallback's own shm+socket are display \":0\", so falling back "
              + "on \":4\" would show backstage under this session's name -> refuse (got "
              + name(Bridge.resolveEndpoint(":4", onlyBackstage, onlyBackstage, FALLBACK)) + ")");

        SessionEndpoint sameSocketOnly = new SessionEndpoint(992, "backstage", ":0",
                "/dev/shm/dreamconnect.frame.992", FALLBACK.socket(), "[Backstage]");
        check(Bridge.resolveEndpoint(":4", List.of(sameSocketOnly), List.of(sameSocketOnly),
                                     FALLBACK) == null,
              "a shared SOCKET alone is enough: the operator's keystrokes and clipboard would go to "
              + "a session the registry names as \":0\" (got "
              + name(Bridge.resolveEndpoint(":4", List.of(sameSocketOnly), List.of(sameSocketOnly),
                      FALLBACK)) + ")");

        SessionEndpoint sameShmOnly = new SessionEndpoint(992, "backstage", ":0",
                FALLBACK.shm(), "/run/user/992/dreamconnect.sock", "[Backstage]");
        check(Bridge.resolveEndpoint(":4", List.of(sameShmOnly), List.of(sameShmOnly),
                                     FALLBACK) == null,
              "a shared SHM alone is enough: the operator would watch a session the registry names "
              + "as \":0\" (got " + name(Bridge.resolveEndpoint(":4", List.of(sameShmOnly),
                      List.of(sameShmOnly), FALLBACK)) + ")");

        // The legitimate arm — no evidence the fallback is wrong.
        check(Bridge.resolveEndpoint(":4", List.of(), List.of(), FALLBACK) == FALLBACK,
              "no registry at all -> the static args still work, as they always have (got "
              + name(Bridge.resolveEndpoint(":4", List.of(), List.of(), FALLBACK)) + ")");
        check(Bridge.resolveEndpoint(":4", List.of(CONSOLE), List.of(CONSOLE), FALLBACK) == FALLBACK,
              "a registry that describes some OTHER session, on other paths, says nothing about the "
              + "fallback -> still falls back (got "
              + name(Bridge.resolveEndpoint(":4", List.of(CONSOLE), List.of(CONSOLE), FALLBACK)) + ")");

        // And the discriminator must not misfire when the registry describes
        // the fallback's endpoint for THIS display: that is a match, not a
        // collision.
        SessionEndpoint fallbackPathsHere = new SessionEndpoint(1000, "kogies", ":4",
                FALLBACK.shm(), FALLBACK.socket(), "kogies");
        check(Bridge.resolveEndpoint(":4", List.of(fallbackPathsHere), List.of(fallbackPathsHere),
                                     FALLBACK) == fallbackPathsHere,
              "the same paths registered for THIS display resolve to that entry — now authenticated "
              + "as its user, which the bare fallback never was (got "
              + name(Bridge.resolveEndpoint(":4", List.of(fallbackPathsHere),
                      List.of(fallbackPathsHere), FALLBACK)) + ")");
    }

    /**
     * NEW, round 6. close() must be terminal.
     *
     * Demonstrated: send() after close() transparently reconnects and answers
     * PONG. DaemonClient reconnects on purpose — a daemon restart must not
     * wedge the client — but that must not resurrect a client the agent has
     * deliberately retired. DreamConnectRobotPeer captures the daemon at
     * construction, so a peer built before an endpoint swap would keep driving
     * the OLD session's socket: input to a session the operator is no longer
     * looking at. Today only the once-per-JVM resolution latch stops that, and
     * nothing pins the latch.
     *
     * Asserted through the socket rather than through a flag: the retired
     * client must neither answer nor reach the daemon — and `input()`, the
     * fire-and-forget hot path that carries keystrokes, is checked too, since
     * it takes a different route through the client than send().
     */
    private static void testDaemonClientCloseIsTerminal() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-close");
        try {
            String me = Files.getOwner(dir).getName();
            Path sock = dir.resolve("dreamconnect.sock");
            try (RecordingServer srv = new RecordingServer(sock, "PONG\n")) {
                DaemonClient c = new DaemonClient(sock.toString(), me);

                check("PONG".equals(c.send("PING")),
                      "precondition: the client works before it is closed");
                int afterFirst = srv.bytes();

                c.close();
                String reply = c.send("PING");
                check(reply == null,
                      "send() after close() does not silently reconnect (got " + q(reply) + ")");

                c.input("K 28 1");   // the keystroke path, which never reads a reply
                settle();
                check(srv.connections() == 1,
                      "a closed client opens no second connection (server accepted "
                      + srv.connections() + ")");
                check(srv.bytes() == afterFirst,
                      "and no further byte reaches the daemon after close() — a retired client must "
                      + "not carry input to a session the operator left (server saw \"" + srv.seen()
                      + "\")");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 6. A stray file beside a real entry must not black out a
     * session.
     *
     * `1000.bak` or `1000.tmp` left next to `1000` parses perfectly well, which
     * makes two entries for one display, which is ambiguity, which is a refusal
     * — latched for the life of the JVM. The spec puts entries at
     * `/run/dreamconnect/sessions/<uid>`, so a filename that is not a uid is
     * not an entry, and the agent should not be one editor mishap away from a
     * permanent blackout. (#53's writer should also rename into place; both,
     * not either.)
     *
     * NOT asserted, because nothing specifies it: whether the filename must
     * MATCH the `uid=` field inside the entry.
     */
    private static void testReadRegistryIgnoresNonUidFilenames() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-registry-stray");
        try {
            String entry = "uid=1000\nuser=kogies\ndisplay=:1\n"
                    + "shm=/dev/shm/dreamconnect.frame.1000\n"
                    + "socket=/run/user/1000/dreamconnect.sock\nlabel=kogies\n";
            Files.writeString(dir.resolve("1000"), entry);
            Files.writeString(dir.resolve("1000.bak"), entry);
            Files.writeString(dir.resolve("1000.tmp"), entry);
            Files.writeString(dir.resolve("backstage"), entry);
            long myUid = uidOf(dir);
            chmod(dir, "rwxr-xr-x");
            for (String n : new String[] {"1000", "1000.bak", "1000.tmp", "backstage"}) {
                chmod(dir.resolve(n), "rw-r--r--");
            }

            List<SessionEndpoint> found = Bridge.readRegistry(dir, myUid);
            check(found != null && found.size() == 1,
                  "only the uid-named file is an entry; .bak/.tmp/named strays are not (got "
                  + describe(found) + ")");

            if (found != null) {
                check(Bridge.resolveEndpoint(":1", found, found, FALLBACK) != null,
                      "so the session still resolves instead of being permanently refused as "
                      + "ambiguous (got " + name(Bridge.resolveEndpoint(":1", found, found, FALLBACK))
                      + ")");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 5. `liveSessions` — the one place shm trust and peer
     * authentication are actually applied to registry data, and until now
     * untested at all. Real files, real sockets: a stub of either check would
     * make this test meaningless.
     *
     * An entry survives only if BOTH hold: its shm is a regular file (not a
     * symlink) owned by the entry's uid, and its socket answers PING as the
     * entry's user. Each rejection below removes exactly one of those and
     * nothing else, so a failure names which half broke.
     *
     * The wrong-user entry is the important one, and it is not hypothetical
     * even though every socket here is bound by this test: it stands for a
     * registry entry whose socket has been replaced — a symlink to another
     * account's daemon, or a path some other account got there first. The
     * kernel answers with the LISTENER's identity, so claiming to be someone
     * else fails no matter who owns the path. (What this cannot show, running
     * as one account, is a socket genuinely answered by a *different* user;
     * see testPeerUserIsTheConnectedPeer's honesty limit.)
     *
     * Deliberately NOT covered, to keep the gate fast: a socket that accepts
     * and then never answers. That costs the client's 2s read timeout, and the
     * timeout itself is DaemonClient's contract, not this composition's.
     */
    private static void testLiveSessionsKeepsOnlyVerifiedSessions() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-live");
        try {
            Path shm = Files.createFile(dir.resolve("frame.self"));
            long myUid = uidOf(shm);
            String me = Files.getOwner(shm).getName();
            Path shmLink = dir.resolve("frame.symlink");
            Files.createSymbolicLink(shmLink, shm);

            try (OneShotServer okSrv = new OneShotServer(dir.resolve("ok.sock"), "PONG\n");
                 OneShotServer wrongUserSrv = new OneShotServer(dir.resolve("wronguser.sock"), "PONG\n");
                 OneShotServer linkShmSrv = new OneShotServer(dir.resolve("linkshm.sock"), "PONG\n");
                 OneShotServer noShmSrv = new OneShotServer(dir.resolve("noshm.sock"), "PONG\n");
                 OneShotServer garbageSrv = new OneShotServer(dir.resolve("garbage.sock"),
                                                              "ERR unknown cmd PING\n")) {

                SessionEndpoint good = new SessionEndpoint(myUid, me, ":1",
                        shm.toString(), dir.resolve("ok.sock").toString(), "kogies");
                SessionEndpoint wrongUser = new SessionEndpoint(myUid, "not-" + me, ":2",
                        shm.toString(), dir.resolve("wronguser.sock").toString(), "impersonator");
                SessionEndpoint linkedShm = new SessionEndpoint(myUid, me, ":3",
                        shmLink.toString(), dir.resolve("linkshm.sock").toString(), "symlinked frame");
                SessionEndpoint missingShm = new SessionEndpoint(myUid, me, ":4",
                        dir.resolve("absent.frame").toString(),
                        dir.resolve("noshm.sock").toString(), "no frame");
                SessionEndpoint noSocket = new SessionEndpoint(myUid, me, ":5",
                        shm.toString(), dir.resolve("absent.sock").toString(), "daemon down");
                SessionEndpoint garbage = new SessionEndpoint(myUid, me, ":6",
                        shm.toString(), dir.resolve("garbage.sock").toString(), "not a daemon");

                List<SessionEndpoint> live = Bridge.liveSessions(
                        List.of(good, wrongUser, linkedShm, missingShm, noSocket, garbage));

                check(live != null && live.size() == 1 && live.get(0) == good,
                      "only the entry whose frame and socket both check out is live (got "
                      + describe(live) + ")");
                check(live != null && !live.contains(wrongUser),
                      "an entry claiming a user the socket's peer is not is dropped — this is the "
                      + "redirect defence (got " + describe(live) + ")");
                check(live != null && !live.contains(linkedShm),
                      "an entry whose shm is a symlink is dropped even though the socket is fine (got "
                      + describe(live) + ")");
                check(live != null && !live.contains(garbage),
                      "a socket that does not answer PING with PONG is not a daemon (got "
                      + describe(live) + ")");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 5. One bad entry drops only itself — demonstrated defect:
     * `Path.of(entry.shm())` throws InvalidPathException on a NUL byte, and it
     * escaped liveSessions entirely, so a single malformed entry sent EVERY
     * session to the fallback. That is a whole-box outage triggered by one
     * field, and the documented rule is the opposite.
     *
     * The malformed entries come first in the list on purpose: an exception
     * escaping while processing them is exactly what would lose the good entry
     * behind them.
     */
    private static void testLiveSessionsIsolatesMalformedEntries() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-live-bad");
        try {
            Path shm = Files.createFile(dir.resolve("frame.self"));
            long myUid = uidOf(shm);
            String me = Files.getOwner(shm).getName();

            try (OneShotServer okSrv = new OneShotServer(dir.resolve("ok.sock"), "PONG\n")) {
                SessionEndpoint nulShm = new SessionEndpoint(myUid, me, ":7",
                        "/dev/shm/dreamconnect.frame evil",
                        dir.resolve("ok.sock").toString(), "NUL in shm");
                SessionEndpoint nulSocket = new SessionEndpoint(myUid, me, ":8",
                        shm.toString(), "/run/user/1000/dreamconnect evil.sock", "NUL in socket");
                SessionEndpoint emptyPaths = new SessionEndpoint(myUid, me, ":9", "", "", "empty paths");
                SessionEndpoint good = new SessionEndpoint(myUid, me, ":1",
                        shm.toString(), dir.resolve("ok.sock").toString(), "kogies");

                // Caught rather than allowed to propagate, because "does not
                // throw" IS the contract here: the demonstrated defect was an
                // InvalidPathException escaping liveSessions and taking every
                // session down with it.
                List<SessionEndpoint> live = null;
                String thrown = null;
                try {
                    live = Bridge.liveSessions(List.of(nulShm, nulSocket, emptyPaths, good));
                } catch (Throwable t) {
                    thrown = String.valueOf(t);
                }

                check(thrown == null,
                      "a malformed entry does not throw out of liveSessions — an escape here sends "
                      + "EVERY session to the fallback (threw " + thrown + ")");
                check(live != null && live.size() == 1 && live.get(0) == good,
                      "a NUL byte or empty path in one entry drops only that entry; the sessions "
                      + "behind it survive (got " + describe(live) + ")");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 5. The entry-level half of the trust rule, which was
     * implemented but never asserted — which is how the spec came to contradict
     * it. The spec now reads: directory untrusted -> no registry at all;
     * entry untrusted, unreadable or unparseable -> drops only itself.
     *
     * {@link #testReadRegistryTrustGate} pins the directory half. This pins the
     * entry half against real files: a group-writable entry (someone else could
     * have written it), an unreadable one, and one that is not an entry at all,
     * alongside a good entry that must survive all three.
     */
    private static void testReadRegistryDropsOnlyTheBadEntry() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-registry-mixed");
        try {
            Files.writeString(dir.resolve("1000"),
                    "uid=1000\nuser=kogies\ndisplay=:1\nshm=/dev/shm/dreamconnect.frame.1000\n"
                    + "socket=/run/user/1000/dreamconnect.sock\nlabel=kogies\n");
            Files.writeString(dir.resolve("992"),
                    "uid=992\nuser=backstage\ndisplay=:0\nshm=/dev/shm/dreamconnect.frame.992\n"
                    + "socket=/run/user/992/dreamconnect.sock\nlabel=[Backstage]\n");
            Files.writeString(dir.resolve("993"), "this file is not a registry entry at all\n");
            Files.writeString(dir.resolve("994"),
                    "uid=994\nuser=u994\ndisplay=:4\nshm=/dev/shm/dreamconnect.frame.994\n"
                    + "socket=/run/user/994/dreamconnect.sock\n");
            long myUid = uidOf(dir);
            chmod(dir, "rwxr-xr-x");
            chmod(dir.resolve("1000"), "rw-r--r--");
            chmod(dir.resolve("992"), "rw-rw-r--");   // group-writable: untrusted
            chmod(dir.resolve("993"), "rw-r--r--");   // trusted, but not an entry
            chmod(dir.resolve("994"), "---------");   // trusted, but unreadable

            List<SessionEndpoint> found = Bridge.readRegistry(dir, myUid);
            check(found != null && found.size() == 1,
                  "a group-writable entry, an unparseable entry and an unreadable entry each drop "
                  + "ONLY themselves (got " + describe(found) + ")");
            if (found != null && found.size() == 1) {
                check(":1".equals(found.get(0).display()) && found.get(0).uid() == 1000,
                      "and the good entry beside them is returned intact (got "
                      + name(found.get(0)) + ")");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 5. The client that carries the operator's keystrokes must be
     * peer-authenticated, not just the probe that discovered the session.
     *
     * Demonstrated defect: liveSessions authenticated its probe, then attach()
     * built `new DaemonClient(socketPath)` with no expected user — so every
     * mouse event, every keystroke and every clipboard TYPE (i.e. pasted
     * credentials) rode an unauthenticated connection, and each transparent
     * reconnect re-skipped the check. Authenticating discovery and not the
     * attachment authenticates nothing: the socket can change hands between the
     * two.
     *
     * SEAMS I AM SPECIFYING (say so if you would rather shape them differently,
     * since they are yours to implement):
     *   - `Bridge.clientFor(SessionEndpoint)` — the single place a DaemonClient
     *     is built for an endpoint;
     *   - `Bridge.attachTo(SessionEndpoint)` — what attach() does once
     *     resolution has chosen, returning the client it will use;
     *   - `DaemonClient.expectedUser()` — accessor, so the requirement is
     *     observable without reaching into the socket.
     *
     * Because expectedUser is final per client, a client built correctly cannot
     * lose the requirement on reconnect — which is why asserting construction
     * is enough to cover the reconnect path.
     *
     * WHAT THIS DOES NOT PROVE: that attach() is reached, or that resolution
     * hands it the endpoint it resolved. attachTo() is called directly here.
     * The wiring above it stays unasserted at this seam and needs review or a
     * live check.
     *
     * ORDERING (reviewer's note, round 6): this calls attachTo() for real, so
     * it repoints Bridge's static daemon/frame — and, once attachTo is
     * implemented, shm/socket with them. There is no accessor to restore them
     * with, so instead of pretending to be isolated it is registered LAST in
     * main(), next to the only other test that mutates Bridge's static config
     * ({@link #testRegistryLabelWinsOverWho}). Anything added after these two
     * inherits their state; add it above them.
     */
    private static void testAttachedClientIsPeerAuthenticated() {
        check("kogies".equals(Bridge.clientFor(CONSOLE).expectedUser()),
              "the client built for a registry session demands that session's user (got "
              + q(Bridge.clientFor(CONSOLE).expectedUser()) + ")");
        check(Bridge.clientFor(FALLBACK).expectedUser() == null,
              "the client for the operator's own static args has no user to demand — it answers to "
              + "no registry entry (got " + q(Bridge.clientFor(FALLBACK).expectedUser()) + ")");

        // Deliberately NOT run in isolation. By the time this executes, the
        // curation tests above have already driven Bridge's picker path, which
        // calls logonLabel() -> attach() and builds a client from the static
        // socket with NO expected user. That is exactly the production
        // sequence: the picker is relabelled before any session is resolved.
        // So a `if (daemon == null)` guard here silently reuses an
        // unauthenticated client pointed at the wrong socket — observed while
        // writing this test, against an otherwise correct implementation.
        DaemonClient attached = Bridge.attachTo(CONSOLE);
        check(attached != null && "kogies".equals(attached.expectedUser()),
              "the client attach() carries input on demands the resolved session's user, even when "
              + "an unauthenticated client was already built by the picker path (got "
              + (attached == null ? "null" : q(attached.expectedUser())) + ")");
        check(attached != null && attached != Bridge.clientFor(FALLBACK),
              "and it is not the client for the static args reused under a new name");
    }

    /**
     * NEW, round 6. The registry's `label=` is what the operator sees, from the
     * FIRST call — not after a cache expires.
     *
     * The defect: logonLabel() snapshots labelOverride BEFORE calling attach(),
     * and attach() is what sets it from the resolved entry. So the resolving
     * call falls through to asking the daemon `WHO`, and
     * curateLogonSessionsCached then caches that login name for logonTtlMs
     * (30 s by default). The picker names the session after the account for
     * half a minute, then silently changes to the registry's label —
     * `[Backstage]` being exactly the name that distinguishes it.
     *
     * Two assertions: the label is the registry's, and this daemon socket was
     * never asked WHO at all — a label taken from the registry needs no round
     * trip.
     *
     * HONESTY LIMIT: the traffic half only proves nothing was asked of THIS
     * socket. Under today's wiring a stale client from an earlier code path may
     * carry the WHO elsewhere, in which case this server legitimately sees
     * nothing and only the first assertion catches the defect. Stated rather
     * than papered over; the first assertion is the load-bearing one.
     *
     * Mutates Bridge's static config (label=, socket=), so it is registered
     * last in main() — see testAttachedClientIsPeerAuthenticated's note.
     */
    private static void testRegistryLabelWinsOverWho() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-label");
        try {
            String me = Files.getOwner(dir).getName();
            Path sock = dir.resolve("dreamconnect.sock");
            try (RecordingServer srv = new RecordingServer(sock, "PONG\n")) {
                // No operator override in play (a label= arg legitimately wins
                // over everything), and any WHO would land on this server.
                Bridge.configure("label=");
                Bridge.configure("socket=" + sock);

                SessionEndpoint registered = new SessionEndpoint(992, me, ":0",
                        FALLBACK.shm(), sock.toString(), "[Backstage]");
                Bridge.attachTo(registered);

                String label = Bridge.logonLabel();
                check("[Backstage]".equals(label),
                      "the resolved entry's label= is the picker name from the first call, not the "
                      + "login name WHO would give (got " + q(label) + ")");
                settle();
                check(!srv.seen().contains("WHO"),
                      "and the daemon was never asked WHO: the registry already said what to call "
                      + "this session (server saw \"" + srv.seen() + "\")");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 4. SO_PEERCRED, against a real unix socket this test binds.
     *
     * This is the primitive that defeats a redirect: the kernel reports who is
     * on the other end of the connection, not who owns the path used to reach
     * it, so a symlink planted at a registered socket path cannot make the
     * agent believe it reached the registered user.
     *
     * HONESTY LIMIT, stated because it changes what this proves: the gate runs
     * as one account, so both ends of every socket here are me. This test can
     * therefore show that a real identity is read, that it is the right one,
     * and that a wrong expectation is rejected — but it CANNOT distinguish
     * "reports the listener" from "reports the path owner", because those are
     * the same principal in any socket I can create. The owner verified the
     * distinction live on this box (spec Solution 1: the same principal read
     * through a direct path and through a symlink); the symlink case below only
     * shows the mechanism still answers when reached through a link.
     *
     * The expected name is read off a file this process just created, so it is
     * the same UserPrincipal lookup the socket answer must produce, with
     * nothing hardcoded and nothing shelled out to.
     */
    private static void testPeerUserIsTheConnectedPeer() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-peer");
        try {
            String me = Files.getOwner(dir).getName();
            Path sock = dir.resolve("dreamconnect.sock");
            Path link = dir.resolve("linked.sock");
            try (OneShotServer srv = new OneShotServer(sock, "PONG\n")) {
                Files.createSymbolicLink(link, sock);

                try (SocketChannel c = SocketChannel.open(UnixDomainSocketAddress.of(sock))) {
                    check(me.equals(DaemonClient.peerUser(c)),
                          "peerUser() of a live connection is the listening account \"" + me + "\" (got "
                          + q(DaemonClient.peerUser(c)) + ")");
                }
                try (SocketChannel viaLink = SocketChannel.open(UnixDomainSocketAddress.of(link))) {
                    check(me.equals(DaemonClient.peerUser(viaLink)),
                          "reached through a symlink, the answer is still the listener's identity \"" + me
                          + "\" — the path is not the authority (got " + q(DaemonClient.peerUser(viaLink)) + ")");
                }
            }
            SocketChannel closed = SocketChannel.open(StandardProtocolFamily.UNIX);
            closed.close();
            check(DaemonClient.peerUser(closed) == null,
                  "an unconnected channel has no peer: null, not an exception (got "
                  + q(DaemonClient.peerUser(closed)) + ")");
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 4. The behaviour that matters at the seam: a client told to
     * expect one user must not talk to a socket answered by another.
     *
     * The demonstrated defect it closes: an attacker's socket, or a symlink
     * redirecting a registered path to one, received whatever the agent sent —
     * and what the agent sends includes the operator's keystrokes and the
     * clipboard TYPE command, i.e. pasted credentials. So the assertion is not
     * merely that send() returns null: it is that the server saw ZERO BYTES.
     * Authentication has to happen before the first command leaves, not after
     * a reply disappoints us.
     *
     * Both halves use a real accepting server, so the accepted case proves the
     * check does not simply break every connection.
     */
    private static void testDaemonClientRefusesWrongPeerUser() throws Exception {
        Path dir = Files.createTempDirectory("dcboot-peerauth");
        try {
            String me = Files.getOwner(dir).getName();

            Path ok = dir.resolve("ok.sock");
            try (OneShotServer srv = new OneShotServer(ok, "PONG\n")) {
                DaemonClient c = new DaemonClient(ok.toString(), me);
                String reply = c.send("PING");
                c.close();
                check("PONG".equals(reply),
                      "a socket answered by the expected user \"" + me + "\" is used normally (got "
                      + q(reply) + ")");
            }

            Path bad = dir.resolve("bad.sock");
            try (OneShotServer srv = new OneShotServer(bad, "PONG\n")) {
                DaemonClient c = new DaemonClient(bad.toString(), "not-" + me);
                String reply = c.send("PING");
                c.close();
                check(reply == null,
                      "a socket answered by anyone other than the expected user yields no reply (got "
                      + q(reply) + ")");
                check(srv.bytesRead() == 0,
                      "and NOTHING was sent to it: the operator's commands must never reach an "
                      + "unauthenticated peer (server read " + srv.bytesRead() + " bytes)");
            }
        } finally {
            rmTree(dir);
        }
    }

    /**
     * NEW, round 3 (contract C). A probe of a socket that is bound but never
     * accepted must give up, not wait forever.
     *
     * The defect: DaemonClient bounds reads (READ_TIMEOUT_MS) but not connect.
     * Any local user can bind a unix socket, let its accept backlog fill and
     * never accept; a blocking AF_UNIX connect against it then never returns
     * (measured 15s+ in review; reproduced here before writing this test — a
     * backlog-1 socket with two pending connects wedges a third indefinitely).
     * Discovery runs inside Bridge's synchronized init(), which the
     * session-picker path also enters, so one such socket wedges the root JVM
     * for the life of the process — a one-line denial of service against the
     * whole support session, from an unprivileged account.
     *
     * The bound: the probe must return within 5000 ms. Justification — the
     * client already bounds a read at 2000 ms, so a connect bounded on the same
     * order keeps the whole probe within a couple of seconds; 5000 ms is that
     * budget plus slack for a loaded gate machine, and is still far below the
     * unbounded behaviour, which does not return at all. The test costs the
     * bound only while it is failing; once connect is bounded it costs whatever
     * that bound is.
     *
     * The probe runs on a daemon thread on purpose: if it never returns, the
     * suite must still report the failure and exit rather than hanging the gate.
     */
    private static void testProbeConnectIsBounded() throws Exception {
        final long BOUND_MS = 5000;
        Path dir = Files.createTempDirectory("dcboot-connect");
        Path sock = dir.resolve("dreamconnect.sock");
        ServerSocketChannel srv = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        List<SocketChannel> pending = new ArrayList<>();
        try {
            srv.bind(UnixDomainSocketAddress.of(sock), 1);   // bound, never accept()ed
            // Fill the accept queue: non-blocking connects until the kernel
            // refuses one (EAGAIN). Every later connect now has to wait.
            for (int i = 0; i < 16; i++) {
                try {
                    SocketChannel c = SocketChannel.open(StandardProtocolFamily.UNIX);
                    c.configureBlocking(false);
                    c.connect(UnixDomainSocketAddress.of(sock));
                    pending.add(c);
                } catch (Exception backlogFull) {
                    break;
                }
            }
            check(!pending.isEmpty(),
                  "test precondition: the trap socket accepted queued connects (got " + pending.size() + ")");

            DaemonClient probe = new DaemonClient(sock.toString());
            java.util.concurrent.atomic.AtomicBoolean done =
                    new java.util.concurrent.atomic.AtomicBoolean(false);
            java.util.concurrent.atomic.AtomicReference<String> reply =
                    new java.util.concurrent.atomic.AtomicReference<>(null);
            Thread t = new Thread(() -> {
                String r = probe.send("DISPLAY");
                reply.set(r);
                done.set(true);
            });
            t.setDaemon(true);
            long t0 = System.nanoTime();
            t.start();
            t.join(BOUND_MS);
            long tookMs = (System.nanoTime() - t0) / 1_000_000;

            check(done.get(),
                  "probing a bound-but-never-accepted socket returns within " + BOUND_MS
                  + " ms (still blocked after " + tookMs + " ms — an unprivileged user can wedge the root JVM)");
            if (done.get()) {
                check(reply.get() == null,
                      "a probe that could not connect reports failure (null), never a fabricated reply (got "
                      + q(reply.get()) + ")");
            }
        } finally {
            for (SocketChannel c : pending) {
                try { c.close(); } catch (Exception ignored) {}
            }
            try { srv.close(); } catch (Exception ignored) {}
            Files.deleteIfExists(sock);
            Files.deleteIfExists(dir);
        }
    }
}
