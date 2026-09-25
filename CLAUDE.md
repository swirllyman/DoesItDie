# DoesItDie

A World of Warcraft: **Forever** addon (released from `v*` tags; see `.github/workflows/release.yml`). It tracks
the player's damage-over-time spells on the current target (and on enemy nameplates) and shows whether they will
finish it off:

- a **damage marker** on the target frame's health bar, covering the damage the DoTs still have to deal
  (if the green health ends inside it, the target dies), and
- a **kill icon** on the target's portrait when the DoTs are lethal (skull, X, checkmark or sunglasses; the
  code still calls it the "skull").

Both are styled from the addon's own options window (`/did`), which has a live preview: while it's open, the
real marker and icon are attached to a mock target frame inside it and fed the preview's plain numbers. The project folder is still called `WillItDie` (the addon's
original name); everything inside the addon is `DoesItDie`.

## Why it's built the way it is: Forever's addon restrictions

Forever runs on the modern (Midnight-era) client, so many combat values are **secret** to addon code: they can
be displayed but not compared or used in math. Verified in-game on the 1.60.1 beta:

| Hidden in combat (secret or erroring) | Readable |
|---|---|
| Target health / max health (even out of combat) | Your own casts (`UNIT_SPELLCAST_SUCCEEDED/SENT`) |
| Your spell power and attack power | Spell descriptions (`C_Spell.GetSpellDescription`) |
| Auras on the target (reading them errors) | `UNIT_COMBAT` damage amounts, school, crit flag, dodge/miss/etc. |
| Combo points | Enemy GUIDs |
| Some Blizzard frames' strata/level | Your stats **out** of combat |

Registering `COMBAT_LOG_EVENT_UNFILTERED` is forbidden: it raises a "blocked action" popup even under `pcall`.

Consequences for the design:

- **The addon never computes "will it die" itself.** It feeds secret values straight into `StatusBar` widgets,
  which *can* use them. The marker is a StatusBar with max = the target's max health and value = remaining DoT
  damage. The skull is a 10,000px StatusBar (max = current health, value = remaining damage) inside a small
  clipping frame on the portrait: the skull rides the end of the fill and only becomes visible when the fill
  reaches 100%, i.e. when damage ≥ health.
- **DoT damage is estimated from events, not auras.** On cast, the spell description gives damage, school and
  duration. Once ticks land, `UNIT_COMBAT` damage on the target is matched to DoTs by school, timing and size,
  and the observed tick size replaces the description's number (descriptions leave out spell/attack power).

## Layout

| Path | What |
|---|---|
| `DoesItDie/DoesItDie.lua` | The addon, in sections: constants and tables, helpers, description parsing, DoT tracking (combo points, cast outcomes, tick matching), display, settings and what `Options.lua` needs (`ns.*`), events, slash commands |
| `DoesItDie/Options.lua` | The options window: live preview with a mock target frame, tabs, presets, hand-built controls; plus a small page in Options > AddOns that opens it. Shares data with `DoesItDie.lua` through the addon namespace (`local _, ns = ...`) |
| `DoesItDie/Nameplates.lua` | The marker and a small kill icon on every enemy nameplate with your DoTs (per-plate widgets parented to Blizzard's recycled plate frames and anchored to Platynator's health bar when it draws the plate, else Blizzard's; fed via `ns.dotBreakdownForUnit`), with their own look settings (`plate*`, since enemy plates are red) and a mock plate in the options preview; plus the `/did plates` probe. Probe verified plates are reachable and anchorable in the open world, in and out of combat; dungeons are untested |
| `DoesItDie/Textures/` | Generated TGAs: patterns (dashes, stripes, spark, shine) and the sunglasses icon |
| `tools/make_textures.py` | Regenerates the textures |
| `tools/scrape_forever_spellbook.py` | Scrapes all nine class spellbooks from foreverchanges.pro into `tools/data/forever_spellbook.json` |
| `tools/test_parse.py` | Runs the addon's real description parser (in Lua, via `lupa`) on hand-written tooltips |
| `tools/test_spellbook.py` | Runs every scraped Forever damage tooltip through the parser and compares with a reviewed snapshot (`tools/data/spellbook_expected.json`) |
| `tools/test_tracking.py` | Plays scripted fights through the real tracking code with game APIs stubbed: tick matching, dodges/misses, recasts, combo points, first-tick waiting. Includes replays of real in-game logs |
| `tools/test_display.py` | Loads the real display code with mocked frames and checks the per-DoT segments (running totals, colors, dividers, text breakdown) |
| `tools/test_load.py` | Smoke test: loads every file in the .toc with a fake WoW environment and drives it like a player (load, `/did`, tabs, presets, controls, Simulate fight, close). Catches runtime errors, not visual ones |
| `WillItDieProbe/` | The original diagnostic addon that established the restrictions above. Not linked into the game any more |

## How the tracking works (high level)

1. **Cast** (`UNIT_SPELLCAST_SUCCEEDED`, player only): parse the description (`parseDot`). Skip ignored spells
   (AoE, channels, traps, delayed damage), heals and weapon poisons. Finishers (Rip, Rupture) read the
   per-combo-point table.
2. **Combo points** are secret, so they're **counted** from builders ("Awards N combo point"), with dodges and
   misses taken back and resets on finishers and target changes. If unknown, finishers assume the lowest entry.
3. **Cast outcomes:** a dodge/parry/miss/resist/immune on the target right after a cast removes that DoT (or
   restores the previous one on a recast). `UNIT_COMBAT` doesn't say which attack was avoided; the first outcome
   right after the cast decides.
4. **Ticks:** each `UNIT_COMBAT` hit on the target is matched to at most one DoT: same school, within a tight
   timing window of the DoT's rhythm, and a plausible size (crits 1.3–2.3×). Physical bleeds and melee white hits
   look alike, hence the tight windows. Learned tick sizes are saved per spell (per combo point count for
   finishers).
5. **Display** (every 0.1s): the remaining damage of all DoTs on the target goes to the marker and the skull.

Tuning constants (tick windows, tolerances, fallbacks) are at the top of `DoesItDie.lua` with the reasoning.

## Working on it

- **Game install:** the Forever beta lives in `C:\Program Files (x86)\World of Warcraft\_classic_beta_\`.
  `Interface\AddOns\DoesItDie` there is a **junction** to this project's `DoesItDie/`, so edits here are live.
- **Reload:** `/reload` picks up Lua changes. **New files** (textures) need a full client restart.
- **Trace log:** the addon always logs casts, ticks, estimates and decisions to its SavedVariables (`db.log`,
  last 500 lines), written on reload or logout to
  `…\_classic_beta_\WTF\Account\<account>\SavedVariables\DoesItDie.lua`. Reading this after the user plays is
  the main debugging loop. `/did debug` echoes the log to chat.
- **Slash commands:** `/did` (options window), `/did skull` (5-second kill icon test with geometry logged), `/did line`,
  `/did debug`, `/did reset` (forget learned tick sizes), `/did plates` (nameplate probe, logged).
- **Tests:** `pip install lupa`, then run the five `tools/test_*.py` scripts (use `--update` on
  `test_spellbook.py` only after reviewing a change). There's no Lua install; `luaparser` (pip) works as a
  syntax check.
- **Gotchas:**
  - WoW runs **Lua 5.1**; `lupa` runs 5.5 (loop variables are read-only there, which is fine for 5.1 code too).
  - Bash heredocs in this environment collapse backslashes, which silently breaks texture paths like
    `"Interface\\Buttons\\WHITE8X8"`. Edit Lua with file tools, and grep `Interface` after scripted edits.
  - Guard every value that might be secret with `isSecret()` before comparing or indexing with it.
  - Bump `DB_VERSION` when learned tick data from older versions would be wrong.
  - Lua allows 200 locals per function scope, including a file's top level. `DoesItDie.lua` is around 170,
    so new features with many top-level locals belong in a new file (added to the .toc) sharing `ns`.

## Status

Verified in-game: Hunter (Serpent Sting, early version), low-level Warlock (Immolate, Corruption), Druid
(Rip with counted combo points, Moonfire, misses). Every Forever damage tooltip for all classes goes through
`test_spellbook.py`: 24 are tracked as DoTs, 13 deliberately ignored.

Known limitations:

- Only the **player's** DoTs are tracked.
- Proc DoTs with no cast (Deep Wounds, Ignite, poisons) aren't tracked. Their ticks show up as unmatched hits.
- Uneven DoTs need a tick shape in `TICK_SHAPES` (Bane/Curse of Agony: 4 ticks at 0.5x, 4 at 1x, 4 at 1.5x the
  average, confirmed in-game); anything uneven that isn't listed is treated as even. Lacerate's stacks are
  approximated.
- Extra combo points from crits (Primal Fury, Seal Fate) aren't counted, so estimates err low.
- Hunter **Black Arrow** (Forever reuses Classic's "150 Shadow damage and draining 150 mana over 30 sec")
  isn't tracked; its tick behavior is unverified.
- Healing on the target isn't accounted for (by design).

## Ideas / next steps

- **Party members' DoTs.** First check whether `UNIT_SPELLCAST_SUCCEEDED` for party units carries readable spell
  IDs in combat (a small probe plus one pull with a party member who has a DoT). If it does, track their casts
  the same way (their target via GUID, tick sizes learned from observed ticks), behind an option and styled
  differently from the player's. If it doesn't, the fallback is addon-to-addon messages, which requires party
  members to install it and may be restricted in combat.
- **Rupture's duration** depends on combo points; if combo counting proves unreliable, consider waiting for
  the first tick for finishers.
