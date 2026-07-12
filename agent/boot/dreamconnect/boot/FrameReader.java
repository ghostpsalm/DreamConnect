package dreamconnect.boot;

import java.io.RandomAccessFile;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.util.Arrays;

/**
 * Reads the daemon's shared-memory frame buffer (/dev/shm/dreamconnect.frame).
 * Layout mirrors runtime/README.md: 64-byte little-endian header + BGRx pixels,
 * with a seqlock (seq_begin/seq_end) so this lock-free reader can detect and
 * retry a frame that was being written mid-read.
 */
final class FrameReader {
    private static final int HEADER = 64;
    private static final long MAGIC = 0x31464344L; // "DCF1" little-endian

    private final String path;
    private RandomAccessFile raf;
    private MappedByteBuffer map;
    private IntBuffer mapInts;   // int-view of map, for bulk row copies
    private int width, height, stride;

    FrameReader(String path) {
        this.path = path;
    }

    private synchronized void ensure() throws Exception {
        if (map == null) { remap(); return; }
        // Cheap in-memory check (no syscall on the hot path): remap only if the
        // daemon changed the frame geometry — e.g. a resolution change, which
        // the old size-stat check missed because a same-inode ftruncate left
        // File.length() and raf.length() equal.
        if (map.getInt(8) != width || map.getInt(12) != height || map.getInt(16) != stride) {
            remap();
        }
    }

    private void remap() throws Exception {
        if (raf != null) try { raf.close(); } catch (Exception ignored) {}
        raf = new RandomAccessFile(path, "r");
        long len = raf.length();
        map = raf.getChannel().map(FileChannel.MapMode.READ_ONLY, 0, len);
        map.order(ByteOrder.LITTLE_ENDIAN);
        mapInts = map.asIntBuffer();   // inherits LITTLE_ENDIAN; index i == byte 4*i
        long magic = map.getInt(0) & 0xffffffffL;
        if (magic != MAGIC) throw new Exception("bad magic " + Long.toHexString(magic));
        width = map.getInt(8);
        height = map.getInt(12);
        stride = map.getInt(16);
    }

    /** ARGB of a single pixel (for Robot.getPixelColor). */
    synchronized int pixel(int x, int y) {
        try {
            ensure();
            if (x < 0 || y < 0 || x >= width || y >= height) return 0xFF000000;
            int off = HEADER + y * stride + x * 4;
            int bgrx = map.getInt(off);
            return 0xFF000000 | (bgrx & 0x00FFFFFF);
        } catch (Exception e) {
            return 0xFF000000;
        }
    }

    /**
     * ARGB pixels for a rectangle (for Robot.createScreenCapture, which calls
     * RobotPeer.getRGBPixels). Seqlock-guarded: retries on a torn read.
     */
    synchronized int[] pixels(int rx, int ry, int rw, int rh) {
        int[] out = new int[rw * rh];
        for (int attempt = 0; attempt < 64; attempt++) {
            try {
                ensure();
                // Seqlock: skip the copy entirely if a write is in progress
                // (begin != end) so we don't copy a whole frame mid-write.
                long begin = map.getLong(24);
                if (begin == 0 || begin != map.getLong(32)) {
                    Thread.onSpinWait();
                    continue;
                }
                copyRect(out, rx, ry, rw, rh);
                if (map.getLong(24) == begin) return out;  // no write started during the copy
            } catch (Exception e) {
                // fall through to a fresh remap on next attempt
                try { remap(); } catch (Exception ignored) {}
            }
        }
        return out; // best-effort: return whatever we last copied
    }

    private void copyRect(int[] out, int rx, int ry, int rw, int rh) {
        final int pixBase = HEADER >> 2;        // header occupies ints [0, pixBase)
        final int strideInts = stride >> 2;     // BGRx: stride is a multiple of 4
        final boolean rowInBounds = rx >= 0 && rx + rw <= width;
        int i = 0;
        for (int y = 0; y < rh; y++) {
            int sy = ry + y;
            if (sy < 0 || sy >= height) {        // whole row off-screen -> opaque black
                Arrays.fill(out, i, i + rw, 0xFF000000);
                i += rw;
                continue;
            }
            int rowInt = pixBase + sy * strideInts;
            if (rowInBounds) {
                // Bulk-read the row in one call (no per-pixel bounds checks),
                // then set alpha in a tight primitive loop.
                mapInts.position(rowInt + rx);
                mapInts.get(out, i, rw);
                for (int k = i, end = i + rw; k < end; k++) out[k] = 0xFF000000 | (out[k] & 0x00FFFFFF);
                i += rw;
            } else {                              // rect extends past a screen edge
                for (int x = 0; x < rw; x++) {
                    int sx = rx + x;
                    out[i++] = (sx < 0 || sx >= width)
                            ? 0xFF000000
                            : 0xFF000000 | (mapInts.get(rowInt + sx) & 0x00FFFFFF);
                }
            }
        }
    }
}
