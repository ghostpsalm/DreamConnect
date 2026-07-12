package dreamconnect.boot;

import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

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
        testFrameReader();
        if (failures > 0) {
            System.out.println(failures + " FAILURE(S)");
            System.exit(1);
        }
        System.out.println("ALL PASS");
    }

    private static void testAwtEvdev() {
        check(AwtEvdev.keycode(KeyEvent.VK_A) == 30, "VK_A -> evdev 30");
        check(AwtEvdev.keycode(KeyEvent.VK_ENTER) == 28, "VK_ENTER -> 28");
        check(AwtEvdev.keycode(KeyEvent.VK_SPACE) == 57, "VK_SPACE -> 57");
        check(AwtEvdev.keycode(KeyEvent.VK_LEFT) == 105, "VK_LEFT -> 105");
        check(AwtEvdev.keycode(-9999) == -1, "unmapped key -> -1");
        check(AwtEvdev.button(InputEvent.BUTTON1_DOWN_MASK) == AwtEvdev.BTN_LEFT, "BUTTON1 -> BTN_LEFT");
        check(AwtEvdev.button(InputEvent.BUTTON2_DOWN_MASK) == AwtEvdev.BTN_MIDDLE, "BUTTON2 -> BTN_MIDDLE");
        check(AwtEvdev.button(InputEvent.BUTTON3_DOWN_MASK) == AwtEvdev.BTN_RIGHT, "BUTTON3 -> BTN_RIGHT");
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
}
