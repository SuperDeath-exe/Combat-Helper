-- Copy this file, fill it in from the wiki, and add its name to index.lua.
-- See telos.lua for a full fixed-rotation example, zuk.lua for a timer/yell-driven one.
return {
    -- Shown in the panel
    name = "Boss name",

    -- NPC display names that start tracking (case-insensitive)
    npcNames = { "Boss name" },

    -- Server ticks between boss attacks (1 tick = 0.6s). Enables "~Xs" countdowns.
    autoTicks = 4,
    -- Move to the next special on timing alone when no yell is seen
    autoAdvance = true,

    -- Fixed rotations. Each special:
    --   attack     name shown
    --   autos      auto-attacks before this special
    --   autosFirst autos before it the first time in the phase (optional)
    --   chat       text (or list) that resyncs to this special when seen in chat
    --   note       how to respond
    -- loopFrom: special to repeat from after the last one (default 1)
    -- openers:  [last special of previous phase] = step, or { step = n, autos = n }
    phases = {
        {
            name = "Phase 1",
            specials = {
                { attack = "Special A", autosFirst = 5, autos = 3, chat = "Boss yell A", note = "Response" },
                { attack = "Special B", autos = 3, note = "Response" },
            },
        },
        {
            name = "Phase 2",
            specials = {
                { attack = "Special C", autos = 3 },
            },
            openers = { ["Special A"] = 1 },
        },
    },

    -- Events that tell the plugin what the boss is doing.
    -- Match on one of:
    --   chat      text contained in a chat line (yells, game messages), needs chatAccess
    --   npcAdded  display name of an NPC that spawns
    --   locAdded  configName of a ground object that spawns (pan Loc in console lists them)
    -- Optional condition: inPhase = { 1, 2 }
    -- Actions:
    --   phase = n          go to phase n (uses its openers)
    --   special = "name"   sync to that special in the current phase
    --   restart = true     restart the fight timer and rotation
    --   alert = "text"     yellow callout for a few seconds (with note)
    --   attack = "text"    set "Now" directly (with note / next), for bosses without phases
    --   phaseName = "text" label for bosses without phases
    triggers = {
        { chat = "Phase change yell", inPhase = { 1 }, phase = 2 },
        { npcAdded = "Minion name", alert = "Minions!", note = "Kill them" },
    },

    -- Callouts at a time after the boss appears (seconds)
    timers = {
        { at = 30, attack = "Something", note = "Get ready" },
    },
}
