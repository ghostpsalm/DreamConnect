package dreamconnect.boot;

import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;

/**
 * Thin, resilient client for the dreamconnect runtime daemon's Unix control
 * socket. Runs inside ScreenConnect's JVM (bootstrap classloader). One command
 * per line; one reply line. Reconnects transparently on failure so a daemon
 * restart doesn't wedge the client.
 */
final class DaemonClient {
    private final String path;
    private SocketChannel ch;
    private final ByteBuffer rbuf = ByteBuffer.allocate(256);

    DaemonClient(String path) {
        this.path = path;
    }

    private synchronized void ensure() throws Exception {
        if (ch != null && ch.isConnected()) return;
        SocketChannel c = SocketChannel.open(StandardProtocolFamily.UNIX);
        c.connect(UnixDomainSocketAddress.of(path));
        ch = c;
    }

    /** Send a command; return the reply line, or null on error. */
    synchronized String send(String cmd) {
        try {
            ensure();
            ch.write(ByteBuffer.wrap((cmd + "\n").getBytes(StandardCharsets.US_ASCII)));
            return readLine();
        } catch (Exception e) {
            close();
            return null;
        }
    }

    /**
     * Fire-and-forget input on the hot path: write and return immediately. The
     * daemon sends NO reply for input commands, so there's nothing to read and
     * the caller (ScreenConnect's input thread) never blocks on an ack.
     */
    synchronized void input(String cmd) {
        try {
            ensure();
            ch.write(ByteBuffer.wrap((cmd + "\n").getBytes(StandardCharsets.US_ASCII)));
        } catch (Exception e) {
            close();
        }
    }

    private String readLine() throws Exception {
        StringBuilder sb = new StringBuilder();
        while (true) {
            rbuf.clear();
            rbuf.limit(1);
            if (ch.read(rbuf) < 0) throw new Exception("eof");
            char c = (char) rbuf.array()[0];
            if (c == '\n') return sb.toString();
            sb.append(c);
        }
    }

    private synchronized void close() {
        if (ch != null) {
            try { ch.close(); } catch (Exception ignored) {}
            ch = null;
        }
    }
}
