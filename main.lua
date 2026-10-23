-- Combat Helper
-- Shows the boss's current attack and what comes next, from wiki-documented
-- patterns stored in bosses/*.lua. The client API can't see NPC animations,
-- so the plugin syncs from: the boss spawning (fight start), attack timing
-- (auto-attack speed x autos between specials), boss yells and game messages
-- in chat, adds/objects spawning, and manual input.
--
-- Hotkeys: Page Down = next special, Page Up = undo, End = next phase, Home = restart.

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

print("CH step: start")

local function lookup(tbl, key)
    local ok, value = pcall(function() return tbl[key] end)
    if ok then return value end
    return nil
end

local function col(hex, text)
    return "<col=" .. hex .. ">" .. text .. "</col>"
end

local function stripTags(text)
    return (text:gsub("<[^>]->", ""))
end

local function contains(haystack, needle)
    return string.find(string.lower(haystack), string.lower(needle), 1, true) ~= nil
end

-- pattern may be a string or a list of strings
local function matches(value, pattern)
    if type(value) == "number" then -- e.g. bossConfig ids: exact match
        if type(pattern) == "table" then
            for _, p in ipairs(pattern) do
                if p == value then return true end
            end
            return false
        end
        return value == pattern
    end
    if type(pattern) == "table" then
        for _, p in ipairs(pattern) do
            if contains(value, p) then return true end
        end
        return false
    end
    return contains(value, pattern)
end

local function listHas(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function shallowCopy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do copy[k] = v end
    return copy
end

local function withCommas(n)
    local text = tostring(math.floor(n))
    local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (formatted:gsub("^,", ""):gsub("^%-,", "-"))
end

local function formatTime(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local COL_HEADER = "ffb000"
local COL_NOW = "ff6040"
local COL_NEXT = "40c0ff"
local COL_SOON = "ffff40"
local COL_DIM = "a0a0a0"
local COL_GOOD = "40ff40"
local COL_THEN = "e0e0e0"
local INDENT = "      "
local DIVIDER = "------------------------------"

local SECONDS_PER_TICK = 0.6
-- NOW shows a phase start / special this long (or the special's own
-- nowTicks / duration if longer), then goes blank until the next one
local NOW_TICKS = 6
local eofSpec = nil -- set by the EoF button (UI section)
local END_GRACE_TICKS = 15      -- boss may despawn briefly (teleports, phase changes)
local ALERT_TICKS = 8           -- how long an alert / fired timer stays highlighted
local TELEPORT_TILES = 50      -- player moved further than this in one tick = teleported out (Zuk arena is ~32 wide)
local TELEPORT_AWAY_TILES = 100 -- ...and landed this far from the boss's last position
local RESYNC_IGNORE_TICKS = 6   -- repeated sync for the same special within this window is ignored
local MAX_HISTORY = 50

------------------------------------------------------------------------
print("CH step: Boss data")
-- Boss data
------------------------------------------------------------------------

local function loadModule(path)
    local ok, result = pcall(require, path)
    if ok then return result end
    local okDot, resultDot = pcall(require, (path:gsub("/", ".")))
    if okDot then return resultDot end
    print("Combat Helper: failed to load " .. path .. ": " .. tostring(result))
    return nil
end

local bosses = {}
local bossByNpcName = {}
for _, fileName in ipairs(loadModule("bosses/index") or {}) do
    local boss = loadModule("bosses/" .. fileName)
    if boss ~= nil then
        boss.triggers = boss.triggers or {}
        boss.timers = boss.timers or {}
        for _, phase in ipairs(boss.phases or {}) do
            if phase.random then
                table.insert(phase.specials, { attack = "Special", random = true, autos = phase.firstAutos or 3 })
                phase.randomIdx = #phase.specials
            end
        end
        table.insert(bosses, boss)
        for _, npcName in ipairs(boss.npcNames or { boss.name }) do
            bossByNpcName[string.lower(npcName)] = boss
        end
    end
end
print(formatStr("Combat Helper: loaded {} boss file(s)", #bosses))

-- Read a VarPlayer / VarClient value by name, nil if unknown or not a number
local function readVarValue(name)
    for _, domain in ipairs({ "VarPlayer", "VarClient" }) do
        local domainTable = lookup(var, domain)
        local v = domainTable and lookup(domainTable, name)
        local value = v and lookup(v, "value")
        if type(value) == "number" then return value end
    end
    return nil
end

------------------------------------------------------------------------
print("CH step: Fight state")
-- Fight state
------------------------------------------------------------------------

local ticks = 0
local fight = nil
local debugLog = function() end -- set to the recorder's Log once it's loaded
local fightHook = function(started) end -- recorder AUTO mode
local fireHpEvent -- defined before onServerTick
local markFirstAuto -- defined before onServerTick
local enabled = (PersistentDB:Get("enabled") or 1) == 1

local function currentPhase()
    if fight == nil or fight.boss.phases == nil then return nil end
    return fight.boss.phases[fight.phaseIndex]
end

local function saveHistory()
    table.insert(fight.history, {
        phaseIndex = fight.phaseIndex,
        nextIdx = fight.nextIdx,
        nextAutos = fight.nextAutos,
        expectTick = fight.expectTick,
        now = fight.now,
        lastSpecial = fight.lastSpecial,
        seen = shallowCopy(fight.seen),
    })
    if #fight.history > MAX_HISTORY then
        table.remove(fight.history, 1)
    end
end

local function undo()
    if fight == nil or #fight.history == 0 then return end
    local state = table.remove(fight.history)
    for k, v in pairs(state) do fight[k] = v end
    -- Shift the expected time forward so undo doesn't instantly auto-advance again
    if fight.expectTick ~= nil and fight.expectTick <= ticks then
        fight.expectTick = ticks + fight.nextAutos * (fight.boss.autoTicks or 0)
    end
end

local applyOpener -- defined with enterPhase below

local function autosBefore(phase, idx)
    local special = phase.specials[idx]
    if not fight.seen[idx] and special.autosFirst ~= nil then
        return special.autosFirst
    end
    return special.autos or 0
end

-- Ticks a special takes before the boss's autos resume
local function specialTicks(special)
    -- enrageDuration: { at = N, duration = d } - from N% enrage up it takes d ticks
    local e = special and special.enrageDuration
    if e ~= nil and fight.enrage ~= nil and fight.enrage >= e.at then return e.duration end
    return (special and special.duration) or fight.boss.specialTicks or fight.boss.autoTicks or 0
end

-- Font push (HP event with hold): the autos he already did toward his next
-- special count, the rest come after the font's bomb (3 in total). Autos left
-- = time until that special was due / autoTicks (matched 9 pushes in 5 fights)
local function autosLeftAt(due, max)
    if due == nil then return max end
    local autoTicks = fight.boss.autoTicks or 4
    return math.max(0, math.min(max, -((ticks - due) // autoTicks)))
end

-- Autos left at a font push. Fitted on 7 pushes (ticks before the special was
-- due -> autos left: 0-1 -> 0, 4 -> 1, 6 -> 2, 9+ -> 3); due drifts a tick or two
local function pushAutosLeft(due)
    if due == nil then return 3 end
    return math.max(0, math.min(3, (due - ticks + 1) // 3))
end

-- Held follow-up of a font (e.g. SO. MUCH. POWER): live while it's due
local function followUpActive()
    local f = fight.followUp
    return f ~= nil and (f.carried or (f.due ~= nil and ticks < f.due + 10)
        or (f.due == nil and ticks - f.tick < 40))
end

local function followUpText()
    local f = fight.followUp
    if f.due == nil then return f.text end
    local left = f.carried and f.autos or math.min(f.autos or 3, math.max(0, autosLeftAt(f.due, 99) - 1))
    if left == 0 then
        return formatStr("{} is his next attack - defensive ready", f.special)
    end
    return formatStr("{} after {} auto{} - defensive ready", f.special, left, left == 1 and "" or "s")
end

-- Specials with minEnrage only happen at or above that enrage (unknown enrage: keep them)
local function specialAllowed(special)
    if special.path ~= nil and fight.closedPath == special.path then return false end
    return special.minEnrage == nil or fight.enrage == nil or fight.enrage >= special.minEnrage
end

-- idx itself if allowed, otherwise the next allowed special in the loop
local function allowedFrom(phase, idx)
    local count = #phase.specials
    local i = idx
    for _ = 1, count do
        if specialAllowed(phase.specials[i]) then return i end
        i = i + 1
        if i > count then i = phase.loopFrom or 1 end
    end
    return idx
end

local function nextIndex(phase, idx)
    local i = idx + 1
    if i > #phase.specials then i = phase.loopFrom or 1 end
    return allowedFrom(phase, i)
end

-- Next special is expected baseTicks + autos x autoTicks from now
local function setNext(idx, autosOverride, baseTicks)
    local phase = currentPhase()
    fight.nextIdx = idx
    fight.expectLate, fight.nextAutosLate = nil, nil
    fight.nextAutos = autosOverride or autosBefore(phase, idx)
    -- noEstimate: no timing for it, it only comes from its own signal
    if phase.specials[idx] and phase.specials[idx].noEstimate then
        fight.expectTick = nil
    elseif fight.boss.autoTicks ~= nil then
        fight.expectTick = ticks + (baseTicks or 0) + fight.nextAutos * fight.boss.autoTicks
    else
        fight.expectTick = nil
    end
end

local function expectText()
    return fight.expectTick and ("+" .. (fight.expectTick - ticks)) or "?"
end

local function doSpecial(idx, estimated)
    local phase = currentPhase()
    if phase == nil or phase.specials[idx] == nil then return end
    saveHistory()
    local special = phase.specials[idx]
    fight.watchFirstHit, fight.firstHitTick = nil, nil
    fight.walkTicks = 0
    -- Autos count from this special now - unless it's an unconfirmed estimate of
    -- a special that yells (no proof he did it, see specialsSinceEvent below)
    if not (estimated and special.chat ~= nil and fight.specialsSinceEvent ~= nil) then
        fight.lastBombTick = nil
    end
    -- notes: one note per use in this phase (e.g. Zuk's conduit fireballs C1-C4)
    fight.useCount = fight.useCount or {}
    local count = (fight.useCount[idx] or 0) + 1
    fight.useCount[idx] = count
    local note = special.notes and special.notes[math.min(count, #special.notes)] or special.note
    fight.now = { attack = special.attack, note = note, index = idx, tick = ticks, estimated = estimated }
    fight.paused = nil
    fight.lastSpecial = special.attack
    fight.lastSpecialTick = ticks
    if not estimated or special.chat == nil then
        fight.pendingPhaseSpecial = nil
        -- Openers of the next phase only trust specials that were actually seen.
        -- No yell (e.g. Magic Onslaught with an empty bar): the estimate is all
        -- there is (fight at 100%: P2 Onslaught est. -> P3 Red Virus opener was right)
        fight.lastConfirmedSpecial = special.attack
    end
    -- An estimate of a special that yells isn't proof he did it (2026-10-22 P4: est.
    -- Uppercut after font 1, no yell -> font 2 push said 3 autos left, SMP came first)
    if not estimated or special.chat == nil then
        fight.autosSinceSpecial = 0
        -- autoVar ticks of his autos after this special (its own hits excluded)
        fight.autoVarAutos, fight.autoCountFrom = {}, ticks + specialTicks(special)
    end
    if fight.specialsSinceEvent ~= nil and (not estimated or special.chat == nil) then
        fight.specialsSinceEvent = fight.specialsSinceEvent + 1
    end
    local firstTime = not fight.seen[idx]
    fight.seen[idx] = true
    local nextIdx = (firstTime and special.firstNext) and allowedFrom(phase, special.firstNext) or nextIndex(phase, idx)
    if phase.random then
        nextIdx = phase.randomIdx
        if not special.random then fight.lastRealSpecial = special.attack end
    end
    setNext(nextIdx, phase.random and (special.autosAfter or phase.defaultAutos or 5) or nil, specialTicks(special))
    -- Special seen right at a font push (same tick, processed after the HP
    -- event): none of his next 3 autos were done yet
    if fight.activeEvent ~= nil and fight.activeEvent.autosLeft ~= nil and ticks - fight.activeEvent.tick <= 2 then
        fight.activeEvent.autosLeft = pushAutosLeft(fight.expectTick)
    end
    -- e.g. Magic Onslaught: lasts as long as the boss's bar takes to drain
    fight.waitBar = special.untilBarEmpty and fight.bar ~= nil and fight.bar > 0
    fight.barDrained, fight.barEndTick = false, nil
    if fight.waitBar then
        fight.expectTick = nil
    end
    -- releaseAnim: he holds the player (Telos's Grip) and his autos wait until the
    -- release animation; the next special counts from there (see onLocAnimation)
    fight.hold = special.releaseAnim and fight.expectTick ~= nil and {
        anim = special.releaseAnim, ticks = special.releaseTicks, untilTick = ticks + special.maxHoldTicks,
        phase = fight.phaseIndex } or nil
    debugLog("PRED", formatStr("{} {} -> next {} after {} autos, expected tick {}", estimated and "estimated" or "synced",
        special.attack, phase.specials[fight.nextIdx].attack, fight.nextAutos, expectText()))
end

-- Phase transition over: the boss starts attacking again
local function resumePhase()
    local phase = currentPhase()
    fight.inTransition = false
    local base = fight.phaseIndex == 1 and (fight.boss.startTicks or specialTicks(nil)) or (phase.resumeTicks or 0)
    base = base + (fight.openerExtraTicks or 0)
    setNext(fight.nextIdx, fight.nextAutos, base)
    if fight.openerAutosLate ~= nil and fight.expectTick ~= nil and fight.boss.autoTicks ~= nil then
        fight.nextAutosLate = fight.openerAutosLate
        fight.expectLate = fight.expectTick + (fight.openerAutosLate - fight.nextAutos) * fight.boss.autoTicks
    end
    fight.openerAutosLate = nil
    -- firstHitSync: he walks a varying distance before his first auto, so the
    -- player's first HP drop is the real start of the opener's autos
    fight.firstHitTick, fight.watchFirstHit = nil, phase.firstHitSync
    fight.now = { attack = phase.name .. " start", note = phase.note, tick = ticks }
    -- Repeating phase mechanic (e.g. Telos's font bomb), counted from the phase start
    fight.cycleNext = phase.cycle and (ticks + phase.cycle.first) or nil
    -- One-off phase mechanics at a fixed time after the phase starts (e.g. Telos's P3 Red Virus)
    fight.phaseTimerStart, fight.phaseTimersFired = ticks, {}
    debugLog("PRED", formatStr("resume {} -> next {} after {} autos, expected tick {}", phase.name,
        phase.specials[fight.nextIdx].attack, fight.nextAutos, expectText()))
end

-- First special of a phase, from the last (seen) special of the previous one
applyOpener = function(phase)
    if phase.random then
        fight.openerExtraTicks = 0
        fight.nextIdx, fight.nextAutos = phase.randomIdx, phase.firstAutos or 3
        return phase.randomIdx
    end
    local last = fight.lastConfirmedSpecial or fight.lastSpecial
    -- openers.none: the previous phase ended before the boss did any special
    local opener = phase.openers and phase.openers[last or "none"]
    local idx, autos = 1, nil
    fight.openerExtraTicks = 0
    if type(opener) == "number" then
        idx = opener
    elseif type(opener) == "table" then
        idx, autos = opener.step, opener.autos
        -- extraTicks: something else happens first (e.g. Telos's P3 Red Virus)
        fight.openerExtraTicks = opener.extraTicks or 0
        -- recentExtraTicks: the old phase's last special landed within 3 ticks of
        -- the phase change - his opener comes that much later
        if opener.recentExtraTicks and fight.lastSpecialTick and math.abs(ticks - fight.lastSpecialTick) <= 3 then
            fight.openerExtraTicks = fight.openerExtraTicks + opener.recentExtraTicks
        end
        -- carryAutos: autos he hadn't done yet in the previous phase carry over
        -- (wiki: Telos P1 -> P2). Still due from the old phase's expected tick;
        -- a special seen during the transition (expectTick cleared) = all of them
        fight.openerAutosLate = nil
        if opener.carryAutos and autos ~= nil and fight.autosSinceSpecial ~= nil and fight.lastSpecialTick ~= nil
            and fight.autoVarTick ~= nil then
            -- Counted from the boss's autoVar (4 fights 2026-10-22: Grip -> 3 done ->
            -- Onslaught first; 2 done -> 1 auto first; Uppercut -> 0 done -> 3)
            autos = math.max(0, autos - fight.autosSinceSpecial)
        elseif opener.carryAutos and autos ~= nil and fight.expectTick ~= nil and fight.boss.autoTicks ~= nil then
            -- Autos still due before his old special, an auto on the phase-change
            -- tick counting as still due. Live (chat synced 1 tick before the
            -- recorder logs it) the higher count was right in all 3 cut-off cases
            -- (2026-10-21 slots 1/4/5: P2 Stun / Tendrils came that auto later)
            local late = -((ticks - fight.expectTick - 1) // fight.boss.autoTicks)
            autos = math.max(0, math.min(autos, late))
        end
    end
    idx = allowedFrom(phase, idx)
    fight.nextIdx = idx
    fight.nextAutos = autos or autosBefore(phase, idx)
    return idx
end

-- waitForTransition: the boss is in its transition animation; the countdown
-- starts when resumePhase() is called (phase var flips / HP moves / timeout)
local function enterPhase(n, waitForTransition)
    local phases = fight.boss.phases
    if phases == nil or phases[n] == nil then return end
    if phases[n].minEnrage ~= nil and fight.enrage ~= nil and fight.enrage < phases[n].minEnrage then
        return -- e.g. Telos phase 5 only exists at 100%+ enrage
    end
    saveHistory()
    -- A stun on the tick the phase changes doesn't hold him: he's already
    -- transitioning (fight 9: Soul Strike on the 75% tick, P2 Tendrils fits without it)
    if fight.lastStun ~= nil and ticks - fight.lastStun.tick <= 1 and fight.expectTick ~= nil then
        fight.expectTick = fight.expectTick - fight.lastStun.shift
    end
    fight.lastStun = nil
    -- A phase timer that counts as a special, once it has run its course
    local pending = fight.pendingPhaseSpecial
    if pending ~= nil and ticks >= pending.at then
        fight.lastSpecial, fight.lastConfirmedSpecial = pending.attack, pending.attack
    end
    fight.pendingPhaseSpecial = nil
    fight.phaseIndex = n
    fight.phaseLabel, fight.paused, fight.useCount = nil, nil, {}
    fight.banner, fight.countdown = nil, nil
    fight.seen = {}
    fight.lastEventEnded, fight.specialsSinceEvent, fight.followUp = nil, nil, nil
    local phase = phases[n]
    local idx = applyOpener(phase)
    debugLog("PRED", formatStr("enter {} (last special {}) -> opener {} after {} autos{}", phase.name,
        tostring(fight.lastSpecial), phase.specials[idx].attack, fight.nextAutos,
        waitForTransition and ", waiting for transition" or ""))
    if waitForTransition then
        fight.inTransition = true
        fight.transitionTick = ticks
        fight.transitionHp = fight.hp
        fight.expectTick = nil
        fight.now = { attack = phase.name .. " transition", note = "Boss resets - countdown starts when it attacks again", tick = ticks }
    else
        resumePhase()
    end
end

local knownEnrage = {} -- boss -> enrage % read from chat before tracking started

local endedUid, endedTick = nil, nil -- last boss killed, see startFight / endFight

-- Bosses with startChat (e.g. Zuk, visible on his throne before the fight) only
-- start tracking after that chat line, not when the NPC comes into view
local startArmed = {}
local function canStart(boss)
    return boss.startChat == nil or startArmed[boss] == true
end

-- Achievement tracker (boss.achievement): eligible until a fail. Saved in
-- PersistentDB so a reload or a checkpoint restart keeps a fail.
-- ach_<boss>      = "" eligible, else the fail reason
-- ach_<boss>_cp   = 1 after a death in a checkpoint phase: the next start is
--                   the checkpoint restart, so the fail carries over
local function achKey(boss) return "ach_" .. boss.name end
local function achStatus(boss)
    local v = PersistentDB:Get(achKey(boss))
    return type(v) == "string" and v or ""
end
local function achFail(boss, reason)
    if boss.achievement == nil or achStatus(boss) ~= "" then return end
    PersistentDB:Set(achKey(boss), reason)
    print(formatStr("Combat Helper: {} failed - {}", boss.achievement.name, reason))
end
local function achStart(boss, isRestart)
    if boss.achievement == nil or isRestart then return end
    if PersistentDB:Get(achKey(boss) .. "_cp") == 1 then
        PersistentDB:Set(achKey(boss) .. "_cp", 0) -- checkpoint restart: keep the fail
    else
        PersistentDB:Set(achKey(boss), "") -- fresh run
    end
end

local function startFight(boss, npc)
    -- The dead boss lingers a few ticks after the kill message: don't restart on it
    -- (a startChat line is an explicit new session, e.g. Zuk checkpoint restart)
    if npc.uid ~= nil and npc.uid == endedUid and endedTick ~= nil and ticks - endedTick < 40
        and not startArmed[boss] then return end
    startArmed[boss] = nil
    achStart(boss, fight ~= nil and fight.boss == boss)
    fight = {
        enrage = knownEnrage[boss],
        inTransition = false,
        boss = boss,
        uid = npc.uid,
        startTick = ticks,
        phaseIndex = 1,
        nextIdx = nil,
        nextAutos = 0,
        expectTick = nil,
        now = nil,
        lastSpecial = nil,
        seen = {},
        history = {},
        phaseName = nil,
        timersFired = {},
        alert = nil,
        endPendingTick = nil,
    }
    fightHook(true) -- recorder AUTO: start before the opener lines are logged
    if boss.phases ~= nil then
        enterPhase(1, false)
        fight.history = {}
    end
    print("Combat Helper: tracking " .. boss.name)
end

local function restartFight()
    if fight ~= nil then
        startFight(fight.boss, { uid = fight.uid })
    end
end

local function endFight()
    if fight ~= nil then
        print("Combat Helper: stopped tracking " .. fight.boss.name)
        endedUid, endedTick = fight.uid, ticks
        fightHook(false)
    end
    fight = nil
end

local function nextPhase()
    if fight ~= nil and fight.boss.phases ~= nil then
        enterPhase(fight.phaseIndex + 1, false)
    end
end

local syncToSpecial -- defined with the triggers below

local function manualNext()
    if fight == nil or fight.nextIdx == nil then return end
    local phase = currentPhase()
    if phase and phase.random then
        -- Random phase: the key means "I saw a special the plugin can't detect"
        -- (Araxxor's Cleave / Web shield, both 5 autos). Replaces a guess made
        -- in the last few ticks instead of adding another special
        syncToSpecial(phase.randomIdx)
        if fight.now then
            fight.now.attack, fight.now.note = phase.manualName or "Special (seen)", nil
        end
        fight.lastRealSpecial = phase.manualName
        return
    end
    doSpecial(fight.nextIdx)
end

------------------------------------------------------------------------
print("CH step: Triggers")
-- Triggers
------------------------------------------------------------------------

-- Resync the rotation to special i. Several signals (yell, game message,
-- object spawn) can report the same special; repeats within a few ticks are ignored.
syncToSpecial = function(i)
    local now = fight.now
    local recentSame = now ~= nil and now.index == i and not now.estimated
        and ticks - now.tick < RESYNC_IGNORE_TICKS
    if recentSame then return end
    -- If the estimate already moved past this special, replace that estimate
    local phase = currentPhase()
    if now ~= nil and now.estimated and (now.index == i
        or (phase and phase.randomIdx and now.index == phase.randomIdx and ticks - now.tick <= 8)) then
        undo()
    end
    doSpecial(i)
end

local function applyTrigger(trigger)
    -- onlyAfter: the signal only means something right after that special
    if trigger.onlyAfter ~= nil and fight.lastSpecial ~= trigger.onlyAfter then return end
    -- stunBroken: the boss broke out of the player's stun (Telos's Freedom at
    -- high enrage): it only held him from the cast until now
    local stun = fight.lastStun
    if trigger.stunBroken and stun ~= nil and not stun.broken and fight.expectTick == stun.expect then
        stun.broken = true
        local held = ticks - stun.tick
        if held < stun.shift then
            fight.expectTick = fight.expectTick - (stun.shift - held)
            stun.shift = held
            debugLog("PRED", formatStr("stun broken after {} ticks -> next {} expected tick {}", held,
                currentPhase().specials[fight.nextIdx].attack, expectText()))
        end
        return
    end
    -- cooldown: some signals repeat (objects respawning); act once per window
    if trigger.cooldown ~= nil then
        fight.triggerTicks = fight.triggerTicks or {}
        local last = fight.triggerTicks[trigger]
        if last ~= nil and ticks - last < trigger.cooldown then return end
        fight.triggerTicks[trigger] = ticks
    end
    if trigger.restart then
        restartFight()
        return
    end
    -- endFight: the encounter is over (e.g. left the boss instance)
    if trigger.endFight then
        debugLog("PRED", "end fight (" .. tostring(trigger.var or trigger.chat) .. ")")
        endFight()
        return
    end
    if trigger.phase ~= nil and trigger.phase > fight.phaseIndex then
        -- noTransition: the signal IS the new phase's first attack (e.g. Zuk's Burn yell)
        enterPhase(trigger.phase, not trigger.noTransition)
    end
    if trigger.phaseTimer ~= nil then
        -- The phase timer happened now: mark it done (if it's still pending) and alert
        local phase = currentPhase()
        for i, timer in ipairs(phase and phase.timers or {}) do
            if timer.attack == trigger.phaseTimer and fight.phaseTimersFired and not fight.phaseTimersFired[i] then
                fight.phaseTimersFired[i] = true
                fight.alert = { attack = timer.attack, note = timer.note, tick = ticks }
                if timer.countsAsSpecial then fight.pendingPhaseSpecial = { attack = timer.attack, at = fight.phaseTimerStart + (timer.countsAfter or 0) } end
                debugLog("PRED", formatStr("phase timer '{}' seen", timer.attack))
                return
            end
        end
    end
    -- label: extra text on the phase line (e.g. "Wave 5 (challenge)"). A new
    -- label also replaces the banner and countdown of the previous one.
    -- banner: yellow line under the header; countdown = { name, ticks }: a
    -- "~name in Ns" line counting down from now
    if trigger.label ~= nil then
        fight.phaseLabel = trigger.label
        fight.banner, fight.countdown = nil, nil
    end
    if trigger.banner ~= nil then fight.banner, fight.bannerRed = trigger.banner, trigger.bannerRed end
    if trigger.countdown ~= nil then
        fight.countdown = { name = trigger.countdown.name, tick = ticks + trigger.countdown.ticks,
            note = trigger.countdown.note }
    end
    -- pause: the next special won't come until a later trigger (e.g. no flame
    -- walls in Zuk's challenge waves); dueIn: it comes that many ticks from now
    if trigger.pause ~= nil then
        fight.paused = trigger.pause
        fight.expectTick = nil
    end
    if trigger.dueIn ~= nil then
        local phase = currentPhase()
        for i, special in ipairs(phase and phase.specials or {}) do
            if special.attack == trigger.dueSpecial then
                fight.paused = nil
                setNext(i, 0, trigger.dueIn)
                debugLog("PRED", formatStr("{} due in {} ticks, expected tick {}", special.attack, trigger.dueIn, expectText()))
                break
            end
        end
    end
    if trigger.special ~= nil then
        local phase = currentPhase()
        if phase ~= nil then
            for i, special in ipairs(phase.specials) do
                -- onlyIfNext: the signal also appears outside the rotation, so only
                -- sync when this special is the one expected next (or was just estimated)
                local justEstimated = fight.now ~= nil and fight.now.estimated and fight.now.index == i
                    and ticks - fight.now.tick <= 3
                if special.attack == trigger.special and (not trigger.onlyIfNext or fight.nextIdx == i or justEstimated) then
                    syncToSpecial(i)
                    break
                end
            end
        end
    end
    -- fontPush: e.g. Telos's font golems - the push happened even if the HP
    -- display stayed above the threshold (fight at 100%: 125000 -> 95000 in one
    -- hit, font golems 7 ticks later, HP stuck at 95000 until after the bomb)
    if trigger.fontPush and fight.activeEvent == nil and not fight.inTransition then
        local phase = currentPhase()
        for i, event in ipairs(phase and phase.hpEvents or {}) do
            if not (fight.hpEventsFired and fight.hpEventsFired[fight.phaseIndex .. ":" .. i]) then
                local pushTick = fight.lastHpDropTick or ticks
                if ticks - pushTick > 12 then pushTick = ticks end
                fireHpEvent(i, event, pushTick)
                break
            end
        end
    end
    -- bombIn: the boss's warning yell before a font bomb (exact timing)
    if trigger.bombIn ~= nil and fight.activeEvent ~= nil then
        fight.activeEvent.bombTick = ticks + trigger.bombIn
        debugLog("PRED", formatStr("bomb warning -> bomb expected tick +{}", trigger.bombIn))
    end
    if trigger.phaseName ~= nil then
        fight.phaseName = trigger.phaseName
    end
    if trigger.attack ~= nil then
        fight.now = { attack = trigger.attack, note = trigger.note, next = trigger.next, tick = ticks }
    end
    if trigger.alert ~= nil then
        fight.alert = { attack = trigger.alert, note = trigger.note, tick = ticks }
    end
    if trigger.endsEvent and fight.activeEvent ~= nil then
        local ended = fight.activeEvent
        fight.activeEvent = nil
        -- His walk out of the font after the bomb is part of the bomb -> special
        -- timing (+8/+12/+16): count walking from here, not from his last special
        fight.walkTicks = 0
        fight.lastEventEnded = ended.index
        fight.autoVarAutos = nil -- counted from his next special again
        fight.specialsSinceEvent = 0
        -- Next special slot: autos left from before the push, first one 4 ticks
        -- after the bomb (bomb -> special +8/+12/+16 for 1/2/3 autos)
        -- Never sooner than +8: 0 autos left still came +8 (2 fights)
        local left = ended.autosLeft or 3
        local autoTicks = fight.boss.autoTicks or 4
        local isFollowUp = (fight.followUp ~= nil and fight.followUp.carried) or ended.def.afterSpecial ~= nil
        -- A held release (SO. MUCH. POWER) after a bomb comes one auto later than a
        -- special would: 0 left +8, 1 left +12 (2 fights), 2 left +16 (2 fights),
        -- 3 left +19/+20 (2 fights 2026-10-22; one older fight said +16)
        local function slotTicks(n)
            if isFollowUp then return autoTicks * math.min(n + 2, 5) end
            return autoTicks * math.max(2, n + 1)
        end
        local due = ticks + slotTicks(left)
        fight.lastBombTick, fight.lastBombLeft = ticks, left
        local lateLeft = ended.autosLeftLate
        if fight.followUp ~= nil and fight.followUp.carried then
            lateLeft = fight.followUp.autosLate
        end
        local dueLate = lateLeft and ticks + slotTicks(lateLeft)
        if dueLate == due then dueLate = nil end
        if fight.followUp ~= nil and fight.followUp.carried then
            -- Pushed into this font before the held release fired: it takes that slot
            fight.followUp.carried = nil
            fight.followUp.tick, fight.followUp.due, fight.followUp.dueLate = ticks, due, dueLate
        elseif ended.def.afterText or ended.def.afterSpecial then
            -- e.g. SO. MUCH. POWER: replaces his next special (afterHold: the
            -- rotation waits for it)
            fight.followUp = { text = ended.def.afterText, special = ended.def.afterSpecial,
                due = ended.def.afterSpecial and due, dueLate = dueLate, autos = left, tick = ticks,
                hold = ended.def.afterHold }
        else
            fight.eventDue, fight.eventDueLate = due, dueLate
        end
    end
    if trigger.openPath ~= nil then
        fight.openPaths = fight.openPaths or {}
        fight.openPaths[trigger.openPath] = true
        local closed, count = nil, 0
        for _, path in ipairs(fight.boss.paths or {}) do
            if fight.openPaths[path] then count = count + 1 else closed = path end
        end
        if fight.boss.paths and count == #fight.boss.paths - 1 and fight.closedPath ~= closed then
            fight.closedPath = closed
            debugLog("PRED", formatStr("path closed this rotation: {}", closed))
        end
    end
    if trigger.path ~= nil then
        fight.path = trigger.path
    end
    if trigger.endRotation then
        fight.nextIdx, fight.expectTick = nil, nil
    end
    if trigger.clearsFollowUp then
        fight.followUp = nil
    end
    -- An interruption landing right when an estimate fired means the estimated
    -- special didn't happen (the boss did this instead): take it back
    if trigger.undoEstimate and fight.now and fight.now.estimated and fight.now.index
        and ticks - fight.now.tick <= 3 then
        debugLog("PRED", formatStr("'{}' instead of estimated {}: undo", trigger.alert or "trigger", fight.now.attack))
        undo()
    end
    if fight.eventDue ~= nil then
        if fight.nextIdx ~= nil and not fight.inTransition and not fight.waitBar then
            fight.expectTick = fight.eventDue
            fight.expectLate = fight.eventDueLate
            debugLog("PRED", formatStr("after font bomb -> next {} expected tick {}",
                currentPhase().specials[fight.nextIdx].attack, expectText()))
        end
        fight.eventDue, fight.eventDueLate = nil, nil
    end
    -- delayNext: an interruption (e.g. Telos's font bomb) pushes the next special back
    -- e.g. SO. MUCH. POWER: his autos count from here, not from the last font bomb
    if trigger.delayNext ~= nil then fight.lastBombTick, fight.autoVarAutos = nil, nil end
    if trigger.delayNext ~= nil and fight.nextIdx ~= nil and not fight.inTransition and not fight.waitBar then
        fight.expectTick = ticks + trigger.delayNext
        debugLog("PRED", formatStr("delayed by '{}' -> next {} expected tick +{}", trigger.alert or "trigger",
            currentPhase().specials[fight.nextIdx].attack, trigger.delayNext))
    end
end

local function fireTriggers(field, value)
    if fight == nil or value == nil then return end
    local phaseAtStart = fight.phaseIndex
    for _, trigger in ipairs(fight.boss.triggers) do
        local pattern = trigger[field]
        if pattern ~= nil and matches(value, pattern)
            and (trigger.inPhase == nil or listHas(trigger.inPhase, phaseAtStart)) then
            applyTrigger(trigger)
            if fight == nil then return end -- endFight trigger
        end
    end
end

-- A special's own `chat` text resyncs the rotation to that special
local function syncSpecialFromChat(text)
    local phase = currentPhase()
    if phase == nil then return false end
    -- A yell within a few ticks of the phase change is the previous phase's
    -- last special (HP threshold and yell can land on the same tick): use it
    -- for this phase's opener instead of syncing the rotation
    local previous = fight.boss.phases[fight.phaseIndex - 1]
    if fight.inTransition and previous and ticks - fight.transitionTick <= 3 then
        for _, special in ipairs(previous.specials) do
            if special.chat ~= nil and matches(text, special.chat) then
                fight.lastConfirmedSpecial = special.attack
                fight.lastSpecialTick = ticks
                applyOpener(phase)
                debugLog("PRED", formatStr("late {} from {} -> {} opener {}", special.attack, previous.name,
                    phase.name, phase.specials[fight.nextIdx].attack))
                return true
            end
        end
    end
    for i, special in ipairs(phase.specials) do
        if special.chat ~= nil and matches(text, special.chat) then
            syncToSpecial(i)
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
print("CH step: UI")
-- UI
------------------------------------------------------------------------

-- Panel size: resizable with the < > ^ v buttons in the title bar, saved
local PANEL_MIN_W, PANEL_MAX_W, PANEL_MIN_H, PANEL_MAX_H = 300, 800, 200, 700
local SIZE_STEP = 30
local PANEL_WIDTH = math.floor(math.max(PANEL_MIN_W, math.min(PANEL_MAX_W, PersistentDB:Get("panelW") or 400)))
local PANEL_HEIGHT = math.floor(math.max(PANEL_MIN_H, math.min(PANEL_MAX_H, PersistentDB:Get("panelH") or 290)))
local TITLE_HEIGHT = 20
local BUTTON_HEIGHT = 26
local MOVE_WIDTH = 28
local TOGGLE_WIDTH = 150
local ROW_GAP = 4
local TOP_ROW_WIDTH = 360 -- move + on/off + recorder buttons
local ROOT_WIDTH = math.max(TOP_ROW_WIDTH, PANEL_WIDTH)
local ROOT_HEIGHT = BUTTON_HEIGHT + ROW_GAP + PANEL_HEIGHT

local FONT = id.Font.MUSEO_SANS_15PT_REGULAR
local WHITE = Vector4.new(1.0, 1.0, 1.0, 1.0)

local gameWindow = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)

-- Invisible container holding everything, so the whole UI moves together
local function container(parent)
    local box = ui.GroupBox.new(parent)
    box:SetHeaderLayout(0, 0, 0, 0, ui.GroupBoxHeaderAlignMode.LEFT)
    pcall(function() box.clickthrough = true end)
    return box
end

local root = container(gameWindow)
root:SetSize(ROOT_WIDTH, ROOT_HEIGHT)

-- Top row: [Move] [on/off] (+ recorder buttons added later)
local moveButton = ui.Button.new(root)
moveButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
moveButton:SetSize(MOVE_WIDTH, BUTTON_HEIGHT)
moveButton:SetPos(0, 0)
moveButton.label = "+"

local toggleButton = ui.Button.new(root)
toggleButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
toggleButton:SetSize(TOGGLE_WIDTH, BUTTON_HEIGHT)
toggleButton:SetPos(MOVE_WIDTH + ROW_GAP, 0)

-- Panel below the top row
local panel = container(root)
panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
panel:SetPos(0, BUTTON_HEIGHT + ROW_GAP)

local background = ui.Rectangle.new(panel)
background:SetSize(0, 0, 1.0, 1.0)
background:SetPos(0, 0)
background.colour = Vector4.new(0.05, 0.05, 0.08, 0.8)
background.fill = true
pcall(function() background.clickthrough = true end)

local title = ui.Text.new(panel)
title:SetPos(8, 4)
title:SetSize(-16, TITLE_HEIGHT, 1.0, 0.0)
title.font = FONT
title.colour = WHITE
title.isShadowed = true
title:AlignTo(ui.AlignMode.TOPLEFT)
title.content = "<col=ffb000>Combat Helper</col>"

local body = ui.Text.new(panel)
body:SetPos(8, 4 + TITLE_HEIGHT)
body:SetSize(-16, -(TITLE_HEIGHT + BUTTON_HEIGHT + 14), 1.0, 1.0)
body.font = FONT
body.colour = WHITE
body.isShadowed = true
body:AlignTo(ui.AlignMode.TOPLEFT)

-- Resize buttons, top-right of the panel: < > width, ^ v height
local SIZE_BUTTON = 22
local function resizePanel(dw, dh)
    PANEL_WIDTH = math.max(PANEL_MIN_W, math.min(PANEL_MAX_W, PANEL_WIDTH + dw))
    PANEL_HEIGHT = math.max(PANEL_MIN_H, math.min(PANEL_MAX_H, PANEL_HEIGHT + dh))
    ROOT_WIDTH = math.max(TOP_ROW_WIDTH, PANEL_WIDTH)
    ROOT_HEIGHT = BUTTON_HEIGHT + ROW_GAP + PANEL_HEIGHT
    panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    root:SetSize(ROOT_WIDTH, ROOT_HEIGHT)
    PersistentDB:Set("panelW", PANEL_WIDTH)
    PersistentDB:Set("panelH", PANEL_HEIGHT)
end
for i, def in ipairs({
    { "<", -SIZE_STEP, 0 }, { ">", SIZE_STEP, 0 }, { "^", 0, -SIZE_STEP }, { "v", 0, SIZE_STEP },
}) do
    local button = ui.Button.new(panel)
    button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    button:SetSize(SIZE_BUTTON, SIZE_BUTTON - 4)
    button:SetPos(-(4 - i + 1) * (SIZE_BUTTON + 2) - 4, 2, 1.0, 0.0)
    button.label = def[1]
    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function() resizePanel(def[2], def[3]) end)
end

------------------------------------------------------------------------
-- Moving the UI: click "+" to pick it up, it sticks to the mouse, click again to lock
------------------------------------------------------------------------
-- Mouse pixels and UI units don't map 1:1, so instead of converting coordinates
-- the "+" homes in on the cursor: invisible probe zones around it report (via
-- isMouseOver) which side the cursor is on, and the UI moves that way each frame.

local moving = false

local NEAR = 40           -- thickness of the near probe ring around "+", in UI units
local NEAR_SPEED = 400    -- UI units per second while the cursor is in the near ring
local FAR_SPEED = 2500    -- UI units per second while the cursor is further away

local function placeRoot(x, y)
    x = math.max(0, math.min(x, gameWindow.width - ROOT_WIDTH))
    y = math.max(0, math.min(y, gameWindow.height - BUTTON_HEIGHT))
    root:SetPos(math.floor(x), math.floor(y))
end

local savedX, savedY = PersistentDB:Get("posX"), PersistentDB:Get("posY")
if savedX ~= nil and savedY ~= nil then
    placeRoot(savedX, savedY)
else
    root:SetPos(0, 10, 0.4, 0.0)
end

local drop -- forward declaration, probes call it when clicked

local probes = {}
local PROBE_NAMES = { "nearL", "nearR", "nearU", "nearD", "farL", "farR", "farU", "farD" }
for _, name in ipairs(PROBE_NAMES) do
    local probe = ui.Button.new(gameWindow)
    pcall(function() probe.alpha = 0 end)
    probe.hidden = true
    probe:Subscribe(ui.Hook.ONBUTTONPRESSED, function() if moving then drop() end end)
    probes[name] = probe
end

local function setRect(probe, x, y, w, h)
    probe:SetPos(math.floor(x), math.floor(y))
    probe:SetSize(math.max(1, math.floor(w)), math.max(1, math.floor(h)))
end

-- The "+" button is at the root's top-left corner
local function layoutProbes()
    local hx, hy, w, h = root.x, root.y, MOVE_WIDTH, BUTTON_HEIGHT
    local W, H = gameWindow.width, gameWindow.height
    setRect(probes.nearL, hx - NEAR, hy - NEAR, NEAR, h + 2 * NEAR)
    setRect(probes.nearR, hx + w, hy - NEAR, NEAR, h + 2 * NEAR)
    setRect(probes.nearU, hx, hy - NEAR, w, NEAR)
    setRect(probes.nearD, hx, hy + h, w, NEAR)
    setRect(probes.farL, 0, 0, hx - NEAR, H)
    setRect(probes.farR, hx + w + NEAR, 0, W - (hx + w + NEAR), H)
    setRect(probes.farU, hx - NEAR, 0, w + 2 * NEAR, hy - NEAR)
    setRect(probes.farD, hx - NEAR, hy + h + NEAR, w + 2 * NEAR, H - (hy + h + NEAR))
end

local function setProbesVisible(visible)
    for _, probe in pairs(probes) do
        probe.hidden = not visible
        if visible then probe:MoveToFront() end
    end
end

drop = function()
    moving = false
    setProbesVisible(false)
    moveButton.label = "+"
    PersistentDB:Set("posX", root.x)
    PersistentDB:Set("posY", root.y)
end

local function pickUp()
    moving = true
    moveButton.label = "o"
    layoutProbes()
    setProbesVisible(true)
end

moveButton:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
    if moving then drop() else pickUp() end
end)

-- Escape also locks the UI where it is
Event.KeyDown.Subscribe("combatHelperMoveKeys", function(event)
    if moving and event.gameKey == GameKey.ESCAPE then
        drop()
    end
end)

local function over(name)
    return probes[name].isMouseOver
end

Event.Draw.Subscribe("combatHelperMove", function(event)
    if not moving then return end
    local dt = math.min(event.timeDeltaSecs or 0.016, 0.1)
    local dx, dy = 0, 0
    if over("farL") then dx = -FAR_SPEED * dt
    elseif over("farR") then dx = FAR_SPEED * dt
    elseif over("nearL") then dx = -NEAR_SPEED * dt
    elseif over("nearR") then dx = NEAR_SPEED * dt
    end
    if over("farU") then dy = -FAR_SPEED * dt
    elseif over("farD") then dy = FAR_SPEED * dt
    elseif over("nearU") then dy = -NEAR_SPEED * dt
    elseif over("nearD") then dy = NEAR_SPEED * dt
    end
    -- Keep each step inside the ring it was detected in, so it can't overshoot the cursor
    dx = math.max(-NEAR + 1, math.min(NEAR - 1, dx))
    dy = math.max(-NEAR + 1, math.min(NEAR - 1, dy))
    if dx ~= 0 or dy ~= 0 then
        placeRoot(root.x + dx, root.y + dy)
        layoutProbes()
    end
end)


local BUTTON_COUNT = 5
local function addButton(index, label, onPress)
    local button = ui.Button.new(panel)
    button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    button:SetSize(-4, BUTTON_HEIGHT, 1 / BUTTON_COUNT, 0.0)
    button:SetPos(2, -(BUTTON_HEIGHT + 4), (index - 1) / BUTTON_COUNT, 1.0)
    button.label = label
    button:Subscribe(ui.Hook.ONBUTTONPRESSED, onPress)
    return button
end

------------------------------------------------------------------------
print("CH step: Rendering")
-- Rendering
------------------------------------------------------------------------

local function nextTimer()
    local elapsed = (ticks - fight.startTick) * SECONDS_PER_TICK
    local best = nil
    for i, timer in ipairs(fight.boss.timers) do
        if not fight.timersFired[i] and (best == nil or timer.at < best.at) then
            best = timer
        end
    end
    if best == nil then return nil end
    return best, best.at - elapsed
end


local function redraw()
    if fight == nil then
        local names = {}
        for _, boss in ipairs(bosses) do table.insert(names, boss.name) end
        body.content = col(COL_DIM, "Waiting for a boss...") .. "<br>" ..
            col(COL_DIM, "Known: " .. (#names > 0 and table.concat(names, ", ") or "none"))
        return
    end

    local elapsed = (ticks - fight.startTick) * SECONDS_PER_TICK
    local header = col(COL_HEADER, fight.boss.name) .. "  " .. col(COL_DIM, formatTime(elapsed))
    if fight.hp ~= nil and fight.hp > 0 then
        header = header .. "  " .. withCommas(fight.hp)
        if fight.maxHp ~= nil and fight.maxHp > 0 then
            header = header .. col(COL_DIM, formatStr(" ({}%)", math.floor(fight.hp / fight.maxHp * 100)))
        end
    end
    if fight.bar ~= nil and fight.bar > 0 then
        header = header .. col(COL_DIM, formatStr("  bar {}", fight.bar))
    end
    local lines = { header }
    local ach = fight.boss.achievement
    if ach ~= nil then
        local failed = achStatus(fight.boss)
        table.insert(lines, failed == "" and col(COL_GOOD, ach.name .. ": eligible")
            or col(COL_NOW, formatStr("{}: FAILED ({})", ach.name, failed)))
    end

    local phase = currentPhase()
    if phase ~= nil then
        local phaseLine = (fight.phaseLabel or phase.name) .. (fight.inTransition and " - transition" or "")
        if fight.enrage ~= nil then
            phaseLine = phaseLine .. formatStr("  {}% enrage", math.floor(fight.enrage))
        end
        table.insert(lines, col(COL_DIM, phaseLine))
        if fight.banner ~= nil then table.insert(lines, col(fight.bannerRed and COL_NOW or COL_SOON, fight.banner)) end
    elseif fight.phaseName ~= nil then
        table.insert(lines, col(COL_DIM, fight.phaseName))
    end
    table.insert(lines, col(COL_DIM, DIVIDER))

    -- NOW / NEXT / THEN blocks: label + attack (+ countdown) on one line,
    -- details indented underneath in grey
    local function block(label, colour, attack, seconds, details)
        if label ~= "NOW " then table.insert(lines, col(COL_DIM, DIVIDER)) end
        local line = col(colour, label .. "  " .. attack)
        if seconds ~= nil then line = line .. "  " .. col(COL_SOON, "~" .. seconds .. "s") end
        table.insert(lines, line)
        for _, d in ipairs(details or {}) do
            if d ~= nil and d ~= "" then table.insert(lines, col(COL_DIM, INDENT .. d)) end
        end
    end
    local function secondsTo(tick, lateTick)
        if tick == nil then return nil end
        local first = math.max(0, math.ceil((tick - ticks) * SECONDS_PER_TICK))
        if lateTick == nil or lateTick <= tick then return first end
        return first .. "-" .. math.max(0, math.ceil((lateTick - ticks) * SECONDS_PER_TICK))
    end
    -- "0-1 autos" when a push landed right at the cut-off
    local function autosText(left, late)
        if late ~= nil and late > left then
            return formatStr("{}-{} autos", left, late)
        end
        return formatStr("{} auto{}", left, left == 1 and "" or "s")
    end

    local now = fight.now
    -- NOW goes blank once the special / phase start is over instead of
    -- repeating it until the next one. nowTicks: the special's own length
    -- (e.g. Zuk's flame wall); else its duration, at least NOW_TICKS
    local nowDef = now and now.index and phase and phase.specials[now.index]
    if nowDef and nowDef.attack ~= now.attack then nowDef = nil end
    local showTicks = (nowDef and nowDef.nowTicks) or math.max(NOW_TICKS, (nowDef and nowDef.duration) or 0)
    if now and not fight.inTransition and ticks - now.tick > showTicks then
        now = nil
    end
    local nowText = now and now.attack or ""
    if now and now.estimated then
        nowText = nowText .. " (est)"
    end
    local nowNote = now and now.note
    -- Nothing special going on: show his autos (style + which one of the run)
    if now == nil and not fight.inTransition and phase ~= nil then
        if fight.activeEvent ~= nil then
            nowText = fight.activeEvent.def.name
        else
            local style = phase.autoStyle or (fight.boss.hits and fight.boss.hits.autoStyle)
            if style == "reach" then style = fight.lastAutoStyle end
            nowText = style == "melee" and "Melee autos" or style == "magic" and "Magic autos" or "Auto attacks"
            local total = fight.nextAutos
            if total ~= nil and total > 0 and fight.expectTick ~= nil and not fight.holdForCycle then
                local left = autosLeftAt(fight.expectTick, total)
                nowNote = left > 0 and formatStr("auto {} of {}", total - left + 1, total) or "special next"
            end
        end
    end
    block("NOW ", COL_NOW, nowText, nil, { nowNote })

    if phase ~= nil and fight.nextIdx ~= nil then
        local special = phase.specials[fight.nextIdx]
        local detail
        if fight.inTransition then
            detail = (fight.nextAutos == 0 and fight.openerAutosLate == nil) and "his first attack after the transition"
                or formatStr("after transition + {}", autosText(fight.nextAutos, fight.openerAutosLate))
        elseif fight.holdForCycle then
            local mechanic = (fight.activeEvent and fight.activeEvent.def.name)
                or (fight.followUp and fight.followUp.hold and (fight.followUp.after or "the bar release"))
                or (phase.cycle and phase.cycle.name) or "mechanic"
            detail = formatStr("after {}", mechanic)
            local left = fight.activeEvent and fight.activeEvent.autosLeft
            local late = fight.activeEvent and fight.activeEvent.autosLeftLate
            if left ~= nil then
                detail = (left == 0 and late == nil) and formatStr("right after the {} bomb", mechanic)
                    or formatStr("after the {} bomb + {}", mechanic, autosText(left, late))
            end
        elseif fight.paused ~= nil then
            detail = fight.paused
        elseif fight.waitBar then
            detail = formatStr("after bar empties ({}) + {} autos", fight.bar or "?", fight.nextAutos)
        elseif special.random and phase.firstAutosMin and fight.lastRealSpecial == nil then
            detail = formatStr("after {}-{} autos (random at fight start)", phase.firstAutosMin, fight.nextAutos)
        elseif special.detail ~= nil then
            detail = special.detail
        else
            detail = (fight.nextAutos == 0 and fight.nextAutosLate == nil) and "his next attack (no autos first)"
                or ("after " .. autosText(fight.nextAutos, fight.nextAutosLate))
        end
        -- animLead: his animation starts that many ticks before the yell we sync
        -- on (display only - all timing stays measured from the yell)
        local lead = special.animLead or 0
        local nextSeconds = (not fight.holdForCycle) and fight.expectTick
            and secondsTo(fight.expectTick - lead, fight.expectLate and fight.expectLate - lead) or nil
        local isRandom = special.random
        if special.random then
            local options = {}
            for _, s2 in ipairs(phase.specials) do
                if not s2.random and s2.attack ~= fight.lastRealSpecial and specialAllowed(s2) then
                    table.insert(options, s2.attack)
                end
            end
            special = { attack = "Special", note = table.concat(options, " / ") }
        end
        -- A held font follow-up (SO. MUCH. POWER) takes his next special slot:
        -- show it as Next, the rotation special as Then
        local f = followUpActive() and fight.followUp.hold and fight.followUp.special and fight.followUp
        local fontSpecial = fight.activeEvent and fight.activeEvent.def.afterSpecial
        if f or fontSpecial then
            local what, fdetail, fseconds = (f and f.special) or fontSpecial, nil, nil
            if fight.activeEvent ~= nil then
                local left = fight.activeEvent.autosLeft or 3
                local late = (f and f.carried and f.autosLate) or fight.activeEvent.autosLeftLate
                fdetail = formatStr("after {} bomb + {}", fight.activeEvent.def.name, autosText(left, late))
            else
                local left = math.min(f.autos or 3, math.max(0, autosLeftAt(f.due, 99) - 1))
                fseconds = secondsTo(f.due, f.dueLate)
                local late = f.dueLate and math.max(0, autosLeftAt(f.dueLate, 99) - 1) or nil
                fdetail = (left == 0 and late == nil) and "his next attack" or ("after " .. autosText(left, late))
            end
            block("NEXT", COL_NEXT, what, fseconds, { fdetail, "defensive ready" })
            block("THEN", COL_THEN, special.attack, nil, { "~8s after it" })
        else
            local nextNote = special.note
            if special.notes then
                local count = ((fight.useCount or {})[fight.nextIdx] or 0) + 1
                nextNote = special.notes[math.min(count, #special.notes)]
            end
            block("NEXT", COL_NEXT, special.attack, nextSeconds, { detail, nextNote })
            -- The special after it (not for random rotations)
            if not isRandom and not phase.random and not fight.inTransition then
                local thenIdx = nextIndex(phase, fight.nextIdx)
                local thenSpecial = phase.specials[thenIdx]
                if thenSpecial ~= nil and thenIdx ~= fight.nextIdx then
                    local thenTick
                    if fight.expectTick ~= nil and not fight.holdForCycle and not fight.waitBar
                        and fight.boss.autoTicks ~= nil then
                        thenTick = fight.expectTick + specialTicks(phase.specials[fight.nextIdx])
                            + (thenSpecial.autos or 0) * fight.boss.autoTicks
                    end
                    block("THEN", COL_THEN, thenSpecial.attack, secondsTo(thenTick and thenTick - (thenSpecial.animLead or 0)))
                end
            end
        end
    elseif now and now.next then
        block("NEXT", COL_NEXT, now.next)
    end
    table.insert(lines, col(COL_DIM, DIVIDER))

    -- pathNotes: phase advice for the path taken (e.g. Araxxor minions path)
    local pathNote = phase and phase.pathNotes and fight.path and phase.pathNotes[fight.path]
    if pathNote and not fight.inTransition then
        table.insert(lines, col(COL_GOOD, pathNote))
    end

    -- lowHpHint: e.g. Araxxor - HP low enough, walk on to phase him
    local hint = phase and phase.lowHpHint
    if hint and fight.hp ~= nil and fight.hp > 0 and fight.hp <= hint.below and not fight.inTransition then
        table.insert(lines, col(COL_GOOD, hint.text))
    end

    if fight.activeEvent ~= nil then
        local event = fight.activeEvent.def
        local text = event.alert
        local bombTick = fight.activeEvent.bombTick
            or (event.bombTicks and fight.activeEvent.tick + event.bombTicks)
        if bombTick then
            local seconds = math.max(0, math.ceil((bombTick - ticks) * SECONDS_PER_TICK))
            text = text .. formatStr(" - bomb in ~{}s", seconds)
        end
        table.insert(lines, col(COL_NOW, text))
        -- What comes after the bomb is in the NEXT block
    elseif phase ~= nil and phase.hpEvents and fight.hp ~= nil and fight.maxHp ~= nil and fight.maxHp > 0
        and not fight.inTransition then
        for i, event in ipairs(phase.hpEvents) do
            if not (fight.hpEventsFired and fight.hpEventsFired[fight.phaseIndex .. ":" .. i]) then
                local at = math.floor(fight.maxHp * event.hpBelow)
                local toGo = withCommas(math.max(0, fight.hp - at))
                -- pushAfter: only push into this font once the previous font is done
                -- and the boss has done N specials since (e.g. 3 autos + special)
                local push = event.pushAfter
                if push ~= nil and fight.lastEventEnded == push.event then
                    if (fight.specialsSinceEvent or 0) < (push.specials or 1) then
                        table.insert(lines, col(COL_SOON, formatStr("HOLD - let Telos do 3 autos + his special, then push to {}",
                            event.name)))
                    else
                        -- Autos already done since his last special carry over: each one
                        -- pushed late is one auto less before what comes after the font
                        local special = fight.now and fight.now.index and phase.specials[fight.now.index]
                        local since = ticks - (fight.now and fight.now.tick or ticks)
                        local first = specialTicks(special)
                        local autoTicks = fight.boss.autoTicks or 4
                        local cycleAutos = push.autos or 3
                        local used = since < first and 0 or math.min(cycleAutos, (since - first) // autoTicks + 1)
                        local left = cycleAutos - used
                        local text = formatStr("PUSH to {} NOW - {} HP to go", event.name, toGo)
                        if push.before then
                            text = text .. formatStr(" - {} autos before {}", left, push.before)
                        end
                        if used > 0 then
                            table.insert(lines, col(COL_SOON, text .. formatStr(" ({} used)", used)))
                        else
                            table.insert(lines, col(COL_GOOD, text))
                        end
                    end
                else
                    table.insert(lines, col(COL_SOON, formatStr("Upcoming: {} at {} ({} to go)", event.name, withCommas(at), toGo)))
                end
                break
            end
        end
    end

    if phase ~= nil and phase.timers and fight.phaseTimerStart and not fight.inTransition then
        for i, timer in ipairs(phase.timers) do
            if not fight.phaseTimersFired[i] then
                local seconds = math.max(0, math.ceil((fight.phaseTimerStart + timer.at - ticks) * SECONDS_PER_TICK))
                table.insert(lines, col(COL_SOON, formatStr("~{} in {}s", timer.attack, seconds)))
                break
            end
        end
    end

    -- Trigger countdown (e.g. Har-Aken submerging): shown until 5s past due
    local cd = fight.countdown
    if cd ~= nil and ticks <= cd.tick + 8 then
        local seconds = math.max(0, math.ceil((cd.tick - ticks) * SECONDS_PER_TICK))
        table.insert(lines, col(COL_SOON, formatStr("~{} in {}s", cd.name, seconds)
            .. (cd.note and ("  " .. col(COL_DIM, cd.note)) or "")))
    end

    if phase ~= nil and phase.cycle and fight.cycleNext ~= nil and not fight.inTransition then
        local seconds = math.max(0, math.ceil((fight.cycleNext - ticks) * SECONDS_PER_TICK))
        table.insert(lines, col(COL_SOON, formatStr("~{} in {}s", phase.cycle.name, seconds)))
    end

    -- A phase can override the boss's full-bar warning (false = none)
    local warning = fight.boss.barWarning
    if phase ~= nil and phase.barWarning ~= nil then warning = phase.barWarning end
    -- (not while NEXT already shows the release, e.g. SO. MUCH. POWER)
    if warning and fight.bar ~= nil and fight.bar >= warning.at and not fight.inTransition
        and fight.activeEvent == nil and not followUpActive() then
        table.insert(lines, col(COL_NOW, formatStr("Bar {}/{}: {}", fight.bar, warning.full, warning.text)))
    end

    -- (an alert that only repeats the active font line is skipped)
    local repeatsEvent = fight.alert ~= nil and fight.activeEvent ~= nil and fight.alert.attack == fight.activeEvent.def.alert
    if fight.alert ~= nil and ticks - fight.alert.tick < ALERT_TICKS and not repeatsEvent then
        table.insert(lines, col(COL_SOON, "! " .. fight.alert.attack) .. (fight.alert.note and (" - " .. fight.alert.note) or ""))
    else
        local timer, remaining = nextTimer()
        if timer ~= nil then
            table.insert(lines, col(COL_SOON, formatStr("~{} in {}s", timer.attack, math.max(0, math.ceil(remaining)))))
        end
    end

    body.content = table.concat(lines, "<br>")
end

------------------------------------------------------------------------
print("CH step: Buttons and keys")
-- Buttons and keys
------------------------------------------------------------------------

addButton(1, "Undo", function() undo() redraw() end)
addButton(2, "Next", function() manualNext() redraw() end)
addButton(3, "Phase+", function() nextPhase() redraw() end)
addButton(4, "Restart", function() restartFight() redraw() end)

-- EoF: the game only reports "Essence of Finality", not the spec stored in the
-- amulet (no API for item vars), so the player picks it here (saved)
local EOF_SPECS = {
    { label = "EoF: Grasp", name = "Death Grasp", stunTicks = 8, style = "necromancy" },
    { label = "EoF: none", name = "EoF (no stun)" },
}
local eofIndex = math.floor(tonumber(PersistentDB:Get("eofSpec")) or 1)
if EOF_SPECS[eofIndex] == nil then eofIndex = 1 end
eofSpec = EOF_SPECS[eofIndex]
local eofButton
eofButton = addButton(5, eofSpec.label, function()
    eofIndex = eofIndex % #EOF_SPECS + 1
    eofSpec = EOF_SPECS[eofIndex]
    PersistentDB:Set("eofSpec", eofIndex)
    eofButton.label = eofSpec.label
    print("Combat Helper: EoF holds " .. eofSpec.name)
end)

local KEY_ACTIONS = {
    [GameKey.PAGE_DOWN] = manualNext,
    [GameKey.PAGE_UP] = undo,
    [GameKey.END] = nextPhase,
    [GameKey.HOME] = restartFight,
}

local function onKeyDown(event)
    if not enabled or event.isRepeat or fight == nil then return end
    local action = KEY_ACTIONS[event.gameKey]
    if action ~= nil then
        action()
        redraw()
    end
end
Event.KeyDown.Subscribe("combatHelperKeys", onKeyDown)

------------------------------------------------------------------------
print("CH step: Game events")
-- Game events
------------------------------------------------------------------------

local scanForBoss -- defined with the on/off toggle below

-- The boss HP bar appearing (max HP var going from 0 to a value) is the exact
-- moment the fight starts. Watched every tick so the timer isn't late.
local lastBarMax = {}     -- boss -> last max HP value read
local barAppearTick = {}  -- boss -> tick the bar appeared

local function watchBossBars()
    for _, boss in ipairs(bosses) do
        local maxVar = boss.hp and boss.hp.maxVar
        if maxVar ~= nil then
            local maxHp = readVarValue(maxVar) or 0
            local previous = lastBarMax[boss]
            if previous ~= nil and previous <= 0 and maxHp > 0 then
                barAppearTick[boss] = ticks
                if fight == nil then scanForBoss() end
            end
            lastBarMax[boss] = maxHp
        end
    end
end

-- Line the new fight's clock up with the tick the boss bar appeared
local function alignFightStart()
    local appeared = fight and barAppearTick[fight.boss]
    if appeared == nil then return end
    local late = ticks - appeared
    if late > 0 and late <= 10 then
        fight.startTick = fight.startTick - late
        if fight.expectTick ~= nil then fight.expectTick = fight.expectTick - late end
        debugLog("PRED", formatStr("fight start aligned to boss bar ({} ticks earlier)", late))
    end
    barAppearTick[fight.boss] = nil
end


-- First auto of a firstHitSync phase: he walks a varying distance first, so
-- his first auto is the real start of the opener's autos. Seen as the player's
-- first HP drop from an auto, or the boss's autoVar transmit (1 tick before the
-- auto, also when it does 0 damage).
-- firstHitSync = N: an HP drop only counts at most N ticks after the expected
-- first auto (his first autos can do 0 damage: the drop seen is a later one)
markFirstAuto = function(autoTick, source)
    if not (fight.watchFirstHit and not fight.inTransition and fight.firstHitTick == nil
        and fight.activeEvent == nil) then return end
    local autoTicks = fight.boss.autoTicks
    if source == "hit" and type(fight.watchFirstHit) == "number" and fight.expectTick ~= nil and autoTicks ~= nil
        and autoTick > fight.expectTick - fight.nextAutos * autoTicks + fight.watchFirstHit then
        return
    end
    fight.firstHitTick = autoTick
    if autoTicks ~= nil then
        fight.expectTick = autoTick + fight.nextAutos * autoTicks
    end
    debugLog("PRED", formatStr("first auto of {} ({}) -> next special expected tick {}", currentPhase().name,
        source, expectText()))
end

-- Every auto seen from the boss's autoVar: his next special replaces one of
-- his autos, so it stays on their autoTicks rhythm. Snap the expected tick to
-- it (walking/stuns drift it). Not a count: autoVar misses ~1 in 6 autos,
-- so a missed one changes nothing here. Half a cycle off is ambiguous: kept
local function alignToAuto(autoTick)
    local autoTicks = fight.boss.autoTicks
    -- Only once two in a row are on the rhythm: after a font bomb or during
    -- Magic Onslaught it also comes 3 apart (2 fights: snapped 2-4 ticks early)
    local prev = fight.lastAutoVarAuto
    fight.lastAutoVarAuto = autoTick
    if prev == nil or autoTicks == nil or (autoTick - prev) % autoTicks ~= 0 or autoTick - prev > 3 * autoTicks then
        return
    end
    if fight.expectTick == nil or fight.expectTick == nil or fight.expectTick <= autoTick then return end
    if fight.inTransition or fight.activeEvent ~= nil or fight.holdForCycle or fight.waitBar
        or followUpActive() or fight.firstHitTick == autoTick or fight.hold ~= nil then return end
    -- autoVar also comes with his specials: the one just done isn't an auto
    if fight.lastSpecialTick ~= nil and autoTick - fight.lastSpecialTick <= 1 then return end
    local off = (fight.expectTick - autoTick) % autoTicks
    if off == 0 or off * 2 == autoTicks then return end
    local shift = off * 2 < autoTicks and -off or autoTicks - off
    fight.expectTick = fight.expectTick + shift
    debugLog("PRED", formatStr("auto at {} -> next special expected tick {} ({})", autoTick, expectText(), string.format("%+d", shift)))
end

-- HP event (e.g. Telos's font push). pushTick: when it really happened - the
-- font golems can be the first sign (HP display stuck above the threshold)
fireHpEvent = function(i, event, pushTick)
    fight.hpEventsFired = fight.hpEventsFired or {}
    fight.hpEventsFired[fight.phaseIndex .. ":" .. i] = true
    fight.activeEvent = { def = event, index = i, tick = pushTick }
    local late = ticks - pushTick -- ticks since the real push
    if event.hold then
        fight.holdForCycle = true -- no estimate this tick
        local f = followUpActive() and fight.followUp.hold and fight.followUp
        local due = (f and f.due) or fight.expectTick
        local pushDue = due and due + late -- due, seen from the push tick
        fight.activeEvent.autosLeft = pushAutosLeft(pushDue)
        -- Pushed right at the cut-off: live and recorded ticks differ by
        -- one there (fight at 100%: 2 before SMP was due -> live said 0,
        -- it was 1). Show both options
        local lateLeft = pushDue and pushAutosLeft(pushDue + 1 + math.min(fight.walkTicks or 0, 8))
        fight.activeEvent.autosLeftLate = (lateLeft and lateLeft > fight.activeEvent.autosLeft) and lateLeft or nil
        -- autoVar saw an auto land by the push tick that the time count misses
        -- (250%: auto on the push tick -> said 3, he did 2). Only ever lowers it:
        -- autoVar misses some autos
        local seen = 0
        for _, t in ipairs(fight.autoVarAutos or {}) do
            if t + 1 <= pushTick then seen = seen + 1 end
        end
        if not f and seen > 0 and fight.nextAutos ~= nil and fight.nextAutos - seen < fight.activeEvent.autosLeft then
            fight.activeEvent.autosLeft = math.max(0, fight.nextAutos - seen)
            fight.activeEvent.autosLeftLate = nil
        end
        -- Pushed again before any special since the last font bomb: his first auto
        -- after a bomb comes at +8, then every 4 (an auto counts 1+ tick before the
        -- push). 3 fights at 100%: push +14 -> 2 done, +15 -> 2 (player saw 2 hits),
        -- +17 -> 3
        if fight.lastEventEnded ~= nil and (fight.specialsSinceEvent or 0) == 0 and fight.lastBombTick ~= nil then
            local since = pushTick - fight.lastBombTick
            local autoTicks = fight.boss.autoTicks or 4
            local done = since >= 9 and (since - 9) // autoTicks + 1 or 0
            fight.activeEvent.autosLeft = math.max(0, (fight.lastBombLeft or 3) - done)
            fight.activeEvent.autosLeftLate = nil
        end
        if not f and fight.firstHitTick ~= nil and fight.firstHitTick <= pushTick and fight.boss.autoTicks ~= nil then
            -- Autos counted from his first hit (pushed before his first special).
            -- An auto only counts 2+ ticks before the push (4 fights: push at
            -- hit +2 -> 1 done, +5 -> 1, +6 -> 2, +8 -> 2+)
            local done = (pushTick - fight.firstHitTick + 2) // fight.boss.autoTicks
            fight.activeEvent.autosLeft = math.max(0, (fight.nextAutos or 3) - done)
            fight.activeEvent.autosLeftLate = nil
        elseif not f and fight.watchFirstHit and fight.firstHitTick == nil then
            -- Pushed before his first auto of the phase: all of them still to come
            fight.activeEvent.autosLeft = fight.nextAutos or 3
            fight.activeEvent.autosLeftLate = nil
        end
        fight.watchFirstHit, fight.firstHitTick = nil, nil
        if f then
            -- Pushed before the held release: it waits until after this font's bomb
            f.carried, f.autos, f.tick = true, fight.activeEvent.autosLeft, ticks
            f.autosLate = fight.activeEvent.autosLeftLate
        end
        debugLog("PRED", formatStr("pushed with {} autos left (due {}){}", fight.activeEvent.autosLeft,
            due or "?", late > 0 and formatStr(", {} ticks ago", late) or ""))
    end
    fight.alert = { attack = event.alert, note = event.note, tick = ticks }
    debugLog("PRED", formatStr("HP event '{}' at {} HP", event.name, fight.hp))
end

local function onServerTick()
    ticks = ticks + 1
    if not enabled then return end
    if fight ~= nil and fight.autoVarTick == ticks - 1 then
        markFirstAuto(ticks, "autoVar")
        alignToAuto(ticks)
    end
    -- Still held: the next special can't come sooner than a release next tick
    local hold = fight and fight.hold
    if hold and hold.untilTick >= ticks and fight.phaseIndex == hold.phase and not fight.inTransition
        and fight.expectTick ~= nil and fight.expectTick < ticks + 1 + hold.ticks then
        fight.expectTick = ticks + 1 + hold.ticks
    end
    watchBossBars()
    if fight ~= nil and barAppearTick[fight.boss] ~= nil then
        alignFightStart()
    end
    if fight == nil then
        -- NPCEntityAdded doesn't always fire for bosses (e.g. instance entry), so also scan
        if ticks % 5 == 0 then
            scanForBoss()
        end
        redraw()
        return
    end

    -- Teleported out (user: a teleport = left the encounter): the player moved
    -- further in one tick than any movement ability (Surge/Dive 10 tiles) AND
    -- ended up far from the boss. Telos moves you 54-78 tiles between his
    -- phase areas (all 5 slots), but you land next to him.
    local okPlayer, playerEntity = pcall(function() return Player.GetEntity() end)
    local pgrid = okPlayer and lookup(playerEntity, "coordGrid")
    local px, pz = pgrid and lookup(pgrid, "x"), pgrid and lookup(pgrid, "z")
    if type(px) == "number" and type(pz) == "number" then
        local jump = fight.playerX and math.max(math.abs(px - fight.playerX), math.abs(pz - fight.playerZ)) or 0
        fight.playerX, fight.playerZ = px, pz
        local fromBoss = fight.bossX and math.max(math.abs(px - fight.bossX), math.abs(pz - fight.bossZ)) or math.huge
        if jump > TELEPORT_TILES and fromBoss > TELEPORT_AWAY_TILES then
            print(formatStr("Combat Helper: teleported {} tiles - fight over", jump))
            debugLog("PRED", formatStr("player teleported {} tiles ({} from boss) -> end fight", jump, fromBoss))
            endFight()
            redraw()
            return
        end
    end

    -- NPCEntityRemoved reports a nil uid, so check directly that the boss is still there
    local bossNpc = NPCList.ByUID(fight.uid)[1]
    -- Ticks the boss spent walking since his last special: walking can hold
    -- his autos back (fight 9 at 100%: followed the player 10 ticks after the
    -- Weak bomb, no autos -> 3 left at the push, not 2)
    local grid = bossNpc and lookup(bossNpc, "coordGrid")
    local gx, gz = grid and lookup(grid, "x"), grid and lookup(grid, "z")
    if type(gx) == "number" and type(gz) == "number" then
        if fight.bossX ~= nil and (gx ~= fight.bossX or gz ~= fight.bossZ) then
            fight.walkTicks = (fight.walkTicks or 0) + 1
        end
        fight.bossX, fight.bossZ = gx, gz
        local size = lookup(lookup(bossNpc, "config"), "gridSize")
        if type(size) == "number" and size > 0 then fight.bossSize = size end
    end
    -- bossConfig triggers: the boss NPC changed form (e.g. Zuk standing up from
    -- his throne: config 28526 -> 28527)
    local configID = bossNpc and lookup(bossNpc, "configID")
    if type(configID) == "number" then
        if fight.bossConfig ~= nil and configID ~= fight.bossConfig then
            debugLog("PRED", formatStr("boss config {} -> {}", fight.bossConfig, configID))
            fireTriggers("bossConfig", configID)
            if fight == nil then return end
        end
        fight.bossConfig = configID
    end
    local bossName = bossNpc and lookup(bossNpc, "displayName")
    if type(bossName) ~= "string" or bossByNpcName[string.lower(bossName)] ~= fight.boss then
        if fight.endPendingTick == nil then fight.endPendingTick = ticks end
        -- It may have come back with a new uid (teleport / new form)
        for npcName, boss in pairs(bossByNpcName) do
            if boss == fight.boss then
                local found = NPCList.ByName(npcName)[1]
                if found ~= nil then
                    fight.uid = found.uid
                    fight.endPendingTick = nil
                    break
                end
            end
        end
    else
        fight.endPendingTick = nil
    end

    if fight.endPendingTick ~= nil and ticks - fight.endPendingTick > END_GRACE_TICKS then
        endFight()
        redraw()
        return
    end

    -- Boss HP from vars; phases with hpBelow switch on at that fraction of max HP (forward only)
    local hpConfig = fight.boss.hp
    if hpConfig ~= nil then
        local previousHp = fight.hp
        fight.hp = readVarValue(hpConfig.var)
        if previousHp ~= nil and fight.hp ~= nil and fight.hp < previousHp then fight.lastHpDropTick = ticks end
        fight.maxHp = hpConfig.maxVar and readVarValue(hpConfig.maxVar)
        -- refillPhase: a big HP jump up means the next phase started (e.g. Araxxor
        -- refills when you walk into the next area)
        local refillPhase = currentPhase() and currentPhase().refillPhase
        -- Not at fight start: the bar appears as 0 (or last fight's value) -> full
        local refilled = previousHp ~= nil and ticks - fight.startTick > 10
            and fight.hp ~= nil and fight.maxHp ~= nil and fight.maxHp > 0
            and fight.hp >= fight.maxHp and previousHp <= fight.maxHp * 0.9
        if refilled and fight.inTransition and currentPhase().resumeOnRefill then
            debugLog("PRED", formatStr("HP refilled {} -> {}: {} starts", previousHp, fight.hp, currentPhase().name))
            resumePhase()
        elseif refilled and refillPhase and not fight.inTransition then
            debugLog("PRED", formatStr("HP refilled {} -> {}: next phase", previousHp, fight.hp))
            enterPhase(refillPhase, true)
        end
        -- hpHeal triggers: HP going up by exactly that much in one tick (Araxxor's
        -- web shield heals 1,000 per tick)
        if previousHp ~= nil and fight.hp ~= nil and fight.hp > previousHp then
            for _, trigger in ipairs(fight.boss.triggers) do
                if trigger.hpHeal == fight.hp - previousHp
                    and (trigger.inPhase == nil or listHas(trigger.inPhase, fight.phaseIndex)) then
                    applyTrigger(trigger)
                end
            end
        end
        if fight.boss.phases ~= nil and fight.hp ~= nil and fight.hp > 0 and fight.maxHp ~= nil and fight.maxHp > 0 then
            local fraction = fight.hp / fight.maxHp
            for i = #fight.boss.phases, fight.phaseIndex + 1, -1 do
                local threshold = fight.boss.phases[i].hpBelow
                if threshold ~= nil and fraction <= threshold then
                    enterPhase(i, true)
                    break
                end
            end
        end
        if fight.enrage == nil and fight.maxHp ~= nil and fight.maxHp > 0 and fight.boss.enrageFromMaxHp then
            fight.enrage = fight.boss.enrageFromMaxHp(fight.maxHp)
        end
    end

    -- Player HP drops, tagged by what most likely caused them. The API has no
    -- hitmarks (no damage type), so: font drain / virus DoT / a special that just
    -- happened, else an auto whose style comes from the phase and distance
    -- (Telos: melee within 3 tiles, magic beyond). Many autos don't show at all
    -- (fully soaked, or healed the same tick), so this filters, it doesn't count.
    local lifePoints = readVarValue("LIFEPOINTS")
    local hitKind = nil
    if lifePoints ~= nil and fight.lastLifePoints ~= nil and lifePoints < fight.lastLifePoints
        and not fight.inTransition then
        local hits = fight.boss.hits or {}
        local hitPhase = currentPhase() or {}
        local dot = hits.dotVar and readVarValue(hits.dotVar.var)
        local dotLeft = dot and dot >= 0 and (math.floor(dot) >> hits.dotVar.shift) & ((1 << hits.dotVar.bits) - 1) or 0
        local now = fight.now
        local dist = nil
        local okMe, meEntity = pcall(function() return Player.GetEntity() end)
        local me = okMe and lookup(meEntity, "coordGrid")
        local mx, mz = me and lookup(me, "x"), me and lookup(me, "z")
        if type(mx) == "number" and type(mz) == "number" and fight.bossX ~= nil then
            local size = fight.bossSize or 1
            local function axis(p, lo)
                if p < lo then return lo - p elseif p > lo + size - 1 then return p - (lo + size - 1) end
                return 0
            end
            dist = math.max(axis(mx, fight.bossX), axis(mz, fight.bossZ))
        end
        if fight.activeEvent ~= nil then
            hitKind = "font"
        elseif dotLeft > 0 then
            hitKind = "virus DoT"
        elseif now ~= nil and not now.estimated and now.attack ~= nil and ticks - now.tick <= (hits.specialTicks or 3) then
            hitKind = "special " .. now.attack
        else
            local style = hitPhase.autoStyle or hits.autoStyle
            if style == "reach" then
                style = (dist ~= nil and dist > (hits.meleeReach or 1)) and "magic" or "melee"
            end
            fight.lastAutoStyle = style
            hitKind = (style or "?") .. " auto"
        end
        debugLog("HIT", formatStr("-{} {} (dist {}, {})", fight.lastLifePoints - lifePoints, hitKind,
            dist or "?", hitPhase.name or "?"))
    end

    -- First auto of a firstHitSync phase: the player's life points drop from an
    -- auto (not font drain, a virus DoT tick or a special)
    -- firstHitSync = N: only a hit at most N ticks after his expected first auto
    -- counts (his first autos can do 0 damage - the hit seen is then a later one)
    if hitKind ~= nil and string.find(hitKind, " auto", 1, true) then
        markFirstAuto(ticks, "hit")
    end
    fight.lastLifePoints = lifePoints

    -- HP events inside a phase (e.g. Telos's fonts in phase 4): when HP drops
    -- below the fraction the boss stops its rotation for the mechanic
    local hpPhase = currentPhase()
    if hpPhase ~= nil and hpPhase.hpEvents and fight.hp ~= nil and fight.maxHp ~= nil and fight.maxHp > 0
        and not fight.inTransition then
        fight.hpEventsFired = fight.hpEventsFired or {}
        for i, event in ipairs(hpPhase.hpEvents) do
            local key = fight.phaseIndex .. ":" .. i
            if not fight.hpEventsFired[key] and fight.hp / fight.maxHp <= event.hpBelow then
                fireHpEvent(i, event, ticks)
            end
        end
    end
    if fight.activeEvent ~= nil and ticks - fight.activeEvent.tick > (fight.activeEvent.def.maxTicks or 45) then
        fight.activeEvent = nil
    end

    -- Phase number kept in the upper bits of a var: its change is the exact
    -- moment the boss starts the new phase (end of the transition)
    local phaseVar = fight.boss.phaseVar
    if phaseVar ~= nil and fight.boss.phases ~= nil then
        local value = readVarValue(phaseVar.var)
        if value ~= nil and value >= 0 then
            local varPhase = (math.floor(value) >> phaseVar.shift) + 1
            if fight.lastVarPhase ~= nil and varPhase ~= fight.lastVarPhase then
                if varPhase > fight.phaseIndex then
                    enterPhase(varPhase, false)
                elseif varPhase == fight.phaseIndex and fight.inTransition then
                    resumePhase()
                end
            end
            fight.lastVarPhase = varPhase
        end
    end

    -- Boss bar (e.g. Telos's anima bar) from the low bits of a var
    local barVar = fight.boss.bar
    if barVar ~= nil then
        local value = readVarValue(barVar.var)
        if value ~= nil and value >= 0 then
            local previousBar = fight.bar
            local raw = math.floor(value)
            local scale = 1 << (barVar.bits or 16)
            fight.bar = raw % scale
            -- The bar resets when the upper bits (phase) change; that's not a special
            local upper = raw // scale
            local samePhaseBits = fight.barUpper == nil or fight.barUpper == upper
            fight.barUpper = upper
            local phase = currentPhase()
            local dropped = samePhaseBits and previousBar ~= nil and previousBar - fight.bar >= (barVar.dropToSync or 5)
            -- Font bomb from his bar (all 12 recorded Telos font bombs): siphoning
            -- raises it +10 every ~4 ticks. From a low bar the bomb comes
            -- bombRiseTicks after it starts rising (bar ~60), from a high bar
            -- bombFullTicks after it reaches 100
            local ev = fight.activeEvent
            if ev ~= nil and samePhaseBits and previousBar ~= nil and fight.bar > previousBar then
                if ev.def.bombRiseTicks and previousBar < 30 and ev.rose == nil then
                    ev.rose = ticks
                    ev.bombTick = ticks + ev.def.bombRiseTicks
                    debugLog("PRED", formatStr("{}: bar rising -> bomb expected tick +{}", ev.def.name, ev.def.bombRiseTicks))
                elseif ev.def.bombFullTicks and previousBar < 100 and fight.bar >= 100 then
                    ev.bombTick = ticks + ev.def.bombFullTicks
                    debugLog("PRED", formatStr("{}: bar full -> bomb expected tick +{}", ev.def.name, ev.def.bombFullTicks))
                end
            end
            -- A sudden drop means a bar-draining special started: sync to it
            if phase ~= nil and dropped and not fight.inTransition and not fight.waitBar then
                for i, special in ipairs(phase.specials) do
                    -- Exact step only: other drops (e.g. blocking a stream) aren't the special
                    if special.untilBarEmpty and previousBar - fight.bar == (special.barStep or 10) then
                        syncToSpecial(i)
                        break
                    end
                end
            end
            -- The draining special hits every autoTicks, taking barStep each time.
            -- It ends one hit after the bar falls below barStep (or at 0), or when
            -- no drain comes for over one auto. Not when the bar refills: the black
            -- stream on him adds +3/tick between hits and the onslaught goes on
            -- (2026-10-22 0% fight: 18->11, 20->10, 13->3, ->0, Stun +16 after the last)
            if fight.waitBar and phase ~= nil then
                local drainer = phase.specials[fight.now and fight.now.index or 0] or {}
                local step = drainer.barStep or 10
                local finished = false
                local lateBy = 0 -- ticks since his last hit, when the end is seen late
                if dropped then fight.barDrained, fight.lastBarDropTick = true, ticks end
                if fight.barDrained and fight.bar <= 0 then
                    finished = true
                elseif dropped and fight.bar < step then
                    fight.barEndTick = ticks + (fight.boss.autoTicks or 0)
                elseif fight.barDrained and fight.lastBarDropTick ~= nil
                    and ticks - fight.lastBarDropTick > (fight.boss.autoTicks or 4) + 1 then
                    finished = true
                    lateBy = ticks - fight.lastBarDropTick
                end
                if (fight.barEndTick ~= nil and ticks >= fight.barEndTick)
                    or (fight.now and ticks - fight.now.tick > (drainer.maxTicks or 60)) then
                    finished = true
                end
                -- No drain at all shortly after it started (bar too low): the special
                -- was instant, so the autos count from when it happened
                local noDrain = not fight.barDrained and fight.now
                    and ticks - fight.now.tick >= (drainer.noDrainTicks or 6)
                if noDrain then
                    fight.waitBar, fight.barEndTick = false, nil
                    setNext(fight.nextIdx, fight.nextAutos, fight.now.tick - ticks + (drainer.noDrainBase or 0))
                    debugLog("PRED", formatStr("no bar drain (bar {}) -> next {} after {} autos, expected tick {}",
                        fight.bar, phase.specials[fight.nextIdx].attack, fight.nextAutos, expectText()))
                elseif finished then
                    fight.waitBar, fight.barDrained, fight.barEndTick = false, false, nil
                    setNext(fight.nextIdx, fight.nextAutos, (drainer.afterBarTicks or specialTicks(nil)) - lateBy)
                    debugLog("PRED", formatStr("bar drained (bar {}) -> next {} after {} autos, expected tick {}",
                        fight.bar, phase.specials[fight.nextIdx].attack, fight.nextAutos, expectText()))
                end
            end
            -- barTarget: the special comes when the bar fills to that value
            -- (+barTargetTicks). Expected tick from the bar's fill rate since it
            -- last started rising; syncAtBar = crossing the value is the special
            if fight.barRise == nil or not samePhaseBits or (previousBar ~= nil and fight.bar < previousBar) then
                fight.barRise = { tick = ticks, bar = fight.bar }
            end
            if phase ~= nil and not fight.inTransition and previousBar ~= nil and samePhaseBits
                and fight.bar > previousBar then
                for i, special in ipairs(phase.specials) do
                    -- Not if a sharper signal already confirmed it (P5 virus DoT ~5 ticks earlier)
                    local confirmed = fight.now ~= nil and fight.now.index == i and not fight.now.estimated
                        and ticks - fight.now.tick < 15
                    if special.syncAtBar and special.barTarget ~= nil and not confirmed
                        and previousBar < special.barTarget and fight.bar >= special.barTarget then
                        debugLog("PRED", formatStr("bar reached {}: {}", special.barTarget, special.attack))
                        syncToSpecial(i)
                        break
                    end
                end
                local nextSpecial = phase.specials[fight.nextIdx]
                local target = nextSpecial and nextSpecial.barTarget
                if target ~= nil and not fight.waitBar then
                    local extra = nextSpecial.barTargetTicks or 0
                    local rise, elapsed = fight.bar - fight.barRise.bar, ticks - fight.barRise.tick
                    if fight.bar >= target then
                        if previousBar < target then fight.expectTick = ticks + extra end
                    elseif rise > 0 and elapsed >= 6 then
                        fight.expectTick = ticks + math.ceil((target - fight.bar) * elapsed / rise) + extra
                    end
                    if fight.boss.autoTicks ~= nil and fight.expectTick ~= nil then
                        fight.nextAutos = math.max(0, (fight.expectTick - ticks) // fight.boss.autoTicks)
                    end
                end
            end
        end
    end

    if fight.inTransition then
        local waited = ticks - fight.transitionTick
        local hpMoved = phaseVar == nil and fight.hp ~= nil and fight.transitionHp ~= nil and fight.hp < fight.transitionHp
        local phaseNow = currentPhase()
        local maxWait = (phaseNow and phaseNow.transitionTicks) or fight.boss.transitionTicks or 40
        if (hpMoved and not (phaseNow and phaseNow.resumeOnRefill)) or waited >= maxWait then
            resumePhase()
        end
    end

    -- Estimate the next special from attack timing; yells correct it
    if fight.boss.autoAdvance and fight.expectTick ~= nil and fight.nextIdx ~= nil and ticks >= fight.expectTick
        and not fight.holdForCycle then
        doSpecial(fight.nextIdx, true)
    end

    local cyclePhase = currentPhase()
    local cycle = cyclePhase and cyclePhase.cycle
    if fight.cycleNext ~= nil and cycle and ticks >= fight.cycleNext + (cycle.grace or 10) then
        -- Not seen (message missed): keep the countdown going from the expected time
        fight.cycleNext = fight.cycleNext + cycle.every
    end
    -- The boss stops its rotation for the cycle mechanic: a special due shortly
    -- before it waits until the cycle's message (which applies delayNext)
    fight.holdForCycle = (cycle ~= nil and fight.cycleNext ~= nil and fight.expectTick ~= nil
        and fight.expectTick > fight.cycleNext - (cycle.holdBefore or 0))
        or (fight.activeEvent ~= nil and fight.activeEvent.def.hold == true)
        or (fight.followUp ~= nil and fight.followUp.hold and followUpActive())

    if cyclePhase and cyclePhase.timers and fight.phaseTimerStart and not fight.inTransition then
        for i, timer in ipairs(cyclePhase.timers) do
            if not fight.phaseTimersFired[i] and ticks - fight.phaseTimerStart >= timer.at then
                fight.phaseTimersFired[i] = true
                fight.alert = { attack = timer.attack, note = timer.note, tick = ticks }
                if timer.countsAsSpecial then fight.pendingPhaseSpecial = { attack = timer.attack, at = fight.phaseTimerStart + (timer.countsAfter or 0) } end
                debugLog("PRED", formatStr("phase timer '{}'", timer.attack))
            end
        end
    end

    local elapsed = (ticks - fight.startTick) * SECONDS_PER_TICK
    for i, timer in ipairs(fight.boss.timers) do
        if not fight.timersFired[i] and elapsed >= timer.at then
            fight.timersFired[i] = true
            fight.alert = { attack = timer.attack, note = timer.note, tick = ticks }
        end
    end

    redraw()
end
Event.ServerLogic.Subscribe("combatHelperTick", onServerTick)

local function onNpcAdded(event)
    if not enabled then return end
    local npc = event.npcEntity
    local name = npc and lookup(npc, "displayName")
    -- New NPC entities can report a nil name; the periodic scan picks bosses up later
    if type(name) ~= "string" then return end
    local boss = bossByNpcName[string.lower(name)]
    if boss ~= nil then
        if fight == nil then
            if canStart(boss) then startFight(boss, npc) end
        elseif fight.boss == boss then
            -- Boss came back (teleport / phase change): keep the fight going
            fight.uid = npc.uid
            fight.endPendingTick = nil
        end
    end
    fireTriggers("npcAdded", name)
end
Event.NPCEntityAdded.Subscribe("combatHelperNpcAdded", onNpcAdded)

local function onNpcRemoved(event)
    if fight ~= nil and event.npcEntity.uid == fight.uid then
        fight.endPendingTick = ticks
    end
end
Event.NPCEntityRemoved.Subscribe("combatHelperNpcRemoved", onNpcRemoved)

local knownNpcUids = nil
local function scanNpcs()
    if fight == nil then knownNpcUids = nil return end
    local ok, list = pcall(function() return NPCList.All() end)
    if not ok or list == nil then return end
    local seen = {}
    for _, npc in ipairs(list) do
        local uid = lookup(npc, "uid")
        if uid ~= nil then
            seen[uid] = true
            if knownNpcUids ~= nil and not knownNpcUids[uid] then
                local name = lookup(npc, "displayName")
                if type(name) == "string" then fireTriggers("npcAdded", name) end
            end
        end
    end
    knownNpcUids = seen
end
Event.ServerLogic.Subscribe("combatHelperNpcScan", function() if enabled then scanNpcs() end end)

local recentLocs = {}
local function onLocAdded(event)
    if enabled and event.config ~= nil then
        table.insert(recentLocs, { name = event.config.configName, tick = ticks })
        if #recentLocs > 300 then table.remove(recentLocs, 1) end
        fireTriggers("locAdded", event.config.configName)
    end
end

-- Called each tick: a newly started fight replays recent objects to preFight triggers
local function replayPreFightLocs()
    if fight == nil or fight.preFightDone then return end
    fight.preFightDone = true
    for _, loc in ipairs(recentLocs) do
        if ticks - loc.tick <= 200 then
            for _, trigger in ipairs(fight.boss.triggers) do
                if trigger.preFight and trigger.locAdded and matches(loc.name, trigger.locAdded) then
                    applyTrigger(trigger)
                end
            end
        end
    end
end
Event.ServerLogic.Subscribe("combatHelperPreFightLocs", replayPreFightLocs)
Event.LocAdded.Subscribe("combatHelperLocAdded", onLocAdded)

-- Release animation of a held player (fight.hold): next special releaseTicks on
local function onLocAnimation(event)
    local hold = enabled and fight and fight.hold
    if not hold or hold.untilTick < ticks then return end
    local name = event.animation and lookup(event.animation, "configName")
    if name == nil or not matches(name, hold.anim) then return end
    hold.untilTick = -1 -- released: no more holding, no auto snap until the special
    if fight.phaseIndex ~= hold.phase or fight.inTransition or fight.expectTick == nil then return end
    fight.expectTick = ticks + hold.ticks
    debugLog("PRED", formatStr("released -> next {} expected tick {}", currentPhase().specials[fight.nextIdx].attack,
        expectText()))
    redraw()
end
Event.LocAnimation.Subscribe("combatHelperLocAnimation", onLocAnimation)

local function handleChatText(text)
    if not enabled then return end
    text = stripTags(text)
    local cyclePhase = fight and currentPhase()
    if cyclePhase and cyclePhase.cycle and cyclePhase.cycle.chat and matches(text, cyclePhase.cycle.chat) then
        fight.cycleNext = ticks + cyclePhase.cycle.every
    end
    for _, boss in ipairs(bosses) do
        local enrage = boss.enrageChat and string.match(text, boss.enrageChat)
        if enrage ~= nil then
            knownEnrage[boss] = tonumber(enrage)
            if fight ~= nil and fight.boss == boss then fight.enrage = tonumber(enrage) end
        end
    end
    for _, boss in ipairs(bosses) do
        if boss.startChat ~= nil and matches(text, boss.startChat) then
            if fight ~= nil and fight.boss == boss then
                restartFight()
            elseif fight == nil then
                startArmed[boss] = true
                scanForBoss()
            end
        end
    end
    if fight == nil then return end
    local ach = fight.boss.achievement
    if ach ~= nil then
        if ach.failChat and matches(text, ach.failChat) then
            achFail(fight.boss, "challenge wave failed")
        end
        if contains(text, "Oh dear, you are dead!") and ach.deathFailPhases
            and listHas(ach.deathFailPhases, fight.phaseIndex) then
            achFail(fight.boss, "died at Zuk")
            PersistentDB:Set(achKey(fight.boss) .. "_cp", 1)
        end
    end
    if contains(text, "Oh dear, you are dead!")
        or (fight ~= nil and contains(text, "You have killed") and (contains(text, fight.boss.name)
            or (fight.boss.killNames and matches(text, fight.boss.killNames)))) then
        endFight()
        return
    end
    if not syncSpecialFromChat(text) then
        fireTriggers("chat", text)
    end
end

local function onChatMessage(event)
    handleChatText(event.chatMessage)
    redraw()
end

local chatSubscribed = false
local function updateChatSubscription()
    if Plugin.HasPermission(PluginPermissions.chatAccess) then
        if not chatSubscribed then
            Event.ChatMessage.Subscribe("combatHelperChat", onChatMessage)
            chatSubscribed = true
            print("Combat Helper: chatAccess granted, boss yell triggers enabled")
        end
    else
        if chatSubscribed then
            Event.ChatMessage.Unsubscribe("combatHelperChat")
            chatSubscribed = false
        end
        print("Combat Helper: chatAccess not granted, reading boss yells from the chat window instead")
    end
end
updateChatSubscription()
------------------------------------------------------------------------
-- Chatbox reader: without chatAccess, read new lines from the chat window
-- interface (found with the recorder's UI scan) instead of the ChatMessage event
------------------------------------------------------------------------

local ChatReader = loadModule("chatreader")
local pollChat = ChatReader and ChatReader.Watcher() or function() return {} end

Event.ServerLogic.Subscribe("combatHelperChatPoll", function()
    local added = pollChat()
    if chatSubscribed or not enabled then return end -- ChatMessage event already delivers these
    for _, line in ipairs(added) do
        handleChatText(line)
    end
    if #added > 0 then redraw() end
end)

-- Also poll, in case granting a permission from the console doesn't fire the event
local permissionPollTicks = 0
Event.ServerLogic.Subscribe("combatHelperPermPoll", function()
    permissionPollTicks = permissionPollTicks + 1
    if not chatSubscribed and permissionPollTicks % 5 == 0 and Plugin.HasPermission(PluginPermissions.chatAccess) then
        updateChatSubscription()
    end
end)
Event.OptionalPermissionChanged.Subscribe("combatHelperPerm", function(event)
    if event.permissionName == "chatAccess" then
        updateChatSubscription()
    end
end)

-- Pick up a boss that's already in view
scanForBoss = function()
    for npcName, boss in pairs(bossByNpcName) do
        if fight == nil and canStart(boss) then
            local found = NPCList.ByName(npcName)
            if found[1] ~= nil then
                startFight(boss, found[1])
            end
        end
    end
end

------------------------------------------------------------------------
print("CH step: On/off toggle")
-- On/off toggle
------------------------------------------------------------------------

local function setEnabled(value)
    enabled = value
    PersistentDB:Set("enabled", enabled and 1 or 0)
    panel.hidden = not enabled
    toggleButton.label = enabled and "Combat Helper: ON" or "Combat Helper: OFF"
    if enabled then
        scanForBoss()
        redraw()
    else
        endFight()
    end
end

toggleButton:Subscribe(ui.Hook.ONBUTTONPRESSED, function() setEnabled(not enabled) end)
setEnabled(enabled)

------------------------------------------------------------------------
print("CH step: Player stuns")
-- Player stuns: a stun on a stunnable boss pauses its attack timer, so the
-- next special comes that much later. Seen via the JUST_USED_ABILITY var
-- (holds the ability's struct id; its COMBATV2_ABILITY_NAME param is the name).
------------------------------------------------------------------------

-- Stun length in ticks (runescape.wiki/w/Stun). Measured on Telos: Soul Strike
-- +4/+5 (fight 17)
local STUN_TICKS = {
    ["Soul Strike"] = 5,
    ["Impact"] = 3,
    ["Backhand"] = 3,
    ["Binding Shot"] = 2,
    ["Asphyxiate"] = 6,
    ["Flurry"] = 6,
    ["Greater Flurry"] = 6,
    ["Death Grasp"] = 8,
}
-- Ticks from cast to the stun landing (default 1). Death Grasp (EoF) hits on the cast tick
-- (fight 9: EoF +0 and Soul Strike +1 fit P2 Tendrils exactly, EoF +1 was 4 late)
local STUN_LAND_TICKS = {
    ["Death Grasp"] = 0,
}

local abilityNameCache = {}
local function abilityName(structId)
    if abilityNameCache[structId] == nil then
        local name = false
        pcall(function()
            local st = config.Struct.FromID(structId)
            name = st:GetParamValue(config.Param.COMBATV2_ABILITY_NAME) or false
        end)
        abilityNameCache[structId] = name
    end
    return abilityNameCache[structId] or nil
end

-- Player's combat style from the abilities they use: the struct name says it
-- (COMBATV2_ABILITY_ATTACK_SEVER, ..._NECROMANCY_SOUL_SAP). EoF specs only work
-- with a weapon of the same style (wiki), so Death Grasp needs Necromancy.
local STYLE_PREFIXES = {
    { "COMBATV2_ABILITY_ATTACK_", "melee" }, { "COMBATV2_ABILITY_STRENGTH_", "melee" },
    { "COMBATV2_ABILITY_MELEE_", "melee" }, { "COMBATV2_ABILITY_NECROMANCY_", "necromancy" },
    { "COMBATV2_ABILITY_RANGED_", "ranged" }, { "COMBATV2_ABILITY_MAGIC_", "magic" },
}
-- Any style can use these, so they say nothing
local STYLE_ANY = { "MAGIC_SURGE", "ATTACK_DIVE", "NECROMANCY_DARKNESS", "RANGED_ESCAPE", "ATTACK_BARGE" }
local styleCache = {}
local recentStyles = {}
local function noteAbilityStyle(structId)
    if styleCache[structId] == nil then
        local style = false
        pcall(function()
            local name = config.Struct.FromID(structId).configName
            if type(name) ~= "string" then return end
            for _, any in ipairs(STYLE_ANY) do
                if string.find(name, any, 1, true) then return end
            end
            for _, p in ipairs(STYLE_PREFIXES) do
                if string.sub(name, 1, #p[1]) == p[1] then style = p[2] return end
            end
        end)
        styleCache[structId] = style
    end
    local style = styleCache[structId]
    if style then
        table.insert(recentStyles, style)
        if #recentStyles > 5 then table.remove(recentStyles, 1) end
    end
end
-- Most used style of the last 5 attacking abilities (nil = none seen yet)
local function playerStyle()
    local counts, best = {}, nil
    for _, style in ipairs(recentStyles) do
        counts[style] = (counts[style] or 0) + 1
        if best == nil or counts[style] > counts[best] then best = style end
    end
    return best
end

local function onPlayerStun(name, stunTicks, landTicks)
    if fight == nil or not fight.boss.stunnable or fight.inTransition or fight.activeEvent ~= nil then return end
    if fight.expectTick == nil or fight.holdForCycle or fight.waitBar then return end
    local phase = currentPhase()
    -- e.g. Magic Onslaught: stunning him doesn't delay his next attack (wiki)
    local now = fight.now and fight.now.index and phase and phase.specials[fight.now.index]
    if now and now.noStunDelay and ticks - fight.now.tick < 30 then return end
    -- The stun lands the tick after the cast and holds him for stunTicks. He acts
    -- every autoTicks; only an action (auto or special) falling inside the stun is
    -- held until it ends, and the rest of his cycle shifts with it. A special due
    -- on the landing tick still goes off. Fits 4 Soul Strikes exactly (fights 17-18:
    -- 18 ticks early +4, 5 early +1, 1 early +0, P2 3 early +3)
    local autoTicks = fight.boss.autoTicks or 4
    local land = ticks + (landTicks or 1)
    if fight.expectTick <= land then return end
    local action = fight.expectTick - autoTicks * ((fight.expectTick - land - 1) // autoTicks)
    local shift = land + stunTicks - action
    if shift <= 0 then return end
    stunTicks = shift
    fight.expectTick = fight.expectTick + shift
    fight.lastStun = { tick = ticks, shift = shift, expect = fight.expectTick }
    fight.alert = { attack = formatStr("{} - +{} ticks", name, stunTicks), note = "Telos stunned", tick = ticks }
    debugLog("PRED", formatStr("player {} -> next {} expected tick {}", name,
        phase.specials[fight.nextIdx].attack, expectText()))
    redraw()
end

Event.VarTransmit.Subscribe("combatHelperAbility", function(event)
    if not enabled or fight == nil then return end
    local name = lookup(event.var, "configName")
    -- autoVar: sent the tick before each of his autos, even unchanged (0 -> 0).
    -- Also in the full var resend after some player abilities (NPCTARGET resent
    -- unchanged the same tick, 32 times in 3 fights, never an auto): decided on
    -- the next tick (onServerTick) once the whole tick's vars are in
    -- autosSinceSpecial: his autos since his last confirmed special (P1 -> P2 carry)
    if name ~= nil and fight.boss.autoVar ~= nil then
        if name == fight.boss.autoVar and fight.targetResendTick ~= ticks and fight.autoVarTick ~= ticks then
            fight.autoVarTick = ticks
            fight.autosSinceSpecial = (fight.autosSinceSpecial or 0) + 1
            -- One auto can send it twice (set, then cleared the next tick)
            local list = fight.autoVarAutos
            if list ~= nil and ticks + 1 >= fight.autoCountFrom and (#list == 0 or ticks - list[#list] > 2) then
                table.insert(list, ticks)
            end
        elseif name == "NPCTARGET" and event.newValue == event.oldValue then
            fight.targetResendTick = ticks
            if fight.autoVarTick == ticks then -- part of the resend, not an auto
                fight.autoVarTick = nil
                fight.autosSinceSpecial = math.max(0, (fight.autosSinceSpecial or 0) - 1)
                local list = fight.autoVarAutos
                if list ~= nil and list[#list] == ticks then table.remove(list) end
            end
        end
    end
    -- Var triggers: { var = "NAME", value = n } fires when the var changes to n
    -- (e.g. Araxxor's cocoon turns your torso into the cocoon model). Event-based:
    -- client vars (VarClient) can't be read by name on the live client
    if name ~= nil and event.newValue ~= event.oldValue then
        for _, trigger in ipairs(fight.boss.triggers) do
            if trigger.var == name and event.newValue == trigger.value
                and (trigger.inPhase == nil or listHas(trigger.inPhase, fight.phaseIndex)) then
                applyTrigger(trigger)
                redraw()
                if fight == nil then return end -- endFight trigger
            end
            -- varRise triggers: { varRise = "NAME", shift = s, bits = b } fires when
            -- that bit field of the var goes from 0 to non-zero (varbit layout from
            -- runescape-api-stubs csvs/VarPlayer.csv)
            if trigger.varRise == name and type(event.newValue) == "number"
                and (trigger.inPhase == nil or listHas(trigger.inPhase, fight.phaseIndex)) then
                local mask = (1 << (trigger.bits or 32)) - 1
                local function field(value)
                    if type(value) ~= "number" or value < 0 then return 0 end
                    return (math.floor(value) >> (trigger.shift or 0)) & mask
                end
                if field(event.oldValue) == 0 and field(event.newValue) > 0 then
                    debugLog("PRED", formatStr("{} bits {}+{} rose to {}", name, trigger.shift or 0, trigger.bits or 32,
                        field(event.newValue)))
                    applyTrigger(trigger)
                    redraw()
                    if fight == nil then return end
                end
            end
        end
    end
    if name == nil or not string.find(name, "JUST_USED_ABILITY", 1, true) then return end
    local value = event.newValue
    if type(value) ~= "number" or value <= 0 then return end
    noteAbilityStyle(value)
    local ability = abilityName(value)
    local stunTicks = ability and STUN_TICKS[ability]
    -- EoF: the spec picked with the EoF button (fight at 100%: EoF/Death Grasp at
    -- P1 +11 pushed Tendrils past the phase change -> P2 opened with Tendrils +16)
    if ability == "Essence of Finality" then
        stunTicks = eofSpec and eofSpec.stunTicks
        ability = eofSpec and eofSpec.name or ability
        -- Death Grasp only with a Necromancy weapon: fighting another style, the
        -- EoF holds that style's spec (melee fight 2026-10-21: 2 EoF uses in P1,
        -- Tendrils came on time with no delay)
        local style = playerStyle()
        if eofSpec and eofSpec.style and style ~= nil and style ~= eofSpec.style then
            debugLog("PRED", formatStr("EoF used while fighting {}: not {}, no stun", style, eofSpec.name))
            stunTicks = nil
        end
    end
    if stunTicks then onPlayerStun(ability, stunTicks, STUN_LAND_TICKS[ability]) end
end)

------------------------------------------------------------------------
print("CH step: Debug recorder (buttons to the right of the on/off toggle)")
-- Debug recorder (buttons to the right of the on/off toggle)
------------------------------------------------------------------------

local Recorder = loadModule("recorder")
if Recorder ~= nil then
    Recorder.Init({
        parent = root,
        x = MOVE_WIDTH + ROW_GAP + TOGGLE_WIDTH + ROW_GAP,
        y = 0,
        xPc = 0.0,
        yPc = 0.0,
        height = BUTTON_HEIGHT,
        getBoss = function()
            if fight == nil then return nil end
            return NPCList.ByUID(fight.uid)[1]
        end,
        snapshotVars = { "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO", "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO_2",
            "GWD2_SOLO_BOSS_TEMP_UNPROTECTED", "LIFEPOINTS" },
        bossNames = (function()
            local names = {}
            for _, boss in ipairs(bosses) do
                for _, name in ipairs(boss.npcNames or { boss.name }) do table.insert(names, name) end
            end
            return names
        end)(),
    })
    debugLog = function(category, text) Recorder.Log(category, text) end
    fightHook = function(started)
        if started then Recorder.FightStarted() else Recorder.FightEnded() end
    end
end

print("CH step: loaded OK")

function PluginShutdown()
    if Recorder ~= nil then Recorder.Shutdown() end
    PersistentDB:Set("enabled", enabled and 1 or 0)
    pcall(function() root:Destroy() end)
    for _, probe in pairs(probes) do pcall(function() probe:Destroy() end) end
end
