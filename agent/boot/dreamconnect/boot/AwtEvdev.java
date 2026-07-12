package dreamconnect.boot;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.util.HashMap;
import java.util.Map;

/**
 * Translates AWT input codes (what ScreenConnect passes to Robot) into the
 * evdev codes Mutter's RemoteDesktop Notify* methods expect.
 *
 * Keyboard: AWT virtual keycode -> evdev keycode (Linux input-event-codes.h,
 * i.e. KEY_A=30, NOT the X11 keycode which is +8). This assumes a US-ish
 * physical layout, which matches how a normal X11 Robot injects via XTEST.
 * Coverage is the common keyboard; gaps return -1 so the caller can fall back
 * to keysym injection. (Keymap fidelity is a known hardening area.)
 */
final class AwtEvdev {
    // evdev button codes
    static final int BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112;

    private static final Map<Integer, Integer> KEY = new HashMap<>();

    private static void m(int vk, int evdev) { KEY.put(vk, evdev); }

    static {
        // letters
        m(KeyEvent.VK_A, 30); m(KeyEvent.VK_B, 48); m(KeyEvent.VK_C, 46);
        m(KeyEvent.VK_D, 32); m(KeyEvent.VK_E, 18); m(KeyEvent.VK_F, 33);
        m(KeyEvent.VK_G, 34); m(KeyEvent.VK_H, 35); m(KeyEvent.VK_I, 23);
        m(KeyEvent.VK_J, 36); m(KeyEvent.VK_K, 37); m(KeyEvent.VK_L, 38);
        m(KeyEvent.VK_M, 50); m(KeyEvent.VK_N, 49); m(KeyEvent.VK_O, 24);
        m(KeyEvent.VK_P, 25); m(KeyEvent.VK_Q, 16); m(KeyEvent.VK_R, 19);
        m(KeyEvent.VK_S, 31); m(KeyEvent.VK_T, 20); m(KeyEvent.VK_U, 22);
        m(KeyEvent.VK_V, 47); m(KeyEvent.VK_W, 17); m(KeyEvent.VK_X, 45);
        m(KeyEvent.VK_Y, 21); m(KeyEvent.VK_Z, 44);
        // number row
        m(KeyEvent.VK_1, 2); m(KeyEvent.VK_2, 3); m(KeyEvent.VK_3, 4);
        m(KeyEvent.VK_4, 5); m(KeyEvent.VK_5, 6); m(KeyEvent.VK_6, 7);
        m(KeyEvent.VK_7, 8); m(KeyEvent.VK_8, 9); m(KeyEvent.VK_9, 10);
        m(KeyEvent.VK_0, 11);
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
        // punctuation (US layout)
        m(KeyEvent.VK_MINUS, 12); m(KeyEvent.VK_EQUALS, 13);
        m(KeyEvent.VK_OPEN_BRACKET, 26); m(KeyEvent.VK_CLOSE_BRACKET, 27);
        m(KeyEvent.VK_BACK_SLASH, 43); m(KeyEvent.VK_SEMICOLON, 39);
        m(KeyEvent.VK_QUOTE, 40); m(KeyEvent.VK_BACK_QUOTE, 41);
        m(KeyEvent.VK_COMMA, 51); m(KeyEvent.VK_PERIOD, 52); m(KeyEvent.VK_SLASH, 53);
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
