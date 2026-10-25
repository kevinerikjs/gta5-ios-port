"""Regression for GTA-193 (player log 2366: "spent a dollar at the beach but can't use the telescope"). The coin-op
telescope on the Del Perro pier with touch only: stand in front of it, tap Interact, pay $1, wait for the view's help
("look around ... zoom ... exit"), drag on the right side to look around, tap Interact to leave. Logs the player's
place in the telescope's frame before and after the walk-up; ob_telescope opens the view only within 1 m of the spot
0.2 m right of and 0.96 m in front of the telescope. Needs `gta.py launch story`; about 1 minute.

    python3 Harness/scenarios/telescope_pier.py [OUT_DIR]

Before the fix Franklin ended 1.21 m from that spot, facing -90 degrees from the eyepiece, and control came back
after about 4.6 s without the view (PG_TEST_CLIP_OFFSET_OLD=1 at launch shows it again in the simulator).
"""
import math, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
AT = (-1851.0, -1243.0, 8.6)   # Del Perro pier, where the player of log 2366 stood
shot = lambda name: gta.shot(os.path.join(OUT, "telescope-%s.png" % name))
gta.teleport(*AT); time.sleep(6)
obj = gta.batch("GET_CLOSEST_OBJECT_OF_TYPE %.1f %.1f %.1f 40.0 u:0x%x false false false" % (AT + (gta.joaat("prop_telescope_01"),)))[0]["r"]["i"]
if not obj: sys.exit("FAILED: no prop_telescope_01 near the pier")
pos = gta.batch("GET_ENTITY_COORDS %d true" % obj)[0]["v"]; heading = gta.batch("GET_ENTITY_HEADING %d" % obj)[0]["r"]["f"]

def where():
    b = gta.batch("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; GET_ENTITY_HEADING r:0")
    dx, dy = b[1]["v"][0] - pos[0], b[1]["v"][1] - pos[1]; r = math.radians(heading)
    x, y = dx * math.cos(r) + dy * math.sin(r), -dx * math.sin(r) + dy * math.cos(r)
    return x, y, (b[2]["r"]["f"] - heading + 540) % 360 - 180

def show(label):
    x, y, facing = where()
    print("%s: %.2f m right, %.2f m in front of the telescope, facing %.0f (180 = the eyepiece), %.2f m from the checked spot"
          % (label, x, y, facing, math.hypot(x - 0.2, y - 0.96)), flush=True)

def cash(): return gta.batch("STAT_GET_INT u:0x%x p:1 -1" % gta.joaat("SP1_TOTAL_CASH"))[0]["out"][0][0]["i"]

spot = gta.batch("GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS %d 0.2 1.3 0.0" % obj)[0]["v"]
gta.teleport(spot[0], spot[1], spot[2] + 0.2)
gta.batch("PLAYER_PED_ID; SET_ENTITY_HEADING r:0 %.1f" % ((heading + 180) % 360))
end = time.time() + 20
while time.time() < end and "telescope" not in (gta.call("state").get("help") or "").lower(): time.sleep(0.3)
print("help:", gta.call("state").get("help")); show("before"); money = cash(); shot("1-help")
time.sleep(0.8); gta.call("tap @interact 0.2")
t0, view = time.time(), False
while time.time() - t0 < 12:
    s = gta.call("state"); text = (s.get("help") or "").lower()
    if s["status"] & 1 and "look around" in text: view = True; break
    if time.time() - t0 > 3 and not s["status"] & 1: break   # control back without the view: the old failure
    time.sleep(0.15)
show("after the walk-up"); print("paid: $%d, view open: %s" % (money - cash(), view)); shot("2-view")
gta.call("drag 1 650 220 820 160 1.2"); time.sleep(1.5); shot("3-looked")
still = bool(gta.call("state")["status"] & 1)
gta.call("tap @interact 0.2")
t1 = time.time()
while time.time() - t1 < 10 and gta.call("state")["status"] & 1: time.sleep(0.2)
left = not gta.call("state")["status"] & 1
time.sleep(2); show("after leaving"); shot("4-left")
print("view stayed open while looking around: %s, control back after Interact: %s" % (still, left))
print("PASSED" if view and still and left else "FAILED")
