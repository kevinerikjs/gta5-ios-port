# Vehicle spawn crash: supplied logs, 17 October 2026

`logs/native-port.log` records 15 successful requests followed by a Besra spawn
on request 16. At line 31866 the engine traps with an invalid indirect call:
`w2c_game_f29099`, table index `1585769`, table size `89368`. The app reports
5087 MB used and 7200 MB free immediately afterward; the memory guard had neither
stopped streaming nor requested eviction. This is not an observed iOS memory kill.
The previous log contains no corresponding trap.

The saved `testGTA5Port.ipa` allows symbolication of the logged addresses. The
main-thread stack runs through `CApp::UpdateState` and `rage::fwFsm::Update`.
Disassembly at unslid `0x10174b740` identifies the failed virtual call: a vehicle
pool traversal reads an object's vtable slot at +1216. Its pool is loaded from
26005240 in the pinned generated engine. Meanwhile the `[GTA] ControlMgr Update
Thread` continues creating the Besra, seating the player, and reporting success
after the main thread has already trapped.

The port called CREATE_VEHICLE, grounding, seating, and entity release from
`ioPad::Update`, which runs on the asynchronous control worker. That permits
vehicle construction/destruction while the main thread traverses the same pool.
This is a concrete thread-safety defect and is consistent with the invalid
vtable call. The logs do not capture enough object memory to prove the precise
construction/lifetime interleaving. The variable number of successful spawns
also fits a timing-dependent failure rather than a fixed three-vehicle limit.

## Change

`prepare_script_menu.py` hooks `GtaThread::Update(int)`. The host accepts only
the `main` script, skips suspended threads, and executes menu requests in the
engine's normal script-update phase. The pad worker no longer calls the vehicle
bridge. Hooking only `CTheScripts::Process` would miss its inlined copy in the
normal frame, so the virtual thread-update entry point is used instead.
The catalog starts warming during gameplay, before Settings pauses scripts.

The existing two-vehicle bound and memory checks remain useful protections but
are not presented as the fix for this logged trap. Repair/clean, time, and
weather actions use the same script hook and never execute engine commands
from UIKit. These operations do not patch any files in the source mirror.

## Validation and remaining check

The ASan/UBSan bridge test covers 200 repeated spawns and native cheat actions.
`python3 app/Tests/script_menu_hook.py` checks fresh/idempotent patching against
the prepared engine, rejects a changed layout, verifies the pad callback cannot
invoke menu mutations, and checks all preparation entry points install the hook.

On a device, first look for `Cheats: main script update hook active` in the log.
Repeat the logged mix of cars, trailers, aircraft and boats, especially Jet then
Besra, with automatic entry enabled. Repeat with it disabled. Test the menu after
death/reload and in Story mode as well as Sandbox. The contributor confirmed
that repeated spawning works after the script-thread fix; broader vehicle and
mission coverage remains useful.
