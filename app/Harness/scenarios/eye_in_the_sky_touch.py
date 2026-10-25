"""GTA-163 with touch only: Eye in the Sky's helicopter camera scan, driven through the touch controls (the prompt layout).
A finger on the right side holds the camera stick toward the target (Franklin's blip; aiming there also sends the pilot),
a finger on the left holds the left stick up to zoom (INPUT_SNIPER_ZOOM), and once the RT mission button is on screen a
third finger holds it through the scan. Reports the mission buttons it saw, whether the scan finished
(COP_HELI_CAM_SCAN_PED_SUCCESS/FAILURE in the log) and the help texts after it.

    python3 Harness/scenarios/eye_in_the_sky_touch.py [SECONDS]

Run after `gta.py mission carsteal2` and `gta.py autopilot "aim the camera"`. Screenshots go to $GTA_OUT (default .).
"""
import math, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 150
out = os.environ.get("GTA_OUT", ".")

def camera():
    r = gta.batch("GET_FINAL_RENDERED_CAM_COORD; GET_FINAL_RENDERED_CAM_ROT 2; GET_FINAL_RENDERED_CAM_FOV")
    return r[0]["v"], r[1]["v"], r[2]["r"]["f"]

FRANKLIN = 0x9B22DBAF
def find_target():
    """Franklin (the first scan target): his ped among the entity handles (pool index * 256 + generation)."""
    for gen in (2, 1, 3, 4, 5, 6, 7, 8):
        for first in range(0, 900, 60):
            handles = [i * 256 + gen for i in range(first, first + 60)]
            r = gta.batch("; ".join("GET_ENTITY_MODEL %d" % h for h in handles))
            for h, v in zip(handles, r):
                if v.get("ok") and (v["r"]["i"] & 0xffffffff) == FRANKLIN and gta.batch("IS_ENTITY_A_PED %d" % h)[0]["r"]["i"] & 1:
                    return h
    return None

def wrap(a): return (a + 180) % 360 - 180

LOOK = (0.60, 0.33); ZOOM = (0.12, 0.42)
ui = gta.call("ui"); W, H = ui["size"]
TRAVEL = 46.0
gta.call("touch 1 down %.3f %.3f" % LOOK); gta.call("touch 2 down %.3f %.3f" % ZOOM)
target = find_target(); print("target entity:", target)
log_from = os.path.getsize(gta.log_path())
start, last_help, rt_down, seen, step, shot_taken, rt_since = time.time(), None, False, set(), 0, False, None
while time.time() - start < seconds:
    s = gta.call("state")
    if s.get("help") != last_help: last_help = s.get("help"); print("%5.1f help: %s" % (time.time() - start, last_help))
    if "carsteal2" not in s.get("scripts", []): print("mission script ended"); break
    ui = gta.call("ui")
    names = [v["name"] for v in ui["visible"]]
    mission = [n for n in names if n.startswith("script_") or n == "interact"]
    seen.update(mission)
    if target is None: target = find_target(); continue
    at = gta.batch("GET_ENTITY_COORDS %d true" % target)[0].get("v")
    if not at or not any(at): target = None; continue
    cam, rot, fov = camera()
    dx, dy, dz = at[0] - cam[0], at[1] - cam[1], at[2] + 0.3 - cam[2]
    heading = math.degrees(math.atan2(-dx, dy)); pitch = math.degrees(math.atan2(dz, math.hypot(dx, dy)))
    eh, ep = wrap(heading - rot[2]), pitch - rot[0]
    k = max(0.12, fov / 28)                     # zoomed in, the same stick turns the view further
    def axis(e):
        if abs(e) < 0.2 * k: return 0
        return math.copysign(max(0.38, min(0.8, abs(e) / (20 * k))), e)
    rx, ry = -axis(eh), axis(ep)
    # Stick right turns right (heading goes down); stick up tilts up. Finger right = stick right, finger up = stick up.
    gta.call("touch 1 move %.4f %.4f" % (LOOK[0] + rx * TRAVEL / W, LOOK[1] - ry * TRAVEL / H))
    centred = abs(eh) < 3 * k and abs(ep) < 3 * k
    zoom = 1 if centred and fov > 6 else 0
    gta.call("touch 2 move %.4f %.4f" % (ZOOM[0], ZOOM[1] - zoom * TRAVEL / H))
    reads_rt = 229 in ui.get("read", [])
    if not rt_down and "script_rt" in names and reads_rt:
        rt_down = gta.call("touch 3 down @script_rt").get("ok", False); rt_since = time.time()
        print("%5.1f RT pressed: the RT button is on screen and the scan reads RT (aim %.2f°/%.2f°, fov %.1f)" % (time.time() - start, eh, ep, fov))
    elif rt_down and not reads_rt and time.time() - rt_since > 6:
        gta.call("touch 3 up"); rt_down = False; print("%5.1f RT let go (the scan stopped reading it)" % (time.time() - start))
    if rt_down and not shot_taken and time.time() - rt_since > 1.5:
        gta.shot(os.path.join(out, "eye-scan-rt-held.png")); shot_taken = True
    step += 1
    if step % 6 == 0:
        print("%5.1f aim %.2f°/%.2f°, fov %.1f, distance %.0f m, RT held %s (trigger %.2f), scan reads RT %s, buttons %s" %
              (time.time() - start, eh, ep, fov, math.hypot(dx, dy), rt_down, ui["pad"]["triggers"][1], reads_rt, ",".join(mission) or "none"), flush=True)
    text = open(gta.log_path(), errors="replace").read()[log_from:]
    if "COP_HELI_CAM_SCAN_PED_SUCCESS" in text or "COP_HELI_CAM_SCAN_PED_FAILURE" in text:
        print("%5.1f scan finished: %s (RT held %s)" % (time.time() - start, "success" if "SCAN_PED_SUCCESS" in text else "failure", rt_down))
        gta.shot(os.path.join(out, "eye-scan-done.png")); time.sleep(1.0); break
    time.sleep(0.1)
for f in (3, 2, 1): gta.call("touch %d up" % f)
print("mission buttons seen:", sorted(seen))
end = time.time() + 20
while time.time() < end:
    s = gta.call("state")
    if s.get("help") != last_help: last_help = s.get("help"); print("after: help: %s" % last_help)
    time.sleep(0.5)
gta.shot(os.path.join(out, "eye-after-scan.png"))
text = open(gta.log_path(), errors="replace").read()[log_from:]
print("\n".join(l for l in text.split("\n") if l.startswith(("Help message", "Story:", "Mission buttons", "Touch layout", "Mission button")) or "SCAN_PED" in l)[-3000:])
