#! /usr/bin/env python3
import evdev
import subprocess
import time
import sys
import os
import glob
import shutil
import fcntl
import select

# Constants
KEY_F24 = evdev.ecodes.KEY_F24
KEY_RIGHTALT = evdev.ecodes.KEY_RIGHTALT
KEY_MENU = evdev.ecodes.KEY_MENU
KEY_LEFTALT = evdev.ecodes.KEY_LEFTALT
KEY_X = evdev.ecodes.KEY_X
KEY_C = evdev.ecodes.KEY_C
KEY_V = evdev.ecodes.KEY_V
DEFAULT_CONTROLLER = "/etc/s2t/result/bin/s2t-controller"
CONTROLLER_ENV_VAR = "S2T_CONTROLLER"
GLOBAL_LOCK_ENV_VAR = "S2T_MONITOR_LOCK_PATH"
GLOBAL_LOCK_DEFAULT = "/tmp/s2t-monitor-global.lock"
KEY_PRIMARY_ENV_VAR = "S2T_MONITOR_PRIMARY_KEY"
KEY_FALLBACK_ENV_VAR = "S2T_MONITOR_FALLBACK_KEYS"
IDLE_REOPEN_ENV_VAR = "S2T_MONITOR_IDLE_REOPEN_SEC"
SECONDARY_HOTKEYS_ENV_VAR = "S2T_MONITOR_SECONDARY_HOTKEYS"

DEFAULT_PRIMARY_KEY = "F24"
DEFAULT_FALLBACK_KEYS = "RIGHTALT,MENU"
DEFAULT_IDLE_REOPEN_SEC = 90
DEFAULT_SECONDARY_HOTKEYS = "1"

KEY_NAME_TO_CODE = {
    "F24": KEY_F24,
    "RIGHTALT": KEY_RIGHTALT,
    "ALTGR": KEY_RIGHTALT,
    "MENU": KEY_MENU,
    "COMPOSE": evdev.ecodes.KEY_COMPOSE,
}

def _safe_device(path: str):
    try:
        return evdev.InputDevice(path), None
    except Exception as e:
        return None, e

def _parse_key_list(raw: str):
    names = [x.strip().upper() for x in (raw or "").replace(";", ",").split(",")]
    names = [x for x in names if x]
    out = []
    for name in names:
        code = KEY_NAME_TO_CODE.get(name)
        if code is not None and code not in out:
            out.append(code)
    return out

def build_target_keys():
    primary_name = (os.environ.get(KEY_PRIMARY_ENV_VAR, DEFAULT_PRIMARY_KEY) or "").strip().upper()
    if not primary_name:
        primary_name = DEFAULT_PRIMARY_KEY
    primary = KEY_NAME_TO_CODE.get(primary_name, KEY_F24)

    fallback_raw = os.environ.get(KEY_FALLBACK_ENV_VAR, DEFAULT_FALLBACK_KEYS)
    fallback = _parse_key_list(fallback_raw)

    ordered = [primary]
    for code in fallback:
        if code not in ordered:
            ordered.append(code)
    return ordered

def secondary_hotkeys_enabled() -> bool:
    raw = (os.environ.get(SECONDARY_HOTKEYS_ENV_VAR, DEFAULT_SECONDARY_HOTKEYS) or "").strip().lower()
    return raw not in {"0", "false", "no", "off", ""}

def key_name_for_code(code: int):
    try:
        return evdev.ecodes.KEY[code]
    except Exception:
        return str(code)

def find_input_device(target_keys):
    paths = glob.glob("/dev/input/event*")
    candidates = []
    permission_denied = []

    for path in paths:
        device, err = _safe_device(path)
        if device is None:
            if isinstance(err, PermissionError):
                permission_denied.append(path)
            continue

        name = (device.name or "")
        name_l = name.lower()

        try:
            keys = device.capabilities().get(evdev.ecodes.EV_KEY, [])
        except Exception:
            keys = []
        keyset = set(keys)
        if not any(code in keyset for code in target_keys):
            device.close()
            continue

        score = 0
        if "keyd virtual keyboard" in name_l:
            score += 150
        if "keyd" in name_l:
            score += 100
        if "keyboard" in name_l:
            score += 40
        if evdev.ecodes.KEY_F24 in keyset:
            score += 25
        if evdev.ecodes.KEY_RIGHTALT in keyset:
            score += 10
        if evdev.ecodes.KEY_MENU in keyset:
            score += 10
        for code in target_keys:
            if code in keyset:
                score += 3

        candidates.append((score, device))

    if not candidates:
        return None, permission_denied

    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1], permission_denied

def acquire_global_lock():
    lock_path = os.environ.get(GLOBAL_LOCK_ENV_VAR, "").strip() or GLOBAL_LOCK_DEFAULT
    lock_dir = os.path.dirname(lock_path) or "."
    os.makedirs(lock_dir, exist_ok=True)
    try:
        lock_file = open(lock_path, "a+")
    except PermissionError:
        # Another user may own the lock file without world-write bit.
        # Read-only open is enough for flock-based serialization.
        lock_file = open(lock_path, "r")
        print(f"Global monitor lock opened read-only: {lock_path}", flush=True)
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(f"Global monitor lock acquired: {lock_path}", flush=True)
    except BlockingIOError:
        print(f"Global monitor lock is held by another process, waiting: {lock_path}", flush=True)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        print(f"Global monitor lock acquired after wait: {lock_path}", flush=True)
    return lock_file

def main():
    print("Starting S2T Key Monitor...", flush=True)
    print(f"Monitor context: uid={os.getuid()} user={os.environ.get('USER', '?')} session={os.environ.get('XDG_SESSION_TYPE', '?')}", flush=True)
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        print("No graphical session variables (DISPLAY/WAYLAND_DISPLAY); exiting monitor.", flush=True)
        return

    controller_override = os.environ.get(CONTROLLER_ENV_VAR, "").strip()
    if controller_override:
        controller = controller_override
    else:
        controller = DEFAULT_CONTROLLER if os.path.exists(DEFAULT_CONTROLLER) else (shutil.which("s2t-controller") or "s2t-controller")
    print(f"Using controller: {controller}", flush=True)
    cmd = [controller]
    lock_file = acquire_global_lock()
    _ = lock_file

    target_keys = build_target_keys()
    secondary_enabled = secondary_hotkeys_enabled()
    watch_keys = list(target_keys)
    if secondary_enabled:
        for code in (KEY_LEFTALT, KEY_X, KEY_C, KEY_V):
            if code not in watch_keys:
                watch_keys.append(code)
    target_key_names = ",".join(key_name_for_code(code) for code in target_keys)
    print(f"Hotkey codes: {target_key_names}", flush=True)
    if secondary_enabled:
        print("Secondary hotkeys enabled: Alt+X(clear), Alt+C(copy), Alt+V(paste)", flush=True)
    try:
        idle_reopen_sec = int(os.environ.get(IDLE_REOPEN_ENV_VAR, str(DEFAULT_IDLE_REOPEN_SEC)))
    except Exception:
        idle_reopen_sec = DEFAULT_IDLE_REOPEN_SEC
    if idle_reopen_sec < 10:
        idle_reopen_sec = 10

    warned_perms = False
    while True:
        keyd_dev = None
        pressed = False
        left_alt_pressed = False
        secondary_chord_active = False

        while True:
            keyd_dev, permission_denied = find_input_device(watch_keys)
            if keyd_dev:
                print(f"Monitoring: {keyd_dev.name} ({keyd_dev.path}) keys={target_key_names}", flush=True)
                break

            if permission_denied and not warned_perms:
                warned_perms = True
                print("No permission to read /dev/input/event* (keyd device). You may need to re-login or adjust udev/ACLs.", flush=True)

            print("Input device for hotkey not found. Retrying in 2s...", flush=True)
            time.sleep(2)

        try:
            idle_since = time.monotonic()
            while True:
                readable, _, _ = select.select([keyd_dev.fd], [], [], 1.0)
                if not readable:
                    if (time.monotonic() - idle_since) >= idle_reopen_sec:
                        print(f"No hotkey events for {idle_reopen_sec}s; reopening input device", flush=True)
                        break
                    continue

                events = keyd_dev.read()
                if not events:
                    continue
                for event in events:
                    if event.type != evdev.ecodes.EV_KEY:
                        continue
                    if event.code not in watch_keys:
                        continue
                    key_name = key_name_for_code(event.code)
                    idle_since = time.monotonic()
                    if secondary_enabled and event.code == KEY_LEFTALT:
                        if event.value == 1:
                            left_alt_pressed = True
                        elif event.value == 0:
                            left_alt_pressed = False
                            secondary_chord_active = False
                        continue
                    if secondary_enabled and left_alt_pressed and event.value == 1 and event.code in (KEY_X, KEY_C, KEY_V):
                        if secondary_chord_active:
                            continue
                        secondary_chord_active = True
                        if event.code == KEY_X:
                            action = "secondary-clear"
                            print("Alt+X -> secondary-clear", flush=True)
                        elif event.code == KEY_C:
                            action = "secondary-copy"
                            print("Alt+C -> secondary-copy", flush=True)
                        else:
                            action = "secondary-paste"
                            print("Alt+V -> secondary-paste", flush=True)
                        subprocess.Popen(cmd + [action], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                        continue
                    if secondary_enabled and event.value == 0 and event.code in (KEY_X, KEY_C, KEY_V):
                        secondary_chord_active = False
                        continue
                    if event.code not in target_keys:
                        continue
                    if event.value == 1 and not pressed:  # Down
                        pressed = True
                        print(f"{key_name} down -> start", flush=True)
                        subprocess.Popen(cmd + ["start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    elif event.value == 0 and pressed:  # Up
                        pressed = False
                        print(f"{key_name} up -> stop", flush=True)
                        subprocess.Popen(cmd + ["stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            print(f"Device error: {e}. Re-discovering...", flush=True)
        except Exception as e:
            print(f"Error: {e}. Re-discovering...", flush=True)
        finally:
            try:
                if keyd_dev is not None:
                    keyd_dev.close()
            except Exception:
                pass

        time.sleep(1)

if __name__ == "__main__":
    main()
