# Simulator harness

Simulator builds of the app listen on `127.0.0.1:7979` (`PG_DEBUG_PORT`) for test commands
(`App/DebugChannel.swift`, `Source/NativeDebugChannel.inc`). Device builds don't contain any of it.
`gta.py` drives the running game from the Mac:

```sh
export GTA_SIM=<simulator UDID> GTA_GAME_FOLDER=<folder with the PC game files> GTA_APP=<built .app>
./gta.py launch sandbox --install        # boots the simulator, starts the game, waits for the world
./gta.py n GET_THIS_SCRIPT_NAME          # any game command by its Script Hook V name
./gta.py tp 215.0 -810.0 31.0            # teleport
./gta.py tap @jump                       # a finger on a touch button, through the real touch code
./gta.py wait help:Handler 120           # until a help text matches
./gta.py run scenarios/smoke.scn         # a scenario file, one command per line
```

`./gta.py` without arguments lists every command.

## Reaching a moment inside a mission

1. `./gta.py mission <script>`. Heists open the planning board first: press A until the heist script runs.
2. `./gta.py checkpoint N` for N = 1, 2, 3, … until the scene matches. Check the help text and the player's ped or vehicle model in `state`. Don't autopilot a whole mission from its start: it is slow, can fail the mission, and the simulator may restart in between.
3. Then `autopilot` or hand-drive the last stretch.
4. `./gta.py trace <script>` shows what a screen or mission step waits for.
5. Save it as `scenarios/<name>.py` so it can be rerun.


## What is a script waiting for?

`./gta.py trace SCRIPT [FRAMES] [NAME,...]` attaches lldb to the app and lists every native SCRIPT calls in one
frame (or FRAMES), in order, with arguments and results for the NAMEd natives (`trace_natives.py`). The game
stands still while it runs (seconds for a small script, a minute or two for a busy one). For a screen that
ignores a button, trace the script that draws it and look at what it reads:

```sh
./gta.py trace Country_Race 1 IS_CONTROL_JUST_PRESSED,SET_INPUT_EXCLUSIVE,DISABLE_CONTROL_ACTION
```

The race result screen (GTA-98) showed `IS_CONTROL_JUST_PRESSED(2, 215) -> 0` while A was held; `n
IS_CONTROL_ENABLED 2 215` then showed the input disabled.

## Reading a mission's logic

- The game's scripts, decompiled (a newer game version, but the mission logic matches): Sainan's
  [GTA-V-Decompiled-Scripts](https://github.com/Sainan/GTA-V-Decompiled-Scripts) (`decompiled_scripts/<script>.c`). Search
  a stage's help and objective labels, the controls it reads (`PAD::GET_CONTROL_VALUE(2, 218)` = the left stick's X axis)
  and its timers. Friend Request (lester1) waits for a channel change, then accepts the call only 77-170 s later.
- Any text label while its mission runs: `./gta.py n GET_FILENAME_FOR_AUDIO_CONVERSATION s:CUT_HELP`. Help texts name the
  inputs (`~INPUT_SCRIPT_RT~`) the touch layout has to offer.
- Script names aren't titles: Friend Request is `lester1`, Monkey Business `fbi5A`, Scouting the Port `docks_setup`.
  `./gta.py checkpoint 0` restarts a running mission from its start.

## Scenarios

`scenarios/*.py` reproduce reported moments and check them; each says what it needs (save, launch mode) and how
long it takes. `race_result.py` (GTA-98) wins the Stock Car Race and checks its result screen;
`fail_prompt_and_exit.py` (GTA-107, GTA-113) the Mission failed prompt; `chop_switch.py` (GTA-81) the switch to
Chop; `handler_frame.py` (GTA-97) the Handler's frame; `safehouse_garages.py` (GTA-104, GTA-52) leaving the car
garage on foot, a parked car kept across a save and a restart, and a PC save's modded garage car.
