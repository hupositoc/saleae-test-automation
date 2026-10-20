# -*- coding: utf-8 -*-
"""
SaleaeGuard - Saleae Logic 2 capture watchdog built on the official Automation API.

Target fault
------------
An EMC burst hits the DUT, the Saleae takes a USB reset and drops off the PC for
a moment, and the capture dies. The watchdog has to notice that momentary drop
and get logging running again.

Why the Automation API and not graphio.log / SendKeys (all measured on site):
  * graphio.log is 4 KiB block-buffered. Observed flush lag 45-77 s, and every
    log file on disk ends on a 4096-byte boundary, so the tail is never flushed.
    It cannot carry real-time state.
  * The "r" hotkey is ToggleRecording (Start/Stop), so sending it blindly will
    STOP a healthy capture.
  * WScript.Shell AppActivate returned True while focus was on another process.
  * Get-PnpDevice -PresentOnly took ~4.4 s and still reported a disabled device
    (Code 22) as present.
The Automation API answers all of this: get_devices() in ~3 ms, real vs
simulation devices flagged explicitly, and separate StartCapture / StopCapture.

Detection strategy - deliberately two independent layers, because a USB reset
can leave Logic in either of two states:
  A) Logic ends the recording session (what the site's graphio.log shows after a
     real drop: "USB device removed" then "stop capture"). The busy-probe then
     reports not-recording and we restart.
  B) Logic keeps a stale "recording" session. The busy-probe would report
     healthy - a false healthy. So USB presence is tracked independently at
     ~0.25 s and ANY observed absence forces a hard restart regardless of what
     the busy-probe says.
Layer B is what actually covers the burst symptom; layer A is the steady-state
check. Optional --rotate-seconds adds a third backstop by recycling the capture
periodically, which caps how long a stale session can ever survive.

The polling hot path never shells out to PowerShell (that costs 200-400 ms per
call); it only uses get_devices(), and a dead gRPC channel is itself the signal
that Logic went away.

Portability - nothing machine-specific is hard-coded:
  * logic.exe is discovered via PATH, then the registry, then common dirs.
  * Config is read from %APPDATA%\\Logic\\config.json.
  * The capture device comes from the API (first non-simulation device), so no
    USB VID/PID appears anywhere.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime

try:
    import saleae.automation as sa
except ImportError:
    sys.stderr.write(
        "logic2-automation is not installed.\n"
        "Run SETUP.bat once on this PC, then start again.\n"
    )
    raise SystemExit(2)


DEFAULT_PORT = 10430
DEFAULT_CHANNELS = "0,1,2,3,4"
DEFAULT_RATE = 5000000
BUSY_MARKERS = ("cannot switch sessions while recording",)
# Transient states that just need another go, not a session teardown.
TRANSIENT_MARKERS = ("cannot create session while creating another session",)
# Capture ids restart at 1 for every Logic process and only ever increment, so a
# short scan is enough to find an orphan session left by a previous run.
MAX_SCAN_CAPTURE_ID = 32
PS = ["powershell.exe", "-NoProfile", "-Command"]


def log(msg, path=None):
    line = "[%s] %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3], msg)
    print(line, flush=True)
    if path:
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass


# ---------------------------------------------------------------- discovery
def find_logic_exe():
    """Locate logic.exe without hard-coding an install path."""
    hit = shutil.which("logic") or shutil.which("Logic")
    if hit:
        return hit

    roots = [os.environ.get("ProgramFiles"),
             os.environ.get("ProgramFiles(x86)"),
             os.environ.get("LOCALAPPDATA")]
    for root in filter(None, roots):
        for sub in ("Logic", os.path.join("Programs", "Logic")):
            cand = os.path.join(root, sub, "Logic.exe")
            if os.path.isfile(cand):
                return cand

    query = (
        "(Get-ItemProperty "
        "'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*',"
        "'HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' "
        "-ErrorAction SilentlyContinue | "
        "Where-Object { $_.DisplayName -like '*Logic*' -and $_.InstallLocation } | "
        "Select-Object -First 1 -ExpandProperty InstallLocation)"
    )
    try:
        out = subprocess.run(PS + [query], capture_output=True, text=True,
                             timeout=30).stdout.strip()
        if out:
            cand = os.path.join(out, "Logic.exe")
            if os.path.isfile(cand):
                return cand
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def config_path():
    appdata = os.environ.get("APPDATA")
    return os.path.join(appdata, "Logic", "config.json") if appdata else None


def ensure_automation_enabled(logfile=None):
    """Turn on automationServerEnabled. Returns True if the file was changed."""
    path = config_path()
    if not path or not os.path.isfile(path):
        log("config.json not found - run Logic once on this PC first.", logfile)
        return False

    raw = open(path, "rb").read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    try:
        cfg = json.loads(raw.decode("utf-8-sig"))
    except ValueError:
        log("config.json is not valid JSON - leaving it untouched.", logfile)
        return False

    if cfg.get("automationServerEnabled") is True:
        return False

    backup = path + ".saleaeguard.bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        log("config.json backed up -> %s" % backup, logfile)

    cfg["automationServerEnabled"] = True
    body = json.dumps(cfg, ensure_ascii=False, indent=2).encode("utf-8")
    with open(path, "wb") as fh:
        fh.write((b"\xef\xbb\xbf" if bom else b"") + body)
    log("automationServerEnabled set to true (Logic must restart).", logfile)
    return True


def logic_running():
    """Only used off the hot path - this costs a PowerShell round trip."""
    try:
        out = subprocess.run(
            PS + ["@(Get-Process -Name 'logic' -ErrorAction SilentlyContinue).Count"],
            capture_output=True, text=True, timeout=30).stdout.strip()
        return int(out or "0") > 0
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def kill_logic(logfile=None):
    subprocess.run(
        PS + ["Get-Process -Name 'logic' -ErrorAction SilentlyContinue | Stop-Process -Force"],
        capture_output=True, text=True)
    time.sleep(3)
    log("Logic terminated.", logfile)


def launch_logic(exe, logfile=None):
    log("launching Logic: %s" % exe, logfile)
    subprocess.Popen([exe], close_fds=True)


# ---------------------------------------------------------------- api layer
def connect(port, timeout_s, logfile=None):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        try:
            return sa.Manager.connect(port=port, connect_timeout_seconds=3)
        except Exception as exc:                      # noqa: BLE001 - startup race
            last = exc
            time.sleep(1.0)
    log("cannot reach the Automation API on port %d: %s" % (port, last), logfile)
    return None


def make_config(channels, rate):
    return sa.LogicDeviceConfiguration(
        enabled_digital_channels=list(channels),
        digital_sample_rate=int(rate))


def is_busy_error(exc):
    text = str(exc).lower()
    return any(marker in text for marker in BUSY_MARKERS)


def is_transient_error(exc):
    text = str(exc).lower()
    return any(marker in text for marker in TRANSIENT_MARKERS)


def clear_orphan_sessions(mgr, logfile=None, max_id=MAX_SCAN_CAPTURE_ID):
    """Stop a recording session this process does not hold a handle for.

    After a USB reset Logic can be left believing it is still recording, while
    our own handle is gone (or never existed, e.g. the watchdog restarted). In
    that state StartCapture keeps failing with 'Cannot switch sessions while
    recording' forever, so the session has to be stopped by id. StopCapture on
    an id that does not exist is harmless, so a short scan is safe.
    """
    from saleae.automation import saleae_pb2      # local: keeps import cost off startup

    cleared = 0
    for cid in range(1, max_id + 1):
        try:
            mgr.stub.StopCapture(saleae_pb2.StopCaptureRequest(capture_id=cid))
            cleared += 1
            log("cleared orphan session capture_id=%d" % cid, logfile)
        except Exception as exc:                  # noqa: BLE001 - most ids simply do not exist
            text = str(exc).lower()
            if "device disconnected" in text:
                cleared += 1
                log("orphan session capture_id=%d was on a disconnected device" % cid, logfile)
    return cleared


def drop_capture(state, logfile=None, quiet=False):
    """Release our capture handle. A stale handle raising here is expected."""
    cap = state.get("capture")
    state["capture"] = None
    if cap is None:
        return
    for fn in ("stop", "close"):
        try:
            getattr(cap, fn)()
        except Exception as exc:                      # noqa: BLE001
            if not quiet:
                log("capture.%s(): %s: %s"
                    % (fn, type(exc).__name__, str(exc)[:120]), logfile)


def start_capture(mgr, dev, dev_cfg, state, logfile=None):
    cap = mgr.start_capture(
        device_id=dev.device_id,
        device_configuration=dev_cfg,
        capture_configuration=sa.CaptureConfiguration(
            capture_mode=sa.ManualCaptureMode()))
    state["capture"] = cap
    state["device_id"] = dev.device_id
    state["started_at"] = time.time()
    log("capture STARTED (id=%s, device=%s %s)"
        % (cap.capture_id, dev.device_type, dev.device_id), logfile)
    return cap


def ensure_capturing(mgr, dev_cfg, state, logfile=None):
    """Probe and repair in one call.

    Logic rejects StartCapture on a device that is mid-recording with
    'Cannot switch sessions while recording'. That rejection IS the proof that
    logging is alive - and when it is NOT recording, the same call starts it.

    Returns 'already', 'started', 'no-device' or 'failed'.
    """
    devices = list(mgr.get_devices(include_simulation_devices=False))
    if not devices:
        state["capture"] = None
        return "no-device"
    try:
        start_capture(mgr, devices[0], dev_cfg, state, logfile)
        return "started"
    except Exception as exc:                          # noqa: BLE001
        if is_busy_error(exc):
            return "already"
        log("StartCapture failed: %s: %s"
            % (type(exc).__name__, str(exc)[:160]), logfile)
        return "failed"


def hard_restart(mgr, dev_cfg, state, logfile, reason, attempts=15, delay=1.0):
    """Force a fresh capture after a USB drop, ignoring any stale session state.

    Logic may still believe it is recording on a device that just went away, so
    the stale handle is torn down first and StartCapture is retried until the
    re-enumerated device accepts it.
    """
    log("hard restart requested (%s)" % reason, logfile)
    drop_capture(state, logfile, quiet=True)
    for i in range(1, attempts + 1):
        try:
            devices = list(mgr.get_devices(include_simulation_devices=False))
            if not devices:
                time.sleep(delay)
                continue
            start_capture(mgr, devices[0], dev_cfg, state, logfile)
            log("hard restart OK on attempt %d" % i, logfile)
            return True
        except Exception as exc:                      # noqa: BLE001
            if is_transient_error(exc):
                log("attempt %d: Logic is mid-session-change, retrying." % i, logfile)
            elif is_busy_error(exc):
                # Logic still holds a session on a device that just reset, and
                # dropping our own handle is not enough because we may not own
                # it. Stop it by id instead - without this the restart loops
                # forever on 'Cannot switch sessions while recording'.
                log("attempt %d: Logic still claims 'recording' - clearing by id." % i, logfile)
                drop_capture(state, logfile, quiet=True)
                clear_orphan_sessions(mgr, logfile)
            else:
                log("attempt %d: %s: %s"
                    % (i, type(exc).__name__, str(exc)[:120]), logfile)
            time.sleep(delay)
    log("hard restart FAILED after %d attempts." % attempts, logfile)
    return False


# ---------------------------------------------------------------- main loop
def main():
    ap = argparse.ArgumentParser(description="Saleae Logic capture watchdog")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--poll", type=float, default=0.25,
                    help="USB presence poll period, seconds (get_devices is ~3 ms)")
    ap.add_argument("--check", type=float, default=5.0,
                    help="steady-state capture health check period, seconds")
    ap.add_argument("--channels", default=DEFAULT_CHANNELS,
                    help="digital channels, e.g. 0,1,2,3,4")
    ap.add_argument("--rate", type=int, default=DEFAULT_RATE,
                    help="digital sample rate, e.g. 5000000 for 5 MS/s")
    ap.add_argument("--rotate-seconds", type=float, default=0.0,
                    help="periodically recycle the capture; 0 disables it. "
                         "Caps how long a stale session can survive, at the cost "
                         "of a short gap each time.")
    ap.add_argument("--logdir",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    ap.add_argument("--once", action="store_true",
                    help="check once and exit (0 = logging OK, 1 = not OK)")
    args = ap.parse_args()

    os.makedirs(args.logdir, exist_ok=True)
    logfile = os.path.join(
        args.logdir, "saleae_guard_%s.log" % datetime.now().strftime("%Y%m%d_%H%M%S"))
    channels = [int(c) for c in args.channels.split(",") if c.strip() != ""]

    log("config: channels=%s  rate=%d S/s  poll=%.2fs  check=%.1fs  rotate=%s"
        % (channels, args.rate, args.poll, args.check,
           ("%.0fs" % args.rotate_seconds) if args.rotate_seconds > 0 else "off"), logfile)

    exe = find_logic_exe()
    log("Logic executable : %s" % (exe or "NOT FOUND"), logfile)

    if ensure_automation_enabled(logfile) and logic_running():
        log("restarting Logic so the automation server binds.", logfile)
        kill_logic(logfile)

    if not logic_running():
        if not exe:
            log("Logic is not running and logic.exe was not found. Aborting.", logfile)
            return 2
        launch_logic(exe, logfile)

    mgr = connect(args.port, 90, logfile)
    if mgr is None:
        return 2

    info = mgr.get_app_info()
    log("connected: Logic %s (pid %s), api %s.%s.%s"
        % (info.app_version, info.app_pid, info.api_version.major,
           info.api_version.minor, info.api_version.patch), logfile)

    dev_cfg = make_config(channels, args.rate)
    state = {"capture": None, "device_id": None, "started_at": 0.0}

    if args.once:
        result = ensure_capturing(mgr, dev_cfg, state, logfile)
        log("STATUS: %s" % result, logfile)
        if result == "started":
            drop_capture(state, logfile)   # we only probed
        mgr.close()
        return 0 if result in ("already", "started") else 1

    log("watchdog running. Ctrl+C to stop.", logfile)
    # Logic needs a few seconds after launch to enumerate the analyzer. Drop
    # detection only arms after the device has been seen once, otherwise that
    # startup gap is misreported as a USB drop.
    armed = False
    present = False
    gone_since = None
    drops = 0
    last_check = 0.0
    last_missing_note = 0.0
    last_state = None

    try:
        while True:
            now = time.time()

            # ---- layer B: fast USB presence tracking (the burst symptom) ----
            try:
                n = len(mgr.get_devices(include_simulation_devices=False))
            except Exception as exc:                  # noqa: BLE001
                # A dead channel means Logic itself went away.
                log("API channel lost (%s) - checking Logic."
                    % type(exc).__name__, logfile)
                drop_capture(state, logfile, quiet=True)
                try:
                    mgr.close()
                except Exception:                     # noqa: BLE001
                    pass
                if not logic_running() and exe:
                    log("Logic is DOWN - relaunching.", logfile)
                    launch_logic(exe, logfile)
                mgr = connect(args.port, 90, logfile)
                if mgr is None:
                    time.sleep(1.0)
                    continue
                log("reconnected to the Automation API.", logfile)
                # A relaunched Logic re-enumerates from scratch, so re-arm
                # rather than treating the enumeration gap as a drop.
                armed, present, gone_since = False, False, None
                last_state, last_check, last_missing_note = None, 0.0, 0.0
                hard_restart(mgr, dev_cfg, state, logfile, "after reconnect")
                continue

            if not armed:
                if n > 0:
                    armed = True
                    present = True
                    log("device detected - drop detection armed.", logfile)
                else:
                    if now - last_missing_note >= 5.0:
                        last_missing_note = now
                        log("waiting for Logic to enumerate the analyzer...", logfile)
                    time.sleep(args.poll)
                    continue

            elif present and n == 0:
                present = False
                gone_since = now
                last_missing_note = now
                drops += 1
                log("*** USB DROP #%d - Saleae disappeared ***" % drops, logfile)

            elif not present and n > 0:
                present = True
                outage = now - gone_since if gone_since else 0.0
                log("*** USB RESTORED after %.2fs ***" % outage, logfile)
                gone_since = None
                hard_restart(mgr, dev_cfg, state, logfile,
                             "USB drop #%d, outage %.2fs" % (drops, outage))
                last_state = "already"
                last_check = now

            if not present:
                if now - last_missing_note >= 10.0:
                    last_missing_note = now
                    log("still missing (%.0fs) - check the USB cable."
                        % (now - gone_since if gone_since else 0.0), logfile)
                time.sleep(args.poll)
                continue

            # ---- layer C: optional periodic rotation ----
            if (args.rotate_seconds > 0 and state.get("capture") is not None
                    and now - state.get("started_at", now) >= args.rotate_seconds):
                hard_restart(mgr, dev_cfg, state, logfile,
                             "scheduled rotation every %.0fs" % args.rotate_seconds)
                last_check = now

            # ---- layer A: steady-state busy-probe ----
            elif now - last_check >= args.check:
                last_check = now
                result = ensure_capturing(mgr, dev_cfg, state, logfile)
                if result != last_state:
                    if result == "already":
                        log("OK - logging is running.", logfile)
                    elif result == "no-device":
                        log("FAULT - no real Saleae device present.", logfile)
                    elif result == "failed":
                        log("FAULT - StartCapture rejected; will retry.", logfile)
                    last_state = result

            time.sleep(args.poll)

    except KeyboardInterrupt:
        log("stopping on user request. USB drops seen: %d" % drops, logfile)
    finally:
        drop_capture(state, logfile, quiet=True)
        try:
            mgr.close()
        except Exception:                             # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
