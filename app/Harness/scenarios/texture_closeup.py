"""GTA-122: fixed-camera close-ups for texture comparisons. The same spot, camera, time and weather every run, so
screenshots from launches with different texture settings (PG_BIG_MIP_SKIP, PG_LITE_BIG_MIP_SKIP, presets) can be
laid side by side. Scenes: the road surface, a stop sign, a face, a car. Ambient traffic and people are kept out.

    gta.py launch sandbox --arg -graphicsPreset --arg 3 --env PG_FORCE_BC_DECODE=1 --env PG_BIG_MIP_SKIP=0
    python3 Harness/scenarios/texture_closeup.py LABEL [SETTLE_SECONDS]

Screenshots: /tmp/gta-texture-closeup/LABEL-<scene>.png. Compare with texture_closeup_compare.py.
"""
import math, os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

label = sys.argv[1] if len(sys.argv) > 1 else "run"
settle = float(sys.argv[2]) if len(sys.argv) > 2 else 20
OUT = "/tmp/gta-texture-closeup"
os.makedirs(OUT, exist_ok=True)

for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()

# The spot: the road along the east side of Legion Square, camera looking north along it.
X, Y, HEADING = 238.0, -870.0, 340.0
gta.teleport(X, Y, 40.0)
time.sleep(3)
z = gta.batch("GET_GROUND_Z_FOR_3D_COORD %.2f %.2f 60.0 p:1 false" % (X, Y))[0]["out"][0][0]["f"] or 29.5
gta.batch("SET_CLOCK_TIME 13 0 0; PAUSE_CLOCK true; SET_WEATHER_TYPE_NOW_PERSIST EXTRASUNNY; DISPLAY_HUD false; DISPLAY_RADAR false; "
          "SET_VEHICLE_POPULATION_BUDGET 0; SET_PED_POPULATION_BUDGET 0; SET_RANDOM_TRAINS false; SET_GARBAGE_TRUCKS false")
# The player stands behind the camera, hidden and frozen.
gta.batch("PLAYER_PED_ID; SET_ENTITY_COORDS_NO_OFFSET r:0 %.2f %.2f %.2f false false false; SET_ENTITY_VISIBLE r:0 false false; FREEZE_ENTITY_POSITION r:0 true"
          % (X - 6 * math.sin(math.radians(-HEADING)), Y - 6 * math.cos(math.radians(-HEADING)), z + 1))

def ahead(d, side=0.0):
    """A point d metres ahead of the spot along HEADING (side metres to the right)."""
    h = math.radians(HEADING)
    return X - d * math.sin(h) + side * math.cos(h), Y + d * math.cos(h) + side * math.sin(h)

def model(name):
    gta.batch("REQUEST_MODEL h:%s" % name)
    for _ in range(80):
        if gta.batch("HAS_MODEL_LOADED h:%s" % name)[0]["r"]["i"] & 1: return True
        time.sleep(0.25)
    print("model %s did not load" % name); return False

def camera(x, y, cz, pitch, heading, fov):
    gta.batch("DESTROY_ALL_CAMS false; CREATE_CAM_WITH_PARAMS DEFAULT_SCRIPTED_CAMERA %.2f %.2f %.2f %.1f 0.0 %.1f %.1f true 2; "
              "RENDER_SCRIPT_CAMS true false 0 true false; SET_FOCUS_POS_AND_VEL %.2f %.2f %.2f 0.0 0.0 0.0"
              % (x, y, cz, pitch, heading, fov, x, y, cz))

def clear():
    gta.batch("CLEAR_AREA %.2f %.2f %.2f 60.0 true false false false" % (X, Y, z))

entities = []
def keep(handle):
    entities.append(handle); return handle

def scene(name):
    end = time.monotonic() + settle
    while time.monotonic() < end:
        clear(); gta.dismiss_autosave(); time.sleep(1)
    path = "%s/%s-%s.png" % (OUT, label, name)
    gta.shot(path)
    print("%s: %s" % (name, path))

# 1. Ground: 1.3 m up, looking down at 30 degrees: pavement tiles in front, the road behind.
camera(X, Y, z + 1.3, -30.0, HEADING, 50.0)
scene("road")

# 2. A stop sign 2.2 m ahead, a little to the right.
if model("prop_sign_road_01a"):
    sx, sy = ahead(2.2, 0.6)
    o = keep(gta.batch("CREATE_OBJECT h:prop_sign_road_01a %.2f %.2f %.2f false false false" % (sx, sy, z))[0]["r"]["i"])
    gta.batch("SET_ENTITY_HEADING %d %.1f; FREEZE_ENTITY_POSITION %d true" % (o, HEADING, o))   # its face towards the camera
    camera(X, Y, z + 1.95, 2.0, HEADING, 40.0)
    scene("sign")
    gta.batch("SET_ENTITY_COORDS_NO_OFFSET %d %.2f %.2f -50.0 false false false" % (o, sx, sy))

# 3. A face 0.9 m ahead, looking at the camera.
if model("a_m_y_business_01"):
    px, py = ahead(1.0)
    p = keep(gta.batch("CREATE_PED 4 h:a_m_y_business_01 %.2f %.2f %.2f %.1f false false" % (px, py, z, (HEADING + 180) % 360))[0]["r"]["i"])
    gta.batch("SET_PED_DEFAULT_COMPONENT_VARIATION %d; SET_BLOCKING_OF_NON_TEMPORARY_EVENTS %d true; FREEZE_ENTITY_POSITION %d true; TASK_STAND_STILL %d -1"
              % (p, p, p, p))
    time.sleep(1)
    head = gta.batch("GET_PED_BONE_COORDS %d 31086 0.0 0.0 0.0" % p)[0]["v"]   # SKEL_Head
    camera(X, Y, head[2] + 0.02, 0.0, HEADING, 30.0)
    scene("face")
    gta.batch("SET_ENTITY_COORDS_NO_OFFSET %d %.2f %.2f -50.0 false false false" % (p, px, py))

# 4. A car 4.5 m ahead, seen from the front-left corner.
if model("buffalo"):
    cx, cy = ahead(4.5)
    c = keep(gta.batch("CREATE_VEHICLE h:buffalo %.2f %.2f %.2f %.1f false false false" % (cx, cy, z + 0.3, (HEADING + 150) % 360))[0]["r"]["i"])
    gta.batch("SET_VEHICLE_COLOURS %d 111 111; SET_VEHICLE_NUMBER_PLATE_TEXT %d GTA122; SET_VEHICLE_DIRT_LEVEL %d 0.0; FREEZE_ENTITY_POSITION %d true"
              % (c, c, c, c))
    camera(X, Y, z + 1.2, -8.0, HEADING, 45.0)
    scene("car")

stats = [l for l in open(gta.log_path(), errors="replace").read().splitlines() if l.startswith("[metal] textures:") or "largest level" in l]
for l in stats[-2:]: print(l)
