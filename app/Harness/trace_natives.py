"""lldb module: every native one script calls in one frame (or a few), in order, with arguments and results for
the natives asked for. `gta.py trace SCRIPT` loads it; it needs a simulator build (lldb attaches to the app).

It breaks on the script interpreter (rage::scrThread::Run) to know which script runs, and on the interpreter's
native call to read the handler's table slot and the call's Info (result pointer, argument count, arguments).
Each stop costs a few tens of milliseconds, so the game stands still while a frame is traced (a busy script's
frame takes a minute or two); the engine may log "Script ... took longer than 1000ms" meanwhile.

How GTA-98 was found: the race result screen called SET_INPUT_EXCLUSIVE 215/216/200 and read 215/216 with
IS_CONTROL_JUST_PRESSED, which answered 0 while A was held.
"""
import lldb, os, re, struct, time
from pathlib import Path

MEMORY = 0x300000000   # replaced at attach by env.memory.data: the host maps wasm memory wherever mmap puts it
APP = Path(__file__).resolve().parents[1]
state = dict(running=None, frames=0, done=False, order=[], pending=None, seen=0)

def joaat(text):
    h = 0
    for c in text.lower().encode():
        h = (h + c) & 0xffffffff; h = (h + (h << 10)) & 0xffffffff; h ^= h >> 6
    h = (h + (h << 3)) & 0xffffffff; h ^= h >> 11
    return (h + (h << 15)) & 0xffffffff

def engine_tables():
    """Function names (Generated/funcnames.tsv) and the indirect table: slot -> function number (game_0.c's element
    segment, placed at table offset 1)."""
    names = {}
    for line in open(APP / "Generated/funcnames.tsv"):
        number, _, name = line.rstrip("\n").partition("\t")
        if number.isdigit(): names[int(number)] = name
    slots, inside = {}, False
    for line in open(APP / "Generated/game_0.c"):
        if line.startswith("const wasm_elem_segment_expr_t elem_segment_exprs_w2c_game_e0[]"): inside = True; continue
        if inside:
            if line.startswith("};"): break
            m = re.search(r"w2c_game_f(\d+)", line)
            slots[len(slots) + 1] = int(m.group(1)) if m else None
    return names, slots

def native_call_sites(names):
    """(file, line of the call, its table-slot variable) for each native call in the interpreter."""
    run = next(n for n, name in names.items() if name == "rage::scrThread::Run(int)")
    heads = (re.compile(r"^static u32 pg_script_run_original_f%d\(" % run), re.compile(r"^u32 w2c_game_f%d\(w2c_game\* instance" % run))
    for path in sorted((APP / "Generated").glob("game_*.c")):
        lines = open(path).read().split("\n")
        for head in heads:
            start = next((i for i, l in enumerate(lines) if head.match(l)), None)
            if start is None: continue
            sites = []
            for i in range(start + 1, len(lines)):
                if lines[i] == "}": break
                if "CALL_INDIRECT(instance->w2c_0x5F_indirect_function_table, void (*)(void*, u64), w2c_game_t1, var_j1" in lines[i]:
                    slot = re.match(r"\s*var_j1 = (var_l\d+);", lines[i - 1])
                    if slot: sites.append((path.name, i + 1, slot.group(1)))
            if sites: return run, sites
    raise RuntimeError("the interpreter's native call wasn't found in Generated/")

def reg(frame, name): return frame.FindRegister(name).GetValueAsUnsigned()

def on_run(frame, location, extra):
    process = frame.GetThread().GetProcess(); error = lldb.SBError()
    data = process.ReadMemory(MEMORY + reg(frame, "x1"), 0x200, error)
    mine = error.Success() and any(struct.unpack_from("<I", data, o)[0] == state["hash"] for o in range(0, 0x1fc, 4))
    if state["running"] and not mine:
        state["frames"] += 1
        if state["frames"] >= state["want_frames"]: state["done"] = True
    state["running"] = mine
    for b in state["call_bps"]: b.SetEnabled(mine and not state["done"])
    return state["done"] or time.time() > state["deadline"]

def on_call(frame, location, extra):
    process = frame.GetThread().GetProcess(); error = lldb.SBError()
    slot = frame.FindVariable(state["slot_var"]).GetValueAsUnsigned()
    name = state["native_name"](slot)
    entry = [name, None, None]
    if name in state["args_of"]:
        info = frame.FindVariable("var_j0").GetValueAsUnsigned()
        raw = process.ReadMemory(MEMORY + info, 24, error)
        if error.Success():
            result, count, params = struct.unpack_from("<QIxxxxQ", raw, 0)
            values = process.ReadMemory(MEMORY + params, 8 * min(count, 8), error) if count else b""
            entry[1] = [struct.unpack_from("<q", values, 8 * i)[0] for i in range(len(values) // 8)]
            state["pending"] = (len(state["order"]), result)
    state["order"].append(entry)
    return False

def on_return(frame, location, extra):
    pending, state["pending"] = state["pending"], None
    if pending:
        error = lldb.SBError(); raw = frame.GetThread().GetProcess().ReadMemory(MEMORY + pending[1], 8, error)
        if error.Success(): state["order"][pending[0]][2] = struct.unpack("<q", raw)[0]
    return False

def report(debugger, command, result, internal_dict):
    if not state["order"]: print("no natives from %s (is it running? %d frames seen)" % (state["script"], state["frames"])); return
    last, count = None, 0
    def flush():
        if last: print("%4s  %s" % ("%dx" % count if count > 1 else "", last))
    for name, args, value in state["order"]:
        text = name + ("(%s)" % ", ".join(map(str, args)) if args is not None else "") + (" -> %s" % value if value is not None else "")
        if text == last: count += 1; continue
        flush(); last, count = text, 1
    flush()
    print("%d natives in %d frame(s) of %s" % (len(state["order"]), max(state["frames"], 1), state["script"]))

def __lldb_init_module(debugger, internal_dict):
    names, slots = engine_tables()
    def native_name(slot):
        name = names.get(slots.get(slot), "slot %d" % slot)
        m = re.search(r"scrWrapped_(\w+)::", name)
        return m.group(1) if m else name.split("(")[0]
    run, sites = native_call_sites(names)
    state.update(script=os.environ["TRACE_SCRIPT"], hash=joaat(os.environ["TRACE_SCRIPT"]), native_name=native_name,
                 want_frames=int(os.environ.get("TRACE_FRAMES", "1")), deadline=time.time() + float(os.environ.get("TRACE_SECONDS", "600")),
                 args_of=set(filter(None, os.environ.get("TRACE_ARGS", "").upper().split(","))), slot_var=sites[0][2], call_bps=[])
    target = debugger.GetSelectedTarget()
    # A fixed address read nothing once the host mmap'd the memory anywhere: no script ever matched (0 frames, GTA-193).
    global MEMORY
    data = target.FindFirstGlobalVariable("env").GetChildMemberWithName("memory").GetChildMemberWithName("data")
    if data.IsValid() and data.GetValueAsUnsigned(): MEMORY = data.GetValueAsUnsigned()
    target.BreakpointCreateByName("w2c_game_f%d" % run).SetScriptCallbackFunction("trace_natives.on_run")
    for path, line, _ in sites:
        call = target.BreakpointCreateByLocation(path, line); call.SetScriptCallbackFunction("trace_natives.on_call"); call.SetEnabled(False)
        after = target.BreakpointCreateByLocation(path, line + 1); after.SetScriptCallbackFunction("trace_natives.on_return")
        state["call_bps"].append(call)
    debugger.HandleCommand("command script add -f trace_natives.report trace_natives_report")
