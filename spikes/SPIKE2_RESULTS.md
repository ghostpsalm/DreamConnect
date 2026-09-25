# Spike 2 — Does a virtual monitor outlive the peer that created it? — **NOT RUN** ⬜

Date: — · Host: —

**This spike has not been run on any box.** Nothing below is a result. The table
is the shape of the answer, not the answer; the verdict row stays blank until
someone runs [`spike2_virtual_monitor_lifetime.py`](spike2_virtual_monitor_lifetime.py)
on a live Fedora GNOME box and pastes what it printed.

## Question (#67)

#55 closed every virtual-monitor leak the daemon can reach in code: `start()`
stops the session it replaces, and `main()`'s `finally` stops the session on
SIGTERM/SIGINT, so `systemctl --user restart` releases too. A SIGKILL, a crash
or an OOM reaches none of that — that process runs nothing at all — so the
monitor's fate is Mutter's alone:

> does Mutter drop a `RecordVirtual` monitor when the creating D-Bus peer
> disconnects without stopping its session?

**dropped** → SIGKILL is already safe and #67 closes on this evidence.
**retained** → every crash adds a monitor, and #67 needs a remedy rather than
the detector it currently has: the X screen grows, gnome-shell puts its top bar
on a monitor we do not capture, and the operator gets a half-black desktop —
the #55 symptom, reintroduced by a kill.

## What is already known, and why none of it settles the question

| Evidence | What it shows | Why it is not the answer |
|---|---|---|
| [`SPIKE0_RESULTS.md`](SPIKE0_RESULTS.md) fact 2 — "Mutter destroys the session the instant the creating connection drops" | Session lifetime follows the connection | Observed on a **clean** exit, and about the *session*, not the virtual monitor it conjured |
| #55's live box: journal logged `Added virtual monitor` **25** times, X screen was **2560** wide = **2** monitors | 23 monitors were reclaimed by something | By *what* is not established — not all 25 daemons were killed, and a clean restart releases one anyway |
| The daemon's own startup line (`virtual capture starting; …`, `Session._report_monitors_before_virtual`) | What each start inherited | Permanent detector, not a controlled experiment: it cannot say whether the previous exit was clean |

## How to run it

As the session's own user, on the box whose Mutter is in question. **A backstage
session is the case that matters** — that is where the leak bites.

```sh
python3 spikes/spike2_virtual_monitor_lifetime.py
```

**Do not run it while an operator is attached**: it briefly adds a monitor,
which resizes the X screen and moves windows about. It exits 0 on `dropped`,
1 on `retained`, and refuses to give a verdict at all if `RecordVirtual` never
added a monitor in the first place (that run is inconclusive — record nothing).

The cheap alternative, on a box already running backstage, which reads the
detector instead of the spike:

```sh
systemctl --user kill -s KILL dreamconnect-daemon
# Restart=always brings it back in ~2s; read the new startup line:
journalctl --user -u dreamconnect-daemon -n 20
```

`no monitor present beforehand` ⇒ Mutter reclaimed the dead peer's monitor.
Monitors named ⇒ it did not. Weaker than the spike (it cannot prove the killed
daemon had actually conjured one), so prefer the spike where both are possible.

## Result

| | |
|---|---|
| Date / host / GNOME version | — |
| Monitors before | — |
| Monitors during (conjured) | — |
| Monitors after SIGKILL + settle | — |
| **VERDICT** | **—** |

Paste the script's `--- paste into spikes/SPIKE2_RESULTS.md ---` block here,
change the title's **NOT RUN** ⬜ to **dropped** ✅ or **retained** ❌, and say
on #67 which it was.
