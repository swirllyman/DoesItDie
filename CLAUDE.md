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

Midnight's curve APIs exist (`C_CurveUtil.CreateCurve/CreateColorCurve`, `Enum.LuaCurveType.Step`), but
`curve:Evaluate(secret)` errors from addon code ("Secret values are only allowed during untainted execution"),
even out of combat. Secret values only reach a curve through Blizzard functions such as
`UnitHealthPercent(unit, false, curve)`, which fits a fixed percent (execute range) but not the kill icon: its
threshold, damage / max health, can't be computed. Tested with `/did exec` icon C on 2026-09-24.

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
| `DoesItDie/DoesItDie.lua` | The addon's core, in sections: constants and tables, helpers, description parsing, DoT tracking (combo points, cast outcomes, tick matching), settings and what `Options.lua` needs (`ns.*`), events, slash commands. Reaches the display through `ns.display`, `ns.refresh`, `ns.playFlash` (runtime only: it loads first) and hands it the tracking through `ns.tracking` |
| `DoesItDie/Display.lua` | The target frame display: the marker on the health bar, the kill icon on the portrait, their look lists, animations, layering, attaching to Blizzard's, a custom or the options preview's frame, and `refresh`. Loaded right after `DoesItDie.lua`; gets `db` on ADDON_LOADED (`ns.display.setDb`) |
| `DoesItDie/Options.lua` | The options window: live preview with a mock target frame, tabs, presets, hand-built controls; the learned tick sizes viewer (Advanced > View, `/did ticks`: per spell its icon, rank, learned vs tooltip tick, hover tooltip, shift-click link, forget); plus a small page in Options > AddOns that opens it. Shares data with `DoesItDie.lua` through the addon namespace (`local _, ns = ...`) |
| `DoesItDie/Frames.lua` | Custom target frame (options' Advanced tab): attach the marker and kill icon to another addon's target frame instead of Blizzard's (which unit frame replacements hide). Settings hold frame paths (`GlobalName.key.key`); a Pick mode highlights and takes the frame under the mouse. The marker only needs the bar's rectangle, so the bar must fill left to right and be exactly the fill area. With the setting empty (or its path not found), a known replacement target frame is used before Blizzard's: EllesmereUI's (`EllesmereUIUnitFrames_Target.Health`, which only exists while EllesmereUI draws the target frame; `ns.knownTargetFrame`), with the kill icon on its `.Portrait` when that's shown (EllesmereUI hides the portrait's backdrop when portraits are off), else on the bar. When the attached frame (custom or Blizzard's) isn't visible, the display hides. Typed EllesmereUI path verified in-game by users |
| `DoesItDie/Nameplates.lua` | The marker and a small kill icon on every enemy nameplate with your DoTs (per-plate widgets parented to Blizzard's recycled plate frames, fed via `ns.dotBreakdownForUnit`; with EllesmereUI's nameplates, parented to its own pooled plate frame instead, found in `EllesmereNameplates_NS.plates[unit]`, in its health bar's strata since it flattens the plate's render layers; verified in-game; with Platynator's, anchored to its health widget's bar (its displays are found by scanning UIParent's and the plate's children, throttled) and re-anchored when Platynator reassigns a display, in that bar's strata); with Threat Plates', anchored the same way to `plate.TPFrame.visual.Healthbar` (`.healthbar` in older versions) while `TPFrame.Active`: its plate frame is parented to WorldFrame, not the plate, so the search below can't reach it (`findThreatPlatesBar`, from its source: Backupiseasy/ThreatPlates `Nameplate.lua`, `Elements/Healthbar.lua`); with any other nameplate addon that hides Blizzard's bar (Plater, KUI, ...), an automatic search finds a shown StatusBar under a field named like `health` among the frames inside the plate (`searchHealthBar`: breadth-first through frames inside the plate and plain tables up to 200 entries; Blizzard's UnitFrame skipped; each field checked under its own pcall, since framework objects can throw when read and one used to abort the whole search; cached per plate and searched again at most once a second); the Advanced tab's Nameplate health bar (`customPlateHealthBar`, keys from the plate) overrides it. When nothing is found and Blizzard's bar is hidden, only the kill icon is drawn beside the plate (as before v0.7.0; a marker there would float). Plater and Threat Plates untested in-game, with their own look settings (`plate*`, since enemy plates are red) and a mock plate in the options preview; plus the `/did plates` probe. Probe verified plates are reachable and anchorable in the open world, in and out of combat; markers work in dungeons too (mobs keyed by plate, see How the tracking works) |
| `DoesItDie/Focus.lua` | The marker (and kill icon) on the focus frame's health bar for your DoTs on the focused mob, using the nameplate widgets (`ns.barMarker` from `Nameplates.lua`, its host pinned so the plate refresh leaves it alone) in its own look: the Focus tab's `focus*` settings, read through a view mapping the widgets' `plate*` keys (`FOCUS_KEYS`). The options preview has a mock focus frame (`ns.setFocusPreview`). Bar: the Advanced tab's custom path, else EllesmereUI's focus frame (`ns.knownFocusFrame`), else Blizzard's. `[@focus]` casts go on the focus: `UNIT_SPELLCAST_SENT` names the target, matched against the focus's name (`sentTargetKey` in `DoesItDie.lua`; a same-named target wins). From toughnuts99's patch (issue #12). Verified in-game on Blizzard's focus frame, including the layering (its art sits far above the bar, so the widgets go above the frame's top strata/level, rechecked once a second) |
| `DoesItDie/Execute.lua` | Execute range: a general "target is below 20%" indicator for every class (no class-specific logic, by design). For now only the `/did exec [percent]` probe, comparing two ways to show it: A, geometry (an icon at the threshold's spot on a long health-fed bar, clipped to the bar's empty part) and B, `UnitHealthPercent` with a step color curve, if Forever has it. Unverified in-game |
| `DoesItDie/Locale.lua` | Other client languages: a registry (`ns.locale.register`) that each language file joins with its own description patterns (`parseDot`, `isFinisher`, `comboPointsAwarded`) and English name -> local names for the name-keyed tables (`NAME_TABLES` in `DoesItDie.lua`). English patterns always run first, unchanged; descriptions they don't read go to every language in turn, whatever `GetLocale()` says (one language's patterns can't match another's text). At load the tables also get the names the client reports for known spell IDs (`L.SPELL_IDS`), in any language. Unread non-English descriptions are logged once per spell (`NOT READ`). Also the addon's own text: `T("English text")` returns it in the window language (`uiLanguage` setting, Advanced > Window language: auto = `GetLocale()`, applies after `/reload`) from that language's `strings` table, else English. `python tools/test_load.py --dump-strings FILE` writes every key as a table to fill in. Covers the options window, tick viewer, `/did help` and the chat messages (PR #23); the probes are English only |
| `DoesItDie/Locale_deDE.lua`, `Locale_esES.lua`, `Locale_frFR.lua`, `Locale_koKR.lua`, `Locale_ptBR.lua`, `Locale_zhCN.lua` | German (PR #2), Spanish (ported from PR #6), French (ported from PR #11; non-breaking spaces fixed in PR #15), Korean (issue #18), Brazilian Portuguese (issue #19) and Chinese (issue #20). Korean, Portuguese and Chinese are from Forever's own tooltips via Wowhead's tooltip API: `https://nether.wowhead.com/forever/tooltip/spell/<id>?locale=N` (1 Korean, 4 Simplified Chinese, 8 Portuguese). Wowhead has no Traditional Chinese for Forever, but zhTW's text is zhCN's wording in traditional characters (issue #20's log), so `Locale_zhCN.lua` turns traditional characters into simplified ones first and reads both. Some Chinese tooltips name no school (Corruption, Pyroblast, Fireball's DoT part): `SCHOOL_BY_NAME`. German is Classic Era wording; Spanish and French are Forever's (Wowhead). None verified on a non-English client yet. German also has the options window's text (`STRINGS`); Spanish and French are still English there |
| `DoesItDie/Textures/` | Generated TGAs: patterns (dashes, stripes, spark, shine) and the sunglasses icon |
| `tools/make_textures.py` | Regenerates the textures |
| `tools/scrape_forever_spellbook.py` | Scrapes all nine class spellbooks from foreverchanges.pro into `tools/data/forever_spellbook.json` |
| `tools/test_parse.py` | Runs the addon's real description parser (in Lua, via `lupa`) on hand-written tooltips |
| `tools/test_spellbook.py` | Runs every scraped Forever damage tooltip through the parser and compares with a reviewed snapshot (`tools/data/spellbook_expected.json`) |
| `tools/test_tracking.py` | Plays scripted fights through the real tracking code with game APIs stubbed: tick matching, dodges/misses, recasts, combo points, first-tick waiting. Includes replays of real in-game logs |
| `tools/test_display.py` | Loads the real display code (`Display.lua`) with mocked frames and checks the per-DoT segments (running totals, colors, dividers, text breakdown) |
| `tools/test_load.py` | Smoke test: loads every file in the .toc with a fake WoW environment and drives it like a player (load, `/did`, tabs, presets, controls, Simulate fight, close). Catches runtime errors, not visual ones |
| `tools/test_locale.py` | Runs `tools/test_locale.lua`: every English and German tooltip in `tools/data/locale_cases.lua` through the real parser, English checked against the v0.5.0 parser (`tools/data/upstream_parser_v0.5.0.lua`), plus the language registry |
| `tools/test_locale_fr_es.py` | French (Forever's own tooltips) and Spanish tooltips through the real parser and name tables, English patterns first as in game |
| `tools/test_locale_ko.py`, `test_locale_pt.py`, `test_locale_zh.py` | Forever's Korean, Portuguese and Chinese tooltips for every tracked and ignored spell (plus heals, poisons, builders) through the real parser and name tables; the Chinese ones again in traditional characters (OpenCC `s2tw`, `pip install opencc-python-reimplemented` to regenerate), plus issue #20's logged zhTW tooltips |
| `WillItDieProbe/` | The original diagnostic addon that established the restrictions above. Not linked into the game any more |

## How the tracking works (high level)

1. **Cast** (`UNIT_SPELLCAST_SUCCEEDED`, player only): parse the description (`parseDot`). Skip ignored spells
   (AoE, channels, Explosive Trap, delayed damage), heals and weapon poisons. Finishers (Rip, Rupture) read the
   per-combo-point table. The DoT goes on the mob that was targeted at `UNIT_SPELLCAST_SENT` (matched by cast
   GUID): players who tab-dot have often changed target by the time an instant's cast event arrives. The send
   event names the cast's target: a name matching the focus or the soft enemy (and not the target) puts it on
   that mob, and a friendly hard target never takes a cast (the soft enemy does; `sentTargetKey`).
   **Immolation Trap** (`TRAP_DOTS`) only arms on cast: the trap casts the DoT when it springs, with no event for
   the player. The first unmatched Fire hit of a plausible size on any mob, at least one tick after placing and
   within the trap's minute, becomes its tick 1 (`springTrap`). Placing another Fire trap disarms it.
2. **Combo points** are secret, so they're **counted** from builders ("Awards N combo point"), with dodges and
   misses taken back and resets on finishers and target changes (which also clear the cached reading). When the
   APIs give no number, Blizzard's combo point display is read (`displayedComboPoints`, PR #14; unverified
   in-game), never over a readable API number. If unknown, finishers assume the lowest entry.
3. **Cast outcomes:** a dodge/parry/miss/resist/immune on the cast's mob right after a cast removes that DoT (or
   restores the previous one on a recast). `UNIT_COMBAT` doesn't say which attack was avoided; the first outcome
   right after the cast decides. For spell (non-Physical) DoTs, the pet's melee is the usual culprit: dodges and
   parries are ignored, and a miss/resist not reported in the spell's school makes a new DoT wait for its first
   tick instead of dropping it. (Which school `UNIT_COMBAT` reports for a spell's own miss is unverified; AVOID
   log lines include it.) The exception to "first outcome decides": a DoT with a direct part (Rake) can hit and
   still have its DoT come back IMMUNE (bleed-immune mobs), so an IMMUNE later in the window still drops it.
   Unverified in-game that Forever reports that IMMUNE through `UNIT_COMBAT`.
4. **Ticks:** each `UNIT_COMBAT` hit on the target is matched to at most one DoT: same school, within a tight
   timing window of the DoT's rhythm, and a plausible size (crits 1.3–2.3×). Physical bleeds and melee white hits
   look alike, hence the tight windows. Learned tick sizes are saved per spell (per combo point count for
   finishers). The same hit arrives once per unit token showing the mob and counts once, but two DoTs of one
   school ticking the same amount in the same instant are two hits from one token and feed both
   (`combatFrameHits`). A fully absorbed tick (ABSORB, 0) keeps a DoT's rhythm without teaching a size, when only
   one DoT fits. Same-slot swaps are judged by the size learned before the cast, not the tooltip's (which leaves
   out attack/spell power). A DoT that never ticks is dropped after two missed ticks, but only ticks that could have been
   seen count: `UNIT_COMBAT` only covers the target, focus and visible nameplates, so a mob you tabbed away from
   keeps its DoTs until they expire.
5. **Mob keys:** DoTs are kept per mob by GUID. In instances creature GUIDs are reportedly secret (PR #8), so a
   mob with a nameplate is keyed `plate:nameplateN` instead (`plateTokenFor`: the token stays the mob's while its
   plate is up; `NAME_PLATE_UNIT_ADDED/REMOVED` drop that key's DoTs before the token goes to another mob). With
   no plate either, only the current target is tracked (key `target`, dropped on target change). Needs enemy
   nameplates on. Verified in a Forever dungeon (2026-10-20, druid): GUIDs were secret, three mobs kept apart by
   plate key while tab-dotting Moonfire and Rip, every tick matched its own mob. A plate removed mid-DoT is untested
   in-game. `/did plates` logs each plate's `key=`.
6. **Display** (every 0.1s): the remaining damage of all DoTs on the target goes to the marker and the skull.

Tuning constants (tick windows, tolerances, fallbacks) are at the top of `DoesItDie.lua` with the reasoning.

## Working on it

- **Game install:** the Forever beta lives in `C:\Program Files (x86)\World of Warcraft\_classic_beta_\`.
  `Interface\AddOns\DoesItDie` there is a **junction** to this project's `DoesItDie/`, so edits here are live.
- **Reload:** `/reload` picks up Lua changes. **New files** (textures) need a full client restart.
- **Releasing:** add the version's notes to the top of `CHANGELOG.md` (player-facing wording), commit, then push a
  `v*` tag. The packager uploads the whole file as the release's changelog (`.pkgmeta` `manual-changelog`).
- **Trace log:** the addon always logs casts, ticks, estimates and decisions to its SavedVariables (`db.log`,
  last 500 lines), written on reload or logout to
  `…\_classic_beta_\WTF\Account\<account>\SavedVariables\DoesItDie.lua`. Reading this after the user plays is
  the main debugging loop. `/did debug` echoes the log to chat.
- **Slash commands:** `/did` (options window), `/did skull` (5-second kill icon test with geometry logged), `/did line`,
  `/did debug`, `/did ticks` (learned tick sizes viewer), `/did reset` (forget learned tick sizes), `/did plates` (nameplate probe, logged), `/did exec [percent]`
  (execute range probe, logged; again to stop).
- **Tests:** `pip install lupa`, then run the ten `tools/test_*.py` scripts (use `--update` on
  `test_spellbook.py` only after reviewing a change). There's no Lua install; `luaparser` (pip) works as a
  syntax check.
- **Gotchas:**
  - WoW runs **Lua 5.1**; `lupa` runs 5.5 (loop variables are read-only there, which is fine for 5.1 code too).
  - Bash heredocs in this environment collapse backslashes, which silently breaks texture paths like
    `"Interface\\Buttons\\WHITE8X8"`. Edit Lua with file tools, and grep `Interface` after scripted edits.
  - Guard every value that might be secret with `isSecret()` before comparing or indexing with it.
  - Lua's `%d` and `%s` follow the C library's locale. In WoW they're plain ASCII (a French non-breaking space
    isn't `%s`, PR #15), but Python on Windows sets code page 1252, where byte 0xB9 is a digit and 0xA0 a space:
    the tests set the "C" locale before starting Lua so they behave like the game. Patterns over multibyte text
    (Korean, Chinese) spell digits `[0-9]`.
  - Bump `DB_VERSION` when learned tick data from older versions would be wrong.
  - Lua allows 200 locals per function scope, including a file's top level. `DoesItDie.lua` uses 102 and
    `Display.lua` 104; features with many top-level locals still belong in a new file (added to the .toc) sharing
    `ns`, and setup-only locals go in `do ... end` blocks (as in `Display.lua`). `test_load.py` runs Lua 5.1
    (`lupa.lua51`), so going over fails it.

## Status

Verified in-game: Hunter (Serpent Sting, early version), low-level Warlock (Immolate, Corruption), Druid
(Rip with counted combo points, Moonfire, misses). Every Forever damage tooltip for all classes goes through
`test_spellbook.py`: 24 are tracked as DoTs, plus Immolation Trap (unverified in-game: tick interval and
whether its first tick lands one interval after springing are assumed from Classic), 12 deliberately ignored.

Known limitations:

- Only the **player's** DoTs are tracked.
- Immolation Trap: if the trapped mob's first tick isn't seen (not target, focus or a visible nameplate), a later
  tick is taken as tick 1 and that trap's estimate runs high. Someone else's Fire tick of a similar size while the
  trap is armed can also be taken for it.
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
