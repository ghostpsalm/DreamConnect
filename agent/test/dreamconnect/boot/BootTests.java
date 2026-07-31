package dreamconnect.boot;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
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
        testAwtEvdevTablesDisjoint();
        testRobotPeerKeyWire();
        testRobotPeerSeparatorKey();
        testAwtEvdevF13ToF24Mapped();
        testAwtEvdevHelpMapped();
        testAwtEvdevKpArrowsMapped();
        testRobotPeerUnmappedKeyDropped();
        testRobotPeerNoPrintableAsciiFallback();
        testNoNamedAwtVkNeedsTheDeletedFallback();
        testFrameReader();
        testFrameReaderNeverBlackMidWrite();
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
     *   4. **a vk's own number is never read as a character**, via the VK_F1
     *      trap: vk 0x70 is the ASCII code of 'p'. Any route that reinterprets
     *      the raw vk as a keysym would type a 'p' ("KS 112 1") instead of
     *      pressing F1 ("K 59 1"). That defect class is what the VK_SEPARATOR
     *      -> 'l' bug was (#19) and why #36 removed the printable-ASCII
     *      fallback altogether; F1 is the cheapest live sentinel for it.
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
              "vk 0x70 is F1, not 'p': keyPress(VK_F1) -> \"K 59 1\", never the keysym 112 (got \""
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
     * Regression being pinned (#19): with vk 0x6C in neither table, sendKey()
     * used to fall through to a printable-ASCII fallback, which saw 108 in range
     * and returned 108 — the keysym for 'l'. Pressing the numpad separator on the
     * SC client typed an "l" on the guest. #36 deleted that fallback, so today
     * the failure mode a missing table entry produces is a drop rather than a
     * wrong character; either way this assertion demands the table entry.
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
     * #36 slice 2: extended function row VK_F13-VK_F24. Some physical
     * keyboards have an extended F-row beyond F12 (ScreenConnect can hand us
     * these vks even though AwtEvdev's function-row block, until this slice,
     * stopped at VK_F12/evdev 88).
     *
     * Expected values are independent of AwtEvdev's implementation:
     *   - evdev: /usr/include/linux/input-event-codes.h on this machine
     *     defines KEY_F13=183, KEY_F14=184, KEY_F15=185, KEY_F16=186,
     *     KEY_F17=187, KEY_F18=188, KEY_F19=189, KEY_F20=190, KEY_F21=191,
     *     KEY_F22=192, KEY_F23=193, KEY_F24=194.
     *   - AWT vk: `javap -constants java.awt.event.KeyEvent` on this JDK shows
     *     VK_F13=61440 (0xF000) through VK_F24=61451 (0xF00B); the two
     *     boundary values are pinned below so a JDK change can't silently
     *     shift what this test exercises.
     *   - Functional (non-printing) keys never get a keysym — matching the
     *     class-javadoc split every other functional key follows (VK_F1-VK_F12
     *     above stay evdev-only) — so keysym() must stay -1 for all twelve.
     *
     * The wire-level check (lowest/highest of the twelve — the boundary is
     * the part an off-by-one would miss) follows the same control-socket
     * contract as {@link #testRobotPeerKeyWire}: `K <evdev_keycode> <state>`.
     */
    private static void testAwtEvdevF13ToF24Mapped() {
        check(KeyEvent.VK_F13 == 61440, "AWT VK_F13 is vk 61440 (0xF000)");
        check(KeyEvent.VK_F24 == 61451, "AWT VK_F24 is vk 61451 (0xF00B)");

        check(AwtEvdev.keycode(KeyEvent.VK_F13) == 183, "VK_F13 -> evdev 183 (KEY_F13)");
        check(AwtEvdev.keycode(KeyEvent.VK_F14) == 184, "VK_F14 -> evdev 184 (KEY_F14)");
        check(AwtEvdev.keycode(KeyEvent.VK_F15) == 185, "VK_F15 -> evdev 185 (KEY_F15)");
        check(AwtEvdev.keycode(KeyEvent.VK_F16) == 186, "VK_F16 -> evdev 186 (KEY_F16)");
        check(AwtEvdev.keycode(KeyEvent.VK_F17) == 187, "VK_F17 -> evdev 187 (KEY_F17)");
        check(AwtEvdev.keycode(KeyEvent.VK_F18) == 188, "VK_F18 -> evdev 188 (KEY_F18)");
        check(AwtEvdev.keycode(KeyEvent.VK_F19) == 189, "VK_F19 -> evdev 189 (KEY_F19)");
        check(AwtEvdev.keycode(KeyEvent.VK_F20) == 190, "VK_F20 -> evdev 190 (KEY_F20)");
        check(AwtEvdev.keycode(KeyEvent.VK_F21) == 191, "VK_F21 -> evdev 191 (KEY_F21)");
        check(AwtEvdev.keycode(KeyEvent.VK_F22) == 192, "VK_F22 -> evdev 192 (KEY_F22)");
        check(AwtEvdev.keycode(KeyEvent.VK_F23) == 193, "VK_F23 -> evdev 193 (KEY_F23)");
        check(AwtEvdev.keycode(KeyEvent.VK_F24) == 194, "VK_F24 -> evdev 194 (KEY_F24)");

        check(AwtEvdev.keysym(KeyEvent.VK_F13) == -1, "VK_F13 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F14) == -1, "VK_F14 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F15) == -1, "VK_F15 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F16) == -1, "VK_F16 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F17) == -1, "VK_F17 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F18) == -1, "VK_F18 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F19) == -1, "VK_F19 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F20) == -1, "VK_F20 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F21) == -1, "VK_F21 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F22) == -1, "VK_F22 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F23) == -1, "VK_F23 has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_F24) == -1, "VK_F24 has no keysym (functional key)");

        FakeDaemon d = new FakeDaemon();
        DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

        peer.keyPress(KeyEvent.VK_F13);
        check("K 183 1".equals(d.last()),
              "keyPress(VK_F13) -> \"K 183 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_F13);
        check("K 183 0".equals(d.last()),
              "keyRelease(VK_F13) -> \"K 183 0\" (got \"" + d.last() + "\")");

        peer.keyPress(KeyEvent.VK_F24);
        check("K 194 1".equals(d.last()),
              "keyPress(VK_F24) -> \"K 194 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_F24);
        check("K 194 0".equals(d.last()),
              "keyRelease(VK_F24) -> \"K 194 0\" (got \"" + d.last() + "\")");

        check(d.sent.size() == 4,
              "one wire line per key event, no extras (got " + d.sent.size() + ": " + d.sent + ")");
    }

    /**
     * #36 slice 3: VK_HELP, the physical Help key found on many extended
     * keyboards. It stayed silently dropped until this slice — neither table
     * had an entry, so sendKey's now-explicit drop branch (#36 slice 1) ate it.
     *
     * Expected values are independent of AwtEvdev's implementation:
     *   - evdev: /usr/include/linux/input-event-codes.h on this machine
     *     defines KEY_HELP=138 ("AL Integrated Help Center").
     *   - AWT vk: `javap -constants java.awt.event.KeyEvent` on this JDK shows
     *     VK_HELP=156 (0x9C), pinned below so a JDK change can't silently shift
     *     what this test exercises.
     *   - VK_HELP produces no character, so — matching the class-javadoc split
     *     every other functional key follows — keysym() must stay -1.
     *
     * The wire-level check follows the same control-socket contract as
     * {@link #testRobotPeerKeyWire}: `K <evdev_keycode> <state>`.
     */
    private static void testAwtEvdevHelpMapped() {
        check(KeyEvent.VK_HELP == 156, "AWT VK_HELP is vk 156 (0x9C)");

        check(AwtEvdev.keycode(KeyEvent.VK_HELP) == 138, "VK_HELP -> evdev 138 (KEY_HELP)");
        check(AwtEvdev.keysym(KeyEvent.VK_HELP) == -1, "VK_HELP has no keysym (functional key)");

        FakeDaemon d = new FakeDaemon();
        DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

        peer.keyPress(KeyEvent.VK_HELP);
        check("K 138 1".equals(d.last()),
              "keyPress(VK_HELP) -> \"K 138 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_HELP);
        check("K 138 0".equals(d.last()),
              "keyRelease(VK_HELP) -> \"K 138 0\" (got \"" + d.last() + "\")");

        check(d.sent.size() == 2,
              "one wire line per key event, no extras (got " + d.sent.size() + ": " + d.sent + ")");
    }

    /**
     * #36 slice 4: the numpad arrow vks VK_KP_UP/DOWN/LEFT/RIGHT. AWT hands
     * these out (instead of VK_UP/DOWN/LEFT/RIGHT) when Num Lock is off and the
     * operator uses the numpad's arrow overlay, so ScreenConnect can pass
     * either vk for what is, physically, the same key. The owner's decision
     * (factory/CHECKPOINT.md, "Agreed seams" 2) is that these four are the same
     * physical/semantic key as their non-numpad counterparts, so they must
     * land on the *same* evdev code as VK_UP/DOWN/LEFT/RIGHT — not merely some
     * plausible arrow code.
     *
     * Expected values are independent of AwtEvdev's implementation:
     *   - AWT vk: `javap -constants java.awt.event.KeyEvent` on this JDK (and a
     *     reflective read of the same fields) shows VK_KP_UP=224 (0xE0),
     *     VK_KP_DOWN=225 (0xE1), VK_KP_LEFT=226 (0xE2), VK_KP_RIGHT=227 (0xE3) —
     *     pinned below so a JDK change can't silently shift what this test
     *     exercises.
     *   - evdev: /usr/include/linux/input-event-codes.h on this machine defines
     *     KEY_UP=103, KEY_DOWN=108, KEY_LEFT=105, KEY_RIGHT=106 — the same
     *     codes VK_UP/DOWN/LEFT/RIGHT already map to (asserted directly in
     *     {@link #testAwtEvdev}). Each KP vk is checked against both: equal to
     *     its counterpart's *current* code, and equal to the absolute value
     *     from the header. A transposition (e.g. KP_LEFT landing on RIGHT's
     *     code, or vice versa) would still pick a value from the correct *set*
     *     of arrow codes but fails the per-key absolute checks below.
     *   - Functional (non-printing) keys never get a keysym — matching the
     *     class-javadoc split every other functional key follows — so keysym()
     *     must stay -1 for all four.
     *
     * The wire-level check follows the same control-socket contract as
     * {@link #testRobotPeerKeyWire}: `K <evdev_keycode> <state>`.
     */
    private static void testAwtEvdevKpArrowsMapped() {
        check(KeyEvent.VK_KP_UP == 224, "AWT VK_KP_UP is vk 224 (0xE0)");
        check(KeyEvent.VK_KP_DOWN == 225, "AWT VK_KP_DOWN is vk 225 (0xE1)");
        check(KeyEvent.VK_KP_LEFT == 226, "AWT VK_KP_LEFT is vk 226 (0xE2)");
        check(KeyEvent.VK_KP_RIGHT == 227, "AWT VK_KP_RIGHT is vk 227 (0xE3)");

        // Same evdev code as the non-numpad counterpart.
        check(AwtEvdev.keycode(KeyEvent.VK_KP_UP) == AwtEvdev.keycode(KeyEvent.VK_UP),
              "VK_KP_UP shares VK_UP's evdev code (got " + AwtEvdev.keycode(KeyEvent.VK_KP_UP)
              + " vs " + AwtEvdev.keycode(KeyEvent.VK_UP) + ")");
        check(AwtEvdev.keycode(KeyEvent.VK_KP_DOWN) == AwtEvdev.keycode(KeyEvent.VK_DOWN),
              "VK_KP_DOWN shares VK_DOWN's evdev code (got " + AwtEvdev.keycode(KeyEvent.VK_KP_DOWN)
              + " vs " + AwtEvdev.keycode(KeyEvent.VK_DOWN) + ")");
        check(AwtEvdev.keycode(KeyEvent.VK_KP_LEFT) == AwtEvdev.keycode(KeyEvent.VK_LEFT),
              "VK_KP_LEFT shares VK_LEFT's evdev code (got " + AwtEvdev.keycode(KeyEvent.VK_KP_LEFT)
              + " vs " + AwtEvdev.keycode(KeyEvent.VK_LEFT) + ")");
        check(AwtEvdev.keycode(KeyEvent.VK_KP_RIGHT) == AwtEvdev.keycode(KeyEvent.VK_RIGHT),
              "VK_KP_RIGHT shares VK_RIGHT's evdev code (got " + AwtEvdev.keycode(KeyEvent.VK_KP_RIGHT)
              + " vs " + AwtEvdev.keycode(KeyEvent.VK_RIGHT) + ")");

        // Absolute values, from input-event-codes.h — catches a transposition
        // within the arrow-code set that the equality checks above would miss
        // only if both sides were transposed identically (they can't be, since
        // VK_UP/DOWN/LEFT/RIGHT's own values are pinned in testAwtEvdev()).
        check(AwtEvdev.keycode(KeyEvent.VK_KP_UP) == 103, "VK_KP_UP -> evdev 103 (KEY_UP)");
        check(AwtEvdev.keycode(KeyEvent.VK_KP_DOWN) == 108, "VK_KP_DOWN -> evdev 108 (KEY_DOWN)");
        check(AwtEvdev.keycode(KeyEvent.VK_KP_LEFT) == 105, "VK_KP_LEFT -> evdev 105 (KEY_LEFT)");
        check(AwtEvdev.keycode(KeyEvent.VK_KP_RIGHT) == 106, "VK_KP_RIGHT -> evdev 106 (KEY_RIGHT)");

        check(AwtEvdev.keysym(KeyEvent.VK_KP_UP) == -1, "VK_KP_UP has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_KP_DOWN) == -1, "VK_KP_DOWN has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_KP_LEFT) == -1, "VK_KP_LEFT has no keysym (functional key)");
        check(AwtEvdev.keysym(KeyEvent.VK_KP_RIGHT) == -1, "VK_KP_RIGHT has no keysym (functional key)");

        FakeDaemon d = new FakeDaemon();
        DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

        peer.keyPress(KeyEvent.VK_KP_UP);
        check("K 103 1".equals(d.last()), "keyPress(VK_KP_UP) -> \"K 103 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_KP_UP);
        check("K 103 0".equals(d.last()), "keyRelease(VK_KP_UP) -> \"K 103 0\" (got \"" + d.last() + "\")");

        peer.keyPress(KeyEvent.VK_KP_DOWN);
        check("K 108 1".equals(d.last()), "keyPress(VK_KP_DOWN) -> \"K 108 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_KP_DOWN);
        check("K 108 0".equals(d.last()), "keyRelease(VK_KP_DOWN) -> \"K 108 0\" (got \"" + d.last() + "\")");

        peer.keyPress(KeyEvent.VK_KP_LEFT);
        check("K 105 1".equals(d.last()), "keyPress(VK_KP_LEFT) -> \"K 105 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_KP_LEFT);
        check("K 105 0".equals(d.last()), "keyRelease(VK_KP_LEFT) -> \"K 105 0\" (got \"" + d.last() + "\")");

        peer.keyPress(KeyEvent.VK_KP_RIGHT);
        check("K 106 1".equals(d.last()), "keyPress(VK_KP_RIGHT) -> \"K 106 1\" (got \"" + d.last() + "\")");
        peer.keyRelease(KeyEvent.VK_KP_RIGHT);
        check("K 106 0".equals(d.last()), "keyRelease(VK_KP_RIGHT) -> \"K 106 0\" (got \"" + d.last() + "\")");

        check(d.sent.size() == 8,
              "one wire line per key event, no extras (got " + d.sent.size() + ": " + d.sent + ")");
    }

    /**
     * The third and last outcome of sendKey(): **silent drop**. After #36 there
     * are exactly two routes — keysym table -> `KS`, evdev table -> `K` — and a
     * vk in neither puts no line on the control socket at all. The two positive
     * routes are asserted in {@link #testRobotPeerKeyWire}; this is the one that
     * says a wire line must NOT appear.
     *
     * Why it needs its own test: the `d.sent.size() == 4` assertion in
     * {@link #testRobotPeerKeyWire} pins "no *extra* lines" for keys that are
     * mapped. Nothing else pins "no line at all" for the vks in neither table.
     * Appending an `else daemon.input("KS " + awtVk + " " + state)` to sendKey()
     * — the obvious way to "fix" those dropped keys — keeps every other
     * assertion in this suite green while handing Mutter a raw AWT vk as if it
     * were a keysym (VK_COPY would emit `KS 65485 1`). That is the same defect
     * class as the VK_SEPARATOR -> 'l' bug, so it gets an alarm.
     *
     * Exemplar choice, and why it is no longer VK_F13. #36's decision (recorded
     * in factory/CHECKPOINT.md, "Agreed seams" 2) maps VK_F13-VK_F24, VK_HELP
     * and the VK_KP_* arrows, and rules that the rest — every VK_DEAD_*, the
     * clipboard/edit commands, VK_UNDEFINED — stay dropped **by design**,
     * because no physical evdev key or X11 keysym means them. VK_F13 was this
     * test's exemplar and stops being unmapped in the very next slice, which
     * would leave the test passing vacuously. The exemplars below are drawn
     * from the deliberately-never-mapped set instead, so they keep their
     * meaning. Each one's absence from both tables is asserted, not assumed.
     */
    private static void testRobotPeerUnmappedKeyDropped() {
        // Value claims, machine-checked so the exemplars cannot silently drift.
        check(KeyEvent.VK_DEAD_GRAVE == 0x80, "AWT VK_DEAD_GRAVE is vk 0x80");
        check(KeyEvent.VK_COPY == 0xFFCD, "AWT VK_COPY is vk 0xFFCD");
        check(KeyEvent.VK_UNDEFINED == 0x0, "AWT VK_UNDEFINED is vk 0x0");

        int[] vks = { KeyEvent.VK_DEAD_GRAVE, KeyEvent.VK_COPY, KeyEvent.VK_UNDEFINED, -9999 };
        String[] names = { "VK_DEAD_GRAVE", "VK_COPY", "VK_UNDEFINED", "nonsense vk -9999" };

        for (int i = 0; i < vks.length; i++) {
            // Precondition: if a later change maps one of these, the test stops
            // meaning what it says — so it fails loudly rather than passing vacuously.
            check(AwtEvdev.keysym(vks[i]) == -1, names[i] + " is in no keysym table");
            check(AwtEvdev.keycode(vks[i]) == -1, names[i] + " is in no evdev table");

            FakeDaemon d = new FakeDaemon();
            DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);

            peer.keyPress(vks[i]);
            check(d.sent.isEmpty(),
                  "unmapped key is dropped: keyPress(" + names[i] + ") puts NO line on the wire (got "
                  + d.sent + ")");

            peer.keyRelease(vks[i]);
            check(d.sent.isEmpty(),
                  "unmapped key is dropped: keyRelease(" + names[i] + ") puts NO line on the wire (got "
                  + d.sent + ")");
        }
    }

    /**
     * #36 slice 1: **there is no printable-ASCII fallback route.** The owner's
     * decision (factory/CHECKPOINT.md, "Agreed seams" 1) deletes
     * AwtEvdev.fallbackKeysym outright and makes sendKey's third branch an
     * explicit drop — so a vk in neither table puts NO line on the control
     * socket, whatever its numeric value happens to be.
     *
     * This is the only assertion in the suite that can observe that change.
     * Issue #36 establishes the surface: after the VK_SEPARATOR fix, zero named
     * AWT vks reach the fallback; it stays reachable "only from a raw int handed
     * to `Robot.keyPress` (13 values in 0x20..0x7E)". Those 13 are therefore the
     * whole observable footprint of the deletion, and the three probed here are
     * drawn from them:
     *
     *   0x2B '+' — AWT's plus key is VK_PLUS = 0x209, so 0x2B is not an AWT vk
     *   0x40 '@' — AWT's at key   is VK_AT   = 0x200, so 0x40 is not an AWT vk
     *   0x7E '~' — the top of the deleted fallback's 0x20..0x7E range, and AWT
     *              has no vk at 0x7E at all (its tilde is VK_DEAD_TILDE = 0x83)
     *
     * Under the old fallback each of these put a KS line on the wire built from
     * the raw int — "KS 43 1", "KS 64 1", "KS 126 1" — i.e. an AWT-side integer
     * handed to Mutter as though it were a keysym. That is precisely the defect
     * class behind VK_SEPARATOR -> 'l'. After the deletion the wire stays empty.
     */
    private static void testRobotPeerNoPrintableAsciiFallback() {
        // Machine-checked form of the "not an AWT vk" claims above.
        check(KeyEvent.VK_PLUS == 0x209, "AWT VK_PLUS is 0x209, so 0x2B ('+') is not an AWT vk");
        check(KeyEvent.VK_AT == 0x200, "AWT VK_AT is 0x200, so 0x40 ('@') is not an AWT vk");
        check(KeyEvent.VK_DEAD_TILDE == 0x83, "AWT VK_DEAD_TILDE is 0x83, so 0x7E ('~') is not an AWT vk");

        for (int vk : new int[] { '+', '@', '~' }) {
            String label = "raw vk 0x" + Integer.toHexString(vk) + " ('" + (char) vk + "')";
            check(AwtEvdev.keysym(vk) == -1 && AwtEvdev.keycode(vk) == -1,
                  "precondition: " + label + " is in neither AwtEvdev table");

            FakeDaemon d = new FakeDaemon();
            DreamConnectRobotPeer peer = new DreamConnectRobotPeer(d, null);
            peer.keyPress(vk);
            peer.keyRelease(vk);
            check(d.sent.isEmpty(),
                  "no printable-ASCII fallback: press+release of " + label
                  + " puts NO line on the wire (got " + d.sent + ")");
        }
    }

    /**
     * Alarm on the premise the deletion rests on. #36's reflection over AWT's
     * VK_ constants found that, once VK_SEPARATOR was mapped, **no named AWT vk
     * reached the printable-ASCII fallback** — which is why removing it costs no
     * real key (factory/CHECKPOINT.md, "Agreed seams" 1: "ScreenConnect appears
     * to only ever pass named VK_* constants; the raw-int safety net has no
     * observed use case").
     *
     * If a JDK upgrade adds a VK_ constant whose value lands in the deleted
     * fallback's 0x20..0x7E window with no table entry behind it, that premise
     * is false and the drop starts eating a key an operator can actually press.
     * Nothing else in this suite would notice, so this scans KeyEvent's own VK_
     * fields — the JDK is the source, not AwtEvdev — and names any offender.
     *
     * Same shape as {@link #testAwtEvdevTablesDisjoint}: a standing guard on an
     * invariant, not a route test. It is expected to pass both before and after
     * the deletion; it is here to fail on a *future* change.
     */
    private static void testNoNamedAwtVkNeedsTheDeletedFallback() throws Exception {
        List<String> stranded = new ArrayList<>();
        int scanned = 0;
        for (Field f : KeyEvent.class.getFields()) {
            if (!f.getName().startsWith("VK_") || f.getType() != int.class) continue;
            scanned++;
            int vk = f.getInt(null);
            if (vk < 0x20 || vk > 0x7E) continue;                                // outside the old window
            if (AwtEvdev.keysym(vk) >= 0 || AwtEvdev.keycode(vk) >= 0) continue; // has a route
            stranded.add(f.getName() + " (0x" + Integer.toHexString(vk) + ")");
        }
        check(scanned >= 150,
              "scanned KeyEvent's VK_ constants by reflection (got " + scanned + ", expected ~189)");
        check(stranded.isEmpty(),
              "no named AWT vk depended on the printable-ASCII fallback (got " + stranded + ")");
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
}
