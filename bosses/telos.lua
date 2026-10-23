-- Telos, the Warden
-- Source: https://runescape.wiki/w/Telos,_the_Warden/Strategies (attack rotation per phase)
--         https://runescape.wiki/w/Transcript:Telos,_the_Warden (yells)
-- Note: the wiki strategy page is flagged as possibly outdated after the
-- March 2026 Combat Style Modernisation update.

local TENDRILS = "Tendrils (Grip)"
local UPPERCUT = "Uppercut"
local STUN = "Stun"
local ONSLAUGHT = "Magic Onslaught"
local BLACK_VIRUS = "Black Virus"
local RED_VIRUS = "Red Virus"
local WEAK_BOMB = "Weak anima bomb"
local GOLEMS = "Golem spawn"
local RANDOM_VIRUS = "Virus (random colour)"
local ANIMA_BOMB = "Anima bomb (instant kill)"

local YELL_TENDRILS = { "Your anima will return to the source!", "break Telos's grip" }
local YELL_UPPERCUT = "Gielinor, give me strength!"
local YELL_STUN = "Hold still, invader."

local NOTE_TENDRILS = "Use a threshold to avoid the heal + adren drain"
-- Grip holds you until you deal enough damage (or 15 s, wiki) and his autos wait:
-- the next special comes 13 ticks after the tendrils' end animation (4 fights,
-- release at yell +3 to +6 -> Uppercut +16 to +19, all release +13 in the log;
-- 14 in the plugin's ticks: loc events come before its tick counter moves)
local GRIP_RELEASE = { releaseAnim = "GWD2_SOLO_BOSS_TENTACLES_END", releaseTicks = 14, maxHoldTicks = 28 }
local NOTE_UPPERCUT = "Surge/Escape/Barge/Dive 1 tick after the text disappears"
local NOTE_STUN = "Freedom/Anticipation before, Resonance/Divert after"

-- Magic Onslaught drains his anima bar (-10 every 4 ticks); it ends one hit
-- after the bar drops below 10, then 3 autos (measured: end -> next special
-- = 16 ticks, in two fights: bar 38->0 and 32->2)
local phase2 = {
    {
        -- With a near-empty bar (stream blocked) nothing drains: instant (fight 7: +12 to Stun)
        -- Wiki: stunning him during the onslaught doesn't delay his next attack
        attack = ONSLAUGHT, autos = 3, untilBarEmpty = true, barStep = 10, afterBarTicks = 4, noDrainTicks = 6,
        noStunDelay = true,
        noDrainBase = 4, -- measured Onslaught -> Stun with no drain: 13-17 ticks (3 fights)
        note = "Block black stream only if his bar is low, else defensives",
    },
    -- P2 specials take longer: Stun -> Uppercut +20 (fights 11, 15, 17), Uppercut -> Tendrils +21
    { attack = STUN, autos = 3, chat = YELL_STUN, note = NOTE_STUN, duration = 8 },
    -- Instant cast: Black Virus -> Uppercut +13 = 1 + 3 autos (fight at 100%: Stun 153,
    -- virus ~173, Uppercut 186)
    { attack = BLACK_VIRUS, autos = 3, minEnrage = 51, duration = 1, note = "Intercept the black stream" },
    { attack = UPPERCUT, autos = 3, chat = YELL_UPPERCUT, note = NOTE_UPPERCUT, duration = 8 },
    { attack = TENDRILS, autos = 3, chat = YELL_TENDRILS, note = NOTE_TENDRILS },
}
local PHASE2_GRIP = 5

return {
    name = "Telos",
    npcNames = { "Telos, the Warden", "Telos" },

    autoTicks = 4,      -- Telos attacks every 4 ticks (2.4s)
    -- Sent the tick before his autos, also 0-damage ones: first transmit after a
    -- phase start = first auto - 1 in all 8 phase starts (3 fights, 2026-10-22).
    -- Undocumented (seasonal-looking name): HP drop stays the fallback
    autoVar = "TRH22_TEMP_VARP_UNPROTECTED",
    -- Not stun immune: a player stun delays his next special by its length
    -- (wiki; Soul Strike +5 measured). At 150%+ enrage he breaks free (stunBroken
    -- trigger below).
    stunnable = true,
    -- Measured from recordings: a special takes ~6 ticks before autos resume
    -- (special-to-special with 3 autos = 18-19 ticks). The fight opens with
    -- 7 autos then Tendrils, ~30 ticks after the boss bar appears (2 + 7 x 4).
    specialTicks = 6,
    -- Tendrils yell at boss bar +29 live in all 5 fights at 100% (+30 was 1 late:
    -- harmless alone, but it put a P1 Death Grasp an auto off - slots 3/4)
    startTicks = 1,
    autoAdvance = true, -- estimate specials from timing when there's no yell
    -- Phase number lives in bits 21+ of this var (0x00, 0x20, 0x40, 0x60 ...).
    -- It changes when Telos starts the new phase, i.e. the end of the transition.
    phaseVar = { var = "GWD2_SOLO_BOSS_TEMP_UNPROTECTED", shift = 21 },
    -- The anima bar over his head is in the low 16 bits of the same var
    bar = { var = "GWD2_SOLO_BOSS_TEMP_UNPROTECTED", bits = 16, dropToSync = 5 },
    -- When the bar hits 100 Telos yells "SO. MUCH. POWER!" and releases it (bar -> 0).
    -- Phase 4+ only; P1-P3 override it (barWarning in the phase)
    barWarning = { at = 80, full = 100, text = "SO. MUCH. POWER at full - defensive ready" },
    -- Player hit tagging (main.lua). No damage-type API, so autos are tagged by the
    -- wiki's styles: P1/P4 melee within 3 tiles ("range of three tiles") else magic,
    -- P2 melee, P3/P5 magic (autoStyle per phase). Virus DoT = stubs varbit
    -- GWD2_SOLO_EXPLODING_DOT_ITERATIONS (bits 7-13 of GWD2_SOLO_BOSS_TEMP_1).
    hits = {
        autoStyle = "reach",
        meleeReach = 3,
        dotVar = { var = "GWD2_SOLO_BOSS_TEMP_1", shift = 7, bits = 7 },
    },
    -- Fallback if the phase var never changes: give up waiting after this many ticks
    transitionTicks = 40,

    -- Enrage from the session message, or from max HP (400k at 0%, +1k per 1%)
    enrageChat = "begin the fight at (%d+)%% enrage",
    enrageFromMaxHp = function(maxHp) return math.max(0, (maxHp - 400000) / 1000) end,

    -- Boss HP from the boss bar vars (found with the recorder). Phases with
    -- hpBelow switch on when HP / max HP drops to that fraction:
    -- 75% / 50% / 25% match the wiki's phase caps at every enrage.
    hp = {
        var = "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO",
        maxVar = "ACTIVITY_PROGRESS_BAR_ACTIVE_INFO_2",
    },

    phases = {
        {
            name = "Phase 1",
            barWarning = false,
            specials = {
                { attack = TENDRILS, autosFirst = 7, autos = 3, chat = YELL_TENDRILS, note = NOTE_TENDRILS,
                    releaseAnim = GRIP_RELEASE.releaseAnim, releaseTicks = GRIP_RELEASE.releaseTicks,
                    maxHoldTicks = GRIP_RELEASE.maxHoldTicks },
                { attack = UPPERCUT, autos = 3, chat = YELL_UPPERCUT, note = NOTE_UPPERCUT },
                { attack = STUN, autos = 3, chat = YELL_STUN, note = NOTE_STUN },
            },
        },
        {
            name = "Phase 2",
            autoStyle = "melee", -- he chases you
            hpBelow = 0.75,
            -- No SO. MUCH. POWER in P2: a full bar means he keeps casting Magic
            -- Onslaught until it's drained (fight 15: bar 100 after Tendrils)
            barWarning = { at = 80, full = 100, text = "Magic Onslaught until the bar drains - block the black stream / defensives" },
            -- After the phase flag flips Telos needs ~16 ticks before his first attack
            -- (4 fights 2026-10-22: +16 x3, +20; older notes said +11)
            resumeTicks = 16,
            -- His first auto varies: flag +16 in 3 fights (2026-10-22). Resync on the
            -- player's first HP drop, only if within 3 ticks of the expected first
            -- auto (fight 3: first autos did 0 damage, the drop was his 3rd)
            firstHitSync = 3,
            specials = phase2,
            -- Opening special depends on the last special of phase 1. Wiki: "if Telos
            -- had not finished its auto-attacks in Phase 1, then it will continue
            -- those" - 3 autos between the specials in total (7 before his first P1
            -- special), done ones carry over (carryAutos, main.lua).
            -- Measured: flag + 11 + 4 per auto left (Onslaught after 3 left: +23;
            -- Tendrils with ~1 left: +16 in 3 fights -> extraTicks 1)
            openers = {
                -- Tendrils within 3 ticks of the phase change (grip still on): Onslaught
                -- at flag +31, not +23 (2 fights at 100%, both from his bar draining)
                [TENDRILS] = { step = 1, autos = 3, carryAutos = true, recentExtraTicks = 8 },
                [UPPERCUT] = { step = 2, autos = 3, carryAutos = true },
                [STUN] = { step = PHASE2_GRIP, autos = 3, carryAutos = true, extraTicks = 1 },
                none = { step = PHASE2_GRIP, autos = 7, carryAutos = true, extraTicks = 1 },
            },
        },
        {
            name = "Phase 3",
            autoStyle = "magic",
            hpBelow = 0.50,
            barWarning = false, -- not seen to release at full in P3
            -- Rotation opener lands at phase flag + 44 = 4 + 10 autos (5 fights)
            resumeTicks = 4,
            -- Every P3 start (5 fights): red stream at flag +21, lands ("drains your
            -- prayer and adrenaline") at +40. Not part of the rotation.
            timers = {
                -- Counts as Telos's last special: if P3 ends before his next special,
                -- phase 4 opens with Stun (wiki table, 3 fights)
                -- notAfter: not after a P2 Onslaught - P3 then opens with its own Virus
                -- (PvME map); if P3 ends before it, P4 opens with Weak anima bomb
                -- (fight 9 at 100%: P3 42 ticks, no special -> Weak bomb; fight 5:
                -- Virus done -> Stun)
                -- Counts once it's done (+44): P3 ended at +42 after a P2 Onslaught -> P4
                -- opened with Weak bomb (fight 9); +50 -> Stun (fight 5); 5 fights after a
                -- P2 Stun with P3 +49..61 -> Stun
                { at = 21, attack = RED_VIRUS, note = "Stand in the red stream to block it", countsAsSpecial = true,
                    countsAfter = 44 },
                -- Second red stream at +54..56 whenever P3 lasts that long (3 fights). Not
                -- a rotation special (fight 11: 12 ticks after Uppercut) and doesn't
                -- change the P4 opener
                { at = 55, attack = RED_VIRUS, note = "Stand in the red stream to block it" },
            },
            note = "Anima-golems charge his bar",
            specials = {
                -- 100% fight 11: Red Virus opener +44 -> Uppercut +57 = 1 + 3 autos (the
                -- 11 was measured at 0%, where the virus doesn't appear)
                { attack = RED_VIRUS, autos = 3, duration = 11, enrageDuration = { at = 50, duration = 1 },
                    note = "Stand in the red stream to block it" },
                { attack = UPPERCUT, autos = 3, chat = YELL_UPPERCUT, note = NOTE_UPPERCUT },
                { attack = STUN, autos = 3, chat = YELL_STUN, note = NOTE_STUN },
            },
            -- First rotation special depends on the last P2 special (wiki table,
            -- confirmed: Tendrils -> Stun at +44, Stun/Uppercut -> Uppercut at +56/+57,
            -- after the phase-start Red Virus lands)
            openers = {
                [TENDRILS] = { step = 3, autos = 10 },
                [STUN] = { step = 2, autos = 10, extraTicks = 12 },
                -- fight 11: last P2 Uppercut -> P3 Uppercut at flag +44 (old note said +57)
                [UPPERCUT] = { step = 2, autos = 10 },
                [BLACK_VIRUS] = { step = 2, autos = 10, extraTicks = 12 },
                [ONSLAUGHT] = { step = 1, autos = 10 },
            },
        },
        {
            name = "Phase 4",
            hpBelow = 0.25,
            -- Measured: first special 28-30 ticks after the phase flag (Telos goes to a font first)
            resumeTicks = 17,
            -- His walk to you varies: first auto at flag +16 / +22 (100% fights).
            -- Resync on the player's first HP drop; a pure-font push before his
            -- first special counts autos from it (fight 1: 1 done -> +12, fight 2: 3 done -> +8)
            firstHitSync = true,
            -- Fonts: at 75% / 50% / 25% of phase 4's HP (= 18.75% / 12.5% / 6.25% of max)
            -- Telos stops attacking, walks to the font and siphons it. Drain the font
            -- before his bar fills or the bomb one-shots you. Measured (fight 5):
            -- threshold -> "preparing to fire an anima bomb" = 25-27 ticks.
            -- Bomb timing (main.lua): fixed bombTicks after the push, replaced by
            -- the bar - first rise +20 from a low bar (pure/corrupted: 7 of 8 within
            -- 1 tick), bar 100 +11 (volcanic: +9..+13) - then the "defy" yell (+4)
            hpEvents = {
                { hpBelow = 0.1875, name = "Pure font", alert = "PURE FONT - drain it now!", bombTicks = 26, bombRiseTicks = 20, bombFullTicks = 11, hold = true,
                    note = "Stand at the font and drain it before his bar fills" },
                -- Ideal: after the pure font, let Telos do 3 autos + his special, then
                -- push to the volcanic font so 3 autos come before SO. MUCH. POWER
                -- (time for defensives to come off cooldown)
                { hpBelow = 0.125, name = "Volcanic font", alert = "VOLCANIC FONT - drain it now!", bombTicks = 26, bombRiseTicks = 20, bombFullTicks = 11, hold = true,
                    note = "Stand at the font and drain it before his bar fills",
                    -- Push right after his special: autos he gets before the push are
                    -- taken off the 3 before SO. MUCH. POWER (fight 8: pushed after 1 auto -> 2)
                    pushAfter = { event = 1, specials = 1, autos = 3, before = "SO. MUCH. POWER" },
                    -- His bar is full after this font: SO. MUCH. POWER takes his next
                    -- special slot (autos left from the push, see main.lua). Pushed into
                    -- the corrupted font first: it waits until after that bomb.
                    afterSpecial = "SO. MUCH. POWER",
                    -- SO. MUCH. POWER replaces his next special: wait for it (6 fights:
                    -- volcanic bomb -> SO. MUCH. POWER +16, next special 13 after that)
                    afterHold = true },
                { hpBelow = 0.0625, name = "Corrupted font", alert = "CORRUPTED FONT - drain it now!", bombTicks = 26, bombRiseTicks = 20, bombFullTicks = 11, hold = true,
                    note = "Stand at the font and drain it before his bar fills" },
            },
            note = "Fonts: pure -> volcanic -> corrupted",
            -- Rotation Stun -> Uppercut -> Weak bomb. Opener depends on the last P3
            -- special (wiki table, matched all 6 recorded fights)
            specials = {
                { attack = STUN, autos = 3, chat = YELL_STUN, note = NOTE_STUN },
                { attack = UPPERCUT, autos = 3, chat = YELL_UPPERCUT, note = NOTE_UPPERCUT },
                { attack = WEAK_BOMB, autos = 3, chat = "Let the anima consume you!" },
            },
            -- PvME attack-pattern map agrees (Virus -> Hold Still, Uppercut -> Uppercut,
            -- Hold Still -> Weak bomb). P2 Onslaught + no P3 special -> Weak bomb (1 fight)
            openers = {
                [UPPERCUT] = 2,
                [STUN] = 3,
                [RED_VIRUS] = 1,
                [ONSLAUGHT] = 3,
            },
        },
        {
            name = "Phase 5",
            autoStyle = "magic",
            minEnrage = 100,
            note = "100%+ enrage only",
            -- Fight at 100%: phase flag 479 (Telos re-added), golems spawn +4..+9
            -- (wiki: 1 s delay before he attacks)
            resumeTicks = 4,
            -- His bar fills by itself, +4 every ~3 ticks (0 -> 100 in ~75 ticks, 2 fights).
            -- Wiki: bomb 2 autos after it's full
            barWarning = { at = 80, full = 100, text = "Bomb 2 autos after full bar - charged font / Immortality" },
            specials = {
                -- Virus lands (420/tick DoT starts) at golems +34/+35 when his bar is ~50
                -- (2 fights: 398 -> 432, 400 -> 433), not after the wiki's 10 autos
                { attack = GOLEMS, autosFirst = 0, autos = 2, duration = 2, note = "Kill 4 golems within 3 tiles of their font to charge it" },
                -- Fight 4: golems 389 -> virus 420 (+31): the bar fills at different
                -- speeds, so the bar crossing 50 is the sync (3 fights: bar ~50 each time)
                -- 3 fights 2026-10-22: virus lands the tick the bar goes 40 -> 44 (all 3)
                { attack = RANDOM_VIRUS, autos = 8, duration = 5, barTarget = 44, syncAtBar = true,
                    note = "Virus when his bar hits ~44 - stand in the matching stream" },
                {
                    -- Wiki table says 17 autos, but the bar is full ~+75 after golems
                    -- (1.25-1.4/tick, 2 fights): virus +49 = 5 + 11 autos. The bomb
                    -- yell came 13 ticks after the bar hit 100 (1 fight, 250%)
                    attack = ANIMA_BOMB,
                    autos = 11,
                    barTarget = 100, barTargetTicks = 12,
                    chat = { "is charging a", "SO. MUCH. POWER!" },
                    note = "Use the charged matching font to knock him out (Immortality works <1000%)",
                },
            },
        },
    },

    triggers = {
        -- Fight start (game message when the instance starts)
        { chat = "Welcome to your session against: Telos", restart = true },
        { chat = "You have made a grave mistake", restart = true },
        -- Freedom at high enrage: the stun only held him until this (250%: Death
        -- Grasp, broke free 2 ticks later -> Tendrils 2 late, not 7)
        { chat = "breaks free from its bindings", stunBroken = true },
        -- Grip tendrils appear as an object: sync to Tendrils
        { locAdded = "GWD2_SOLO_TENDRILS_SPAWN", special = TENDRILS },
        -- Red Virus: the red stream objects appear when it's cast
        -- Red stream: the phase-start Red Virus, or the rotation one when it's next
        { locAdded = "GWD2_SOLO_RED_ANIMA_STREAM_PARTICLE", phaseTimer = RED_VIRUS, special = RED_VIRUS,
            onlyIfNext = true, cooldown = 30 },
        { chat = "drains your prayer and adrenaline", alert = "Virus landed", note = "Prayer + adrenaline drained" },
        -- Virus DoT on the player: GWD2_SOLO_EXPLODING_DOT_ITERATIONS = bits 7-13 of
        -- GWD2_SOLO_BOSS_TEMP_1 (stubs), 30 when it lands then -1 per tick. P5: the
        -- landing tick is the virus special (3 fights: 388/396/397, 3-4 ticks before
        -- the bar-50 sync). Not hit if the stream blocked it all - bar-50 sync stays
        { varRise = "GWD2_SOLO_BOSS_TEMP_1", shift = 7, bits = 7, inPhase = { 5 }, special = RANDOM_VIRUS,
            onlyIfNext = true },
        -- Anima stream objects
        { locAdded = "GWD2_SOLO_BOSS_ANIMA_BLOCKING_SPRAY", alert = "Anima stream", note = "Block it if his bar is high" },
        -- Full anima bar released (not a phase change - recorded at 0% enrage in phase 4)
        { chat = "SO. MUCH. POWER!", alert = "SO. MUCH. POWER!", note = "Bar released", delayNext = 13, clearsFollowUp = true, undoEstimate = true },
        -- Phase 4 font / bomb messages
        { chat = "anima from the font", inPhase = { 1, 2, 3 }, phase = 4 },
        { chat = "anima from the font", inPhase = { 4 }, alert = "Font siphon", note = "Absorb the anima / shield the font" },
        -- Yelled 3-4 ticks before every font bomb (12 of 12 recorded)
        { chat = "You dare to defy me?", inPhase = { 4 }, bombIn = 4 },
        -- Font bomb ends the font hold; measured: next special 8-16 ticks after this message
        -- Next special: autos left from before the push (main.lua: autosLeftAt)
        { chat = "preparing to fire an anima bomb", alert = "Anima bomb incoming!", note = "Be inside the font shield",
            endsEvent = true, undoEstimate = true },
        { chat = "You unleash anima from the font", alert = "Font shield up", note = "Stay inside it for the bomb" },
        -- Phase 5: six golems of one type spawn = Golem spawn (cooldown: they come 1 tick apart)
        { npcAdded = "anima-golem", inPhase = { 5 }, special = GOLEMS, cooldown = 30 },
        -- Phase 4: font golems = he was pushed into the next font (backup for the HP threshold)
        { npcAdded = "anima-golem", inPhase = { 4 }, fontPush = true },
        -- Phase 4 -> 5 (100%+ enrage only; the phase var also covers this)
        { chat = "use my power against me", inPhase = { 4 }, phase = 5 },
    },
}
