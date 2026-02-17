#! /usr/bin/env python3
import evdev
import subprocess
import time
import sys
import os
import glob
import shutil

# Constants
KEY_F24 = evdev.ecodes.KEY_F24
DEFAULT_CONTROLLER = "/etc/s2t/result/bin/s2t-controller"
CONTROLLER_ENV_VAR = "S2T_CONTROLLER"

def _safe_device(path: str):
    try:
        return evdev.InputDevice(path), None
    except Exception as e:
        return None, e

def find_keyd_device():
    paths = glob.glob("/dev/input/event*")
    candidates = []
    permission_denied = []

    for path in paths:
        device, err = _safe_device(path)
        if device is None:
            if isinstance(err, PermissionError):
                permission_denied.append(path)
            continue

        name = (device.name or "").lower()
        if "keyd" not in name:
            continue

        try:
            keys = device.capabilities().get(evdev.ecodes.EV_KEY, [])
        except Exception:
            keys = []

        score = 0
        if "keyd virtual keyboard" in name:
            score += 100
        if "keyboard" in name:
            score += 50
        if evdev.ecodes.KEY_F24 in keys:
            score += 25

        candidates.append((score, device))

    if not candidates:
        return None, permission_denied

    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1], permission_denied

def main():
    print("Starting S2T Key Monitor...")

    controller_override = os.environ.get(CONTROLLER_ENV_VAR, "").strip()
    if controller_override:
        controller = controller_override
    else:
        controller = DEFAULT_CONTROLLER if os.path.exists(DEFAULT_CONTROLLER) else (shutil.which("s2t-controller") or "s2t-controller")
    cmd = [controller]

    warned_perms = False
    while True:
        keyd_dev = None
        pressed = False

        while True:
            keyd_dev, permission_denied = find_keyd_device()
            if keyd_dev:
                print(f"Monitoring: {keyd_dev.name} ({keyd_dev.path})", flush=True)
                break

            if permission_denied and not warned_perms:
                warned_perms = True
                print("No permission to read /dev/input/event* (keyd device). You may need to re-login or adjust udev/ACLs.", flush=True)

            print("Keyd device not found. Retrying in 2s...", flush=True)
            time.sleep(2)

        try:
            for event in keyd_dev.read_loop():
                if event.type == evdev.ecodes.EV_KEY and event.code == KEY_F24:
                    if event.value == 1 and not pressed:  # Down
                        pressed = True
                        print("F24 down -> start", flush=True)
                        subprocess.Popen(cmd + ["start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    elif event.value == 0 and pressed:  # Up
                        pressed = False
                        print("F24 up -> stop", flush=True)
                        subprocess.Popen(cmd + ["stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            # Common when keyd restarts and the evdev node disappears/reappears.
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
