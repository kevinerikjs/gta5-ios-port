"""Regression for GTA-202: the ATM screen with touch only. At an ATM, Interact opens atm_trigger's screen (Maze Bank,
"Account Transactions", "Exit (B)") with player control still on, and the touch layout stayed the on-foot play one
with no Back, so a touch-only player couldn't leave. The frontend Accept and Back (201/202) don't tell the screen apart:
scripts poll them all through normal play. Once the screen takes input (about 4 s after Interact) atm_trigger reads the
frontend D-pad (187-190) every frame with IS_CONTROL_JUST_PRESSED and the like; that now gives the script menu layout
(arrows, Accept, Back, X), like the shop menus.

Stands in front of the Fleeca ATM by Legion Square, checks the play layout has no Back, taps Interact, waits for the
menu layout, taps Down, Up and Accept (the story ATM has one page: they must not close it), taps Back, then checks the
play layout is back and the move stick walks the player. Needs `gta.py launch story`; about 1 minute.

    python3 Harness/scenarios/atm_touch_back.py [OUT_DIR]
"""
import math, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)
AT = (147.0, -1033.5, 29.3)   # the Fleeca ATM by Legion Square
shot = lambda name: gta.shot(os.path.join(OUT, "atm-%s.png" % name))
def say(text): print(time.strftime("%H:%M:%S ") + text, flush=True); gta.call("mark GTA-202 " + text)
def ui(): return gta.call("ui")
def names(u): return {b["name"] for b in u.get("visible", [])}
def control(): return not gta.call("state")["status"] & 1
def wait_for(predicate, timeout, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value: return value
        time.sleep(step)
    return None
def menu_open(u=None):
    u = u or ui()
    return u.get("scriptMenu") and "back" in names(u) and {201, 202} <= set(u.get("polled", []))
def play_layout(u=None):
    u = u or ui()
    return not u.get("scriptMenu") and "back" not in names(u) and "jump" in names(u)

gta.teleport(*AT); time.sleep(6)
obj = 0
for model in ("prop_fleeca_atm", "prop_atm_01", "prop_atm_02", "prop_atm_03"):
    obj = gta.batch("GET_CLOSEST_OBJECT_OF_TYPE %.1f %.1f %.1f 25.0 u:0x%x false false false" % (AT + (gta.joaat(model),)))[0]["r"]["i"]
    if obj: break
if not obj: sys.exit("FAILED: no ATM near Legion Square")
heading = gta.batch("GET_ENTITY_HEADING %d" % obj)[0]["r"]["f"]
spot = gta.batch("GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS %d 0.0 -0.9 0.0" % obj)[0]["v"]
gta.teleport(spot[0], spot[1], spot[2])
gta.batch("PLAYER_PED_ID; SET_ENTITY_HEADING r:0 %.1f" % heading)
help_text = wait_for(lambda: "atm" in (gta.call("state").get("help") or "").lower() and gta.call("state")["help"], 20, 0.3)
u = ui()
before = play_layout(u)
say("help %r; play layout without Back: %s (polled %s)" % (help_text, before, u.get("polled")))
shot("1-help")

gta.call("tap @interact 0.2")
opened = wait_for(lambda: menu_open(), 15)
u = ui()
say("ATM screen: menu layout %s, control %s, polled %s, read %s, buttons %s"
    % (bool(opened), "on" if control() else "off", u.get("polled"), u.get("read"), sorted(names(u))))
time.sleep(0.5); shot("2-screen")

# The arrows and Accept send the frontend D-pad and A. The story ATM shows one page (balance and transactions), so
# they must leave it open.
for button in ("down", "up", "accept"):
    if button in names(ui()): gta.call("tap @%s 0.15" % button); time.sleep(1.0)
still = bool(menu_open())
say("after Down, Up, Accept: still open %s" % still)
shot("3-accept")

gta.call("tap @back 0.2")
closed = wait_for(lambda: play_layout() and control(), 10)
u = ui()
say("after Back: play layout %s, control %s, polled %s" % (bool(closed), "on" if control() else "off", u.get("polled")))
time.sleep(1.5); shot("4-left")

# Control is back: the move stick (the left side's empty area) walks the player away from the ATM (the camera looks
# at the ATM, so stick down).
_, p0, _ = gta.player()
gta.call("drag 7 0.22 0.55 0.22 0.72 0.3 1.8"); time.sleep(2.6)
_, p1, _ = gta.player()
moved = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
say("moved %.2f m with the move stick" % moved)
shot("5-walked")
ok = before and opened and still and closed and moved > 0.8
print("PASSED" if ok else "FAILED (play layout before %s, menu opened %s, stayed open %s, closed by Back %s, walked %.2f m)"
      % (before, bool(opened), still, bool(closed), moved))
