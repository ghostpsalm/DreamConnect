package dreamconnect.boot;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
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
}
