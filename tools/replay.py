"""Replay a recorder log through combat-helper offline.

Feeds the recorded chat lines, object spawns and var values (boss HP, phase
var) back into main.lua tick by tick using simulate.py's fake API, then prints
the plugin's predictions next to what actually happened.

Usage: python replay.py [recording.log]
"""
import os
import re
import sys

from lupa import lua54

import simulate

LINE = re.compile(r"\[\s*(\d+)\]\s+(\S+)\s+(.*)")

# The live plugin reads the chatbox more often than the recorder: it syncs every
# yell 1 tick before the recorder logs it (all 4 slots, 2026-10-21). Feed chat
# that much earlier so replays match live.
CHAT_LEAD = 1


def parse(path):
    events = {}
    for raw in open(path, encoding="utf-8", errors="replace").read().replace("\x00", "").splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        tick, cat, rest = int(m.group(1)), m.group(2), m.group(3).strip()
        if cat == "CHAT":
            tick = max(1, tick - CHAT_LEAD)
        events.setdefault(tick, []).append((cat, rest))
    return events


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "recording.log"
    events = parse(path)
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    sim = lua.execute(simulate.STUBS, simulate.PLUGIN_DIR.replace("\\", "/"))
    run = lua.eval("function(src) local f = assert(load(src, '@main.lua')); return f() end")
    lua.execute("print = function() end")  # silence plugin console output
    run(open(os.path.join(simulate.PLUGIN_DIR, "main.lua"), encoding="utf-8").read())
    # Capture the plugin's prediction log lines
    # HITS=1 also prints the plugin's player-hit tags
    hits = "true" if os.environ.get("HITS") else "false"
    lua.execute('package.loaded.recorder.Log = function(c, t) if c == "PRED" or (' + hits + ' and c == "HIT") then'
                ' SIM_PRED[#SIM_PRED + 1] = (c == "HIT" and "HIT " or "") .. t end end')
    set_var = lua.eval("function(name, value) SIM_VARS[name] = value end")
    # Abilities: ABIL lines -> VarTransmit, with a config.Struct stub for the name
    lua.execute("""
        SIM_ABIL = {}
        SIM_STRUCT = {}
        config = config or {}
        config.Param = config.Param or setmetatable({}, { __index = function(_, k) return k end })
        config.Struct = { FromID = function(id)
            return { configName = SIM_STRUCT[id], GetParamValue = function(_, param) return SIM_ABIL[id] end }
        end }
    """)

    pred_log = lua.eval("function() local out = SIM_PRED; SIM_PRED = {}; return out end")

    for _ in range(3):
        sim.chat("(replay start)")
    # Recorder start snapshot ("X -1 -> value" at tick 0): values that existed
    # before the recording, so set them before the first tick (as live)
    for cat, rest in events.get(0, []):
        parts = rest.split()
        if cat == "VAR" and len(parts) >= 5 and parts[-3] == "-1":
            try:
                set_var(parts[1], int(parts[-1]))
            except ValueError:
                pass
    sim.tick(1)
    last_panel = None
    for tick in range(0, max(events) + 1):
        for cat, rest in events.get(tick, []):
            if cat == "BOSS" and rest.startswith("tracking"):
                m = re.match(r"tracking '([^']*)' config=(\d+)", rest) or re.match(r"tracking '([^']*)'", rest)
                sim.spawnTelos(m[1] if m else None)
                if m and m.lastindex == 2:
                    sim.setBossConfig(int(m[2]))
            elif cat == "BOSS" and rest.startswith("transform"):
                m = re.search(r"-> '[^']*' config (\d+)", rest)
                if m:
                    sim.setBossConfig(int(m[1]))
            elif cat == "CHAT":
                sim.chat(rest)
                if "Telos:" in rest or "anima bomb" in rest or "dead" in rest or "Araxx" in rest or "cocoon" in rest or "acidic spider appears" in rest or "TzKal-Zuk:" in rest:
                    print(f"[{tick:4}] ACTUAL  {rest}")
            elif cat == "POS":
                m = re.search(r"boss (-?\d+),(-?\d+)", rest)
                if m:
                    sim.setBossPos(int(m[1]), int(m[2]))
                m = re.search(r"you (-?\d+),(-?\d+)", rest)
                if m:
                    sim.setPlayerPos(int(m[1]), int(m[2]))
            elif cat == "LOC+":
                name = rest.split()[0]
                sim.fire("LocAdded", lua.table_from({"config": lua.table_from({"configName": name})}))
                if "TENDRILS" in name:
                    print(f"[{tick:4}] ACTUAL  object {name}")
            elif cat == "LOCANI":
                name = rest.split()[0]
                sim.fire("LocAnimation", lua.table_from({"animation": lua.table_from({"configName": name})}))
            elif cat in ("NPCS+", "NPCS-"):
                m = re.match(r"'([^']*)'.*?uid=(\d+)", rest)
                if m and m[1] not in ("Araxxor", "Araxxi", "TzKal-Zuk") and "Telos" not in m[1]:
                    if cat == "NPCS+":
                        sim.addNpc(int(m[2]), m[1])
                        if "spider" in m[1]:
                            print(f"[{tick:4}] ACTUAL  npc {m[1]}")
                    else:
                        sim.removeNpc(int(m[2]))
            elif cat == "ABIL":
                m = re.match(r"(\S+) = (\d+)(?: struct (\S+))?(?:.*?COMBATV2_ABILITY_NAME='([^']*)')?", rest)
                if m:
                    if m[3]:
                        lua.globals().SIM_STRUCT[int(m[2])] = m[3]
                    if m[4]:
                        lua.globals().SIM_ABIL[int(m[2])] = m[4]
                    sim.fire("VarTransmit", lua.table_from({
                        "var": lua.table_from({"configName": m[1]}), "newValue": int(m[2]), "oldValue": 0}))
            elif cat == "VAR":
                parts = rest.split()
                if len(parts) >= 5 and parts[0] in ("VarPlayer", "VarClient"):
                    try:
                        set_var(parts[1], int(parts[-1]))
                        sim.fire("VarTransmit", lua.table_from({"var": lua.table_from({"configName": parts[1]}),
                            "oldValue": int(parts[-3]), "newValue": int(parts[-1])}))
                    except ValueError:
                        pass
        sim.tick(1)
        for line in pred_log().values():
            print(f"[{tick:4}] PLUGIN  {line}")
        # PANEL_TICKS=300,340 prints the panel text at those ticks
        if str(tick) in os.environ.get("PANEL_TICKS", "").split(","):
            print(f"[{tick:4}] PANEL   " + str(sim.panel()).replace(chr(10), chr(10) + " " * 15))


if __name__ == "__main__":
    main()
