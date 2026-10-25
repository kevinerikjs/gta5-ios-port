"""GTA-104 / GTA-52: safehouse garages. Needs a copy of the 100% save (Franklin at his Vinewood Hills house) and
`gta.py launch story --root ROOT` on that copy; part2 runs after an app restart on the same ROOT. About 3 minutes a part.

    python3 Harness/scenarios/safehouse_garages.py OUT ROOT exit|park|check|pcsave

exit (GTA-104): drives a car into Franklin's car garage near Grove Street (vehicle_gen_controller), stands at the door
facing it and leaves with the touch Interact button. The exit is a context prompt whose help label (WEB_VEH_EXIT) the
game files don't have, so the button has to come from the prompt itself (PGControlHints.contextPrompt).
park (GTA-52): takes a car from traffic (a script's car is never kept by a safehouse garage), parks it in Franklin's
house garage, walks out and saves in a new slot (the save menu a bed opens). check: after the restart, the house
garage's saved car is back in the world and the car garage still has the car from `exit`.
pcsave: on a root made with `gta.py save-from-log <log 1824> ROOT` (a PC save whose Zentorno in Michael's garage has
parts the port's files don't have), the game keeps running and the car stands in the garage.
Screenshots and notes go to OUT.
"""
import json, math, os, struct, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

OUT, ROOT, PART = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)
B = gta.batch
def r(x): return x["r"]["i"]
def note(*words):
    line = " ".join(str(w) for w in words)
    print(line, flush=True)
    with open(os.path.join(OUT, PART + "-notes.txt"), "a") as f: f.write(line + "\n")
def check(ok, what):
    note(("ok: " if ok else "FAILED: ") + what)
    if not ok: sys.exit(1)
def shot(name): gta.shot(os.path.join(OUT, name + ".png")); note("shot", name)
def peek(a, n): return bytes.fromhex(gta.call("peek %d %d" % (a, n))["hex"])
def u64(a): return struct.unpack("<Q", peek(a, 8))[0]
def me():
    res = B("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; IS_PED_IN_ANY_VEHICLE r:0 false; GET_VEHICLE_PED_IS_IN r:0 false")
    return r(res[0]), [round(v, 2) for v in res[1]["v"]], r(res[2]) & 1, r(res[3])
def place(x, y, z, h):
    ped, _, inside, veh = me()
    ent = veh if inside else ped
    B("SET_ENTITY_COORDS %d %.2f %.2f %.2f false false false true; SET_ENTITY_HEADING %d %.2f" % (ent, x, y, z, ent, h))
def buttons(): return [b["name"] for b in gta.call("ui").get("visible", [])]
def help_text(): return gta.call("state").get("help") or ""
def wait_for(test, timeout):
    start = time.time()
    while time.time() - start < timeout:
        if test(): return True
        time.sleep(0.5)
    return False
def garage_cars(garage):
    """A safehouse code garage's saved cars: CGarages at 15493232 (136 bytes each: +56 state, 1 = its cars are in the
    world; +64 its slot), slots of 2 x 144 bytes at 15493280 (+88 model, +72 position, +98 bit 0: still in storage)."""
    g = peek(u64(15493232) + 136 * garage, 136)
    cars = []
    for k in range(2):
        v = peek(15493280 + 288 * g[64] + 144 * k, 144)
        model = struct.unpack("<I", v[88:92])[0]
        if model: cars.append(dict(model=model, at=[round(x, 1) for x in struct.unpack("<3f", v[72:84])], stored=bool(v[98] & 1)))
    return struct.unpack("<i", g[56:60])[0], cars

CAR_GARAGE_DRIVE = (-70.2, -1823.2, 26.2, 53.0)        # in front of Franklin's car garage, in a car
CAR_GARAGE_FOOT = (-72.54, -1820.45, 26.0, 140.0)
CAR_GARAGE_EXIT = (194.6, -1025.4, -99.6, 180.0)       # inside, facing the door (the prompt wants heading 90-270)
HOUSE_GARAGE = 5                                       # Franklin's Vinewood Hills house (code garage 5)
HOUSE_PARK = (22.5, 544.2, 175.0, 329.0)
HOUSE_OUTSIDE = (14.0, 551.0, 175.9)

if PART == "exit":
    B("REQUEST_MODEL h:tailgater"); wait_for(lambda: r(B("HAS_MODEL_LOADED h:tailgater")[0]) & 1, 10)
    x, y, z, h = CAR_GARAGE_DRIVE
    B("CREATE_VEHICLE h:tailgater %.2f %.2f %.2f %.2f false false false; PLAYER_PED_ID; SET_PED_INTO_VEHICLE r:1 r:0 -1" % (x, y, z, h))
    check(wait_for(lambda: "enter garage" in help_text(), 20) and "interact" in buttons(), "the garage asks to enter, Interact on screen")
    shot("1-car-garage-entrance")
    gta.call("tap @interact")
    check(wait_for(lambda: me()[1][2] < -90 and not me()[2], 40), "inside the car garage, on foot")
    time.sleep(3); shot("2-car-garage-inside")
    place(*CAR_GARAGE_EXIT); time.sleep(4)
    note("at the door: help %r" % help_text())
    check("interact" in buttons(), "Interact shows at the garage door")
    shot("3-car-garage-door")
    gta.call("tap @interact")
    check(wait_for(lambda: me()[1][2] > 0, 30), "the tap took the player out of the garage")
    time.sleep(3); shot("4-left-on-foot")
elif PART == "park":
    place(-55.0, -1785.0, 28.0, 140.0); time.sleep(6)   # Grove Street, traffic
    car = 0
    for attempt in range(30):
        _, (px, py, pz), _, _ = me()
        v = r(B("GET_CLOSEST_VEHICLE %.1f %.1f %.1f 40.0 0 70" % (px, py, pz))[0])
        if v and not (r(B("IS_ENTITY_A_MISSION_ENTITY %d" % v)[0]) & 1):
            driver = r(B("GET_PED_IN_VEHICLE_SEAT %d -1 false" % v)[0])
            if driver: B("CLEAR_PED_TASKS_IMMEDIATELY %d" % driver); time.sleep(0.5)
            B("PLAYER_PED_ID; SET_PED_INTO_VEHICLE r:0 %d -1" % v); time.sleep(1)
            if me()[2]: car = v; break
        time.sleep(1.5)
    check(car != 0, "took a car from traffic")
    model = r(B("GET_ENTITY_MODEL %d" % car)[0]) & 0xffffffff
    json.dump({"model": model}, open(os.path.join(OUT, "house-car.json"), "w"))
    place(*HOUSE_PARK); time.sleep(4)
    gta.call("tap @enter"); time.sleep(4)
    shot("5-house-garage-parked")
    B("PLAYER_PED_ID; TASK_GO_STRAIGHT_TO_COORD r:0 %.1f %.1f %.1f 1.0 -1 150.0 0.5" % HOUSE_OUTSIDE)
    check(wait_for(lambda: math.dist(me()[1][:2], HOUSE_OUTSIDE[:2]) < 1.5, 20), "walked out of the house garage")
    shot("6-house-garage-walked-out")
    B("SET_SAVE_MENU_ACTIVE true"); time.sleep(3); gta.call("tap @accept"); time.sleep(3); gta.call("tap @accept")
    wait_for(lambda: "menu" not in str(gta.call("ui").get("context")), 30); time.sleep(4)
    folder = os.path.join(ROOT, "userdata/Documents/Rockstar Games/GTA V/Default")
    newest = max((f for f in os.listdir(folder) if f.startswith("SGTA5") and not f.endswith(".bak")), key=lambda f: os.path.getmtime(os.path.join(folder, f)))
    check(time.time() - os.path.getmtime(os.path.join(folder, newest)) < 60, "saved (%s)" % newest)
elif PART == "check":
    model = json.load(open(os.path.join(OUT, "house-car.json")))["model"]
    place(19.5, 545.85, 175.6, 241.0); time.sleep(8)
    B("SET_GAMEPLAY_CAM_RELATIVE_HEADING 0.0; SET_GAMEPLAY_CAM_RELATIVE_PITCH -12.0 1.0"); time.sleep(2)
    state, cars = garage_cars(HOUSE_GARAGE)
    note("house garage: state", state, "cars", cars)
    check(state == 1 and any(c["model"] == model and not c["stored"] for c in cars), "the parked car came back into the house garage")
    shot("7-house-garage-after-restart")
    place(*CAR_GARAGE_FOOT)
    check(wait_for(lambda: "enter garage" in help_text(), 20), "the car garage asks to enter")
    gta.call("tap @interact")
    check(wait_for(lambda: me()[1][2] < -90, 40), "inside the car garage")
    time.sleep(4)
    _, (px, py, pz), _, _ = me()
    found = set()
    for dx in (-12, -6, 0, 6, 12):
        for dy in (-12, -6, 0, 6, 12):
            v = r(B("GET_CLOSEST_VEHICLE %.1f %.1f %.1f 8.0 0 70" % (px + dx, py + dy, pz))[0])
            if v: found.add(r(B("GET_ENTITY_MODEL %d" % v)[0]) & 0xffffffff)
    check(gta.joaat("tailgater") in found, "the car garage still has the Tailgater")
    place(197.0, -1025.0, -99.6, 0.0); time.sleep(2); shot("8-car-garage-after-restart")
elif PART == "pcsave":
    time.sleep(10)
    state, cars = garage_cars(0)   # Michael's house
    note("Michael's garage: state", state, "cars", cars)
    check("Native trap" not in open(gta.log_path(), errors="replace").read(), "the engine is running")
    check(state == 1 and any(c["model"] == gta.joaat("zentorno") and not c["stored"] for c in cars), "the Zentorno came back into Michael's garage")
    place(-814.35, 186.3, 72.3, 282.0); time.sleep(3)
    B("SET_GAMEPLAY_CAM_RELATIVE_HEADING 0.0; SET_GAMEPLAY_CAM_RELATIVE_PITCH -10.0 1.0"); time.sleep(3)
    shot("9-pc-save-michael-garage")
