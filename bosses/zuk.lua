-- TzKal-Zuk, HARD MODE (waves 1-17 + Zuk)
-- Sources: https://runescape.wiki/w/TzKal-Zuk/Strategies, PvME hm-zuk guides,
--          HM run logs 1 (waves 1-7) and 2 (full kill, 21:43), 2026-10-21.
-- Zuk sits on his throne during waves 1-17, so tracking starts at wave 1:
-- phase 1 = waves (flame wall countdown), phase 2 = Zuk, phase 3 = conduits.
-- No enrage (user). 1.2M HP.
--
-- Tick notes: "+N" = ticks between chat lines in the logs. A dueIn trigger's
-- estimate lands 1 tick before ticks + dueIn (wall: due 80 -> estimate var +79),
-- so dueIn values are measured gap + 1.

local BURN = "Geothermal Burn"
local SEAR = "Sear"
local QUAKE = "Quake"
local EMPOWERED = "Empowered Magic"
local RAIN = "Igneous Rain"
local CHARGE = "Interrupt (Igneous Vengeance)"
local WALL = "Flame wall"
local FIREBALL = "Charged fireball"

-- Flame walls (waves). Wiki: not used in challenge waves or the Zuk fight.
-- Measured, logs 1+2 (all waves 1-17):
--   yell -> next yell 88 ticks (52.8s) while the timer runs
--   wave 1 start (BOSS_INSTANCE_TIMED_START), igneous waves 4/9/14 and the
--   waves after a challenge (6/11/16) reset it: wall at wave start +80/81
--   other waves: no reset, the timer carries on; challenge waves: no wall
-- Repeated igneous wave (damage threshold missed): unknown.
local YELL_FIRE = { "The skies burn!", "Flames consume you!", "Fall, and burn to ash!" }
local WALL_TICKS = 88
local WALL_RESET_TICKS = 81

-- Wave number = EGWD_FUL_BOSS_ENCOUNTER_PROGRESS: 2, 10, 18 ... (2 + 8 per wave,
-- 138 = wave 18), changes on the tick the wave starts
local WAVE_VAR = "EGWD_FUL_BOSS_ENCOUNTER_PROGRESS"
local IGNEOUS = { [4] = true, [9] = true, [14] = true }
local CHALLENGE = { [5] = true, [10] = true, [15] = true }
local JAD = { [6] = true, [11] = true, [16] = true }

-- Challenge waves: fail = "You have failed, as expected" (That's my seat). Tasks: wiki
local CHALLENGE_TASK = {
    [5] = "kill all 5 Volatile Hurs before their bars fill",
    [10] = "kill the Unbreakable Ket before its bar fills (3k+ hits only)",
    [15] = "take NO damage from the 3 Fatal Yt-Hurkots (Barricade)",
}

-- Har-Aken (wave 17). Wiki: head up ~40s, then submerged ~50-60s; hard mode:
-- 1 bombardment (+/X) while up, 2 while submerged, plus 3 single blobs.
-- Logs 2+3: killed 76 ticks after the wave started, still up (no NPCS~ form
-- change, no bombardment message) -> he's up longer than the wiki's 40s.
-- Test timer (user asked): 60s from his spawn (spawn = wave start +3 ticks,
-- logs 2+3). User reports the time left if he dives earlier.
local AKEN_UP_TICKS = 3 + 100

local function waveTriggers()
    local list = {}
    for wave = 2, 18 do
        local label = "Wave " .. wave
        if IGNEOUS[wave] then label = label .. " (igneous)"
        elseif CHALLENGE[wave] then label = label .. " (challenge)"
        elseif JAD[wave] then label = label .. " (Jad)"
        elseif wave == 17 then label = label .. " (Har-Aken)"
        elseif wave == 18 then label = label .. " (Zuk)" end
        local t = { var = WAVE_VAR, value = 2 + 8 * (wave - 1), inPhase = { 1 }, label = label }
        if CHALLENGE[wave] then
            t.banner = "CHALLENGE WAVE " .. wave .. ": " .. CHALLENGE_TASK[wave]
            t.bannerRed = true
        elseif CHALLENGE[wave + 1] then
            t.banner = "Next wave (" .. (wave + 1) .. ") is a CHALLENGE wave"
        elseif wave == 17 then
            t.countdown = { name = "Har-Aken submerges", ticks = AKEN_UP_TICKS, note = "(test: 60s)" }
        end
        if CHALLENGE[wave] then
            t.pause = "none in challenge waves"
        elseif wave == 18 then
            t.pause = "none in the Zuk fight"
        elseif IGNEOUS[wave] or CHALLENGE[wave - 1] then
            t.dueSpecial, t.dueIn = WALL, WALL_RESET_TICKS
        end
        table.insert(list, t)
    end
    -- Wave 1: the instance timer starts with it
    table.insert(list, { varRise = "BOSS_INSTANCE_TIMED_START", inPhase = { 1 }, label = "Wave 1",
        dueSpecial = WALL, dueIn = WALL_RESET_TICKS })
    return list
end

-- Zuk (log 2, 2 cycles): he attacks every 5 ticks; specials 15 apart (2 autos),
-- Empowered -> Rain 20 (3 autos) - the PvME "one auto fewer in hard mode" rotation.
-- Burn yell in game is "You will break beneath me." (period, wiki has "!").
-- Sear yell was "Burn!" once (also said after every Rain yell, so not used);
-- the searing-pain game message comes 1 tick after every Sear.
-- Rain yell -> "is charging a powerful attack. Interrupt it!" +83 / +82
-- (minions rise every 25 ticks). Interrupted (his pain lines) -> Burn +15.
-- Rain: he pulls you ~6 tiles and stuns you 4-5 ticks after the yell, his
-- "Burn!" 1 tick before ("You've been prevented from moving."; 4 Rains, logs 2+3)
local INTERRUPTED = { "Ungh. Not bad", "You dare...", "Gah! Lucky hit", "Gah! Treacherous dog",
    "Caught me off guard", "A coward's trick" }

local boss = {
    name = "TzKal-Zuk (HM)",
    npcNames = { "TzKal-Zuk" },
    killNames = { "TzKal-Zuk" },
    -- He sits on his throne in view before the run: start only on the session
    -- message ("Welcome to your session against: TzKal-Zuk (Hard Mode).", user)
    -- or his greeting "Interesting, you return." (user)
    startChat = { "Welcome to your session against: TzKal-Zuk", "Interesting, you return" },

    -- Flawless hard mode run: all 3 challenge waves (5, 10, 15) passed and Zuk
    -- killed in one attempt (no death -> checkpoint restart at wave 18)
    achievement = {
        name = "That's my seat",
        -- Only two ways to fail (user): a challenge wave failed (this shout) or
        -- any death. Other Zuk achievements failing don't matter.
        failChat = { "You have failed, as expected" },
        deathFailPhases = { 2, 3 },
    },

    autoTicks = 5,   -- measured, log 2 (wiki infobox says 1.8s)
    autoAdvance = true,
    -- Until the wave 1 timer var resyncs it (session msg -> wall: 84 ticks)
    startTicks = 84,

    hp = {
        var = "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO",
        maxVar = "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO_2",
    },

    phases = {
        {
            name = "Waves",
            specials = {
                { attack = WALL, autos = 0, duration = WALL_TICKS, chat = YELL_FIRE, detail = "every ~53s",
                  nowTicks = 10, -- fire spawns yell +0..+8 (log 1), then NOW goes blank
                  note = "Dodge the lava wall - leave the safespot if needed" },
            },
        },
        {
            name = "Zuk",
            specials = {
                -- autos = autos BEFORE this special
                { attack = BURN, autos = 2, chat = "You will break beneath me",
                  note = "Deflect Melee - Freedom right after the hit (bleed)" },
                { attack = SEAR, autos = 2, chat = { "Sear!", "Suffer!", "inflicts a searing pain" },
                  note = "Deflect Magic, Surge out + run to clear stacks" },
                { attack = QUAKE, autos = 2, chat = { "Tremble before me!", "Fall before my might!", "The earth yields to me!" },
                  note = "Surge/Dive past him after the sword hits" },
                { attack = EMPOWERED, autos = 2, chat = { "Die!", "Begone!", "Ful's flame burns within me!", "Ful's power flows through me!" },
                  note = "Resonance/Divert/Disruption Shield/Barricade" },
                { attack = RAIN, autos = 3, chat = YELL_FIRE, duration = 84,
                  note = "Pull + stun ~3s after the yell: Anticipation first (else Freedom). Then Hur -> Xil -> Mej" },
                -- Interrupt time is up to the player (7-10 ticks in log 2); his pain
                -- line resyncs Burn to +15
                { attack = CHARGE, autos = 0, chat = "is charging a powerful attack", duration = 13,
                  detail = "after the 3 igneous minions",
                  nowTicks = 15, note = "Spam the Igneous Vengeance button NOW" },
            },
        },
        {
            name = "Last stand (conduits)",
            hpBelow = 100000 / 1200000, -- entered at exactly 100,000 (log 2)
            transitionTicks = 1,
            -- No regular fireball signal in the log, so no countdown. Each conduit kill
            -- (Zuk -20k) -> "The conduit is superheated ..." -> charged fireball;
            -- C2 hit 11 ticks after its message (Disruption Shield, log 2)
            specials = {
                { attack = FIREBALL, autos = 0, noEstimate = true,
                  chat = "The conduit is superheated",
                  detail = "after each conduit kill (~6s after the warning)",
                  nowTicks = 12,
                  -- PvME necro guide
                  notes = { "Conduit 1: Disruption Shield", "Conduit 2: Resonance / Divert",
                      "Conduit 3: Reflect", "Conduit 4: Powerburst of vitality" } },
            },
        },
    },

    triggers = {
        -- Zuk stands up: "Perhaps you are worthy...to die by my blade!" -> Burn +15
        { chat = "Perhaps you are worthy", inPhase = { 1 }, phase = 2, noTransition = true,
          dueSpecial = BURN, dueIn = 16 },
        -- Same moment without chat: his NPC changes form as he stands (log 2: 28526 ->
        -- 28527 on the yell's tick). Whichever comes first switches the phase.
        { bossConfig = 28527, inPhase = { 1 }, phase = 2, noTransition = true,
          dueSpecial = BURN, dueIn = 16 },
        -- Fallback if both are missed: the Burn yell itself
        { chat = "You will break beneath me", inPhase = { 1 }, phase = 2, noTransition = true, special = BURN },
        -- Left the instance (backup for the teleport check in main.lua): boss
        -- instance var 45 -> 0 on the teleport tick (log 4, War's Retreat)
        { var = "BOSS_INSTANCE_CURRENT_BOSS", value = 0, endFight = true },
        -- Har-Aken's lava bombardment (wiki message; 1x while up, 2x submerged in HM)
        { chat = "bombarding you", inPhase = { 1 }, alert = "Lava bombardment",
          note = "Run 3+ tiles N/S/E/W (not diagonal)" },
        -- Rain's pull + stun is next tick
        { chat = "TzKal-Zuk: Burn!", inPhase = { 2 }, onlyAfter = RAIN, alert = "Pulled + stunned",
          note = "Freedom if you're stunned, then Deflect Magic" },
        -- Only right after the charge (same lines are said in igneous waves)
        { chat = INTERRUPTED, inPhase = { 2 }, dueSpecial = BURN, dueIn = 16, onlyAfter = CHARGE },
    },
}

for _, t in ipairs(waveTriggers()) do table.insert(boss.triggers, t) end

return boss
