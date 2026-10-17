# Vehicle spawn menu

Open Settings → Cheats → Spawn vehicle during gameplay. The menu searches the registered
vehicle models by label, model name, or class. It supports Story and Sandbox and
uses the same Settings entry point with touch, a controller, or a keyboard.
Cheats also contains Set money and every existing Story cheat, directly on the
same page, along with vehicle repair/cleaning, four time presets, seven weather
choices and an option to restore the natural weather cycle.

Persistent god mode and Never wanted each have an inline toggle switch. Changing
either keeps the menu open; both choices apply when normal gameplay resumes.
The switches show the requested state and can be changed repeatedly during a
long pause without timing out or occupying the single-action queue.
They remain enabled for this app session, including
character switches and respawns, and start off after the app is relaunched.
God mode restores player invincibility if gameplay scripts remove it. Never
wanted clears existing stars and holds the maximum wanted level at zero; turning
it off restores the prior limit (or a newer nonzero limit set by a mission).
These overrides can interfere with mission objectives that require damage or a
police pursuit; turn them off for those objectives.

The port discovers models from the running engine, so the list includes registered
DLC and special vehicles without bundling game metadata or a fixed vehicle list.
Availability means a registered vehicle model, not a guarantee that every special
model can be driven or created at every location. Boats need water, aircraft need
space, and rail vehicles are spawned individually, not as configured train routes.

## Implementation

`NativeVehicleSpawn.inc` runs from the main script update hook. UIKit
only reads copied catalogue entries and submits a single pending spawn request.
Discovery starts automatically during gameplay, scans 512 model slots per frame, deduplicates hashes, and never requests
model assets. Model labels are the game's label identifiers; model names remain
visible to distinguish variants.

Spawning waits up to 10 seconds for normal gameplay after Settings closes the
pause menu, then requests the model under the engine's `main` script context.
Creation only runs after `HasModelLoaded`, with a 30-second loading timeout.
Interrupted gameplay cancels the spawn and releases its model request. The menu
retains ownership of at most two vehicles. Before requesting a third model, it
explicitly deletes the oldest empty vehicle it still owns. Occupants (including
peds entering a seat) and entities taken over by another script are protected.
A failed deletion is checked by querying the entity, because this engine clears
the handle argument even when deletion fails. If both slots are occupied, the
spawn is declined. Model references are released on success, failure, timeout,
and cancellation while their owning script remains alive.

Previously, SET_ENTITY_AS_NO_LONGER_NEEDED left nearby vehicles eligible for
cleanup but still resident, allowing their assets to accumulate. The two-vehicle
bound addresses that source of memory growth. Spawning also checks the existing
native memory guard's reserve before requesting a model and while it loads, and
returns a visible low-memory result instead of continuing into vehicle creation.
The supplied logs subsequently identified an invalid vehicle-pool virtual call
while the asynchronous input worker was creating a vehicle, with ample free
memory. Spawning now runs in the main script update phase. See
[the crash analysis](spawn-crash-analysis.md) for evidence and remaining device checks.

The bridge validates that the main script has a resource handler, tracks that
handler across loading frames, and cancels if it changes. Old handler teardown
owns its outstanding references; the bridge must not release them through a new
handler. Temporary native arguments use a scoped, 32-byte WASM stack reservation
instead of a persistent engine heap pointer. Reentrant input polling cannot
execute the same spawn twice. The prior script context and stack are restored.

The model pool capacity address (10872120), archetype hash (+24), type (+157),
and main-script thread lookup are specific to build `8b0b5899ed`. They were checked
against that build's function bodies. `prepare.py` already rejects other WASM
checksums. New host functions are resolved by exact names in `engine_names.py`.
No files under the source game mirror are patched.

Persistent cheats run only on the same main script hook, never the input worker.
They resolve the current player on each tick and suspend native writes during
pause/loading or when no player exists. UIKit reads state under the menu mutex;
switch requests retain the most recent value per cheat until gameplay resumes.
Once disabled, the bridge stops enforcing that cheat.

## Validation

Run the bridge regression checks on macOS:

```sh
clang -std=c11 -fsanitize=address,undefined app/Tests/vehicle_spawn.c -o /tmp/vehicle-spawn
/tmp/vehicle-spawn
```

After preparing the pinned engine sources, also run
`python3 app/Tests/script_menu_hook.py` to check that the script-update hook is
installed once, remains idempotent, and cannot execute from the input worker.

These exercise the production bridge with a simulated engine: paginated discovery,
duplicate and non-vehicle filtering, unavailable names, single-request gating,
pause/readiness handling, loading completion and timeout, cutscene cancellation,
missing/changing script handlers, placement, seating, create failure, and asset
cleanup. They also exercise 200 consecutive replacements with auto-entry on and off, a
maximum of two live menu vehicles, reentrant polling, occupied slots, failed
deletion, mission ownership changes, and low-memory cancellation.
They do not substitute for engine integration testing.

The checks also cover persistent cheats surviving script resets and player
changes, no redundant native writes, invalid toggle values/player IDs, delayed
or expired toggles, disabled cheats no longer applying, and wanted-limit restore
including a pre-existing zero limit.
Switch tests also cover simultaneous changes, long pauses, rapid reversals,
no-player transitions, and independent one-shot actions.

On a device or a fully prepared simulator build, check:

1. Enter free roam in both Story and Sandbox, then open the menu. Search a base
   model and a DLC model; verify variants remain distinguishable and clearing the
   search restores the full list.
2. Spawn a car with automatic entry on, then off. Confirm the Settings sheet
   closes, gameplay resumes, and the vehicle appears ahead of the player.
3. Spawn a motorcycle, helicopter, plane, boat near water, and a trailer in open
   space. Test rail models near tracks; they have no route automation.
4. Repeat at least ten spawns with automatic entry on and off. Confirm that older
   empty menu vehicles are removed and the occupied one stays. Then interrupt a loading request by opening the pause menu, and try
   during a cutscene. Confirm feedback and that no delayed vehicle appears later.

The Release iPhoneOS build and sanitized bridge checks pass. Device testing by
the contributor confirmed repeated vehicle spawning and the persistent cheat
switches work. The scenarios above remain a checklist for broader device and
mission coverage.
