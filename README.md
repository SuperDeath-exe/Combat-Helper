# Combat Helper

RS3 client plugin (Lua) that shows a boss's current, next and following special
attack. Bosses: Telos, Araxxor, TzKal-Zuk (HM). Built and tested on the RS3
developer beta client.

> Uses features listed as *subject to review* in the
> [plugin guidelines](https://developer.runescape.com/rs/submission/guidelines.html)
> (combat information overlays, enemy state tracking). Not submitted or approved;
> use at your own risk.

## Install

You need the RS3 beta client (it installs to `C:\ProgramData\Jagex\RuneScape-BETA`).
The client loads development plugins from its `dev_plugins` folder. The plugin
doesn't run on the live client. The offline tools in `tools/` are optional and
need Python 3 and `pip install lupa`.

1. Get the code: **Code > Download ZIP** on GitHub (or `git clone` it).
2. Put the files in `C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins\combat-helper\`,
   so `main.lua` and `plugin.json` sit directly in that folder (not in a subfolder
   like `combat-helper\combat-helper-main\`). Create `dev_plugins` if it isn't there.

## Enable it in game

Plugins are managed from the developer console for now (the in-game plugin menu is
still being built).

1. Log in on the beta client and open the console with **Alt + `** (the key left of 1).
2. Run `prf` to rescan the plugin folder (needed once after adding the folder).
3. Run `plist` and check that `combat-helper` is listed.
4. Run `pon combat-helper` to enable it. The panel appears on screen.

Console commands take the plugin's folder name. If yours has a space, quote it:
`pon "combat-helper Public"`.

Other console commands:

| Command | What it does |
|---|---|
| `poff combat-helper` | Disable the plugin |
| `prl combat-helper` | Reload it (after updating the files) |
| `prf` | Rescan the folder (after adding or removing a plugin, or a `plugin.json` change) |

Optional: `ppe combat-helper chatAccess` lets the plugin read boss yells from chat events.
Without it (permissions don't work on the beta yet) it reads them from the chatbox,
which works the same.

Only enable one copy at a time: each copy draws its own panel.

Hotkeys: Page Down = next special, Page Up = undo, End = next phase, Home = restart.
Move the panel: click `+`, it follows the mouse, click again to drop it.

To uninstall: run `poff combat-helper`, then delete the plugin's folder.

## Reading the panel

```
Telos  3:54  78,289 (78%)  bar 36      boss, fight time, HP, his anima bar
Phase 5  100% enrage
------------------------------
NOW   Magic autos                      what he's doing right now
      auto 1 of 3
------------------------------
NEXT  Virus (random colour)  ~8s       his next special and a countdown
      after 3 autos                    autos he does before it
      Stand in the matching stream     how to deal with it
------------------------------
THEN  Anima bomb (instant kill)        the special after that
```

- **NOW:** the special or phase change that just started, for a few seconds. Between
  specials it shows his autos ("Melee autos", "auto 2 of 3") or the font you're charging.
- **NEXT:** his next special. `~8s` is the estimated time left. "after 3 autos" counts
  his auto attacks before it, and "his next attack" means it's the very next one.
- **THEN:** the special after the next one, when the rotation is fixed.

The countdown is a prediction. It corrects itself as the fight goes:
- **Yells:** when he yells a special, the timer snaps to it.
- **Your stuns:** a stun that holds him pushes his next special back. At high enrage
  Telos breaks free, and that's accounted for.
- **Fonts and grips:** charging a font or being held by Telos's Grip pauses or
  shifts it.

## What it's been tested on

| Boss | Recorded fights | Status |
|---|---|---|
| Telos | 30-40, 0-250% enrage | Main focus. Phase 5 only exists at 100%+ enrage |
| TzKal-Zuk (HM) | several | Works: timers and yells |
| Araxxor | a handful | Very early. Expect wrong predictions |

## Known limits

- **Accuracy:** most specials land within a tick of the countdown. When the boss
  walks, or a signal is missed, a prediction can be one auto (4 ticks, 2.4 s) off.
- **Until he yells:** NEXT is a prediction. Trust the yell.
- **Telos's autos:** these are detected through an undocumented game variable that
  may change or disappear in an update. If it does, the plugin falls back to timers
  and gets a little less precise.
- **Plugin API:** it shows no boss animations, projectiles or hitsplats. Everything
  is worked out from yells, HP, the boss bar, game variables and objects.

## Layout

- `main.lua` - engine (phases, openers, transitions, panel UI)
- `bosses/` - one data file per boss (`_template.lua` to start a new one)
- `recorder.lua` - fight recorder (5 rotating slots in the plugin's data store)
- `chatreader.lua` - reads boss yells from the chatbox
- `tools/` - offline Python tools (`pip install lupa`)
  - `simulate.py` - smoke test against a fake game API
  - `dump_recording.py [out_dir]` - extract recorder logs from `PluginData.db`
  - `replay.py <log>` - replay a log through the plugin, prints predicted vs actual

## Sending a fight log

1. Click the panel's `Rec` button so it says `Rec: AUTO`. It starts recording when you
   enter a supported boss instance (new session or Rejoin) and saves after the kill or death,
   or as soon as you leave the instance.
2. Close the client, then run `python tools/dump_recording.py` (set `RS3_BETA_ROOT`
   if your beta client is not in the default folder).
3. Attach `recording.log` (newest fight) to an issue with the boss, enrage and what
   went wrong.

What the recorder keeps out of logs:
- your own name (replaced with `<you>`)
- News, login/logout, clan/friends and private chat lines; chat sender names
- key presses (only the Insert marker is logged; abilities are logged by name)
- XP totals (only XP gained per drop)
- right-click options on other players (Follow, Trade with, Report, ...)
- the UI scan taken when an AUTO recording starts (stored apart, only exported with `dump_recording.py --ui`;
  it holds everything on screen, don't share it)

Other names can still show up (for example in game messages that mention another
player), so skim the log before you share it.

## Adding a boss

1. Copy `bosses/_template.lua` to `bosses/<boss>.lua` and fill it in from the RS3 wiki:
   NPC names, the time between autos, and each phase's specials (autos before each
   one, the yell that confirms it, a short note).
2. Add the file name (without `.lua`) to `bosses/index.lua`.
3. Record a few fights with `Rec: AUTO` and check them with `tools/replay.py`.

`telos.lua` is the full example of a fixed rotation. `zuk.lua` runs on game timers
and yells.

## Pull requests

Timing changes should be backed by a recorded fight: run `tools/replay.py` on the log
before and after, and include the log or the relevant lines.

**I will NOT accept or merge pull requests that:**
- add rotation helpers, ability suggestions or prayer-switch prompts
- automate anything or send inputs/actions to the game
- export or track information about other players
- break the [RuneScape plugin guidelines](https://developer.runescape.com/rs/submission/guidelines.html)
  or the [Jagex Terms of Service](https://legal.jagex.com/docs/terms) in any other way

Such PRs are closed without review.

## Changelog

### 0.1.0
- First public release: Telos, TzKal-Zuk (HM) and Araxxor (early).
