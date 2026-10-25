"""Regression for GTA-74 (GitHub #20): the barber works the first time, then the chair does nothing. Two haircuts at
Herr Kutz in Davis: walk in, sit, buy a cut, leave the chair (the shop walks the player out), walk back in, sit, buy
another cut. Each cut must change the player's hair (component 2). Needs a story save where the shop is open (the
cash test save) and `gta.py launch story`; about 3 minutes.

    python3 Harness/scenarios/barber_twice.py [OUT_DIR] [--stay] [--visits N] [--door X,Y,Z --inside X,Y,Z]

--stay buys the second cut without leaving the chair. Screenshots go to OUT_DIR (default the current directory).
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

# Positional arguments: not an option, and not the value after --visits, --door or --inside.
args = [a for i, a in enumerate(sys.argv[1:], 1) if not a.startswith("--") and sys.argv[i - 1] not in ("--visits", "--door", "--inside")]
OUT = args[0] if args else "."
STAY = "--stay" in sys.argv
VISITS = int(sys.argv[sys.argv.index("--visits") + 1]) if "--visits" in sys.argv else 2
DOOR = (134.8, -1707.9, 29.3)      # outside Herr Kutz, Davis (the shop script runs near here)
INSIDE = (137.2, -1707.2, 29.3)    # inside, a few steps from the chairs at (137.5, -1708.9)
# Another shop: --door X,Y,Z (its map marker) --inside X,Y,Z (where it offers the chair). Mirror Park:
# --door 1208.3,-470.9,65.2 --inside 1209.8,-473.5,66.2
def point(flag, default):
    return tuple(map(float, sys.argv[sys.argv.index(flag) + 1].split(","))) if flag in sys.argv else default
DOOR, INSIDE = point("--door", DOOR), point("--inside", INSIDE)
os.makedirs(OUT, exist_ok=True)

def shot(name): gta.shot(os.path.join(OUT, name + ".png"))
def say(text): print(time.strftime("%H:%M:%S ") + text, flush=True); gta.call("mark " + text)
def hair():
    r = gta.batch("PLAYER_PED_ID; GET_PED_DRAWABLE_VARIATION r:0 2; GET_PED_TEXTURE_VARIATION r:0 2")
    return r[1]["r"]["i"], r[2]["r"]["i"]
def help_text(): return gta.call("state").get("help") or ""
def wait_for(predicate, timeout, step=0.5):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value: return value
        time.sleep(step)
    return None

def sit(visit):
    """Walks up to the chair until the shop offers it, then takes it (INPUT_CONTEXT is the d-pad's right)."""
    gta.teleport(*DOOR); time.sleep(3)
    gta.teleport(*INSIDE)
    prompt = wait_for(lambda: "INPUT_CONTEXT" in help_text() and help_text(), 25)
    shot("%d-1-prompt" % visit)
    say("visit %d: prompt %r" % (visit, prompt))
    if not prompt: return False
    gta.call("pad right 0.3")
    # The menu: control off, the shop camera, and the menu's own help (SHOP_HAIR_WHAT_WANT or a list of cuts).
    opened = wait_for(lambda: gta.call("state")["status"] & 1, 12)
    time.sleep(6); shot("%d-2-menu" % visit)
    say("visit %d: control off after the prompt: %s; help %r" % (visit, bool(opened), help_text()))
    return bool(opened)

def cut(visit, step):
    """Buys a cut from Hairstyles (A on the category, down to another cut, A) and waits for the barber to finish."""
    before = hair()
    gta.call("pad a 0.2"); time.sleep(1.5)
    for _ in range(1 + step):
        gta.call("pad down 0.2"); time.sleep(0.8)
    shot("%d-3-choice" % visit)
    gta.call("pad a 0.2")
    changed = wait_for(lambda: hair() != before and hair(), 40, 1)
    time.sleep(4); shot("%d-4-cut" % visit)
    say("visit %d: hair %s -> %s" % (visit, before, hair()))
    return bool(changed)

def leave(visit):
    """Backs out of the menu; the shop walks the player out and gives control back."""
    time.sleep(8)   # B does nothing while the barber cuts
    for _ in range(6):
        gta.call("pad b 0.2"); time.sleep(2)
        if not gta.call("state")["status"] & 1: break
    # Leaving after a purchase autosaves; the prompt about the test save's autosave slot is answered No
    # (gta.dismiss_autosave), so the save stays as it is.
    end = time.time() + 40
    while time.time() < end:
        if gta.dismiss_autosave(): continue
        if not gta.call("state")["status"] & 9: break
        time.sleep(0.5)
    if wait_for(lambda: gta.call("state")["status"] & 8, 8): gta.dismiss_autosave()   # it can come a moment later
    time.sleep(3); shot("%d-5-left" % visit)
    say("visit %d: control back: %s" % (visit, not gta.call("state")["status"] & 1))

gta.dismiss_autosave()   # the prompt a fresh start can show on the test save
# Money for the cuts (the test save has none): every story character's cash.
gta.batch("; ".join("STAT_SET_INT h:SP%d_TOTAL_CASH 100000 true" % c for c in range(3)))
results = []
for visit in range(1, VISITS + 1):
    if visit == 1 or not STAY:
        if not sit(visit): results.append((visit, "no menu")); say("visit %d: FAILED, no menu" % visit); break
    if STAY and visit > 1: time.sleep(10)   # the barber's animation ends and the menu shows its categories again
    ok = cut(visit, visit - 1)
    results.append((visit, "cut" if ok else "no cut"))
    if not STAY or visit == VISITS: leave(visit)
print("RESULTS", results)
print("PASSED" if all(r == "cut" for _, r in results) and len(results) == VISITS else "FAILED")
