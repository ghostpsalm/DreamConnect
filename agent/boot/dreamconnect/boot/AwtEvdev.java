package dreamconnect.boot;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.util.HashMap;
import java.util.Map;

/**
 * Translates AWT input codes (what ScreenConnect passes to Robot) into what
 * Mutter's RemoteDesktop Notify* methods expect.
 *
 * Keyboard is split two ways:
 *   - Character-producing keys (letters, digits, punctuation) map to an X11
 *     **keysym** (see {@link #keysym}). Mutter's NotifyKeyboardKeysym then picks
 *     whatever keycode produces that symbol *on the guest's own layout*, so the
 *     right character lands regardless of the guest keymap (US, QWERTZ, AZERTY,
 *     …). We send the *base* (unshifted) keysym; an operator-held Shift/AltGr,
 *     injected as an evdev modifier below, promotes it (verified: evdev-Shift +
 *     keysym 'a' -> 'A'; Ctrl held + keysym 'c' -> Ctrl+C).
 *   - Everything else — modifiers, whitespace/control, navigation, function row,
 *     numpad, locks — maps to an **evdev keycode** (Linux input-event-codes.h,
 *     KEY_A=30, not the X11 +8 keycode). These are physical/functional keys that
 *     mean the same thing on every layout, so position-based injection is right.
 *
 * Gaps return -1 so the caller can fall back ({@link #fallbackKeysym}) or drop.
 */
final class AwtEvdev {
    // evdev button codes
    static final int BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112;

    private static final Map<Integer, Integer> KEY = new HashMap<>();   // vk -> evdev
    private static final Map<Integer, Integer> KSYM = new HashMap<>();  // vk -> X11 keysym

    private static void m(int vk, int evdev) { KEY.put(vk, evdev); }
    private static void k(int vk, int keysym) { KSYM.put(vk, keysym); }

    static {
        // Character keys -> base (unshifted) keysym, for layout-independent text.
        for (int vk = KeyEvent.VK_A; vk <= KeyEvent.VK_Z; vk++) k(vk, vk + 0x20); // 'a'..'z'
        for (int vk = KeyEvent.VK_0; vk <= KeyEvent.VK_9; vk++) k(vk, vk);        // '0'..'9'
        k(KeyEvent.VK_MINUS, '-'); k(KeyEvent.VK_EQUALS, '=');
        k(KeyEvent.VK_OPEN_BRACKET, '['); k(KeyEvent.VK_CLOSE_BRACKET, ']');
        k(KeyEvent.VK_BACK_SLASH, '\\'); k(KeyEvent.VK_SEMICOLON, ';');
        k(KeyEvent.VK_QUOTE, '\''); k(KeyEvent.VK_BACK_QUOTE, '`');
        k(KeyEvent.VK_COMMA, ','); k(KeyEvent.VK_PERIOD, '.'); k(KeyEvent.VK_SLASH, '/');

        // whitespace / control
        m(KeyEvent.VK_ENTER, 28); m(KeyEvent.VK_ESCAPE, 1);
        m(KeyEvent.VK_BACK_SPACE, 14); m(KeyEvent.VK_TAB, 15);
        m(KeyEvent.VK_SPACE, 57); m(KeyEvent.VK_CAPS_LOCK, 58);
        // modifiers
        m(KeyEvent.VK_SHIFT, 42);   // left shift
        m(KeyEvent.VK_CONTROL, 29); // left ctrl
        m(KeyEvent.VK_ALT, 56);     // left alt
        m(KeyEvent.VK_ALT_GRAPH, 100); // right alt
        m(KeyEvent.VK_META, 125);   // left meta / super
        m(KeyEvent.VK_WINDOWS, 125);
        m(KeyEvent.VK_CONTEXT_MENU, 127);
        // navigation
        m(KeyEvent.VK_INSERT, 110); m(KeyEvent.VK_DELETE, 111);
        m(KeyEvent.VK_HOME, 102); m(KeyEvent.VK_END, 107);
        m(KeyEvent.VK_PAGE_UP, 104); m(KeyEvent.VK_PAGE_DOWN, 109);
        m(KeyEvent.VK_UP, 103); m(KeyEvent.VK_DOWN, 108);
        m(KeyEvent.VK_LEFT, 105); m(KeyEvent.VK_RIGHT, 106);
        // function row
        m(KeyEvent.VK_F1, 59); m(KeyEvent.VK_F2, 60); m(KeyEvent.VK_F3, 61);
        m(KeyEvent.VK_F4, 62); m(KeyEvent.VK_F5, 63); m(KeyEvent.VK_F6, 64);
        m(KeyEvent.VK_F7, 65); m(KeyEvent.VK_F8, 66); m(KeyEvent.VK_F9, 67);
        m(KeyEvent.VK_F10, 68); m(KeyEvent.VK_F11, 87); m(KeyEvent.VK_F12, 88);
        // locks / sysreq
        m(KeyEvent.VK_NUM_LOCK, 69); m(KeyEvent.VK_SCROLL_LOCK, 70);
        m(KeyEvent.VK_PRINTSCREEN, 99); m(KeyEvent.VK_PAUSE, 119);
        // numpad
        m(KeyEvent.VK_NUMPAD0, 82); m(KeyEvent.VK_NUMPAD1, 79);
        m(KeyEvent.VK_NUMPAD2, 80); m(KeyEvent.VK_NUMPAD3, 81);
        m(KeyEvent.VK_NUMPAD4, 75); m(KeyEvent.VK_NUMPAD5, 76);
        m(KeyEvent.VK_NUMPAD6, 77); m(KeyEvent.VK_NUMPAD7, 71);
        m(KeyEvent.VK_NUMPAD8, 72); m(KeyEvent.VK_NUMPAD9, 73);
        m(KeyEvent.VK_MULTIPLY, 55); m(KeyEvent.VK_ADD, 78);
        m(KeyEvent.VK_SUBTRACT, 74); m(KeyEvent.VK_DECIMAL, 83);
        m(KeyEvent.VK_DIVIDE, 98);
    }

    /** AWT virtual keycode -> evdev keycode, or -1 if unmapped. */
    static int keycode(int awtVk) {
        Integer e = KEY.get(awtVk);
        return e == null ? -1 : e;
    }

    /** AWT virtual keycode -> base X11 keysym for character keys, or -1. */
    static int keysym(int awtVk) {
        Integer s = KSYM.get(awtVk);
        return s == null ? -1 : s;
    }

    /**
     * Last-resort keysym for a printable VK not in either table. Java's
     * character VK constants equal the uppercase ASCII code, so letters map to
     * the lowercase (base) keysym and other printables map to themselves.
     */
    static int fallbackKeysym(int awtVk) {
        if (awtVk >= 'A' && awtVk <= 'Z') return awtVk + 0x20;
        if (awtVk >= 0x20 && awtVk <= 0x7E) return awtVk;
        return -1;
    }

    /**
     * AWT button mask (Robot.mousePress/Release argument) -> evdev button code.
     * Accepts both the modern *_DOWN_MASK and legacy *_MASK forms.
     */
    static int button(int awtMask) {
        if ((awtMask & InputEvent.BUTTON1_DOWN_MASK) != 0 || (awtMask & InputEvent.BUTTON1_MASK) != 0)
            return BTN_LEFT;
        if ((awtMask & InputEvent.BUTTON3_DOWN_MASK) != 0 || (awtMask & InputEvent.BUTTON3_MASK) != 0)
            return BTN_RIGHT;
        if ((awtMask & InputEvent.BUTTON2_DOWN_MASK) != 0 || (awtMask & InputEvent.BUTTON2_MASK) != 0)
            return BTN_MIDDLE;
        return BTN_LEFT;
    }

    private AwtEvdev() {}
}
