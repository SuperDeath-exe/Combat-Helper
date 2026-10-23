-- Araxxor / Araxxi
-- Source: https://runescape.wiki/w/Araxxor/Strategies, https://runescape.wiki/w/Araxxor,
--         https://runescape.wiki/w/Transcript:Araxxor (game messages)
-- Not a fixed rotation: each special is random (never the same twice in a row),
-- but the number of autos before the next one depends on the last special:
-- "Araxxor's special attack triggers after four to seven auto-attacks, each
-- depending on which special attack was last used." So the panel shows WHEN the
-- next special comes and which ones are possible.
-- Untested in-game: only darkness has a sync message; the other specials need
-- signals found with the recorder.

local NOTE_COCOON = "Click 5x to break free (2 with Freedom/Anticipation) - defensives reset"
local NOTE_CLEAVE = "Move away or Freedom/Anticipation to avoid the drag - 4k+ hit"
local NOTE_WEB = "Web shield: Cease - damage is reflected, he heals 1k x5"
local NOTE_EGGS = "Egg bomb: lure it onto 4+ eggs/minions for no damage"
local NOTE_ACID = "Acidic spider: lure it under Araxxor before it fills yellow - one-shots"
local NOTE_MINIONS = "Minions: kill mirrorbacks first (immune + reflect), then pulsing (heal)"
local NOTE_DARK = "Darkness: stay in the spotlight"

-- autosAfter: autos before his next special (wiki)
-- Cleave and Web shield can't be seen by the plugin (animation only; the web
-- shield's +1k heals get cancelled by any hit). Press Page Down (or the Next
-- button) when you see either: both have 5 autos before his next special
local MANUAL = "Cleave / Web shield (key)"

local function specials()
    return {
        { attack = "Cocoon", autosAfter = 4, note = NOTE_COCOON },
        { attack = "Cleave", autosAfter = 5, note = NOTE_CLEAVE },
        { attack = "Web shield", autosAfter = 5, note = NOTE_WEB },
        { attack = "Egg bomb", autosAfter = 5, note = NOTE_EGGS },
        -- Path specials: the CLOSED path's one is never used (wiki: "The blocked path
        -- determines which two of the acidic spider, minions, and spotlight attacks are used")
        { attack = "Acidic spider", autosAfter = 7, note = NOTE_ACID, path = "acid" },
        { attack = "Minions", autosAfter = 5, note = NOTE_MINIONS, path = "minions" },
        { attack = "Darkness", autosAfter = 7, note = NOTE_DARK, path = "darkness" },
    }
end

return {
    name = "Araxxor",
    npcNames = { "Araxxor", "Araxxi" },
    killNames = { "Araxxi", "Araxxor" },
    -- Lanes 1-3 = minions, acid, darkness (object names SB_*_LANE_<n>A)
    paths = { "minions", "acid", "darkness" },

    autoTicks = 4,     -- 2.4s (wiki infobox). Faster in phase 3 - not measured yet
    -- A special takes 8 ticks before his autos resume (fight 3: cocoon 37 -> cocoon 90
    -- -> web shield 142 fit exactly with 8 + autos x 4 and one unseen special each gap)
    specialTicks = 8,
    autoAdvance = true,
    -- No phase var / HP var known yet: phase changes come from game messages and
    -- he attacks again shortly after (player walks through), so short transitions
    transitionTicks = 6,
    -- Stun immune (wiki), so player stuns don't delay him

    -- Boss bar HP - same vars as Telos's boss bar, assumed (check with the recorder).
    -- Phasing = get his HP low, then WALK into the next area: he refills and the
    -- next phase starts. Low HP alone does nothing, the spiders keep healing him.
    hp = {
        var = "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO",
        maxVar = "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO_2",
    },

    phases = {
        {
            name = "Phase 1",
            random = true,
            manualName = MANUAL,
            -- First special of the fight: after 1 to 5 autos, random (user; fight 1:
            -- 1 auto). Count to 5, show the range
            firstAutos = 5,
            firstAutosMin = 1,
            note = "Burn a web - path opens in ~1 min. Get him to ~10k, then walk through",
            -- Walking into the next area refills him to 100k = next phase. Every
            -- phase change in fight 1 was a refill to 100k (P2, P3, Araxxi)
            refillPhase = 2,
            lowHpHint = { below = 10000, text = "HP low - walk into the next area to phase him" },
            specials = specials(),
        },
        {
            name = "Phase 2",
            random = true,
            manualName = MANUAL,
            firstAutos = 4,
            note = "Path phase - get him to ~10k, then move on",
            -- Refilled to 100k at P3 too (fight 1, acid path) - the wiki says it carries over
            refillPhase = 3,
            lowHpHint = { below = 10000, text = "HP low - move on to the next area" },
            -- Minions path: P3 trigger area is a straight walk, no damage needed (user;
            -- fight 2: P3 14 ticks into P2 at 85k)
            pathNotes = { minions = "Minions path: walk on to start P3 any time - no damage needed" },
            specials = specials(),
        },
        {
            name = "Phase 3",
            random = true,
            manualName = MANUAL,
            firstAutos = 4,
            note = "Faster attacks. Kill him - Araxxi comes next",
            refillPhase = 4, -- Araxxi spawns with 100k (fight 1; fight 3 from 0 HP)
            specials = (function()
                local list = specials()
                -- Highly acidic spiders (wiki: 5 autos after). Need the acid path OPEN in
                -- the rotation, not taken (user; fight 1 took minions, acid open)
                table.insert(list, { attack = "Highly acidic spider", autosAfter = 5, path = "acid",
                    chat = "A highly acidic spider appears nearby", note = "Lure it under Araxxor or ignore (low enrage)" })
                return list
            end)(),
        },
        {
            name = "Phase 4 (Araxxi)",
            random = true,
            manualName = MANUAL,
            -- "heads over to the final platform" starts the cutscene; Araxxi spawning
            -- (HP -> 100k, ~32 ticks later in fights 2-3) ends it
            transitionTicks = 60,
            resumeOnRefill = true,
            firstAutos = 4,
            -- Wiki gives no timing for Araxxi: Araxxor's counts assumed. Cleave is
            -- her most common special; path special by priority acid > minions > darkness
            note = "Stand 4-5 tiles away. 50k HP: she stops specials, enrage climbs. 25k: adren halved",
            specials = {
                { attack = "Cleave", autosAfter = 5, note = NOTE_CLEAVE },
                { attack = "Web shield", autosAfter = 5, note = NOTE_WEB },
                { attack = "Cocoon", autosAfter = 4, note = NOTE_COCOON },
                -- Fight 1 (minions path, acid open): "Araxxi absorbs some of the left over
                -- acid." Assumed to need acid open too, like the P3 spiders
                { attack = "Absorb acid", autosAfter = 5, chat = "absorbs some of the left over acid", path = "acid",
                    note = "Boosted damage while affected" },
                { attack = "Minions", autosAfter = 5, note = NOTE_MINIONS, path = "minions" },
                { attack = "Darkness", autosAfter = 7, note = NOTE_DARK, path = "darkness" },
            },
        },
    },

    triggers = {
        { chat = "You enter the den", restart = true },
        { chat = "Welcome to your session against: Araxx", restart = true },
        -- Phase changes: his HP refilling to 100k (refillPhase) is the main signal;
        -- messages as backup
        { chat = "The spiders above are watching Araxxor", inPhase = { 1 }, phase = 2 },
        { chat = "take note of Araxxor's health and prepare to heal", inPhase = { 1, 2 }, phase = 3 },
        { chat = "flees to the next area", inPhase = { 1, 2 }, phase = 3 },
        -- Cutscene: no attacks until Araxxi spawns (~32 ticks, her HP refill ends it)
        { chat = "Araxxor heads over to the final platform", phase = 4, alert = "Araxxi next", note = "Cutscene - she spawns in ~19s" },
        { chat = "The web burns down", alert = "Path open", note = "Get him low, then walk through" },
        -- Open paths have a burnable web (fight 1: NE by lane 1, E by lane 2; lane 3
        -- closed had none). They spawn before Araxxor is tracked -> preFight
        { locAdded = "SB_WEB_BURN_NE", openPath = "minions", preFight = true },
        { locAdded = "SB_WEB_BURN_E", openPath = "acid", preFight = true },
        -- Web you lit = your path
        { locAdded = "SB_WEB_DOOR_LANE_1A_ONFIRE", path = "minions", alert = "Minions path" },
        { locAdded = "SB_WEB_DOOR_LANE_2A_ONFIRE", path = "acid", alert = "Acid path" },
        { locAdded = "SB_WEB_DOOR_LANE_3A_ONFIRE", path = "darkness", alert = "Darkness path" },
        -- Paths
        { chat = "blocking out the light", alert = "Darkness path", note = "Charges: watch his legs for the swipe direction" },
        { chat = "come down from the ceiling and charge", alert = "Charge!", note = "Dodge so he smashes the wall" },
        { chat = "smashes into the wall, damaging it", alert = "Wall damaged" },
        { chat = "acid on Araxxor drips", alert = "Acid platform", note = "Platform degrades - don't linger in noxious acid" },
        { chat = "becomes noxious", alert = "Move on!", note = "Noxious acid - leave the area" },
        -- Specials with a message
        { chat = "plunges the area into temporary darkness", special = "Darkness" },
        { chat = "A highly acidic spider appears nearby", alert = "Highly acidic spider", note = "Lure it under Araxxor or ignore (low enrage)" },
        { chat = "Araxxor absorbs the highly acidic spider", alert = "Acid absorbed", note = "Heals 5k" },
        -- Cocoon: your torso turns into the cocoon model (kit 3199) the tick it lands,
        -- back when you break free (fight 1: 46-52, 136-141)
        { var = "PLAYER_KIT_TORSO_CLIENT", value = 3199, special = "Cocoon" },
        -- Minions: Imbued/Bladed/Mirrorback/Spitting spiders spawn 3 ticks apart in
        -- waves (fight 2: P3 163-175 and 205-217, Araxxi 291-303). First spawn = the special
        { npcAdded = { "Imbued spider", "Bladed spider", "Mirrorback spider", "Spitting spider", "Pulsing spider" },
            special = "Minions", cooldown = 45 },
        -- Web shield: he heals exactly 1,000 per tick (5 heals; a hit on the same tick
        -- cancels one). Fight 3: +1000 at 142, 151, 154 (user)
        { hpHeal = 1000, special = "Web shield", cooldown = 20 },
        -- Egg bomb: 3 egg objects (fight 1, P2)
        { locAdded = "SB_2014_SPIDER_EGG_SPAWN", special = "Egg bomb", cooldown = 10 },
        { chat = "refuse to allow Araxxor to die", alert = "Spiders heal him 5k" },
        { chat = "run out of energy to heal Araxxor", alert = "Healing buff over" },
        { chat = "putrid acid wave", alert = "Acid wave", note = "Stand still, step 1 tile when it hits" },
        -- 50k: she stops using specials, enrage climbs
        { chat = "Araxxi starts to get enraged", alert = "Araxxi enraged", note = "No more specials - burn her", endRotation = true },
    },
}
