package dreamconnect.boot;

import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SelectionKey;
import java.nio.channels.Selector;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;

/**
 * Thin, resilient client for the dreamconnect runtime daemon's Unix control
 * socket. Runs inside ScreenConnect's JVM (bootstrap classloader). One command
 * per line; one reply line. Reconnects transparently on failure so a daemon
 * restart doesn't wedge the client.
 *
 * Not final: BootTests substitutes a subclass that captures input() lines.
 */
class DaemonClient {
    private static final long READ_TIMEOUT_MS = 2000;
    private static final long CONNECT_TIMEOUT_MS = 2000;

    private final String path;
    private final String expectedUser;   // null = unauthenticated (operator config)
    private boolean retired;             // close() is terminal, not a disconnect
    private SocketChannel ch;
    private final ByteBuffer rbuf = ByteBuffer.allocate(256);

    DaemonClient(String path) {
        this(path, null);
    }

    /**
     * A client that will only ever talk to a socket answered by
     * {@code expectedUser}. The registry says which account serves a session;
     * this is what makes the socket prove it, before a single byte is sent.
     * A null expectedUser skips authentication — that is the operator's own
     * shm=/socket= configuration, which answers to no registry entry.
     */
    DaemonClient(String path, String expectedUser) {
        this.path = path;
        this.expectedUser = expectedUser;
    }

    /**
     * Seam added by the test author (issue #51 round 5), not logic: the account
     * this client demands on every connect, including every transparent
     * reconnect. Asserted in BootTests.testAttachedClientIsPeerAuthenticated.
     */
    String expectedUser() {
        return expectedUser;
    }

    /**
     * The account whose process is listening on the other end, from the kernel
     * rather than from the path used to reach it — so a symlink pointing at
     * another session's socket still names that session's owner, not the link's.
     * Null when there is no peer to ask.
     *
     * Reflective because jdk.net is a platform module and these boot classes
     * load in the bootstrap loader; the returned principal must be read through
     * the UserPrincipal *interface*, since its implementation class lives in
     * sun.nio.fs, which java.base does not export.
     */
    static String peerUser(SocketChannel ch) {
        try {
            Class<?> options = Class.forName("jdk.net.ExtendedSocketOptions");
            @SuppressWarnings("unchecked")
            java.net.SocketOption<Object> soPeerCred =
                    (java.net.SocketOption<Object>) options.getField("SO_PEERCRED").get(null);
            Object principal = ch.getOption(soPeerCred);
            if (principal == null) return null;
            Object user = principal.getClass().getMethod("user").invoke(principal);
            return ((java.nio.file.attribute.UserPrincipal) user).getName();
        } catch (Throwable noPeer) {
            return null;
        }
    }

    /**
     * Connect, bounded. A blocking connect to a Unix socket that is bound but
     * never accept()ed waits forever once the listener's backlog is full — and
     * any local user can arrange that for a socket they own. Discovery probes
     * such sockets from inside a lock that the session-picker path also takes,
     * so an unbounded connect here wedges the whole client. Non-blocking
     * connect plus a deadline keeps a hostile or hung daemon local to itself.
     */
    private synchronized void ensure() throws Exception {
        // Transparent reconnection is for a daemon restart, never for a client
        // the bridge has retired. A retired client's session is one the operator
        // has left; carrying input back to it is exactly the wrong-session bug.
        if (retired) throw new java.io.IOException("client retired: " + path);
        if (ch != null && ch.isConnected()) return;
        SocketChannel c = SocketChannel.open(StandardProtocolFamily.UNIX);
        try {
            c.configureBlocking(false);
            if (!c.connect(UnixDomainSocketAddress.of(path))) {
                try (Selector sel = Selector.open()) {
                    c.register(sel, SelectionKey.OP_CONNECT);
                    long deadline = System.currentTimeMillis() + CONNECT_TIMEOUT_MS;
                    while (!c.finishConnect()) {
                        long left = deadline - System.currentTimeMillis();
                        if (left <= 0) {
                            throw new java.io.IOException(
                                    "connect timed out after " + CONNECT_TIMEOUT_MS + " ms: " + path);
                        }
                        sel.select(left);
                        sel.selectedKeys().clear();
                    }
                }
            }
            c.configureBlocking(true);
            // Authenticate BEFORE the channel is published: send()/input() write
            // as soon as ensure() returns, and an operator's keystrokes must
            // never reach a peer that has not proved who it is.
            if (expectedUser != null) {
                String actual = peerUser(c);
                if (!expectedUser.equals(actual)) {
                    throw new java.io.IOException("peer of " + path + " is "
                            + (actual == null ? "unidentifiable" : "'" + actual + "'")
                            + ", not '" + expectedUser + "'");
                }
            }
            ch = c;
        } catch (Exception e) {
            try { c.close(); } catch (Exception ignored) {}
            throw e;
        }
    }

    /** Send a command; return the reply line, or null on error. */
    synchronized String send(String cmd) {
        try {
            ensure();
            ch.write(ByteBuffer.wrap((cmd + "\n").getBytes(StandardCharsets.US_ASCII)));
            return readLine();
        } catch (Exception e) {
            disconnect();       // transient: the next call may reconnect
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
            disconnect();       // transient: the next call may reconnect
        }
    }

    /**
     * Read one reply line, bounded by READ_TIMEOUT_MS so a daemon that accepts
     * but never replies can't wedge the caller (the SC thread constructing the
     * Robot at attach). Uses a temporary selector; send() is low-frequency
     * (control commands only), so the per-call selector cost is irrelevant.
     */
    private String readLine() throws Exception {
        ch.configureBlocking(false);
        try (Selector sel = Selector.open()) {
            ch.register(sel, SelectionKey.OP_READ);
            StringBuilder sb = new StringBuilder();
            long deadlineNanos = System.nanoTime() + READ_TIMEOUT_MS * 1_000_000L;
            while (true) {
                long remainMs = (deadlineNanos - System.nanoTime()) / 1_000_000L;
                if (remainMs <= 0) throw new Exception("read timeout");
                sel.select(remainMs);
                rbuf.clear();
                rbuf.limit(1);
                int n = ch.read(rbuf);
                if (n < 0) throw new Exception("eof");
                if (n == 0) continue;
                char c = (char) rbuf.array()[0];
                if (c == '\n') return sb.toString();
                sb.append(c);
            }
        } finally {
            if (ch != null) ch.configureBlocking(true);
        }
    }

    /**
     * Drop the connection but stay usable: the next call reconnects. This is
     * the transient-error path, so a daemon restart doesn't wedge the client.
     */
    private synchronized void disconnect() {
        if (ch != null) {
            try { ch.close(); } catch (Exception ignored) {}
            ch = null;
        }
    }

    /**
     * Retire this client for good — used on discovery probes, and on the old
     * client when the bridge attaches to a different session. Terminal rather
     * than a disconnect: a retired client must never reconnect and carry input
     * back to a session the operator has left.
     */
    synchronized void close() {
        retired = true;
        disconnect();
    }
}
