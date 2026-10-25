#!/usr/bin/env python3
"""Drive the game running in the iOS Simulator through its debug channel (App/DebugChannel.swift).

    gta.py launch story|sandbox [--env K=V]... [--arg A]... [--install] [--root DIR] [--keep-log]
    gta.py ping | state | ui
    gta.py n NAME|0xHASH [args]...          a game command (native) by its Script Hook V name
    gta.py batch "NAME args; NAME args"     several in one frame; r:K is command K's result
    gta.py tp X Y Z                         teleport the player (on foot or with the vehicle)
    gta.py g INDEX [COUNT] | gset INDEX VALUE   script globals
    gta.py peek ADDRESS LENGTH | poke ADDRESS HEX
    gta.py touch F down|move X Y | touch F up | tap X Y|@button [S] | drag F X0 Y0 X1 Y1 S [HOLD]
    gta.py pad a+up|- SECONDS [LX LY RX RY LT RT]
    gta.py resize W H                       the live back-buffer resize Settings or a TV makes
    gta.py wait CONDITION [TIMEOUT]         help:REGEX nohelp script:NAME noscript:NAME control nocontrol
                                            cutscene nocutscene player button:NAME log:REGEX near:X,Y,Z,R
    gta.py shot [FILE] | log [-n N] [REGEX] | mark TEXT
    gta.py run SCENARIO                     one command per line (sleep S, expect CONDITION, shot NAME too)
    gta.py missions | mission NAME|NUMBER   story missions; replay one (needs a save that completed it)
    gta.py autopilot HELP_REGEX [TIMEOUT]   move the mission along until that help text shows
    gta.py retry | blips                    fail and retry from the checkpoint; every map marker
    gta.py checkpoint N                     restart the running mission at its checkpoint N (Chop 2: the rail yard)
    gta.py save-from-log LOG ROOT           a player's save sent with their log, ready for launch --root ROOT
    gta.py trace SCRIPT [FRAMES] [NAME,...] the natives SCRIPT calls in FRAMES frames (lldb), in order; arguments and
                                            results of the NAMEd ones (the game stands still meanwhile)

Native arguments: 12 is an int, 1.5 a float, true/false a bool, h:name a model hash (joaat), any other word
text; the prefixes i: f: b: u: s: p:N (out-parameter of N words) r:K pick the type. Floats need a dot (100.0).

Environment: GTA_SIM (simulator UDID, default "booted"), GTA_PORT (7979), and for launch GTA_GAME_FOLDER
(the PC game files), GTA_APP (the built .app, for --install), GTA_MODS (Mods folder), GTA_ENGINE_ROOT (--root
default: a folder with userdata/ saves).
"""
import json, math, os, re, shlex, socket, subprocess, sys, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = "io.github.playgta5ios.app"
SIM = os.environ.get("GTA_SIM", "booted")
PORT = int(os.environ.get("GTA_PORT", "7979"))

_names = None
def natives():
    global _names
    if _names is None:
        _names = {}
        with open(os.path.join(HERE, "../Scripts/asi_native_hashes.txt")) as f:
            for line in f:
                if line.startswith("#") or not line.strip(): continue
                hash_, *names = line.split()
                for name in names: _names.setdefault(name.upper(), hash_)
    return _names

def joaat(text):
    h = 0
    for c in text.lower().encode():
        h = (h + c) & 0xffffffff; h = (h + (h << 10)) & 0xffffffff; h ^= h >> 6
    h = (h + (h << 3)) & 0xffffffff; h ^= h >> 11; h = (h + (h << 15)) & 0xffffffff
    return h

def encode(token):
    if re.match(r"^[ifbupr]:", token): return token
    if token.startswith("s:"): return "s:" + urllib.parse.quote(token[2:], safe="")
    if token.startswith("h:"): return "u:0x%x" % joaat(token[2:])
    if token in ("true", "false"): return "b:%d" % (token == "true")
    if re.match(r"^-?(0x[0-9a-fA-F]+|\d+)$", token): return "i:" + token
    if re.match(r"^-?(\d+\.\d*|\.\d+)(e-?\d+)?$", token): return "f:" + token
    return "s:" + urllib.parse.quote(token, safe="")

def native_line(words):
    name = words[0]
    if re.match(r"^0x[0-9a-fA-F]+$", name): hash_ = name[2:]
    else:
        hash_ = natives().get(name.upper())
        if not hash_: raise SystemExit("no native named %s" % name)
    return "native %s %s" % (hash_, " ".join(encode(w) for w in words[1:]))

class Channel:
    def __init__(self, timeout=20):
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
        self.file = self.sock.makefile("rb")
    def __call__(self, line):
        self.sock.sendall(line.encode() + b"\n")
        reply = self.file.readline()
        if not reply: raise ConnectionError("the game closed the channel")
        return json.loads(reply.decode("utf-8", "replace"))

_channel = None
def channel():
    global _channel
    if _channel is None: _channel = Channel()
    return _channel

def call(line):
    return channel()(line)

# MARK: Simulator
_container = None
def container():
    # Asked once per run: frequent simctl calls seemed to go with the simulator host crashing.
    global _container
    if not _container and os.environ.get("GTA_CONTAINER"): _container = os.environ["GTA_CONTAINER"]   # the Mac app's container
    if not _container:
        out = subprocess.run(["xcrun", "simctl", "get_app_container", SIM, BUNDLE, "data"], capture_output=True, text=True)
        _container = out.stdout.strip()
    return _container

def log_path():
    return os.path.join(container(), "Documents/native-port.log")

def shot(path=None):
    path = path or time.strftime("shot-%H%M%S.png")
    subprocess.run(["xcrun", "simctl", "io", SIM, "screenshot", path], capture_output=True)
    return path

def launch(mode, envs, args, install=False, root=None, timeout=420, keep_log=False):
    subprocess.run(["xcrun", "simctl", "boot", SIM], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", SIM, "-b"], capture_output=True)
    if install: subprocess.run(["xcrun", "simctl", "install", SIM, os.environ["GTA_APP"]], check=True)
    log = log_path()
    # --keep-log leaves the last run's log for the app to rotate (a stopped run is kept, GTA-159); the wait below
    # then starts once the app has replaced it.
    old = os.stat(log).st_ino if keep_log and os.path.exists(log) else None
    if os.path.exists(log) and not keep_log: os.remove(log)
    env = dict(os.environ)
    env["SIMCTL_CHILD_PG_TEST_NO_MODS_NOTICE"] = "1"
    if os.environ.get("GTA_MODS"): env["SIMCTL_CHILD_PG_MODS_FOLDER"] = os.environ["GTA_MODS"]
    root = root or os.environ.get("GTA_ENGINE_ROOT")
    if root: env["SIMCTL_CHILD_PG_SIMULATOR_ENGINE_ROOT"] = root
    for kv in envs:
        key, _, value = kv.partition("=")
        env["SIMCTL_CHILD_" + key] = value
    command = ["xcrun", "simctl", "launch", "--terminate-running-process", SIM, BUNDLE,
               "--local-game-folder", os.environ["GTA_GAME_FOLDER"], "--game-mode", mode, "--mute", "--boot-engine", "--touch-controls-preview"]
    if mode == "sandbox": command += ["-sandboxMap", "0"]
    subprocess.run(command + list(args), env=env, capture_output=True, check=True)
    for _ in range(60):
        if old is None or (os.path.exists(log) and os.stat(log).st_ino != old): break
        time.sleep(0.5)
    global _channel
    _channel = None
    start = time.time()
    while time.time() - start < timeout:
        try:
            text = open(log, errors="replace").read()
            if "Native trap" in text or "stopped:" in text: raise SystemExit("the game stopped while loading; see " + log)
            if "WORLD_READY" in text: return time.time() - start
        except FileNotFoundError: pass
        time.sleep(1)
    raise SystemExit("no WORLD_READY after %d s" % timeout)

# MARK: Story missions
# Script globals of this game build (the pinned game.wasm), found with gdump/gdiff around a Replay Mission:
# the mission table (34 words a mission: script name, then its label) and the repeat-play request that
# Pause > Game > Replay Mission writes (the mission number, 1 for a story mission, 5 to start it). main then
# starts mission_repeat_controller, which asks about the restore point.
MISSION_TABLE, MISSION_WORDS, REPEAT_PLAY = 99461, 34, 86717
# The replay controller's state: 14 idle, 1 Mission failed screen, 10 restarting.
REPLAY_STATE = 109375
# The checkpoint a mission retry starts from (seen 0 -> 3 when Scouting the Port reached the Handler).
CHECKPOINT = 109415

def missions():
    reply = call("gget %d %d" % (MISSION_TABLE, 110 * MISSION_WORDS))
    words = [int(v["u"], 16) if v else 0 for v in reply["values"]]
    text = lambda at, n: b"".join(w.to_bytes(8, "little") for w in words[at:at + n]).split(b"\0")[0].decode("latin1")
    table = {}
    for number in range(110):
        script = text(number * MISSION_WORDS, 3)
        if not re.match(r"^\w+$", script): break
        table[number] = (script, text(number * MISSION_WORDS + 8, 1))
    return table

# MARK: Driving a mission
def batch(text):
    """Game commands in one frame ("NAME args; NAME r:0 ..."): their results, or the error reply."""
    reply = call("; ".join(native_line(shlex.split(part)) for part in text.split(";") if part.strip()))
    if not reply.get("ok"): raise RuntimeError(reply.get("error", "batch failed"))
    return reply["results"]

def player():
    """The player ped, its position, and the vehicle it sits in (0 on foot)."""
    r = batch("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; GET_VEHICLE_PED_IS_IN r:0 false; IS_PED_IN_ANY_VEHICLE r:0 false")
    return r[0]["r"]["i"], r[1]["v"], r[2]["r"]["i"] if r[3]["r"]["i"] & 1 else 0

def teleport(x, y, z):
    batch("PLAYER_PED_ID; SET_PED_COORDS_KEEP_VEHICLE r:0 %.2f %.2f %.2f" % (x, y, z))

def blips(sprites=range(0, 830), each=6):
    """Every map marker: sprite, position, colour, whether the GPS route leads to it, the entity it marks."""
    found, sprites = [], list(sprites)
    for k in range(0, len(sprites), 6):
        group, lines = sprites[k:k + 6], []
        for sprite in group:
            lines += ["GET_FIRST_BLIP_INFO_ID %d" % sprite] + ["GET_NEXT_BLIP_INFO_ID %d" % sprite] * (each - 1)
        handles = [(group[i // each], r["r"]["i"]) for i, r in enumerate(batch("; ".join(lines))) if r.get("ok") and r["r"]["i"]]
        if not handles: continue
        lines = []
        for _, h in handles:
            lines += ["GET_BLIP_INFO_ID_COORD %d" % h, "GET_BLIP_COLOUR %d" % h, "DOES_BLIP_HAVE_GPS_ROUTE %d" % h, "GET_BLIP_INFO_ID_ENTITY_INDEX %d" % h]
        r = []
        for at in range(0, len(lines), 60):   # the engine runs at most 64 commands a batch
            r += batch("; ".join(lines[at:at + 60]))
        for i, (sprite, h) in enumerate(handles):
            coord, colour, route, entity = r[4 * i:4 * i + 4]
            found.append(dict(sprite=sprite, handle=h, at=[round(v, 1) for v in coord["v"]], colour=colour["r"]["i"],
                              route=bool(route["r"]["i"] & 1), entity=entity["r"]["i"]))
    return found

def objective():
    """The marker the mission points at: the GPS route's, else the first non-enemy standard one."""
    marked = [b for b in blips(sprites=[1, 162, 225, 226, 280]) if b["colour"] != 1]
    return ([b for b in marked if b["route"]] or marked or [None])[0]

def autopilot(until, timeout=600, near=3.0, verbose=True):
    """Moves a mission along until a help text matches `until`: skips cutscenes, teleports a few metres short of
    the objective marker (escorts are followed), and gets into marked vehicles at the driver's door with Enter."""
    end, last, fails = time.time() + timeout, None, 0
    while time.time() < end:
        s = call("state")
        if s.get("help") and re.search(until, s["help"], re.I): return s
        if call("gget %d 1" % REPLAY_STATE)["values"][0]["i"] == 1:
            # Mission failed (a teleport can blow a cover): Retry, through the touch prompt's Accept.
            fails += 1
            if fails > 3: raise RuntimeError("autopilot: the mission failed %d times" % fails)
            if verbose: print("mission failed; retrying", flush=True)
            time.sleep(1.5); call("tap @accept 0.2"); time.sleep(3); continue
        if s["status"] & 4:
            # Skip as a player does (A): STOP_CUTSCENE_IMMEDIATELY can leave a mission waiting for the cutscene's
            # exit states for good (By the Book's opening).
            call("pad a 0.3"); time.sleep(2); continue
        if s["status"] & 9:
            time.sleep(1); continue
        b = objective()
        if verbose and b and b["at"] != last: print("objective", b, flush=True); last = b["at"]
        _, at, vehicle = player()
        if b and b["entity"] and not vehicle and batch("IS_ENTITY_A_VEHICLE %d" % b["entity"])[0]["r"]["i"] & 1:
            door = batch("GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS %d -2.2 0.0 0.0" % b["entity"])[0]["v"]
            teleport(*door); time.sleep(1); call("tap @enter 0.2")
            for _ in range(20):
                time.sleep(0.5)
                if player()[2]: break
            continue
        if b:
            dx, dy = b["at"][0] - at[0], b["at"][1] - at[1]; d = math.hypot(dx, dy)
            if d > near + 2: teleport(at[0] + dx * (d - near) / d, at[1] + dy * (d - near) / d, b["at"][2] + 0.5)
        time.sleep(1.5)
    raise TimeoutError("autopilot: no help matching %r after %d s" % (until, timeout))

def dismiss_autosave():
    """The autosave prompt ("overwrite the data in this slot?") on the test save: No, then Yes to "Autosaving will be
    turned off", then OK, so the save the harness loads stays as it is. True if it was up."""
    if not call("state").get("status", 0) & 8: return False
    for button in ("back", "accept", "accept"):
        for _ in range(10):
            if call("state").get("status", 0) & 8: break
            time.sleep(0.5)
        else: break
        time.sleep(1.2); call("tap @%s 0.2" % button); time.sleep(2)
    return True

def retry_checkpoint(timeout=60):
    """Fails the mission (the player dies) and presses Retry: the mission restarts at its last checkpoint."""
    batch("PLAYER_PED_ID; SET_ENTITY_HEALTH r:0 0 0")
    end = time.time() + timeout
    while call("gget %d 1" % REPLAY_STATE)["values"][0]["i"] != 1:
        if time.time() > end: raise TimeoutError("no Mission failed screen")
        time.sleep(0.5)
    time.sleep(1.5); call("pad a 0.3")
    while call("state")["status"] & 1 or call("gget %d 1" % REPLAY_STATE)["values"][0]["i"] == 1:
        if time.time() > end: raise TimeoutError("the mission didn't restart")
        time.sleep(0.5)
    time.sleep(2)

# MARK: Waiting
def check(condition, state, log_from=None):
    kind, _, value = condition.partition(":")
    status = state.get("status", 16)
    if kind == "help": return bool(state.get("help") and re.search(value, state["help"], re.I))
    if kind == "nohelp": return not state.get("help")
    if kind == "script": return value.lower() in [s.lower() for s in state.get("scripts", [])]
    if kind == "noscript": return value.lower() not in [s.lower() for s in state.get("scripts", [])]
    if kind == "control": return not status & 1
    if kind == "nocontrol": return bool(status & 1)
    if kind == "cutscene": return bool(status & 4)
    if kind == "nocutscene": return not status & 4
    if kind == "player": return not status & 16
    if kind == "near":
        x, y, z, r = map(float, value.split(","))
        p = state.get("pos")
        return bool(p) and (p[0] - x) ** 2 + (p[1] - y) ** 2 + (p[2] - z) ** 2 <= r * r
    if kind == "button": return any(b["name"] == value for b in call("ui").get("visible", []))
    if kind == "log":
        with open(log_path(), "rb") as f:
            f.seek(log_from or 0)
            return bool(re.search(value.encode(), f.read()))
    raise SystemExit("unknown condition " + condition)

def wait(condition, timeout=60):
    start = time.time()
    log_from = os.path.getsize(log_path()) if condition.startswith("log:") else None
    while True:
        state = call("state")
        if check(condition, state, log_from): return time.time() - start
        if time.time() - start > timeout:
            raise TimeoutError("%s not true after %d s; state %s" % (condition, timeout, json.dumps(state)[:600]))
        time.sleep(0.25)

# MARK: Commands
def show(reply):
    print(json.dumps(reply, ensure_ascii=False))

def result_line(result):
    if not result.get("ok"): return "error: " + result.get("error", "?")
    r = result["r"]
    parts = ["int %d" % r["i"], "float %g" % r["f"], "word %s" % r["u"]]
    if any(result["v"]): parts.append("vector %s" % result["v"])
    if "s" in result: parts.append("text %r" % result["s"])
    if "out" in result: parts.append("out %s" % [[(w["i"], w["f"]) for w in o] for o in result["out"]])
    return ", ".join(parts)

def command(words, base="."):
    if not words: return
    verb, rest = words[0], words[1:]
    if verb in ("ping", "state", "ui"): show(call(verb))
    elif verb == "n":
        reply = call(native_line(rest))
        print(result_line(reply["results"][0]) if reply.get("ok") else "error: " + reply.get("error", "?"))
    elif verb == "batch":
        lines = [native_line(shlex.split(part)) for part in " ".join(rest).split(";") if part.strip()]
        reply = call("; ".join(lines))
        if not reply.get("ok"): print("error: " + reply.get("error", "?")); return
        for i, result in enumerate(reply["results"]): print("%d: %s" % (i, result_line(result)))
    elif verb == "tp":
        x, y, z = rest[:3]
        f = lambda v: v if "." in v else v + ".0"
        command(["batch", "PLAYER_PED_ID; SET_PED_COORDS_KEEP_VEHICLE r:0 %s %s %s" % (f(x), f(y), f(z))])
    elif verb == "g": show(call("gget %s %s" % (rest[0], rest[1] if len(rest) > 1 else 1)))
    elif verb == "gset": show(call("gset %s %s" % (rest[0], rest[1])))
    elif verb in ("peek", "poke", "touch", "tap", "drag", "pad", "mark", "resize", "mouse", "open", "modbutton", "modremap", "modkey", "spawn", "teststop", "trap", "stopfix", "alert", "screen"): show(call(" ".join([verb] + rest)))
    elif verb == "raw": show(call(" ".join(rest)))
    elif verb == "wait":
        took = wait(rest[0], float(rest[1]) if len(rest) > 1 else 60)
        print("%s after %.1f s" % (rest[0], took))
    elif verb == "expect":
        state = call("state")
        if not check(rest[0], state): raise AssertionError("expected %s; state %s" % (rest[0], json.dumps(state)[:600]))
        print("ok: " + rest[0])
    elif verb == "sleep": time.sleep(float(rest[0]))
    elif verb == "shot": print(shot(os.path.join(base, rest[0] if rest else time.strftime("shot-%H%M%S.png"))))
    elif verb == "log":
        n = 40
        if rest[:1] == ["-n"]: n, rest = int(rest[1]), rest[2:]
        lines = open(log_path(), errors="replace").read().splitlines()
        if rest: lines = [l for l in lines if re.search(rest[0], l)]
        print("\n".join(lines[-n:]))
    elif verb == "launch":
        mode, envs, args, install, root, keep_log = rest[0], [], [], False, None, False
        i = 1
        while i < len(rest):
            if rest[i] == "--env": envs.append(rest[i + 1]); i += 2
            elif rest[i] == "--arg": args.append(rest[i + 1]); i += 2
            elif rest[i] == "--root": root = rest[i + 1]; i += 2
            elif rest[i] == "--install": install = True; i += 1
            elif rest[i] == "--keep-log": keep_log = True; i += 1
            else: raise SystemExit("launch: unknown option " + rest[i])
        print("WORLD_READY after %.0f s" % launch(mode, envs, args, install, root, keep_log=keep_log))
    elif verb == "run":
        path = rest[0]; base = os.path.splitext(path)[0] + "-out"
        os.makedirs(base, exist_ok=True)
        start = time.time()
        for number, line in enumerate(open(path), 1):
            line = line.strip()
            if not line or line.startswith("#"): continue
            print("[%6.1f] %s" % (time.time() - start, line), flush=True)
            try: command(shlex.split(line), base)
            except (AssertionError, TimeoutError) as error:
                print("FAILED at line %d: %s" % (number, error)); shot(os.path.join(base, "failed.png")); sys.exit(1)
        print("PASSED in %.0f s" % (time.time() - start))
    elif verb == "gdump":
        # gdump FILE [START] [COUNT]: script globals as {index: word} (nonzero only), for gdiff
        start, count = int(rest[1]) if len(rest) > 1 else 0, int(rest[2]) if len(rest) > 2 else 262144
        words = {}
        for at in range(start, start + count, 4096):
            reply = call("gget %d %d" % (at, min(4096, start + count - at)))
            for i, value in enumerate(reply.get("values", [])):
                if value and value["u"] != "0x0": words[at + i] = value["u"]
        json.dump(words, open(rest[0], "w"))
        print("%d nonzero globals in %s" % (len(words), rest[0]))
    elif verb == "gdiff":
        # gdiff A B: the globals that changed between two dumps
        a, b = (json.load(open(p)) for p in rest[:2])
        for key in sorted(set(a) | set(b), key=int):
            if a.get(key) != b.get(key):
                word = int(b.get(key, "0x0"), 16)
                f = __import__("struct").unpack("<f", (word & 0xffffffff).to_bytes(4, "little"))[0]
                print("Global_%s: %s -> %s (int %d, float %g)" % (key, a.get(key, "0x0"), b.get(key, "0x0"), (word & 0xffffffff) - ((word & 0x80000000) << 1), f))
    elif verb == "blips":
        for b in blips(): print(b)
    elif verb == "autopilot":
        s = autopilot(rest[0], float(rest[1]) if len(rest) > 1 else 600)
        print("reached:", s.get("help"))
    elif verb == "retry": retry_checkpoint()
    elif verb == "checkpoint":
        # checkpoint N: the running mission restarts at its checkpoint N (fails it and retries; Global_109415 is the
        # checkpoint a retry starts from, 109416 the next one, as the game sets them when a mission reaches one).
        call("gset %d %d" % (CHECKPOINT, int(rest[0]))); call("gset %d %d" % (CHECKPOINT + 1, int(rest[0]) + 1))
        retry_checkpoint()
        print("restarted at checkpoint %s" % rest[0])
    elif verb == "missions":
        for number, (script, label) in sorted(missions().items()): print("%3d %-24s %s" % (number, script, label))
    elif verb == "mission":
        # mission NAME|NUMBER: replays a story mission the way Pause > Game > Replay Mission does (needs a save
        # that has completed it), accepts the restore-point alert and waits until the mission script runs.
        table = missions()
        wanted = rest[0].lower()
        number = int(wanted) if wanted.isdigit() else next((n for n, (s, l) in table.items() if wanted in (s.lower(), l.lower())), None)
        if number not in table: raise SystemExit("no mission %s; `missions` lists them" % rest[0])
        script = table[number][0]
        for index, value in ((REPEAT_PLAY, number), (REPEAT_PLAY + 1, 1), (REPEAT_PLAY + 2, 5)): call("gset %d %d" % (index, value))
        start = time.time()
        while not call("state").get("status", 0) & 8:
            if time.time() - start > 30: raise SystemExit("the replay alert didn't come up")
            time.sleep(0.25)
        # The Accept button shows once the touch layout has switched to the prompt (0.6 s), and the alert can
        # ignore the first taps: tap while the alert is up, until the mission script runs.
        while True:
            state = call("state")
            if script.lower() in [s.lower() for s in state.get("scripts", [])]: break
            if time.time() - start > 90: raise SystemExit("the mission didn't start; state %s" % json.dumps(state)[:300])
            if state.get("status", 0) & 8: call("tap @accept 0.15")
            time.sleep(1)
        print("%s (%s) running after %.0f s" % (script, table[number][1], time.time() - start))
    elif verb == "save-from-log":
        # save-from-log LOG ROOT: the save a player sent with their log ("Include my latest save") into ROOT's save
        # folder; then `launch story --root ROOT` loads their game where it happened.
        import base64
        text = open(rest[0], errors="replace").read()
        found = re.search(r"===== SAVE \(([A-Za-z0-9_]+), (\d+) bytes, base64\) =====\n(.*?)\n===== END SAVE =====", text, re.S)
        if not found: raise SystemExit("no save in %s (the player didn't include one)" % rest[0])
        data = base64.b64decode(found.group(3))
        if len(data) != int(found.group(2)): raise SystemExit("the save is cut short: %d of %s bytes" % (len(data), found.group(2)))
        folder = os.path.join(rest[1], "userdata/Documents/Rockstar Games/GTA V/Default")
        os.makedirs(folder, exist_ok=True)
        open(os.path.join(folder, found.group(1)), "wb").write(data)
        print("%s (%d bytes) -> %s; now: gta.py launch story --root %s" % (found.group(1), len(data), folder, rest[1]))
    elif verb == "trace":
        # trace SCRIPT [FRAMES] [NAME,...]: lldb attaches to the app and Harness/trace_natives.py lists the natives
        # SCRIPT calls; e.g. trace Country_Race 1 IS_CONTROL_JUST_PRESSED,SET_INPUT_EXCLUSIVE (GTA-98).
        import tempfile
        found = subprocess.run(["pgrep", "-f", "%s.*PlayGTA5Native.app/PlayGTA5Native" % SIM], capture_output=True, text=True).stdout.split()
        if not found: raise SystemExit("no game process for simulator %s (set GTA_SIM to its UDID)" % SIM)
        script = os.path.join(tempfile.mkdtemp(), "trace.lldb")
        open(script, "w").write("process attach --pid %s\ncommand script import %s\nprocess continue\nbreakpoint delete --force\n"
                                "trace_natives_report\nprocess detach\n" % (found[0], os.path.join(HERE, "trace_natives.py")))
        env = dict(os.environ, TRACE_SCRIPT=rest[0], TRACE_FRAMES=rest[1] if len(rest) > 1 else "1", TRACE_ARGS=rest[2] if len(rest) > 2 else "")
        # An x86_64 Python (Rosetta) starts a translated lldb, which can't attach to the arm64 simulator app.
        translated = subprocess.run(["sysctl", "-n", "sysctl.proc_translated"], capture_output=True, text=True).stdout.strip() == "1"
        run = subprocess.run((["arch", "-arm64"] if translated else []) + ["lldb", "-b", "-s", script], capture_output=True, text=True, env=env)
        out = run.stdout + run.stderr
        print(out.split("trace_natives_report", 1)[1].split("(lldb) process detach")[0].strip() if "trace_natives_report" in out else out[-3000:])
    elif verb == "hash": print(natives().get(rest[0].upper()) or "0x%08x (joaat)" % joaat(rest[0]))
    else: raise SystemExit(__doc__)

if __name__ == "__main__":
    try: command(sys.argv[1:])
    except ConnectionRefusedError: raise SystemExit("no game listening on port %d (is the simulator build running?)" % PORT)
    except TimeoutError as error: raise SystemExit(str(error))
