"""GTA-198: "Native trap 6" in __dynamic_cast from NullContext::SetCBuffers a few frames after a device restore (a
live resize: a resolution change, a TV, a Mac window). Drives through Legion Square's traffic while it resizes the
back buffer every GAP seconds (with blood and petrol decals around the car each time) and, every BACKGROUND-th time, sends the app to the background (Settings opens) and
brings it back, then resumes from the pause menu. Fails if the game stops or hangs. Counts the restores and the
"held a freed buffer" lines (the GTA-198 guard) and, with --env PG_CBUF_TRACE=1 at launch, the stale binds.
Needs `gta.py launch story|sandbox` first.

    python3 Harness/scenarios/restore_cbuffers.py [CYCLES] [GAP] [BACKGROUND] [pause]

With "pause", each resize happens with the pause menu open, as a resolution change from Settings does (Settings opens
the game's pause menu), and the menu closes again after it.
"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

cycles = int(sys.argv[1]) if len(sys.argv) > 1 else 40
gap = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
every = int(sys.argv[3]) if len(sys.argv) > 3 else 4
in_pause = len(sys.argv) > 4 and sys.argv[4] == "pause"

def say(text): print(time.strftime("%H:%M:%S ") + text, flush=True)
def paused(): return gta.batch("IS_PAUSE_MENU_ACTIVE")[0]["r"]["i"] & 1
def stopped(text): return "Native trap" in text or "stopped:" in text or "Invalid call_indirect" in text

for _ in range(60):
    s = gta.call("state")
    if s.get("pos") and not s["status"] & 16: break
    gta.dismiss_autosave(); time.sleep(1)
gta.dismiss_autosave()
gta.teleport(195.0, -933.0, 30.5)   # Legion Square: traffic, pedestrians, the busiest render
time.sleep(4)
gta.batch("REQUEST_MODEL h:buffalo")
for _ in range(40):
    if gta.batch("HAS_MODEL_LOADED h:buffalo")[0]["r"]["i"] & 1: break
    time.sleep(0.25)
def drive():
    gta.batch("PLAYER_PED_ID; GET_ENTITY_COORDS r:0 true; CREATE_VEHICLE h:buffalo 200.0 -930.0 30.5 0.0 false false false; SET_PED_INTO_VEHICLE r:0 r:2 -1;"
              " TASK_VEHICLE_DRIVE_WANDER r:0 r:2 25.0 786603")
drive()
def decals():
    """Blood and petrol decals around the car: the decal batcher binds its own constant buffer to draw them."""
    _, at, _ = gta.player()
    x, y, z = at
    lines = ["ADD_DECAL %d %.1f %.1f %.1f 0.0 0.0 -1.0 0.0 1.0 0.0 3.0 3.0 1.0 1.0 1.0 1.0 60.0 false false false" % (kind, x + dx, y + dy, z - 0.6)
             for kind in (1010, 9000) for dx, dy in ((0.0, 3.0), (3.0, 0.0), (-3.0, 0.0), (0.0, -3.0))]
    gta.batch("; ".join(lines))
log = gta.log_path()
sizes = [(960, 444), (1280, 592), (720, 333), (1440, 666), (1170, 540)]
backgrounds, failed, start = 0, None, time.time()
for n in range(1, cycles + 1):
    w, h = sizes[n % len(sizes)]
    try:
        decals()
        time.sleep(0.5)
        if in_pause:
            for _ in range(6):
                if paused(): break
                gta.call("tap @pause 0.25"); time.sleep(1.5)
        reply = gta.call("resize %d %d" % (w, h))
        if not reply.get("ok"): failed = "resize refused: %s" % reply; break
        before = gta.call("state")["frames"]
        time.sleep(gap)
        if in_pause:
            for _ in range(6):
                if not paused(): break
                gta.call("tap @pause 0.25"); time.sleep(1.5)
        if gta.call("state")["frames"] <= before: failed = "the game stopped drawing after %d resizes (hang)" % n; break
        if every and n % every == 0:
            # Away and back: Settings comes to the front, then the game again (its own pause menu opens on the way out).
            subprocess.run(["xcrun", "simctl", "launch", gta.SIM, "com.apple.Preferences"], capture_output=True)
            time.sleep(3)
            subprocess.run(["xcrun", "simctl", "launch", gta.SIM, gta.BUNDLE], capture_output=True)
            time.sleep(3); backgrounds += 1
            for _ in range(6):
                if not paused(): break
                gta.call("tap @pause 0.25"); time.sleep(2)
            if n % (every * 3) == 0: drive()   # a fresh car now and then (the wander can end in a crash)
    except Exception as error:
        failed = "the game stopped after %d resizes (%s)" % (n, error); break
    text = open(log, errors="replace").read()
    if stopped(text[-30000:]): failed = "the engine stopped after %d resizes" % n; break
    if n % 5 == 0: say("%d resizes, %d times in the background" % (n, backgrounds))
text = open(log, errors="replace").read()
restores = text.count("FINISHED DEVICE RESTORE")
guarded = sum(1 for l in text.splitlines() if "held a freed buffer" in l)
stale = sum(1 for l in text.splitlines() if "binds the freed buffer" in l)
say("device restores %d, background trips %d, guard lines %d, stale-bind lines (trace) %d" % (restores, backgrounds, guarded, stale))
if failed:
    print("FAILED: " + failed)
    print("\n".join(l for l in text.splitlines()[-400:] if "trap" in l or "call_indirect" in l or "stopped" in l or "frame" in l)[-3000:])
else:
    print("PASSED: %d live resizes (%d device restores), %d trips to the background, in %.0f s while driving" % (n, restores, backgrounds, time.time() - start))
