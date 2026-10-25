"""GTA-189: Monkey Business (fbi5A), the dive off the boat with touch. With player control off the script waits for
INPUT_VEH_EXIT (Y) as a disabled control, and the help says "Press ~input_veh_exit~ to dive into the sea." (lowercase):
the touch prompt layout must show the Y mission button, and a tap on it must start the swim to the tunnel.

    python3 Harness/scenarios/monkey_business_dive.py      (after `gta.py mission fbi5a`)
"""
import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gta

out = os.environ.get("GTA_OUT", ".")
gta.autopilot("dive into the sea", timeout=300)
ui = gta.call("ui")
names = [v["name"] for v in ui["visible"]]
print("layout %s, help asks for Y (exit) %s, on screen: %s" % ("prompt" if ui["prompt"] else ui["context"], ui.get("helpExit"), names))
gta.shot(os.path.join(out, "dive-1-help.png"))
if "script_y" not in names: sys.exit("FAILED: no Y button at the dive")
log_from = os.path.getsize(gta.log_path())
gta.call("tap @script_y 0.2")
end = time.time() + 15
while time.time() < end:
    if "FBI_5_SWIM_TO_TUNNEL_ENTRANCE" in open(gta.log_path(), errors="replace").read()[log_from:]: break
    time.sleep(0.5)
else: sys.exit("FAILED: the dive didn't start")
time.sleep(4); gta.shot(os.path.join(out, "dive-2-swimming.png"))
print("PASSED: the Y button started the dive; player at", gta.call("state").get("pos"))
