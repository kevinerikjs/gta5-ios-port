"""GTA-163: Eye in the Sky (carsteal2), the helicopter camera on touch-style input. From the camera stage ("Use … to aim
the camera"), aims the camera at the target marker with the right stick (what a right-side drag sends in the touch
controls' prompt layout), zooms in with the left stick, holds RT for the police scan, and reports whether the mission
moved past the scan. Run after `gta.py mission carsteal2` and `gta.py autopilot "aim the camera"`.

    python3 Harness/scenarios/eye_in_the_sky.py [SECONDS]
"""
import math, os, re, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 120

def camera():
    r = gta.batch("GET_FINAL_RENDERED_CAM_COORD; GET_FINAL_RENDERED_CAM_ROT 2; GET_FINAL_RENDERED_CAM_FOV")
    return r[0]["v"], r[1]["v"], r[2]["r"]["f"]

FRANKLIN = 0x9B22DBAF   # player_one: in this stage Franklin is a mission ped the camera has to find and scan
def find_franklin():
    # Script entity handles here were pool index * 256 + 2 (heli 5122, player 5634, Franklin 4610).
    for first in range(0, 600, 30):
        handles = [i * 256 + 2 for i in range(first, first + 30)]
        r = gta.batch("; ".join("GET_ENTITY_MODEL %d" % h for h in handles))
        for h, v in zip(handles, r):
            if v.get("ok") and (v["r"]["i"] & 0xffffffff) == FRANKLIN: return h
    return None

franklin = None
def target():
    global franklin
    if franklin is None: franklin = find_franklin(); print("Franklin's entity:", franklin)
    if franklin is None: return None
    at = gta.batch("GET_ENTITY_COORDS %d true" % franklin)[0].get("v")
    return [at[0], at[1], at[2] + 0.5] if at else None

def wrap(a):
    return (a + 180) % 360 - 180

start, scanned, last_help = time.time(), False, None
log_from = os.path.getsize(gta.log_path())
while time.time() - start < seconds:
    s = gta.call("state")
    if s.get("help") != last_help:
        last_help = s.get("help"); print("help:", last_help)
    if "carsteal2" not in s.get("scripts", []): print("mission script ended"); break
    goal = target()
    if not goal: time.sleep(0.5); continue
    at, rot, fov = camera()
    dx, dy, dz = goal[0] - at[0], goal[1] - at[1], goal[2] - at[2]
    heading = math.degrees(math.atan2(-dx, dy)); pitch = math.degrees(math.atan2(dz, math.hypot(dx, dy)))
    eh, ep = wrap(heading - rot[2]), pitch - rot[0]
    # Right stick: positive x turns right (heading goes down), positive y tilts up (GTA-163 simulator runs).
    rx = max(-0.7, min(0.7, -eh / 25)); ry = max(-0.7, min(0.7, ep / 25))
    zoom = 1 if abs(eh) < 4 and abs(ep) < 4 and fov > 8 else 0           # left stick up (pad leftY 1) zooms in
    rt = 1 if abs(eh) < 4 and abs(ep) < 4 else 0
    gta.call("pad - 0.35 0 %.2f %.2f %.2f 0 %d" % (zoom, rx, ry, rt))
    time.sleep(0.3)
    steps = globals().get("steps", 0) + 1; globals()["steps"] = steps
    if steps % 8 == 0: print("aim error %.1f° heading, %.1f° pitch, fov %.1f, rt %d" % (eh, ep, fov, rt))
print("help at the end:", gta.call("state").get("help"))
text = open(gta.log_path(), errors="replace").read()[log_from:]
print("\n".join(l for l in text.split("\n") if l.startswith(("Help message", "Story:", "Mission buttons", "Touch layout")))[-2000:])
