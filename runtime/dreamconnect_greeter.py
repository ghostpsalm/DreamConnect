#!/usr/bin/env python3
"""Greeter mode — serve the GDM login screen to ScreenConnect.

Neither attended nor backstage mode can show the login screen: Mutter refuses
capture and input to anything running against the greeter, so there has never
been a way for an operator to log a box in. Backstage sidesteps that by not
needing a login; it does not solve it.

GNOME already ships the one sanctioned bridge into the greeter:
`gnome-remote-desktop` in **system mode** (Remote Login). A client that
authenticates to it is handed a *separate headless Wayland GDM greeter* — its
own session, its own dynamically-allocated greeter user, `Seat=` empty and
`Remote=yes`. The physical seat0 session is not involved and is not displayed
to. Authenticating there runs the normal PAM stack (`Service=gdm-password`) and
produces a real Wayland user session.

So greeter mode does not fight Mutter. It becomes an RDP *client* of the local
remote-login service and republishes that view through DreamConnect's existing
seam:

      gnome-remote-desktop --system  (127.0.0.1, loopback only)
                │ RDP/TLS
                ▼
          xfreerdp  ──draws──►  private Xvfb  ──ximagesrc──►  shm frame buffer
                                     ▲                              │
                                  XTEST                             ▼
                                     │                     DreamConnect agent
                          control socket (input)          (unmodified) → SC

Capture and input are the only things that differ from `Session`; the shm frame
layout, the control-socket grammar and the agent are untouched. `ControlServer`
talks to whichever session object it was handed, so this class only has to
present the same surface.

The operator flow this enables: pick the "Login screen" entry in ScreenConnect,
see the real greeter, log in as any account, and that account's own session
comes up and registers itself in the picker.

SECURITY — read before enabling. GDM's existing-session lookup
(`find_session_for_user`, daemon/gdm-manager.c) matches on **username only**; it
does not filter by seat. Authenticating here as a user who already holds a
*locked seat0* session makes GDM call `session_unlock()` on that session — which
drops the screen lock on the physical machine with nobody in front of it. Log in
as an account that has no console session (a dedicated support account), never
as the console user. See docs/greeter-login.md.
"""
import os
import subprocess
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402

from dreamconnect_daemon import log, _now_ms  # noqa: E402
# Same notion of "a desktop" the discovery reconciler uses; a tty login is
# Class=user too, and counting it reported a duplicate for every console login.
from dreamconnect_discovery import GRAPHICAL_TYPES  # noqa: E402

# evdev button codes on the control socket (Mutter's vocabulary) -> X button
# numbers. The agent speaks evdev because the Mutter path does; greeter mode
# must accept exactly the same wire values rather than a dialect of its own.
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
EVDEV_TO_X_BUTTON = {BTN_LEFT: 1, BTN_MIDDLE: 2, BTN_RIGHT: 3}

# Scroll is buttons 4/5 (vertical) and 6/7 (horizontal) in X11.
AXIS_VERTICAL, AXIS_HORIZONTAL = 0, 1
AXIS_TO_X_BUTTONS = {AXIS_VERTICAL: (4, 5), AXIS_HORIZONTAL: (6, 7)}

# X11 keycodes are evdev keycodes plus the XKB base offset. This is the whole
# translation: both sides are already using the evdev keymap.
XKB_KEYCODE_OFFSET = 8

# Needed to reach the shifted level of a key (capitals, most punctuation).
KEY_LEFTSHIFT = 42

# A keycode we borrow to type a keysym the greeter's layout has no key for
# (accented characters in a password, say). 255 is above every real key on a
# standard keymap, so remapping it cannot shadow one.
SCRATCH_KEYCODE = 255

DEFAULT_RDP_HOST = "127.0.0.1"
DEFAULT_RDP_PORT = 3389


def evdev_to_x_keycode(evdev_code):
    """evdev keycode -> X11 keycode."""
    return evdev_code + XKB_KEYCODE_OFFSET


def evdev_to_x_button(evdev_button):
    """evdev button code -> X11 button number, or None if we don't carry it.

    Returning None rather than raising keeps an unknown button consistent with
    the daemon's other input paths: dropped quietly, never a broken stream.
    """
    return EVDEV_TO_X_BUTTON.get(evdev_button)


def axis_to_x_button(axis, steps):
    """(axis, signed steps) -> (X button, repeat count).

    X11 has no scroll axis; each step is a button click. Sign picks which of the
    pair, so the caller never has to know the direction convention.
    """
    pair = AXIS_TO_X_BUTTONS.get(axis)
    if pair is None or steps == 0:
        return None, 0
    negative, positive = pair
    return (positive if steps > 0 else negative), abs(int(steps))


def xvfb_argv(display, width, height):
    """Xvfb command line for the private display the RDP client draws on.

    -nolisten tcp because nothing off-box has any business reaching it; the
    display is an implementation detail between two local processes.
    """
    return ["Xvfb", display, "-screen", "0", f"{width}x{height}x24",
            "-nolisten", "tcp"]


def xfreerdp_argv(host, port, username, width, height):
    """RDP client command line.

    /from-stdin:force makes FreeRDP read the password from stdin instead of a
    command line, so the transport credential never reaches argv (and therefore
    never reaches /proc, ps, or an audit log).

    /cert:ignore is deliberate and safe *here* and nowhere else: the peer is
    gnome-remote-desktop on 127.0.0.1 with a self-signed certificate it
    generated locally, reached over loopback where there is no MITM position to
    occupy. Do not copy this flag to a connection that leaves the machine.
    """
    return ["xfreerdp", f"/v:{host}:{port}", f"/u:{username}",
            "/from-stdin:force", "/cert:ignore",
            f"/size:{width}x{height}", "/log-level:WARN"]


def pipeline_desc(display, use_damage=False):
    """ximagesrc -> appsink, matching the shm writer's BGRx expectation.

    use-damage=false: the damage extension makes ximagesrc emit only on change,
    which starves the stall watchdog on a static login screen and reads as a
    dead capture. A greeter is mostly static, so poll instead.
    """
    return (
        f"ximagesrc display-name={display} use-damage={'true' if use_damage else 'false'} ! "
        "videoconvert ! video/x-raw,format=BGRx ! "
        "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
    )


def find_duplicate_sessions(sessions):
    """[(id, user, class, type)] -> [(user, [ids])] for users with >1 desktop.

    Class=user alone is not enough, and assuming it was produced a false
    positive on the first box this ran against: a `tty` login is also
    Class=user, so anyone with a console login plus a desktop looked like a
    double login. The type must be graphical too.

    The other classes are excluded for the same reason as always — logind lists
    a `manager` session per logged-in account and `manager-early`/`greeter`
    entries for display-manager plumbing, and counting those reports a
    duplicate for every single normal login.
    """
    by_user = {}
    for session_id, user, klass, type_ in sessions:
        if klass == "user" and type_ in GRAPHICAL_TYPES:
            by_user.setdefault(user, []).append(session_id)
    return sorted((u, ids) for u, ids in by_user.items() if len(ids) > 1)


def parse_session_properties(text):
    """logind property blocks -> [(id, user, class, type)].

    `loginctl show-session` emits Key=Value lines with a blank line between
    sessions. Parsed rather than reading `list-sessions` columns because that
    table's fields shift with content and there is no stable machine format:
    -o json is accepted and silently ignored on systemd 258.
    """
    sessions, current = [], {}

    def flush():
        if current.get("Id"):
            sessions.append((current["Id"], current.get("Name", ""),
                             current.get("Class", ""), current.get("Type", "")))
        current.clear()

    for line in text.splitlines():
        line = line.strip()
        if not line:
            flush()
            continue
        key, _, value = line.partition("=")
        if key in ("Id", "Name", "Class", "Type"):
            current[key] = value
    flush()
    return sessions


def _list_sessions():
    """[(id, user, class, type)] from logind, or [] if it cannot be read."""
    try:
        listing = subprocess.run(["loginctl", "list-sessions", "--no-legend"],
                                 capture_output=True, text=True, timeout=5,
                                 check=True).stdout
        # Only field 1 (the session id) is positionally safe to read here.
        ids = [line.split()[0] for line in listing.splitlines() if line.split()]
        if not ids:
            return []
        out = subprocess.run(["loginctl", "show-session", *ids,
                              "-p", "Id", "-p", "Name", "-p", "Class", "-p", "Type"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError, IndexError):
        return []
    return parse_session_properties(out)


class GreeterSession:
    """Presents `Session`'s surface, sourced from a local RDP login view.

    Deliberately duck-typed against Session rather than sharing a base class:
    the two have almost nothing in common below the interface (no D-Bus, no
    PipeWire node, no Mutter session lifetime), and a shared base would exist
    only to be overridden.
    """

    def __init__(self, frame, *, width=1920, height=1080, display=":89",
                 rdp_host=DEFAULT_RDP_HOST, rdp_port=DEFAULT_RDP_PORT,
                 rdp_user="dreamconnect", password_file=None,
                 stall_timeout_ms=4000):
        self.frame = frame
        self.width, self.height = width, height
        self.display = display
        self.rdp_host, self.rdp_port = rdp_host, rdp_port
        self.rdp_user, self.password_file = rdp_user, password_file
        self.stall_timeout_ms = stall_timeout_ms

        # node_id exists only so the NODE control command has an answer. There
        # is no PipeWire node in this mode; say so rather than inventing one.
        self.node_id = 0
        self.active_clients = 0
        self.pipeline = None
        self.xvfb = self.rdp = None
        self._x = None          # Xlib display, opened once the Xvfb is up
        self._xtest = None
        self._last_frame_ms = 0

    # ---- lifecycle ---------------------------------------------------------
    def start(self):
        """Bring up everything except the RDP connection.

        The connection is opened lazily, on first attach. Holding it open from
        startup would keep a GDM greeter session alive on every endpoint for as
        long as the daemon runs, for nobody's benefit — and every one of the
        session-lifecycle hazards is live only while that connection exists.
        The Xvfb and the capture pipeline are cheap and stay up, so the picker
        entry is always there to be chosen.
        """
        self._start_xvfb()
        self._connect_x()
        self._start_pipeline()

    def _start_xvfb(self):
        self.xvfb = subprocess.Popen(xvfb_argv(self.display, self.width, self.height),
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        # Wait for the socket rather than sleeping a guessed interval: a slow
        # box would otherwise have the RDP client race the server it draws on.
        sock = f"/tmp/.X11-unix/X{self.display.lstrip(':')}"
        for _ in range(100):
            if os.path.exists(sock):
                return
            if self.xvfb.poll() is not None:
                raise RuntimeError(f"Xvfb exited immediately (rc={self.xvfb.returncode}); "
                                   f"is display {self.display} already in use?")
            time.sleep(0.05)
        raise RuntimeError(f"Xvfb did not create {sock} within 5s")

    def _connect_x(self):
        from Xlib import display as xdisplay
        from Xlib.ext import xtest
        self._x = xdisplay.Display(self.display)
        if not self._x.query_extension("XTEST"):
            raise RuntimeError("the private X server has no XTEST extension; "
                               "input injection is impossible without it")
        self._xtest = xtest

    def _start_rdp(self):
        argv = xfreerdp_argv(self.rdp_host, self.rdp_port, self.rdp_user,
                             self.width, self.height)
        env = dict(os.environ, DISPLAY=self.display)
        # The password goes in on stdin and nowhere else. Reading it here rather
        # than holding it on the instance keeps it out of tracebacks and repr().
        self.rdp = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        try:
            self.rdp.stdin.write(self._read_password())
            self.rdp.stdin.flush()
        finally:
            self.rdp.stdin.close()
        log(f"greeter: RDP client -> {self.rdp_host}:{self.rdp_port} "
            f"as {self.rdp_user} on {self.display}")

    def _read_password(self):
        if not self.password_file:
            raise RuntimeError("greeter mode needs --rdp-password-file: the "
                               "remote-login transport credential")
        with open(self.password_file, "rb") as f:
            # One trailing newline is what FreeRDP expects; strip whatever the
            # file happens to end with and add exactly one.
            return f.read().strip() + b"\n"

    def _start_pipeline(self):
        self.pipeline = Gst.parse_launch(pipeline_desc(self.display))
        self.pipeline.get_by_name("sink").connect("new-sample", self._on_sample)
        self._last_frame_ms = _now_ms()
        self.pipeline.set_state(Gst.State.PLAYING)

    def _reap(self, proc, name):
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                log(f"greeter: {name} ignored SIGTERM, killing")
                proc.kill()

    def _stop_rdp(self):
        if self._rdp_alive():
            log("greeter: last client detached; closing the login view")
        self._reap(self.rdp, "xfreerdp")
        self.rdp = None

    def stop(self):
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None
        self._stop_rdp()
        self._reap(self.xvfb, "Xvfb")
        self.xvfb = None

    # ---- capture -----------------------------------------------------------
    def _on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if not sample:
            return Gst.FlowReturn.OK
        self._last_frame_ms = _now_ms()
        if self.active_clients == 0:
            return Gst.FlowReturn.OK  # nothing reading; skip the copy into shm
        buf = sample.get_buffer()
        caps = sample.get_caps().get_structure(0)
        w, h = caps.get_value("width"), caps.get_value("height")
        ok, mapinfo = buf.map(Gst.MapFlags.READ)
        if ok:
            stride = mapinfo.size // h
            try:
                self.frame.write(mapinfo.data, w, h, stride)
            finally:
                buf.unmap(mapinfo)
            if (w, h) != (self.width, self.height):
                self.width, self.height = w, h
                log(f"greeter: stream geometry {w}x{h}")
        return Gst.FlowReturn.OK

    def client_connected(self):
        """First attach opens the login view."""
        self.active_clients += 1
        if self.active_clients == 1 and not self._rdp_alive():
            try:
                self._start_rdp()
            except Exception as e:  # noqa: BLE001
                # Never let a failed connect take the daemon down: the operator
                # sees a blank view and the watchdog keeps retrying, which beats
                # a dead unit and no picker entry at all.
                log(f"greeter: could not open the login view: {e}")

    def client_disconnected(self):
        """Last detach closes it again, and GDM reaps the greeter behind it.

        A session created through the greeter is NOT ended by this — it is a
        real login and outlives the connection. Re-attaching lands on a fresh
        greeter and requires authenticating again, which is the same boundary a
        reconnect faces anywhere else.
        """
        self.active_clients = max(0, self.active_clients - 1)
        if self.active_clients == 0:
            self._stop_rdp()

    def _rdp_alive(self):
        return self.rdp is not None and self.rdp.poll() is None

    def _watchdog(self):
        """Restart the RDP client if the view goes dead while someone is watching.

        The failure this catches is the RDP connection dropping — the Xvfb keeps
        serving its last contents, so ximagesrc happily reports frames and only
        the *client* is gone. Check the process, not just frame arrival.

        Gated on a client being attached, because with lazy connect "no client,
        no RDP" is the intended resting state, not a fault. An operator who
        attaches gets a fresh connection from client_connected(); this only has
        to cover the connection dying *underneath* somebody who is watching.
        """
        from gi.repository import GLib
        if self.stall_timeout_ms <= 0 or self.active_clients == 0:
            return GLib.SOURCE_CONTINUE
        if self.rdp and self.rdp.poll() is not None:
            log(f"greeter: RDP client exited (rc={self.rdp.returncode}); reconnecting")
            try:
                self._start_rdp()
            except Exception as e:  # noqa: BLE001
                log(f"greeter: reconnect failed: {e}")
        return GLib.SOURCE_CONTINUE

    # ---- input -------------------------------------------------------------
    def motion_abs(self, x, y):
        from Xlib import X
        self._xtest.fake_input(self._x, X.MotionNotify, x=int(x), y=int(y))
        self._x.sync()

    def button(self, evdev_button, pressed):
        x_button = evdev_to_x_button(evdev_button)
        if x_button is None:
            return
        self._fake_button(x_button, pressed)

    def axis_discrete(self, axis, steps):
        x_button, count = axis_to_x_button(axis, steps)
        if x_button is None:
            return
        for _ in range(count):
            self._fake_button(x_button, True)
            self._fake_button(x_button, False)

    def key_code(self, evdev_code, pressed):
        self._fake_key(evdev_to_x_keycode(evdev_code), pressed)

    def key_sym(self, keysym, pressed):
        """Inject a keysym, synthesising Shift when the symbol needs it.

        keysym_to_keycode() alone is a trap: it returns the keycode carrying the
        symbol but not *which level* of it. 'D' and 'd' live on one keycode, so
        pressing it bare yields 'd' — a password typed through here would come
        out silently lowercased and simply fail to authenticate, with nothing in
        any log to say why. keysym_to_keycodes() gives (keycode, index) pairs;
        an odd index is a shifted level.
        """
        keycode, needs_shift = self._lookup_keysym(keysym)
        if keycode is None:
            # No key on the greeter's layout produces this symbol. Borrow one,
            # mapping it at both levels so it needs no modifier.
            self._x.change_keyboard_mapping(SCRATCH_KEYCODE, [[keysym, keysym]])
            self._x.sync()
            try:
                self._fake_key(SCRATCH_KEYCODE, pressed)
            finally:
                if not pressed:  # release is the second half; restore after it
                    self._x.change_keyboard_mapping(SCRATCH_KEYCODE, [[0, 0]])
                    self._x.sync()
            return
        # Shift wraps the key on the way in and unwraps on the way out, so it is
        # held across the caller's separate press and release calls.
        if needs_shift and pressed:
            self._fake_key(evdev_to_x_keycode(KEY_LEFTSHIFT), True)
        self._fake_key(keycode, pressed)
        if needs_shift and not pressed:
            self._fake_key(evdev_to_x_keycode(KEY_LEFTSHIFT), False)

    def _lookup_keysym(self, keysym):
        """(X keycode, needs_shift) for a keysym, or (None, False) if unmapped."""
        for keycode, index in self._x.keysym_to_keycodes(keysym):
            if keycode:
                return keycode, bool(index & 1)
        return None, False

    def type_string(self, text):
        for ch in text:
            keysym = ord(ch)
            # Latin-1 and ASCII are their own keysyms; everything else uses the
            # Unicode keysym range.
            if keysym > 0xFF:
                keysym += 0x01000000
            self.key_sym(keysym, True)
            self.key_sym(keysym, False)

    def _fake_key(self, keycode, pressed):
        from Xlib import X
        self._xtest.fake_input(self._x, X.KeyPress if pressed else X.KeyRelease,
                               keycode)
        self._x.sync()

    def _fake_button(self, x_button, pressed):
        from Xlib import X
        self._xtest.fake_input(self._x,
                               X.ButtonPress if pressed else X.ButtonRelease,
                               x_button)
        self._x.sync()

    # ---- duplicate-session detection ---------------------------------------
    # Reported, never acted on. DreamConnect does not end a session it did not
    # create, and a duplicate is the operator's call to resolve, not ours.
    def duplicate_sessions(self):
        """Users holding more than one graphical session: [(user, [ids]), ...].

        The case worth catching: someone logs in through the greeter, then the
        same account logs in at the physical console. GDM cannot migrate a
        seatless session onto a seat — ActivateSessionOnSeat fails with "not on
        seat seat0" — so instead of reusing it, it starts a second one and that
        user now has two live desktops.
        """
        return find_duplicate_sessions(_list_sessions())

    # ---- operator commands that do not apply here --------------------------
    # A headless greeter has no physical panel to blank and no local idle timer
    # to inhibit. Accept and ignore rather than erroring: the agent sends these
    # unconditionally, and an ERR on the control socket would look like a fault.
    def set_wake_lock(self, on):
        pass

    def set_blank(self, on):
        pass

    def _release_wake_lock(self):
        pass
