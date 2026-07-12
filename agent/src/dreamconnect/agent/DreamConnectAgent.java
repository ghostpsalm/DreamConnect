package dreamconnect.agent;

import java.io.File;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.instrument.Instrumentation;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.jar.JarFile;

import net.bytebuddy.agent.builder.AgentBuilder;
import net.bytebuddy.asm.Advice;
import net.bytebuddy.description.type.TypeDescription;
import net.bytebuddy.matcher.ElementMatchers;

import static net.bytebuddy.matcher.ElementMatchers.named;
import static net.bytebuddy.matcher.ElementMatchers.takesArgument;

/**
 * dreamconnect Java agent. Injected into ScreenConnect's JVM via
 * JAVA_TOOL_OPTIONS=-javaagent:. At premain it:
 *   1. loads the bootstrap peer classes into the bootstrap classloader (so the
 *      platform class java.awt.Robot can reference them);
 *   2. opens java.desktop's java.awt.peer / sun.awt packages to those classes
 *      (JAVA_TOOL_OPTIONS can't carry --add-exports, so we do it here);
 *   3. instruments java.awt.Robot.init to swap in the dreamconnect peer.
 */
public final class DreamConnectAgent {

    public static void premain(String args, Instrumentation inst) {
        try {
            // ByteBuddy: tolerate class-file versions newer than it knows.
            System.setProperty("net.bytebuddy.experimental", "true");

            // 1. Bootstrap-inject the boot jar (bundled as a resource).
            File bootJar = extractBootJar();
            inst.appendToBootstrapClassLoaderSearch(new JarFile(bootJar));

            // 2. Open the non-exported platform packages to the boot classes.
            Class<?> bridge = Class.forName("dreamconnect.boot.Bridge", true, null);
            Module bootModule = bridge.getModule();
            Module desktop = java.awt.Robot.class.getModule();
            Map<String, Set<Module>> exports = new HashMap<>();
            exports.put("java.awt.peer", Set.of(bootModule));
            exports.put("sun.awt", Set.of(bootModule));
            inst.redefineModule(desktop, Set.of(), exports, Map.of(), Set.of(), Map.of());

            // 3. Configure the bridge from agent args (shm=…,socket=…,debug=…).
            bridge.getMethod("configure", String.class).invoke(null, args);

            // 4. Instrument java.awt.Robot.init(GraphicsDevice).
            new AgentBuilder.Default()
                    .disableClassFormatChanges()
                    .with(AgentBuilder.RedefinitionStrategy.RETRANSFORMATION)
                    .ignore(ElementMatchers.nameStartsWith("net.bytebuddy.")
                            .or(ElementMatchers.nameStartsWith("dreamconnect.")))
                    .type(named("java.awt.Robot"))
                    .transform((builder, type, cl, module, pd) ->
                            builder.visit(Advice.to(RobotInitAdvice.class)
                                    .on(named("init")
                                            .and(takesArgument(0, named("java.awt.GraphicsDevice"))))))
                    .installOn(inst);

            System.err.println("[dreamconnect-agent] installed; Robot peer will be swapped on next Robot()");
        } catch (Throwable t) {
            // Never take down the client: log and let ScreenConnect run as-is.
            System.err.println("[dreamconnect-agent] premain failed; ScreenConnect continues on X11: " + t);
            t.printStackTrace();
        }
    }

    private static File extractBootJar() throws Exception {
        File out = File.createTempFile("dreamconnect-boot", ".jar");
        out.deleteOnExit();
        try (InputStream in = DreamConnectAgent.class.getResourceAsStream("/dreamconnect-boot.jar");
             OutputStream os = Files.newOutputStream(out.toPath())) {
            if (in == null) throw new IllegalStateException("embedded dreamconnect-boot.jar missing");
            in.transferTo(os);
        }
        return out;
    }

    private DreamConnectAgent() {}
}
