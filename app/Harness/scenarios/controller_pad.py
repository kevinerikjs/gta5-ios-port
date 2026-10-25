"""GTA-195 in the simulator: the Controller buttons touch scheme. Every button reaches the engine as its pad input,
the sticks move and look, multi-touch, a drive and an on-foot fight, Menu opens the pause menu, the layout editor
moves a button, and switching back restores the situational layout. Usage (game running in sandbox, launched with the
harness): python3 Harness/scenarios/controller_pad.py <app tree> <out dir> [PAD_SKIP_BUTTONS=1 skips the per-button checks]."""
import json, math, os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "Harness"))
import gta
OUT = sys.argv[2]
results = []

def say(*a): print(*a, flush=True)
def check(name, ok, detail=""):
    results.append((name, bool(ok), detail)); say(("PASS" if ok else "FAIL"), name, detail)
def shot(name): gta.shot(os.path.join(OUT, name + ".png"))
def call(line):
    r = gta.call(line)
    if not r.get("ok", True): say("  !", line, r)
    return r
def ui(): return gta.call("ui")
def val(result, kind="i"):
    r = result.get("r", {})
    return r.get(kind, r.get("i"))
def natives(text, kinds=""):
    """Results as ints, or floats where `kinds` has an f at that command's position (e.g. "if")."""
    out = gta.batch(text)
    return [val(x, kinds[k] if k < len(kinds) else "i") for k, x in enumerate(out)]
def at(name):
    for v in ui()["visible"]:
        if v["name"] == name: return v["at"]
    return None
def dismiss():
    for _ in range(3): gta.call("alert 1")

# ---- the scheme on
say("--- scheme controller"); dismiss()
call("scheme controller"); time.sleep(1.5)
state = ui()
names = [v["name"] for v in state["visible"]]
say("on screen:", names)
check("scheme shows the full pad + Settings", state.get("scheme") == "controller" and all(n in names for n in
      ["pad_ls", "pad_rs", "pad_a", "pad_b", "pad_x", "pad_y", "pad_lb", "pad_rb", "pad_lt", "pad_rt", "pad_l3", "pad_r3",
       "pad_view", "pad_menu", "pad_up", "pad_down", "pad_left", "pad_right", "settings"]), names)
shot("1-controller-buttons")

if os.environ.get("PAD_SKIP_BUTTONS") != "1":
    # ---- every button: the engine's script input for that pad button (standard pad layout)
    BUTTONS = [("pad_a", 223, 0x40), ("pad_x", 224, 0x80), ("pad_b", 225, 0x20), ("pad_y", 222, 0x10),
               ("pad_lb", 226, 0x4), ("pad_rb", 227, 0x8), ("pad_l3", 230, 0x200), ("pad_r3", 231, 0x400),
               ("pad_view", 236, 0x100), ("pad_left", 234, 0x8000), ("pad_right", 235, 0x2000),
               ("pad_down", 233, 0x4000), ("pad_up", 232, 0x1000)]
    for name, control, bit in BUTTONS:
        call("touch 1 down @" + name); time.sleep(0.35)
        pad = ui()["pad"]["buttons"]
        pressed, disabled = natives("IS_CONTROL_PRESSED 0 %d; IS_DISABLED_CONTROL_PRESSED 0 %d" % (control, control))
        call("touch 1 up"); time.sleep(0.4)
        released = natives("IS_DISABLED_CONTROL_PRESSED 0 %d" % control)[0]
        check("button %s -> pad bit 0x%x, input %d" % (name, bit, control), pad & bit and (pressed or disabled) and not released,
              "pad=0x%x pressed=%s disabled_pressed=%s after_release=%s" % (pad, pressed, disabled, released))
        if name == "pad_up":   # the phone came out: put it away
            time.sleep(1); call("tap @pad_b"); time.sleep(1)

    # Triggers: full on touch, analog when the finger slides up.
    for name, control in [("pad_lt", 228), ("pad_rt", 229)]:
        call("touch 1 down @" + name); time.sleep(0.35)
        full = natives("GET_DISABLED_CONTROL_NORMAL 0 %d" % control, "f")[0]
        x, y, w, h = at(name)
        call("touch 1 move %.4f %.4f" % (x, y - h * 0.5)); time.sleep(0.35)
        half = natives("GET_DISABLED_CONTROL_NORMAL 0 %d" % control, "f")[0]
        trig = ui()["pad"]["triggers"]
        call("touch 1 up"); time.sleep(0.3)
        off = natives("GET_DISABLED_CONTROL_NORMAL 0 %d" % control, "f")[0]
        check("trigger %s full then analog" % name, full > 0.95 and 0.2 < half < 0.8 and off < 0.05,
              "full=%.2f slid=%.2f (pad %s) released=%.2f" % (full, half, trig, off))

    # Sticks: a drag in each stick area; the engine's axes follow (script axes 218-221, -1..1 scaled to its own range).
    for name, axes in [("pad_ls", (218, 219)), ("pad_rs", (220, 221))]:
        x, y, w, h = at(name)
        call("touch 1 down %.4f %.4f" % (x, y)); time.sleep(0.1)
        call("touch 1 move %.4f %.4f" % (x + w * 0.4, y)); time.sleep(0.4)
        right = natives("GET_DISABLED_CONTROL_NORMAL 0 %d" % axes[0], "f")[0]
        call("touch 1 move %.4f %.4f" % (x, y - h * 0.4)); time.sleep(0.4)
        up = natives("GET_DISABLED_CONTROL_NORMAL 0 %d" % axes[1], "f")[0]
        pad = ui()["pad"]
        call("touch 1 up"); time.sleep(0.4)
        check("stick %s right and up" % name, right > 0.5 and up < -0.5, "x=%.2f y=%.2f (y negative is up in the game) pad=%s" % (right, up, pad))
        # tap twice and hold: the stick clicks (L3/R3)
        click = 230 if name == "pad_ls" else 231
        call("touch 1 down %.4f %.4f" % (x, y)); time.sleep(0.08); call("touch 1 up"); time.sleep(0.1)
        call("touch 1 down %.4f %.4f" % (x, y)); time.sleep(0.35)
        pressed = natives("IS_DISABLED_CONTROL_PRESSED 0 %d" % click)[0]
        call("touch 1 up"); time.sleep(0.4)
        check("stick %s tap twice and hold clicks (input %d)" % (name, click), pressed, str(pressed))

    # Multi-touch: both sticks, A and RT at once.
    ls, rs = at("pad_ls"), at("pad_rs")
    call("touch 1 down %.4f %.4f" % (ls[0], ls[1])); call("touch 1 move %.4f %.4f" % (ls[0], ls[1] - ls[3] * 0.4))
    call("touch 2 down %.4f %.4f" % (rs[0], rs[1])); call("touch 2 move %.4f %.4f" % (rs[0] + rs[2] * 0.4, rs[1]))
    call("touch 3 down @pad_a"); call("touch 4 down @pad_rt"); time.sleep(0.4)
    pad = ui()["pad"]
    a, rt, lx, ly, rx = natives("IS_DISABLED_CONTROL_PRESSED 0 223; GET_DISABLED_CONTROL_NORMAL 0 229; GET_DISABLED_CONTROL_NORMAL 0 218; GET_DISABLED_CONTROL_NORMAL 0 219; GET_DISABLED_CONTROL_NORMAL 0 220", "iffff")
    shot("2-four-fingers")
    for f in (1, 2, 3, 4): call("touch %d up" % f)
    check("four fingers at once: left stick, right stick, A, RT", a and rt > 0.9 and ly < -0.5 and rx > 0.5,
          "A=%s RT=%.2f left=(%.2f,%.2f) right x=%.2f pad=%s" % (a, rt, lx, ly, rx, pad))
    time.sleep(1)

# ---- on-foot fight: a pistol, a hostile ped, LT aims (lock-on), RT fires, the right stick looks.
say("--- fight")
me = natives("PLAYER_PED_ID")[0]
natives("REMOVE_ALL_PED_WEAPONS %d true; GIVE_WEAPON_TO_PED %d h:weapon_pistol 120 false true" % (me, me))
r = gta.batch("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; GET_GAMEPLAY_CAM_ROT 2")
pos, heading = r[1]["v"], r[2]["v"][2]   # the camera's yaw: the ped stands where the camera looks
natives("REQUEST_MODEL h:g_m_y_ballaeast_01")
for _ in range(40):
    if natives("HAS_MODEL_LOADED h:g_m_y_ballaeast_01")[0] & 1: break
    time.sleep(0.25)
fx, fy = -math.sin(math.radians(heading)) * 6, math.cos(math.radians(heading)) * 6
ped = natives("CREATE_PED 4 h:g_m_y_ballaeast_01 %.2f %.2f %.2f %.1f false true" % (pos[0] + fx, pos[1] + fy, pos[2] - 0.9, heading + 180))[0]
say("ped", ped, "player", me, "at", pos, "camera heading", heading)
if ped: natives("SET_BLOCKING_OF_NON_TEMPORARY_EVENTS %d true; TASK_STAND_STILL %d 15000" % (ped, ped))
ammo0 = natives("GET_AMMO_IN_PED_WEAPON %d h:weapon_pistol" % me)[0]
time.sleep(1.5)
health0 = natives("GET_ENTITY_HEALTH %d" % ped)[0]
call("touch 1 down @pad_lt"); time.sleep(1.2)
aiming = [v & 1 for v in natives("PLAYER_ID; IS_PLAYER_FREE_AIMING r:0; IS_PED_SHOOTING %d" % me)[1:]]
shot("3-fight-aim")
for _ in range(6):
    call("touch 2 down @pad_rt"); time.sleep(0.15); call("touch 2 up"); time.sleep(0.35)
shot("4-fight-fired")
call("touch 1 up")
health1, dead = natives("GET_ENTITY_HEALTH %d; IS_PED_DEAD_OR_DYING %d true" % (ped, ped)); dead &= 1
ammo = natives("GET_AMMO_IN_PED_WEAPON %d h:weapon_pistol" % me)[0]
check("on-foot fight: LT aims, RT shoots the ped", (health1 < health0 or dead),   # Sandbox refills ammo to 9999, so the count is only shown
      "ped health %s -> %s, dead=%s, pistol ammo %s -> %s, aiming/shooting %s" % (health0, health1, dead, ammo0, ammo, aiming))
time.sleep(1)

# ---- drive: spawn a car with the player in it, RT throttle with the left stick steering, LT brakes.
say("--- drive")
call("spawn 0x%x" % gta.joaat("blista"));
for _ in range(40):
    if natives("PLAYER_PED_ID; IS_PED_IN_ANY_VEHICLE r:0 false")[1] & 1: break
    time.sleep(0.5)
time.sleep(2)
car = natives("PLAYER_PED_ID; GET_VEHICLE_PED_IS_IN r:0 false")[1]
h0 = natives("GET_ENTITY_HEADING %d" % car, "f")[0]
ls = at("pad_ls")
call("touch 1 down @pad_rt"); time.sleep(3)
speed1 = natives("GET_ENTITY_SPEED %d" % car, "f")[0]
call("touch 2 down %.4f %.4f" % (ls[0], ls[1])); call("touch 2 move %.4f %.4f" % (ls[0] + ls[2] * 0.45, ls[1])); time.sleep(1.5)
shot("5-driving")
call("touch 2 up")
h1 = natives("GET_ENTITY_HEADING %d" % car, "f")[0]
call("touch 1 up"); call("touch 1 down @pad_lt"); time.sleep(2)
speed2 = natives("GET_ENTITY_SPEED %d" % car, "f")[0]
call("touch 1 up")
turn = (h1 - h0 + 540) % 360 - 180
check("drive: RT accelerates, the left stick steers, LT brakes", speed1 > 5 and abs(turn) > 10 and speed2 < speed1,
      "speed after 3 s RT %.1f m/s, heading change %.0f deg, speed after 2 s LT %.1f" % (speed1, turn, speed2))
time.sleep(1)

# ---- Menu: the pause menu
say("--- pause menu")
call("tap @pad_menu"); time.sleep(2.5)
paused = natives("IS_PAUSE_MENU_ACTIVE")[0] & 1
shot("6-pause-menu")
for _ in range(3):
    if not natives("IS_PAUSE_MENU_ACTIVE")[0] & 1: break
    call("tap @pad_b"); time.sleep(1.5)
closed = not natives("IS_PAUSE_MENU_ACTIVE")[0] & 1
check("Menu opens the pause menu (and closes it)", paused and closed, "open=%s closed after=%s" % (paused, closed))

# ---- Settings stays; the Touch scheme row
say("--- settings")
check("Settings button is on screen in the scheme", at("settings") is not None, str(at("settings")))
call("open controls"); time.sleep(1.5); shot("7-settings-touch-scheme"); call("open close"); time.sleep(1)
r = call("open hud"); time.sleep(1.5); shot("7b-hud-editor-with-pad"); call("open close"); time.sleep(1)
check("HUD layout editor opens (pad buttons dimmed behind its boxes: see 7b)", r.get("ok"), str(r))

# ---- the layout editor moves a button
say("--- layout editor")
before = at("pad_a")
call("open layout"); time.sleep(1.5)
r = call("editor pad pad_a 0.5 0.45 1.5")
time.sleep(0.5); shot("8-layout-editor-pad"); call("open close"); time.sleep(1.5)
after = at("pad_a")
check("layout editor moves and resizes pad_a in the game", after and before and abs(after[0] - before[0]) > 0.2 and after[2] > before[2] * 1.3,
      "before %s after %s (editor %s)" % (before, after, r))
shot("9-pad-a-moved")
call("tap @pad_a"); time.sleep(0.1)
call("open layout"); time.sleep(1); call("editor pad reset"); call("open close"); time.sleep(1)
check("editor reset puts pad_a back", at("pad_a") == before, str(at("pad_a")))

# ---- back to the situational layout
say("--- scheme situational")
natives("PLAYER_PED_ID; TASK_LEAVE_ANY_VEHICLE r:0 0 16"); time.sleep(3)
call("scheme situational"); time.sleep(2)
state = ui()
names = [v["name"] for v in state["visible"]]
check("switching back restores the situational layout", "scheme" not in state and "fire" in names and "jump" in names and not any(n.startswith("pad_") for n in names), names)
shot("10-situational-again")
call("touch 1 down @jump"); time.sleep(0.3)
x = natives("IS_DISABLED_CONTROL_PRESSED 0 224")[0]; call("touch 1 up")
check("situational Jump still presses X", x, str(x))

json.dump(results, open(os.path.join(OUT, "results.json"), "w"), indent=1)
say("RESULT: %d/%d passed" % (sum(1 for r in results if r[1]), len(results)))
