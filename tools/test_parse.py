"""Runs DoesItDie's real description parser (extracted from the addon) against vanilla-style DoT tooltips.

Descriptions are reconstructed from memory of Classic Era wording; Forever's text may differ.
Prints what the addon would track for each cast: total, school, duration, tick interval, ticks.

    pip install lupa
    python tools/test_parse.py
"""
import os
from lupa import LuaRuntime

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "DoesItDie", "DoesItDie.lua")
src = open(SRC, encoding="utf-8").read()
# The files before DoesItDie.lua in the .toc (Locale.lua and the languages) put ns.locale on the namespace the
# chunks below use.
TOC = [line.strip() for line in open(os.path.join(os.path.dirname(SRC), "DoesItDie.toc"), encoding="utf-8")]
LOCALE_PRELUDE = "local ns = {}\n" + "".join(
    ";(function(...)\n" + open(os.path.join(os.path.dirname(SRC), name), encoding="utf-8").read()
    + "\nend)(\"DoesItDie\", ns)\n"
    for name in TOC[:TOC.index("DoesItDie.lua")] if name.endswith(".lua"))


def chunk(start_marker, end_marker):
    start = src.index(start_marker)
    end = src.index(end_marker, start)
    return src[start:end]


lua_code = "\n".join([
    LOCALE_PRELUDE,
    "local function isSecret(v) return false end",
    chunk("local DEFAULT_TICK_INTERVAL", "local TICK_MATCH_WINDOW"),
    chunk("-- Tick intervals that differ", "-- User options"),
    chunk("local function schoolFromWords", "---------------------------------------------------------------------------\n-- DoT tracking"),
    """
    return function(name, desc, comboPoints)
        if IGNORED_SPELLS[name] then return "ignored (list)" end
        local total, school, duration, stated = parseDot(desc, comboPoints)
        if not total then return "not tracked" end
        local interval = stated or KNOWN_TICK_INTERVALS[name] or DEFAULT_TICK_INTERVAL
        school = SCHOOL_BY_NAME[name] or school
        local ticks = math.max(1, math.floor(duration / interval + 0.5))
        return string.format("%d dmg, school %d, %gs, every %gs -> %d ticks of %.1f",
            total, school, duration, interval, ticks, total / ticks)
    end
    """,
])
# The chunks declare locals referenced by later chunks; wrap so they share one scope.
track = LuaRuntime(unpack_returned_tuples=True).execute(lua_code)

CASES = [
    # (class, spell, description, expectation)
    ("Warlock", "Corruption", "Corrupts the target, causing 40 Shadow damage over 12 sec.", "4 ticks, shadow"),
    ("Warlock", "Immolate", "Burns the enemy for 11 Fire damage and then an additional 20 Fire damage over 15 sec.", "periodic part only"),
    ("Warlock", "Curse of Agony", "Curses the target with agony, causing 84 Shadow damage over 24 sec.  This damage is dealt slowly at first, and builds up as the Curse reaches its full duration.", "12 ticks every 2s"),
    ("Warlock", "Siphon Life", "Transfers 15 health from the target to the caster every 3 sec.  Lasts 30 sec.", "10 ticks, shadow"),
    ("Warlock", "Curse of Doom", "Curses the target with impending doom, causing 3200 Shadow damage after 1 min.  If the target dies from this damage, there is a chance that a Doomguard will be summoned.", "not a DoT"),
    ("Warlock", "Rain of Fire", "Calls down a fiery rain to burn enemies in the area of effect for 240 Fire damage over 8 sec.", "ignored (AoE)"),
    ("Priest", "Shadow Word: Pain", "A word of darkness that causes 30 Shadow damage over 18 sec.", "6 ticks"),
    ("Priest", "Devouring Plague", "Afflicts the target with a disease that causes 152 Shadow damage over 24 sec.  Damage caused by the Devouring Plague heals the caster.", "8 ticks"),
    ("Priest", "Holy Fire", "Consumes the enemy in holy flame that causes 84 to 104 Holy damage and an additional 21 Holy damage over 10 sec.", "periodic part, holy"),
    ("Priest", "Starshards", "Rains starshards down on the enemy target's head, causing 84 Arcane damage over 6 sec.", "channel: ignore"),
    ("Druid", "Moonfire", "Burns the enemy for 9 to 12 Arcane damage and then an additional 12 Arcane damage over 9 sec.", "periodic part, arcane"),
    ("Druid", "Insect Swarm", "The enemy target is swarmed by insects, decreasing their chance to hit by 2% and causing 66 Nature damage over 12 sec.", "6 ticks every 2s"),
    ("Druid", "Rake", "Rake the target for 19 damage and an additional 39 damage over 9 sec.  Awards 1 combo point.", "bleed, physical"),
    ("Druid", "Rip (5 pts, Classic text)", "Finishing move that causes damage over time.  Damage increases per combo point:\n   1 point: 42 damage over 12 sec.\n   2 points: 66 damage over 12 sec.\n   5 points: 138 damage over 12 sec.", "138 over 12s, 6 ticks", 5),
    ("Druid", "Entangling Roots", "Roots the target in place and causes 20 Nature damage over 12 sec.", "DoT"),
    ("Rogue", "Garrote", "Garrote the enemy, causing 144 damage over 18 sec.  Must be stealthed.  Awards 1 combo point.", "bleed, physical"),
    ("Rogue", "Rupture (1 pt)", "Finishing move that causes damage over time, increased by your attack power.  Lasts longer per combo point:\n   1 point: 40 damage over 8 secs\n   5 points: 128 damage over 16 secs", "40 over 8s, 4 ticks", 1),
    ("Rogue", "Eviscerate", "Finishing move that causes damage per combo point:\n   1 point: 6-11 damage\n   5 points: 30-35 damage", "no DoT: not tracked", 5),
    ("Rogue", "Deadly Poison", "Coats a weapon with poison that lasts for 30 minutes.  Each strike has a 30% chance of poisoning the enemy for 36 Nature damage over 12 sec.  Stacks up to 5 times on a single target.", "weapon buff: ignore"),
    ("Warrior", "Rend", "Wounds the target causing them to bleed for 15 damage over 9 sec.", "bleed, physical"),
    ("Mage", "Fireball", "Hurls a fiery ball that causes 16 to 25 Fire damage and an additional 2 Fire damage over 4 sec.", "2 ticks every 2s"),
    ("Mage", "Pyroblast", "Hurls an immense fiery boulder that causes 141 to 188 Fire damage and an additional 56 Fire damage over 12 sec.", "4 ticks"),
    ("Mage", "Flamestrike", "Calls down a pillar of fire, burning all enemies within the area for 55 to 71 Fire damage and an additional 48 Fire damage over 8 sec.", "ignored (AoE)"),
    ("Shaman", "Flame Shock", "Instantly sears the target with fire, causing 25 Fire damage immediately and 28 Fire damage over 12 sec.", "4 ticks"),
    ("Hunter", "Serpent Sting", "Stings the target, causing 20 Nature damage over 15 sec.  Only one Sting per Hunter can be active on any one target.", "5 ticks"),
    ("Hunter", "Immolation Trap", "Place a fire trap that will burn the first enemy to approach for 105 Fire damage over 15 sec.  Trap will exist for 1 min.", "trap: ignore"),
    ("Hunter", "Explosive Trap", "Place a fire trap that explodes when an enemy approaches, causing 100 to 130 Fire damage and burning all enemies for 110 additional Fire damage over 20 sec to all within 10 yards.", "trap: ignore"),
    ("Hunter", "Wyvern Sting", "A stinging shot that puts the target to sleep for 12 sec.  When the target wakes up, the Sting causes 300 Nature damage over 12 sec.", "delayed: ignore"),
    # Forever (quoted from Wowhead Forever tooltips unless marked guessed)
    ("Forever", "Frostfire Bolt", "Launches a bolt of frostfire at the enemy, causing 412 Frostfire damage, slowing movement speed by 40% and causing an additional 39 Frostfire damage over 9 sec.", "school 20, 3 ticks"),
    ("Forever", "Lacerate", "Lacerates the enemy target, making them bleed for 50 damage over 15 sec plus 10% weapon damage per existing application of Lacerate on the target. This effect stacks up to 5 times on the same target.", "bleed, 5 ticks"),
    ("Forever", "Bane of Agony", "Banes the target with agony, causing 84 Shadow damage over 24 sec.  This damage is dealt slowly at first, and builds up as the Bane reaches its full duration.", "(guessed text) 12 ticks every 2s"),
    ("Forever", "Rip (5 pts)", "Finishing move that causes damage over time. Damage increases per combo point and by your Attack Power: 1 point : 243 damage over 12 sec. 2 points: 396 damage over 12 sec. 3 points: 549 damage over 12 sec. 4 points: 702 damage over 12 sec. 5 points: 855 damage over 12 sec.", "855 over 12s, 6 ticks", 5),
    ("Forever", "Rip (1 pt)", "Finishing move that causes damage over time. Damage increases per combo point and by your Attack Power: 1 point : 243 damage over 12 sec. 2 points: 396 damage over 12 sec. 3 points: 549 damage over 12 sec. 4 points: 702 damage over 12 sec. 5 points: 855 damage over 12 sec.", "243 (stray space before colon)", 1),
    ("Forever", "Rupture (5 pts, guessed text)", "Finishing move that causes damage over time, increased by your attack power. Lasts longer per combo point:\n   1 point: 25 damage over 8 secs\n   2 points: 36 damage over 10 secs\n   3 points: 50 damage over 12 secs\n   4 points: 66 damage over 14 secs\n   5 points: 87 damage over 16 secs", "87 over 16s, 8 ticks", 5),
    ("Forever", "Rupture (3 pts, guessed text)", "Finishing move that causes damage over time, increased by your attack power. Lasts longer per combo point:\n   1 point: 25 damage over 8 secs\n   2 points: 36 damage over 10 secs\n   3 points: 50 damage over 12 secs\n   4 points: 66 damage over 14 secs\n   5 points: 87 damage over 16 secs", "50 over 12s, 6 ticks", 3),
]

if __name__ == "__main__":  # tools/test_spellbook.py imports `track` from here
    width = max(len(c[1]) for c in CASES)
    for case in CASES:
        cls, label, desc, expect = case[:4]
        combo_points = case[4] if len(case) > 4 else None  # finishers only
        spell = label.split(" (")[0]  # labels may carry a note, e.g. "Rip (5 pts)"
        print(f"{cls:8} {label:<{width}}  {track(spell, desc, combo_points):<55}  expect: {expect}")
