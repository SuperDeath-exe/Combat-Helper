"""Offline smoke test: runs combat-helper's main.lua against a fake game API.

Simulates a Telos fight (boss in view, HP dropping through the phase
thresholds, yells appearing in the chatbox interface, tendrils object
spawning) and prints the panel text at a few points. Catches Lua runtime
errors before testing in the client.

Usage: python simulate.py   (needs: pip install lupa)
"""
import os
import sys

from lupa import lua54

# The plugin folder is this script's parent folder
PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STUBS = r'''
local plugin_dir = ...
local events = {}
local db = {}
local printed = {}

-- Generic component: accepts any property / method
local Component = {}
Component.__index = function(t, k)
    local raw = rawget(t, "_props")[k]
    if raw ~= nil then return raw end
    if k == "x" or k == "y" or k == "width" or k == "height" then return 0 end
    if k == "isMouseOver" then return false end
    return function(self, ...)
        if k == "SetPos" then local a = {...}; rawget(self, "_props").x = a[1]; rawget(self, "_props").y = a[2] end
        if k == "SetSize" then local a = {...}; rawget(self, "_props").width = a[1]; rawget(self, "_props").height = a[2] end
        if k == "Subscribe" then local a = {...}; rawget(self, "_hooks")[a[1]] = a[#a] end
        if k == "IterateDynamicComponents" then
            local cb = ...
            for _, child in ipairs(rawget(self, "_children")) do
                if cb(child) then break end
            end
        end
        return nil
    end
end
Component.__newindex = function(t, k, v) rawget(t, "_props")[k] = v end
local function newComponent(props)
    return setmetatable({ _props = props or {}, _hooks = {}, _children = {} }, Component)
end

local gameWindow = newComponent({ width = 1920, height = 1080 })
local chatbox = newComponent()
local components = {}

local function ctor() return { new = function() local c = newComponent(); table.insert(components, c); return c end } end
ui = {
    Interfaces = {
        GetComponent = function(self, a, b)
            if a == 137 and b == 86 then return chatbox end
            return gameWindow
        end,
        GetInterface = function() return nil end,
    },
    GroupBox = ctor(), Text = ctor(), Button = ctor(), Rectangle = ctor(),
    Hook = setmetatable({}, { __index = function(_, k) return k end }),
    AlignMode = setmetatable({}, { __index = function(_, k) return k end }),
    GroupBoxHeaderAlignMode = setmetatable({}, { __index = function(_, k) return k end }),
}
id = {
    Component = setmetatable({}, { __index = function() return 1 end }),
    StyleSheet = setmetatable({}, { __index = function() return 1 end }),
    Font = setmetatable({ MUSEO_SANS_15PT_REGULAR = 30 }, { __index = function() return -1 end }),
}
Vector4 = { new = function(...) return { ... } end }

Event = setmetatable({}, { __index = function(t, name)
    local e = {
        -- Real client: subscribers run in subscription order; same ref replaces in place
        Subscribe = function(ref, fn)
            events[name] = events[name] or {}
            for _, entry in ipairs(events[name]) do
                if entry.ref == ref then entry.fn = fn return end
            end
            table.insert(events[name], { ref = ref, fn = fn })
        end,
        Unsubscribe = function(ref)
            for i, entry in ipairs(events[name] or {}) do
                if entry.ref == ref then table.remove(events[name], i) return end
            end
        end,
    }
    rawset(t, name, e)
    return e
end })

PersistentDB = {}
function PersistentDB:Get(k) return db[k] end
function PersistentDB:Set(k, v) db[k] = v end

Plugin = { HasPermission = function() return false end }
PluginPermissions = { chatAccess = "chatAccess" }

local telos = nil
NPCList = {
    ByName = function(name)
        if telos and string.lower(name) == string.lower(telos.displayName) then return { telos } end
        return {}
    end,
    ByUID = function(uid) if telos and telos.uid == uid then return { telos } end return {} end,
    All = function()
        local out = {}
        if telos then out[1] = telos end
        for _, npc in pairs(SIM_NPCS) do out[#out + 1] = npc end
        return out
    end,
}
SIM_NPCS = {}
Mouse = { GetPosition = function() return { x = 100, y = 100 } end }
GameKey = setmetatable({}, { __index = function(_, k) return k end })
SkillType = { FromID = function(i) return "skill" .. tostring(i) end }

SIM_VARS = {}
SIM_PRED = {}
local vars = SIM_VARS
var = {
    VarPlayer = setmetatable({}, { __index = function(_, k) if vars[k] ~= nil then return { value = vars[k] } end end }),
    VarClient = setmetatable({}, { __index = function() return nil end }),
}

formatStr = function(fmt, ...)
    local args = { ... }
    local i = 0
    return (fmt:gsub("{}", function() i = i + 1; return tostring(args[i]) end))
end
log = print

-- require relative to the plugin folder
package.path = plugin_dir .. "/?.lua;" .. package.path

local sim = {}
function sim.fire(name, payload)
    for _, entry in ipairs(events[name] or {}) do entry.fn(payload) end
end
function sim.tick(n) for _ = 1, (n or 1) do sim.fire("ServerLogic") end end
function sim.spawnTelos(name) telos = { displayName = name or "Telos, the Warden", uid = 65537, isValid = true, config = { gridSize = 5 } } end
function sim.despawnTelos() telos = nil end
function sim.setBossConfig(id) if telos then telos.configID = id end end
function sim.setBossPos(x, z) if telos then telos.coordGrid = { x = x, z = z } end end
local me = { isValid = true }
Player = { GetEntity = function() return me end }
function sim.setPlayerPos(x, z) me.coordGrid = { x = x, z = z } end
function sim.addNpc(uid, name) SIM_NPCS[uid] = { uid = uid, displayName = name, isValid = true } end
function sim.removeNpc(uid) SIM_NPCS[uid] = nil end
function sim.setHp(hp, max) vars.ACTIVITY_PROGRESS_BAR_ACTIVE_INFO = hp; vars.ACTIVITY_PROGRESS_BAR_ACTIVE_INFO_2 = max end
local chatLines = {}
function sim.chat(text)
    -- newest first, like the real chatbox
    table.insert(chatLines, 1, text)
    local children = rawget(chatbox, "_children")
    for i = #children + 1, #chatLines do children[i] = newComponent() end
    for i, line in ipairs(chatLines) do
        rawget(children[i], "_props").content = line
        rawget(children[i], "_props").dynamicID = i - 1
    end
end
function sim.panel()
    -- the body text is the Text component whose content mentions the boss or "Waiting"
    for _, c in ipairs(components) do
        local content = rawget(c, "_props").content
        if type(content) == "string" and (content:find("Telos") or content:find("Araxx") or content:find("Waiting") or content:find("Zuk")) then
            return (content:gsub("<br>", "\n    "):gsub("<[^>]->", ""))
        end
    end
    return "(no panel text)"
end
function sim.shutdown() if PluginShutdown then PluginShutdown() end end
function sim.press(label)
    for _, c in ipairs(components) do
        if rawget(c, "_props").label == label then
            local hook = rawget(c, "_hooks").ONBUTTONPRESSED
            if hook then hook() return true end
        end
    end
    error("no button labelled " .. label)
end
function sim.recording()
    local slot = math.floor(db.rec_last or 1)
    local chunks = db["rec" .. slot .. "_chunks"] or 0
    local out = {}
    for i = 1, chunks do out[#out + 1] = db["rec" .. slot .. "_" .. i] end
    return table.concat(out, string.char(10))
end
return sim
'''


def main():
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    sim = lua.execute(STUBS, PLUGIN_DIR.replace("\\", "/"))
    main_src = open(os.path.join(PLUGIN_DIR, "main.lua"), encoding="utf-8").read()
    run = lua.eval("function(src) local f = assert(load(src, '@main.lua')); return f() end")

    def step(label, fn=None):
        if fn:
            fn()
        print(f"--- {label}\n    {sim.panel()}")

    run(main_src)
    for i in range(5):
        sim.chat(f"old line {i}")
    sim.tick(1)
    step("loaded, no boss")

    sim.press("Rec: OFF")
    sim.spawnTelos()
    sim.setHp(400000, 400000)
    sim.chat("<br>Welcome to your session against: Telos, the Warden.")
    sim.tick(6)
    step("boss in view (scan) + session message")

    sim.tick(20)
    step("20 ticks later (timing estimate)")

    sim.chat("<col=84D477>Telos</col>: Your anima will return to the source!")
    sim.tick(1)
    step("tendrils yell in chatbox")

    sim.fire("LocAdded", lua.table_from({"config": lua.table_from({"configName": "GWD2_SOLO_TENDRILS_SPAWN"})}))
    sim.tick(1)
    step("tendrils object (should not double-advance)")

    sim.chat("<col=84D477>Telos</col>: Gielinor, give me strength!")
    sim.tick(1)
    step("uppercut yell")

    sim.setHp(299000, 400000)
    sim.tick(1)
    step("HP below 75% -> phase 2")

    sim.setHp(150000, 400000)
    sim.tick(1)
    step("HP below 50% -> phase 3")

    sim.setHp(90000, 400000)
    sim.tick(1)
    step("HP below 25% -> phase 4")

    sim.chat("<col=EB2F2F>Telos is preparing to fire an anima bomb!")
    sim.tick(1)
    step("anima bomb message -> alert")

    sim.chat("Oh dear, you are dead!")
    sim.tick(1)
    step("player died -> fight ends")

    sim.chat("<br>Welcome to your session against: Telos, the Warden.")
    sim.tick(6)
    step("new session, boss found again")

    sim.despawnTelos()
    sim.tick(20)
    step("Telos gone for 20 ticks -> fight ends")

    print("--- recording (non-VAR lines):")
    for line in str(sim.recording()).splitlines():
        if " VAR " not in line:
            print("    " + line)
    # Still AUTO: next fight records by itself
    sim.tick(45)  # past the dead-boss guard (same uid in the sim)
    sim.spawnTelos()
    sim.chat("<br>Welcome to your session against: Telos, the Warden.")
    sim.tick(6)
    step("AUTO: new fight -> recording starts")
    sim.despawnTelos()
    sim.tick(45)
    step("AUTO: fight over -> saved 20 ticks later")
    sim.shutdown()
    print("--- shutdown OK")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # Lua errors surface here with file:line
        print("SIMULATION FAILED:", error)
        sys.exit(1)
