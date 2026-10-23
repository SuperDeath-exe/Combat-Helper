-- Debug recorder: logs everything the API reports during a fight so boss
-- signals (yells, vars, object spawns/animations, NPC changes) can be found.
-- Recordings rotate through 5 slots so a new one never overwrites the last.
-- Slot s is stored in PersistentDB as "rec<s>_1".."rec<s>_N", with the chunk
-- count in "rec<s>_chunks"; "rec_last" is the newest slot.
-- and echoed to the console for the less spammy categories.
--
-- Insert key = add a MARK line (press it when the boss does something).

print("REC step: start")
local Recorder = {}

local MAX_LINES = 80000 -- Zuk HM run is 20+ min (~2500 ticks, ~15 lines/tick in waves)
local SLOTS = 5
local AUTOSAVE_TICKS = 100

-- Vars that change constantly and say nothing about the boss
local NOISY_VARS = {
    "COOLDOWN_TRIGGER", "TELEMETRY", "JUST_USED_ABILITY", "IF_HIGHLIGHT", "NEXT_ABILITY",
    "ABILITY_AVAILABILITY", "MAINHAND_DELAY", "OFFHAND_DELAY", "INVENT_PERK",
    "INVENT_CHARGE", "MTXRECOL", "DROPLOG",
    -- HITCHANCE, TEMP_VARP3, TARGET_EFFECTS_TRIGGER, QUEUE_TRIGGER_TIME unfiltered
    -- 2026-10-22: looking for a var that marks every Telos auto (TRH22 misses ~1 in 6)
    -- Player-side spam that filled the 5000-line cap before phase 5 (100% fight)
    "PRAYER_POINTS_VAR", "TARGET_SIDE_PANEL_HEALTH", "REAPER_NECKLACE", "PRAYER_BASE", "GOD_BOOK_VAR",
    "BUFF_NECROMANCY", "MTXMGT_PVP", "NECROMANCY_CONJURE", "ABILITY_BOOK_UPDATE",
    "SA_ENERGY", "COMBATV2_COOLDOWN_", "COMBATV2_GLOBAL_COOLDOWN",
}
local CHUNK_LINES = 100
local MAX_UI_LINES = 800
local MAX_INTERFACE_ID = 2500
local MAX_STATIC_ID = 600
local STATIC_MISS_LIMIT = 40

local recording = false
-- Rec button: OFF <-> AUTO (saved). AUTO records each fight by itself:
-- starts on entering a boss instance (the "Welcome to your session against:"
-- line of a supported boss, or BOSS_INSTANCE_CURRENT_BOSS 0 -> id, which also
-- fires on Rejoin), saves AUTO_STOP_TICKS after the fight ends, or at once
-- on leaving the instance. A recording where the plugin never tracked a
-- supported boss is dropped, not saved.
local MODE_LABELS = { [0] = "Rec: OFF", [2] = "Rec: AUTO" }
local AUTO_STOP_TICKS = 20
local AUTO_IDLE_TICKS = 1000 -- in an instance this long without a fight: drop
local MIN_SAVE_TICKS = 20 -- shorter recordings are dropped
local WELCOME_CHAT = "Welcome to your session against: "
local INSTANCE_VAR = "BOSS_INSTANCE_CURRENT_BOSS"
local mode = 0
local autoStopTick = nil
local autoFight = false -- AUTO recording: the plugin tracked a supported boss
local bossNames = {} -- npc names of supported bosses (Recorder.Init option)
local setRecording -- defined in Controls; onTick (above it) needs it
local autoStart, autoDrop -- defined in Controls too
local snapshotVars = {} -- logged when a recording starts (Recorder.Init option)
local slot = 1
local lines = {}
local tick = 0
local startTick = 0
local getBoss = function() return nil end
local lastBoss = nil
local buttons = {}

local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function field(obj, key)
    if obj == nil then return nil end
    return safe(function() return obj[key] end)
end

-- Privacy: logs get shared, so the player's own name is replaced with <you>
local function plainReplace(text, find, repl)
    local out, from = {}, 1
    while true do
        local i, j = string.find(text, find, from, true)
        if i == nil then break end
        out[#out + 1] = string.sub(text, from, i - 1) .. repl
        from = j + 1
    end
    out[#out + 1] = string.sub(text, from)
    return table.concat(out)
end

local myName = nil
local function anonymize(text)
    if myName == nil then
        local ok, me = pcall(function() return Player.GetEntity() end)
        local name = ok and me and field(me, "displayName") or nil
        if type(name) == "string" and #name > 0 then myName = name end
    end
    if myName ~= nil then text = plainReplace(text, myName, "<you>") end
    return text
end

-- Chat lines that only carry other players' names or messages: never logged
local PRIVATE_CHAT = { "^News:", "has logged in%.$", "has logged out%.$", "^%[", "^From ", "^To " }
local function isPrivateChat(text)
    for _, pattern in ipairs(PRIVATE_CHAT) do
        if string.find(text, pattern) then return true end
    end
    return false
end

local function add(category, text, echo, force)
    if not recording and not force then return end
    if #lines >= MAX_LINES then return end
    text = anonymize(text)
    local line = string.format("[%5d] %-6s %s", tick - startTick, category, text)
    table.insert(lines, line)
    if echo then print("REC " .. line) end
end

local okChat, ChatReader = pcall(require, "chatreader")
local pollChat = okChat and ChatReader.Watcher() or function() return {} end

-- Chunks below this are full and already written: autosave only rewrites the
-- tail, so long recordings (Zuk, 80k lines) don't rewrite every chunk each minute
local savedFullChunks = 0

local function save()
    local chunks = math.ceil(#lines / CHUNK_LINES)
    for i = savedFullChunks + 1, chunks do
        local first = (i - 1) * CHUNK_LINES + 1
        local last = math.min(i * CHUNK_LINES, #lines)
        PersistentDB:Set("rec" .. slot .. "_" .. i, table.concat(lines, "\n", first, last))
    end
    PersistentDB:Set("rec" .. slot .. "_chunks", chunks)
    PersistentDB:Set("rec_last", slot)
    savedFullChunks = #lines // CHUNK_LINES
    print(formatStr("Recorder: saved {} lines to slot {} ({} chunk(s))", #lines, slot, chunks))
end

------------------------------------------------------------------------
-- Interface scan: dump visible text from every loaded interface
------------------------------------------------------------------------

-- Privacy: a scan holds everything on screen (friends list, bank, chat), so it
-- goes to its own uiscan_* keys, not into the fight recording.
-- dump_recording.py only exports it with --ui.
local scanLines = {}
local function recordText(comp, label, count)
    local content = field(comp, "content")
    if type(content) == "string" and content ~= "" and field(comp, "visibleGlobal") ~= false then
        table.insert(scanLines, "UI     " .. label .. " '" .. content .. "'")
        return count + 1
    end
    return count
end

local function saveScan()
    local chunks = math.ceil(#scanLines / CHUNK_LINES)
    for i = 1, chunks do
        local first = (i - 1) * CHUNK_LINES + 1
        PersistentDB:Set("uiscan_" .. i, table.concat(scanLines, "\n", first, math.min(i * CHUNK_LINES, #scanLines)))
    end
    PersistentDB:Set("uiscan_chunks", chunks)
end

local function scanInterfaces()
    scanLines = {}
    local count = 0
    local interfaces = 0
    for iid = 0, MAX_INTERFACE_ID do
        if count >= MAX_UI_LINES then break end
        if safe(function() return ui.Interfaces:GetInterface(iid) end) ~= nil then
            interfaces = interfaces + 1
            local misses = 0
            for sid = 0, MAX_STATIC_ID do
                local comp = safe(function() return ui.Interfaces:GetComponent(iid, sid) end)
                if comp == nil then
                    misses = misses + 1
                    if misses > STATIC_MISS_LIMIT then break end
                else
                    misses = 0
                    count = recordText(comp, formatStr("{}:{}", iid, sid), count)
                    if field(comp, "IterateDynamicComponents") ~= nil then
                        safe(function()
                            comp:IterateDynamicComponents(function(child)
                                count = recordText(child, formatStr("{}:{}:dyn{}", iid, sid, field(child, "dynamicID")), count)
                                return count >= MAX_UI_LINES
                            end)
                        end)
                    end
                end
            end
        end
    end
    print(formatStr("Recorder: UI scan found {} text component(s) in {} interface(s)", count, interfaces))
    saveScan()
end

------------------------------------------------------------------------
-- Event logging
------------------------------------------------------------------------

local function npcText(npc)
    return formatStr("'{}' config={} uid={} at {}", field(npc, "displayName"), field(npc, "configID"),
        field(npc, "uid"), tostring(field(npc, "coordGrid")))
end

-- Chebyshev distance (tiles) from a tile to the nearest tile of an NPC of
-- gridSize x gridSize whose coordGrid is its south-west tile
local function tileDistance(c, npcCoord, size)
    local function axis(p, lo)
        local hi = lo + size - 1
        if p < lo then return lo - p elseif p > hi then return p - hi end
        return 0
    end
    return math.max(axis(c.x, npcCoord.x), axis(c.z, npcCoord.z))
end

local lastPos = nil
local lastShape = nil

-- NPC scan: NPCEntityAdded gives nil names, so diff NPCList.All() every tick
-- and log spawns/despawns with name, config and position (minions, eggs, ...)
local knownNpcs = nil
local function scanNpcs()
    local list = safe(function() return NPCList.All() end)
    if list == nil then return end
    local seen = {}
    for _, npc in ipairs(list) do
        local uid = field(npc, "uid")
        if uid ~= nil then
            seen[uid] = formatStr("'{}' config={}", field(npc, "displayName"), field(npc, "configID"))
            if knownNpcs ~= nil and knownNpcs[uid] == nil then
                local c = field(npc, "coordGrid")
                add("NPCS+", formatStr("{} uid={} at {},{}", seen[uid], uid, c and field(c, "x"), c and field(c, "z")))
            elseif knownNpcs ~= nil and knownNpcs[uid] ~= seen[uid] then
                -- Same NPC, new form (e.g. Har-Aken submerging)
                add("NPCS~", formatStr("{} -> {} uid={}", knownNpcs[uid], seen[uid], uid))
            end
        end
    end
    if knownNpcs ~= nil then
        for uid, text in pairs(knownNpcs) do
            if seen[uid] == nil then add("NPCS-", formatStr("{} uid={}", text, uid)) end
        end
    end
    knownNpcs = seen
end

local function onTick()
    if autoStopTick ~= nil and recording and tick >= autoStopTick then
        setRecording(false)
    end
    tick = tick + 1
    -- Poll every tick (even when not recording) so the chat snapshot stays current
    local chatLines = pollChat()
    for _, line in ipairs(chatLines) do
        local text = line:gsub("<[^>]->", "")
        local i = string.find(text, WELCOME_CHAT, 1, true)
        if mode == 2 and i ~= nil then
            local against = string.sub(text, i + #WELCOME_CHAT)
            for _, name in ipairs(bossNames) do
                if string.find(against, name, 1, true) == 1 then
                    autoStart("welcome " .. name)
                    break
                end
            end
        end
        if recording and not isPrivateChat(text) then add("CHAT", text, true) end
    end
    if not recording then return end
    if mode == 2 and not autoFight and tick - startTick >= AUTO_IDLE_TICKS then
        autoDrop("no supported boss fight")
        return
    end
    -- AUTO: only autosave once it is a real fight, so a dropped recording never
    -- overwrites an old slot
    if (tick - startTick) % AUTOSAVE_TICKS == 0 and (mode ~= 2 or autoFight) then
        save()
    end
    scanNpcs()
    local boss = getBoss()
    if boss == nil or not field(boss, "isValid") then
        lastBoss = nil
        return
    end
    local state = {
        configID = field(boss, "configID"),
        name = field(boss, "displayName"),
        coord = tostring(field(boss, "coordGrid")),
        facingTarget = field(boss, "facingTarget"),
    }
    if lastBoss == nil then
        add("BOSS", "tracking " .. npcText(boss), true)
        safe(function()
            local cfg = field(boss, "config")
            add("BOSS", formatStr("config gridSize={} maxRange={} wanderRange={} attackOpIndex={}",
                field(cfg, "gridSize"), field(cfg, "maxRange"), field(cfg, "wanderRange"),
                field(cfg, "attackOpIndex")), true)
        end)
    else
        if state.configID ~= lastBoss.configID or state.name ~= lastBoss.name then
            add("BOSS", formatStr("transform '{}' config {} -> '{}' config {}", lastBoss.name, lastBoss.configID,
                state.name, state.configID), true)
        end
        if state.coord ~= lastBoss.coord then
            add("BOSS", "moved to " .. state.coord)
        end
        if state.facingTarget ~= lastBoss.facingTarget then
            add("BOSS", formatStr("facing {} -> {}", lastBoss.facingTarget, state.facingTarget))
        end
    end
    lastBoss = state
    -- Boss model bounding box: changes with animations (testing whether Araxxor's
    -- Cleave swipe / web shield show up). Logged when a dimension moves > 3%
    safe(function()
        local box = field(boss, "aabb")
        if box == nil then return end
        local w, h, l = field(box, "width"), field(box, "height"), field(box, "length")
        if w == nil then return end
        local function moved(a, b) return b == nil or math.abs(a - b) > math.max(8, math.abs(b) * 0.03) end
        if lastShape == nil or moved(w, lastShape[1]) or moved(h, lastShape[2]) or moved(l, lastShape[3]) then
            add("SHAPE", formatStr("w={} h={} l={}", math.floor(w), math.floor(h), math.floor(l)))
            lastShape = { w, h, l }
        end
    end)
    -- Player vs boss position: distance shows kiting / out-of-range delays
    safe(function()
        local me = Player.GetEntity()
        if me == nil or not field(me, "isValid") then return end
        local mc, bc = field(me, "coordGrid"), field(boss, "coordGrid")
        if mc == nil or bc == nil then return end
        local cfg = field(boss, "config")
        local size = (cfg and field(cfg, "gridSize")) or 1
        local pos = formatStr("you {},{} boss {},{} dist {}", mc.x, mc.z, bc.x, bc.z, tileDistance(mc, bc, size))
        if pos ~= lastPos then
            add("POS", pos)
            lastPos = pos
        end
    end)
end

local function onChat(e)
    local msg = e.chatMessage or ""
    if isPrivateChat(msg) then return end
    -- Sender names are other players (or the boss): logged only as present/absent
    local sender = (e.senderNameSimple or "") ~= "" and "<someone>" or ""
    add("CHAT", formatStr("type={} sender='{}' msg='{}'", e.chatType, sender, msg), true)
end

-- Ability used: JUST_USED_ABILITY vars hold (probably) the ability's struct id.
-- Resolve it to the struct name + any string params (the ability name)
local abilityNames = {}
local function abilityText(value)
    if type(value) ~= "number" or value <= 0 then return tostring(value) end
    if abilityNames[value] == nil then
        local text = tostring(value)
        safe(function()
            local st = config.Struct.FromID(value)
            if st == nil then return end
            local parts = { field(st, "configName") or "?" }
            for _, param in ipairs(field(st, "params") or {}) do
                local ok, pv = pcall(function() return st:GetParamValue(param) end)
                if ok and type(pv) == "string" and pv ~= "" and #parts < 4 then
                    table.insert(parts, formatStr("{}='{}'", field(param, "configName"), pv))
                end
            end
            text = formatStr("{} struct {}", value, table.concat(parts, " "))
        end)
        abilityNames[value] = text
    end
    return abilityNames[value]
end

local function onVar(e)
    local v = e.var
    local name = field(v, "configName") or ""
    if string.find(name, "JUST_USED_ABILITY", 1, true) then
        -- Logged even when unchanged: the same ability twice in a row
        add("ABIL", formatStr("{} = {}", name, abilityText(e.newValue)))
        return
    end
    -- AUTO: entering a boss instance (new or Rejoin) starts a recording,
    -- leaving it drops one without a fight or saves it at once
    local entered = name == INSTANCE_VAR and e.oldValue == 0 and type(e.newValue) == "number" and e.newValue ~= 0
    if mode == 2 and entered then autoStart("instance " .. e.newValue) end
    for _, pattern in ipairs(NOISY_VARS) do
        if string.find(name, pattern, 1, true) then return end
    end
    add("VAR", formatStr("{} {} {} -> {}", field(v, "typeName"), field(v, "configName"), tostring(e.oldValue),
        tostring(e.newValue)))
    if mode == 2 and recording and name == INSTANCE_VAR and e.newValue == 0 then
        if not autoFight then
            autoDrop("left the instance")
        else
            setRecording(false) -- nothing left to log once out of the instance
        end
    end
end

local function onNpcAdded(e) add("NPC+", npcText(e.npcEntity), true) end
local function onNpcRemoved(e) add("NPC-", npcText(e.npcEntity), true) end

local function onLocAdded(e)
    add("LOC+", formatStr("{} at {}", field(e.config, "configName"), tostring(e.coordGrid)))
end
local function onLocRemoved(e)
    add("LOC-", "at " .. tostring(e.coordGrid))
end
local function onLocAnimation(e)
    add("LOCANI", formatStr("{} at {} delay={}", e.animation and field(e.animation, "configName") or "stop",
        tostring(e.coordGrid), e.animationDelay))
end
local function onLocCustomised(e)
    add("LOCCUS", formatStr("{} at {}", field(e.config, "configName"), tostring(e.coordGrid)))
end

-- Privacy: xp gained only, exact totals can be matched to the hiscores
local function onSkill(e)
    local gained = (tonumber(e.newXP) or 0) - (tonumber(e.oldXP) or 0)
    add("SKILL", formatStr("{} +{} xp", SkillType.FromID(e.skill), gained))
end

local function stripText(text)
    if type(text) ~= "string" then return tostring(text) end
    return (text:gsub("<[^>]->", ""))
end

-- Privacy: right-click options on other players carry their names
local PLAYER_VERBS = {
    ["Follow"] = true, ["Trade with"] = true, ["Challenge"] = true, ["Report"] = true,
    ["Req Assist"] = true, ["Invite"] = true, ["Add friend"] = true, ["Add ignore"] = true,
    ["Message"] = true, ["Kick"] = true, ["Group"] = true, ["Inspect"] = true, ["Lookup"] = true,
}
local function onMenu(e)
    local verb = stripText(e.entry.verbText)
    if PLAYER_VERBS[verb] then return end
    add("CLICK", formatStr("{} {}", verb, stripText(e.entry.subjectText)), true)
end

-- Privacy: other keys are never logged (typed chat, bank PIN). Abilities are
-- logged by name from the JUST_USED_ABILITY vars instead.
local function onKey(e)
    if not recording or e.isRepeat then return end
    if e.gameKey == GameKey.INSERT then
        add("MARK", "----- marked by player -----", true)
    end
end

local function subscribeChat()
    if Plugin.HasPermission(PluginPermissions.chatAccess) then
        Event.ChatMessage.Subscribe("recorderChat", onChat)
    end
end

------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------

local function updateLabel()
    local label = MODE_LABELS[mode]
    if mode == 2 and recording then label = "Rec: AUTO*" end
    buttons.rec.label = label
end

setRecording = function(value)
    recording = value
    autoStopTick = nil
    autoFight = false
    updateLabel()
    if recording then
        -- The slot is only overwritten when the recording is saved
        slot = (math.floor(PersistentDB:Get("rec_last") or 0) % SLOTS) + 1
        print("Recorder: recording to slot " .. slot)
        lines = {}
        savedFullChunks = 0
        startTick = tick
        lastBoss = nil
        subscribeChat()
        add("START", "recording started", true)
        -- Values set before the recording started (e.g. boss max HP at instance
        -- start) as VAR lines, so the replay sees them
        for _, name in ipairs(snapshotVars) do
            local value = nil
            pcall(function()
                local v = var.VarPlayer[name] or var.VarClient[name]
                value = v and v.value
            end)
            if type(value) == "number" then
                add("VAR", formatStr("VarPlayer {} -1 -> {}", name, value))
            end
        end
    elseif tick - startTick < MIN_SAVE_TICKS then
        -- e.g. clicking through ON to get to AUTO: don't use up a slot
        print("Recorder: recording too short, not saved")
        lines, savedFullChunks = {}, 0
    else
        add("STOP", "recording stopped", true, true)
        save()
    end
end

autoStart = function(reason)
    if recording and autoStopTick ~= nil then
        setRecording(false) -- previous fight's recording was still finishing
    end
    if recording then return end
    setRecording(true)
    add("AUTO", "started: " .. reason, true)
    scanInterfaces()
end

-- Throw away an AUTO recording (nothing was autosaved for it yet)
autoDrop = function(reason)
    recording, autoStopTick, autoFight = false, nil, false
    lines, savedFullChunks = {}, 0
    updateLabel()
    print("Recorder: AUTO recording dropped (" .. reason .. ")")
end

-- options: parent component, x/y offset and parent percentages for the button row,
--          getBoss() -> NPCEntity of the tracked boss (or nil),
--          bossNames = npc names of the supported bosses (AUTO welcome line)
function Recorder.Init(options)
    print("REC step: init")
    getBoss = options.getBoss or getBoss
    snapshotVars = options.snapshotVars or snapshotVars
    bossNames = options.bossNames or bossNames

    local function makeButton(label, width, x, onPress)
        local button = ui.Button.new(options.parent)
        button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        button:SetSize(width, options.height)
        button:SetPos(options.x + x, options.y, options.xPc, options.yPc)
        button.label = label
        button:Subscribe(ui.Hook.ONBUTTONPRESSED, onPress)
        return button
    end

    mode = math.floor(tonumber(PersistentDB:Get("rec_mode")) or 0)
    if MODE_LABELS[mode] == nil then mode = 0 end -- old saved ON (1) -> OFF
    buttons.rec = makeButton(MODE_LABELS[mode], 90, 0, function()
        local wasFight = autoFight
        mode = mode == 2 and 0 or 2
        PersistentDB:Set("rec_mode", mode)
        if mode == 0 and recording then
            -- Turned OFF mid-recording: keep it only if it has a fight in it
            if wasFight then setRecording(false) else autoDrop("turned off") end
        end
        updateLabel()
        print("Recorder: " .. MODE_LABELS[mode])
    end)

    Event.ServerLogic.Subscribe("recorderTick", onTick)
    Event.VarTransmit.Subscribe("recorderVar", onVar)
    Event.NPCEntityAdded.Subscribe("recorderNpcAdded", onNpcAdded)
    Event.NPCEntityRemoved.Subscribe("recorderNpcRemoved", onNpcRemoved)
    Event.LocAdded.Subscribe("recorderLocAdded", onLocAdded)
    Event.LocRemoved.Subscribe("recorderLocRemoved", onLocRemoved)
    Event.LocAnimation.Subscribe("recorderLocAnimation", onLocAnimation)
    Event.LocCustomised.Subscribe("recorderLocCustomised", onLocCustomised)
    Event.SkillTransmit.Subscribe("recorderSkill", onSkill)
    Event.MiniMenuEntrySelected.Subscribe("recorderMenu", onMenu)
    Event.KeyDown.Subscribe("recorderKeys", onKey)
    print("REC step: init done")
end

-- AUTO mode: the plugin started / stopped tracking a boss
function Recorder.FightStarted()
    if mode ~= 2 then return end
    -- Usually already recording since the instance was entered
    autoStart("boss tracked")
    autoFight = true
end

function Recorder.FightEnded()
    if mode == 2 and recording then autoStopTick = tick + AUTO_STOP_TICKS end
end

-- Lets the plugin add its own lines (e.g. predictions) to the recording
function Recorder.Log(category, text, echo)
    add(category, text, echo)
end

function Recorder.SetVisible(visible)
    for _, button in pairs(buttons) do
        button.hidden = not visible
    end
end

function Recorder.Shutdown()
    if recording then
        add("STOP", "plugin shutdown", false, true)
        save()
    end
    for _, button in pairs(buttons) do
        pcall(function() button:Destroy() end)
    end
end

return Recorder
