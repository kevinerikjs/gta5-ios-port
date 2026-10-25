"""GTA-163, the thermal camera: from Eye in the Sky's checkpoint 2 (follow Chad), keep the camera on the Z-Type with a
touch drag (as the mission asks) until the help says "Press ~INPUT_SCRIPT_PAD_RIGHT~
to toggle the thermal vision mode", then tap the Interact button and check the game turned thermal vision on
(Thermal_On sound, and the mission's next help "With thermal vision, heat sources show up as a bright color.").

    python3 Harness/scenarios/eye_in_the_sky_thermal.py [SECONDS]

Run after `gta.py mission carsteal2` and `gta.py checkpoint 2`. Screenshots go to $GTA_OUT (default .).
"""
import math, os, re, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 240
out = os.environ.get("GTA_OUT", ".")
def wrap(a): return (a + 180) % 360 - 180
def camera():
    r = gta.batch("GET_FINAL_RENDERED_CAM_COORD; GET_FINAL_RENDERED_CAM_ROT 2; GET_FINAL_RENDERED_CAM_FOV")
    return r[0]["v"], r[1]["v"], r[2]["r"]["f"]
ZTYPE, FRANKLIN = 0x2D3BD401, 0x9B22DBAF
def find_model(model, vehicle):
    """An entity of this model among the script handles (pool index * 256 + generation)."""
    check = "IS_ENTITY_A_VEHICLE" if vehicle else "IS_ENTITY_A_PED"
    for gen in (2, 1, 3, 4, 5, 6, 7, 8):
        for first in range(0, 900, 60):
            handles = [i * 256 + gen for i in range(first, first + 60)]
            for h, v in zip(handles, gta.batch("; ".join("GET_ENTITY_MODEL %d" % h for h in handles))):
                if v.get("ok") and (v["r"]["i"] & 0xffffffff) == model and gta.batch("%s %d" % (check, h))[0]["r"]["i"] & 1:
                    return h
    return None
def find_target():
    """The Z-Type (keep it in view) until the thermal stage, then Franklin in the car park."""
    help_text = gta.call("state").get("help") or ""
    want = (FRANKLIN, False) if tapped else (ZTYPE, True)
    e = find_model(*want); print("target %s: %s" % ("Franklin" if want[0] == FRANKLIN else "Z-Type", e), flush=True)
    return e

LOOK = (0.60, 0.33)
ui = gta.call("ui"); W, H = ui["size"]; TRAVEL = 46.0
gta.call("touch 1 down %.3f %.3f" % LOOK)
log_from = os.path.getsize(gta.log_path())
start, last_help, target, tapped, last_search = time.time(), None, None, None, 0
while time.time() - start < seconds:
    s = gta.call("state")
    if s.get("help") != last_help: last_help = s.get("help"); print("%5.1f help: %s" % (time.time() - start, last_help), flush=True)
    if "carsteal2" not in s.get("scripts", []): print("mission script ended"); break
    if s.get("status", 0) & 4: gta.call("pad a 0.3"); time.sleep(1.5); continue      # skip a cutscene
    help_text = s.get("help") or ""
    if tapped is None and re.search("thermal vision mode", help_text):
        for _ in range(25):
            ui = gta.call("ui"); names = [v["name"] for v in ui["visible"]]
            if "interact" in names: break
            time.sleep(0.2)
        print("%5.1f thermal help up; layout %s; on screen: %s" % (time.time() - start, "prompt" if ui["prompt"] else ui["context"], names), flush=True)
        gta.shot(os.path.join(out, "thermal-1-help.png"))
        r = gta.call("tap @interact 0.2"); tapped = time.time(); print("tap Interact:", r, flush=True); target = None
        time.sleep(2.5); gta.shot(os.path.join(out, "thermal-2-after-tap.png"))
    if tapped and time.time() - tapped > 12: break
    if target is None and time.time() - last_search > 3: target = find_target(); last_search = time.time()
    if target is None: time.sleep(0.5); continue
    at = gta.batch("GET_ENTITY_COORDS %d true" % target)[0].get("v")
    if not at or not any(at): target = None; continue
    cam, rot, fov = camera()
    dx, dy, dz = at[0] - cam[0], at[1] - cam[1], at[2] - cam[2]
    eh = wrap(math.degrees(math.atan2(-dx, dy)) - rot[2]); ep = math.degrees(math.atan2(dz, math.hypot(dx, dy))) - rot[0]
    k = max(0.12, fov / 28)
    def axis(e):
        if abs(e) < 0.4 * k: return 0
        return math.copysign(max(0.38, min(0.8, abs(e) / (20 * k))), e)
    gta.call("touch 1 move %.4f %.4f" % (LOOK[0] - axis(eh) * TRAVEL / W, LOOK[1] - axis(ep) * TRAVEL / H))
    time.sleep(0.15)
gta.call("touch 1 up")
text = open(gta.log_path(), errors="replace").read()[log_from:]
print("Thermal_On played:", "Thermal_On" in text, "| SET_SEETHROUGH/thermal lines:",
      [l[:120] for l in text.split("\n") if "Thermal" in l][:4])
print("\n".join(l for l in text.split("\n") if l.startswith(("Help message", "Story:", "Mission buttons", "Touch layout", "Control hints")))[-2500:])
