# dreamconnect Java agent

The in-JVM half of the bridge. Injected into ScreenConnect's JVM with
`JAVA_TOOL_OPTIONS=-javaagent:dreamconnect-agent.jar`, it makes `java.awt.Robot`
serve capture and input from the Wayland side (via the runtime daemon) instead
of X11 — without modifying any ScreenConnect binary.

## How it works

`java.awt.Robot` delegates every operation to a private `peer`
(`java.awt.peer.RobotPeer`) that the AWT toolkit builds — normally the X11 one,
which is exactly what's broken under Wayland. The agent replaces that peer:

1. **premain** (`DreamConnectAgent`):
   - appends a bundled **boot jar** to the *bootstrap* classloader, so the
     platform class `java.awt.Robot` can see our peer;
   - opens `java.desktop`'s non-exported `java.awt.peer` / `sun.awt` packages to
     the boot classes via `Instrumentation.redefineModule` (JAVA_TOOL_OPTIONS
     can't carry `--add-exports`);
   - instruments `java.awt.Robot.init(GraphicsDevice)` with a ByteBuddy advice.
2. **advice** (`RobotInitAdvice`): at `init` exit, overwrites `peer` with a
   `DreamConnectRobotPeer`. `suppress = Throwable` means any failure leaves the
   original X11 peer in place — the client degrades, never crashes.
3. **peer** (`DreamConnectRobotPeer`, bootstrap):
   - `getRGBPixels` / `getRGBPixel` → read the daemon's shared-memory frame;
   - `mouseMove` / `mousePress` / `mouseWheel` / `keyPress` … → send evdev-coded
     commands over the daemon's Unix socket (`AwtEvdev` does AWT→evdev);
   - `useAbsoluteCoordinates` → true (we inject absolute pointer motion).

One seam, every Robot method rerouted, X11 never touched.

## Build

```sh
./build.sh          # fetches ByteBuddy (cached in lib/), outputs target/dist/
```
Produces `target/dist/dreamconnect-agent.jar` — self-contained (ByteBuddy shaded
in, boot jar embedded). Requires a JDK (built/tested on JDK 25).

## Agent options

Passed after the jar path: `-javaagent:dreamconnect-agent.jar=shm=…,socket=…,debug=true`

| option | default | meaning |
|--------|---------|---------|
| `shm` | `/dev/shm/dreamconnect.frame` | shared-memory frame buffer path |
| `socket` | `$XDG_RUNTIME_DIR/dreamconnect.sock` or `/run/user/1000/dreamconnect.sock` | daemon control socket |
| `debug` | `false` | verbose logging |

Also honours `DREAMCONNECT_SHM` / `DREAMCONNECT_SOCKET` from the environment.
Because ScreenConnect runs as root while the daemon runs as the desktop user,
the defaults point at the user's runtime paths (root can read them).

## Validate

With the daemon running, exercise the real `Robot` API under the agent:

```sh
java -javaagent:target/dist/dreamconnect-agent.jar -cp . ToyRobot
```
(A `Robot().createScreenCapture(...)` returns the live desktop; `mouseMove`
moves the real Wayland cursor.)
