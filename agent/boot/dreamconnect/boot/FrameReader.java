package dreamconnect.boot;

import java.io.RandomAccessFile;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;

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
    private int width, height, stride;

    FrameReader(String path) {
        this.path = path;
    }

    private synchronized void ensure() throws Exception {
        long fileLen = new java.io.File(path).length();
        if (map != null && raf != null && raf.length() == fileLen) return;
        remap();
    }

    private void remap() throws Exception {
        if (raf != null) try { raf.close(); } catch (Exception ignored) {}
        raf = new RandomAccessFile(path, "r");
        long len = raf.length();
        map = raf.getChannel().map(FileChannel.MapMode.READ_ONLY, 0, len);
        map.order(ByteOrder.LITTLE_ENDIAN);
        long magic = map.getInt(0) & 0xffffffffL;
        if (magic != MAGIC) throw new Exception("bad magic " + Long.toHexString(magic));
        width = map.getInt(8);
        height = map.getInt(12);
        stride = map.getInt(16);
    }

    int width() { try { ensure(); } catch (Exception e) { return width; } return width; }
    int height() { try { ensure(); } catch (Exception e) { return height; } return height; }

    /** ARGB of a single pixel (for Robot.getPixelColor). */
    int pixel(int x, int y) {
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
    int[] pixels(int rx, int ry, int rw, int rh) {
        int[] out = new int[rw * rh];
        for (int attempt = 0; attempt < 16; attempt++) {
            try {
                ensure();
                long end = map.getLong(32);
                copyRect(out, rx, ry, rw, rh);
                long begin = map.getLong(24);
                if (begin == end && begin != 0) return out;
            } catch (Exception e) {
                // fall through to a fresh remap on next attempt
                try { remap(); } catch (Exception ignored) {}
            }
        }
        return out; // best-effort: return whatever we last copied
    }

    private void copyRect(int[] out, int rx, int ry, int rw, int rh) {
        int i = 0;
        for (int y = 0; y < rh; y++) {
            int sy = ry + y;
            if (sy < 0 || sy >= height) { i += rw; continue; }
            int rowBase = HEADER + sy * stride;
            for (int x = 0; x < rw; x++) {
                int sx = rx + x;
                if (sx < 0 || sx >= width) { out[i++] = 0xFF000000; continue; }
                int bgrx = map.getInt(rowBase + sx * 4);
                out[i++] = 0xFF000000 | (bgrx & 0x00FFFFFF);
            }
        }
    }
}
