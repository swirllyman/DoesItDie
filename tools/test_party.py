"""Tests for Party.lua: sharing DoT estimates with party members over addon messages (issue #25).

    pip install lupa
    python tools/test_party.py

Loads Party.lua alone with the game APIs and DoesItDie's tracking stubbed, then plays both sides: what this client
sends for its own DoTs (change detection, refresh, throttle, gating), and what it does with a party member's
messages (anchoring to its own clock, ticking down, replacing, expiring, roster changes). tools/test_load.py
checks the whole addon with it (the marker's total and the API).

Facts these tests encode, from the in-game probe on Forever 1.60.1 (2026-11-15):
- SendAddonMessage on PARTY works in combat in the open world; result 3 = throttled (after a burst of 10),
  11 = refused during boss encounters.
- Messages over 255 bytes are silently truncated.
- Mob GUIDs are readable in the open world and secret in instances.
- The sender comes back as "Name Realm" or "Name-Realm".
"""
import os
import sys

import locale  # noqa: E402
locale.setlocale(locale.LC_CTYPE, "C")  # as in WoW: Lua's %d and %s follow the C library's locale
from lupa.lua51 import LuaRuntime  # WoW runs Lua 5.1

HERE = os.path.dirname(os.path.abspath(__file__))
PARTY = os.path.join(HERE, "..", "DoesItDie", "Party.lua")

failures = []


def check(label, actual, expected):
    ok = actual == expected
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"\n     got  {actual!r}\n     want {expected!r}"))
    if not ok:
        failures.append(label)


FAKE = r"""
now = 100
sent = {}
sendResult = 0
inInstance = false
encounter = false
inGroup = true
inRaid = false
members = { party1 = "Warlock" }
prefixes = {}
traceLog = {}
frames = {}
SECRET = setmetatable({}, { __tostring = function() error("tostring on a secret") end })
function issecretvalue(v) return v == SECRET end

local function mock()
    local f = { events = {}, scripts = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    table.insert(frames, f)
    return f
end
function CreateFrame() return mock() end
function GetTime() return now end
function IsInInstance() return inInstance, inInstance and "party" or "none" end
function IsEncounterInProgress() return encounter end
function IsInGroup() return inGroup end
function IsInRaid() return inRaid end
function UnitName(u)
    if u == "player" then return "Priest" end
    return members[u]
end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(p) prefixes[p] = true return 0 end,
    SendAddonMessage = function(prefix, msg, channel)
        table.insert(sent, { prefix = prefix, msg = msg, channel = channel })
        return sendResult
    end,
}
C_Spell = { GetSpellName = function(id) return ({ [6222] = "Corruption", [980] = "Curse of Agony" })[id] end }

-- What DoesItDie's tracking reports for this client's own DoTs: key -> list (see ns.tracking.ownDots).
OWN = {}
ns = {
    db = { partyDots = true },
    tracking = { ownDots = function() return OWN end },
    trace = function(msg) table.insert(traceLog, msg) end,
}

function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end
function update(sec)
    local step = 0.05
    local target = now + sec
    while now < target - 1e-9 do
        now = now + step
        for _, f in ipairs(frames) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f, step) end end
    end
end
function clearSent() for i = #sent, 1, -1 do sent[i] = nil end end
function msgs()
    local out = {}
    for _, s in ipairs(sent) do table.insert(out, s.msg) end
    return out
end
function breakdown(key)
    local list = {}
    ns.party.addRemote(key, list)
    return list
end
"""

GUID = "Creature-0-6826-0-16-260157-C332992C58"
GUID2 = "Creature-0-6826-0-16-6123-3A327A94F9"


def new():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(FAKE)
    G = lua.globals()
    src = open(PARTY, encoding="utf-8").read()
    chunk = lua.eval("function(src) return assert(loadstring(src, '@Party.lua')) end")(src)
    chunk("DoesItDie", G.ns)
    return lua, G, G.ns.party


def sent_list(G):
    return list(G.msgs().values())


def lua_list(lua, py):
    return lua.eval("function(...) return {...} end")(*py)


def dot(lua, spell, school, damage, next_tick_at, expires_at, interval, name="x"):
    return lua.eval("function(a,b,c,d,e,f,g) return { spellID=a, school=b, damage=c, nextTickAt=d, expiresAt=e, "
                    "interval=f, name=g } end")(spell, school, damage, next_tick_at, expires_at, interval, name)


def set_own(lua, G, mapping):
    t = lua.table()
    for key, dots in mapping.items():
        t[key] = lua_list(lua, dots)
    G.OWN = t


def receive(G, msg, sender="Warlock-Realm"):
    G.fire("CHAT_MSG_ADDON", "DoesItDie", msg, "PARTY", sender)


def entries(G, key):
    out = []
    for e in G.breakdown(key).values():
        out.append({k: e[k] for k in ("name", "spellID", "school", "damage", "expiresAt", "remote", "sender")})
    return out


# ---------------------------------------------------------------------------
print("== codec ==")
lua, G, party = new()
d1 = lua.eval("{ spellID = 6222, school = 32, damage = 240, nextTickIn = 1.43, ticksLeft = 4, interval = 3 }")
d2 = lua.eval("{ spellID = 980, school = 32, damage = 300.4, nextTickIn = 0.5, ticksLeft = 12, interval = 2 }")
msg = party.encode(GUID, lua_list(lua, [d1, d2]))
check("encode", msg, f"M;1;{GUID};6222:32:240:1.4:4:3,980:32:300:0.5:12:2")
check("encode an empty set clears the mob", party.encode(GUID, lua.table()), f"M;1;{GUID};")
kind, payload = party.decode(msg)
check("decode kind", kind, "M")
check("decode guid", payload.guid, GUID)
got = [(d.spellID, d.school, d.damage, d.nextTickIn, d.ticksLeft, d.interval) for d in payload.dots.values()]
check("decode dots", got, [(6222, 32, 240, 1.4, 4, 3), (980, 32, 300, 0.5, 12, 2)])
kind, payload = party.decode(f"M;1;{GUID};")
check("decode empty set", (kind, len(list(payload.dots.values()))), ("M", 0))
check("decode hello query", party.decode("H;1;q")[0], "H")
check("decode rejects another version", party.decode(f"M;2;{GUID};6222:32:240:1.4:4:3")[0], None)
check("decode rejects a non-GUID key", party.decode("M;1;plate:nameplate1;6222:32:240:1.4:4:3")[0], None)
check("decode rejects a bad dot", party.decode(f"M;1;{GUID};6222:32:abc:1.4:4:3")[0], None)
check("decode rejects zero ticks / interval", party.decode(f"M;1;{GUID};6222:32:240:1.4:0:3")[0], None)
check("decode rejects garbage", party.decode("hello")[0], None)
check("decode rejects a secret", party.decode(G.SECRET)[0], None)
many = [lua.eval("{ spellID = 100000, school = 32, damage = 99999, nextTickIn = 1.5, ticksLeft = 10, interval = 1.5 }")
        for _ in range(12)]
long_msg = party.encode(GUID, lua_list(lua, many))
check("encode keeps under 255 bytes (drops what doesn't fit)", len(long_msg) <= 255, True)
check("  ...and still decodes", party.decode(long_msg)[0], "M")
bad = lua.eval("{ spellID = 6222, school = 32, damage = SECRET, nextTickIn = 1, ticksLeft = 4, interval = 3 }")
check("encode skips a dot with a secret field", party.encode(GUID, lua_list(lua, [bad, d1])),
      f"M;1;{GUID};6222:32:240:1.4:4:3")

# ---------------------------------------------------------------------------
print("== receiving ==")
lua, G, party = new()
check("registers its addon message prefix", G.prefixes["DoesItDie"], True)
G.update(0.3)  # the option is on: its first tick
G.now = 100
receive(G, f"M;1;{GUID};6222:32:240:1:4:3")   # arrives at t=100: ticks at 101, 104, 107, 110
G.now = 100.5
check("anchored on arrival: full damage before the first tick", entries(G, GUID),
      [{"name": "Corruption", "spellID": 6222, "school": 32, "damage": 240, "expiresAt": 110, "remote": True,
        "sender": "Warlock"}])
G.now = 101.0
check("steps down when a tick is due", entries(G, GUID)[0]["damage"], 180)
G.now = 107.5
check("three ticks gone", entries(G, GUID)[0]["damage"], 60)
G.now = 110.0
check("nothing left after the last tick", entries(G, GUID), [])
check("expired mob is pruned", party.remote["Warlock"] is None or party.remote["Warlock"][GUID] is None, True)

G.now = 200
receive(G, f"M;1;{GUID};6222:32:240:1:4:3,980:32:120:0.5:6:2")
check("two DoTs from one sender", [e["spellID"] for e in entries(G, GUID)], [6222, 980])
receive(G, f"M;1;{GUID};980:32:120:0.5:6:2")
check("a new set replaces the old one (no double counting)", [e["spellID"] for e in entries(G, GUID)], [980])
receive(G, f"M;1;{GUID};")
check("an empty set clears the mob", entries(G, GUID), [])

receive(G, f"M;1;{GUID};6222:32:240:1:4:3")
check("other mobs get nothing", entries(G, GUID2), [])
check("per-client keys get nothing (plate)", entries(G, "plate:nameplate1"), [])
check("per-client keys get nothing (target)", entries(G, "target"), [])
check("a nil key gets nothing", entries(G, None), [])

receive(G, f"M;1;{GUID2};6222:32:999:1:4:3", sender="Priest Oone")
receive(G, f"M;1;{GUID2};6222:32:999:1:4:3", sender="Priest-Realm")
check("own echoes are ignored (both realm spellings)", entries(G, GUID2), [])
receive(G, f"M;1;{GUID2};6222:32:999:1:4:3", sender=G.SECRET)
check("a secret sender is ignored", entries(G, GUID2), [])
G.fire("CHAT_MSG_ADDON", "OtherAddon", f"M;1;{GUID2};6222:32:999:1:4:3", "PARTY", "Warlock")
check("other prefixes are ignored", entries(G, GUID2), [])

G.ns.db.partyDots = False
check("option off: nothing added", entries(G, GUID), [])
G.update(0.3)
G.ns.db.partyDots = True
check("turning the option off wipes what was received", entries(G, GUID), [])
receive(G, f"M;1;{GUID};6222:32:240:1:4:3")
G.ns.db.partyDots = False
receive(G, f"M;1;{GUID2};6222:32:240:1:4:3")
G.ns.db.partyDots = True
check("option off: messages are ignored", entries(G, GUID2), [])

receive(G, f"M;1;{GUID};6222:32:240:1:4:3")
G.members = lua.table()
G.fire("GROUP_ROSTER_UPDATE")
check("a sender who left the group is dropped", entries(G, GUID), [])
G.members = lua.eval('{ party1 = "Warlock" }')
receive(G, f"M;1;{GUID};6222:32:240:1:4:3")
G.inGroup = False
G.fire("GROUP_ROSTER_UPDATE")
check("leaving the group drops everything", entries(G, GUID), [])

# ---------------------------------------------------------------------------
print("== peers ==")
lua, G, party = new()
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, 101, 115, 3)]})
G.update(1)
check("no known party member with the option: nothing sent but a hello query", sent_list(G), ["H;1;q"])
G.clearSent()
receive(G, "H;1;q")
check("a hello query is answered", sent_list(G)[:1], ["H;1;a"])
G.clearSent()
receive(G, "H;1;q")
G.update(0.1)
check("  ...but not again within a few seconds",
      [m for m in sent_list(G) if m.startswith("H")], [])
G.clearSent()
receive(G, "H;1;a")
G.update(0.1)
check("an answer is never answered", [m for m in sent_list(G) if m.startswith("H")], [])

# Hello retries: a query lost to a loading screen, the throttle, or an instance must not stop sharing for good.
lua, G, party = new()
G.inInstance = True
G.update(1)  # option on (e.g. /reload) inside a dungeon
check("no hello inside an instance", sent_list(G), [])
G.inInstance = False
G.update(1)
check("leaving the instance: the hello goes out", sent_list(G), ["H;1;q"])
G.clearSent()
G.update(25)
check("still nobody answered: asked again (every ~20 s)", sent_list(G).count("H;1;q"), 1)
G.clearSent()
G.sendResult = 3
G.update(21)
G.sendResult = 0
G.update(3)
check("a throttled hello is retried", sent_list(G).count("H;1;q") >= 2, True)
receive(G, "H;1;a")
G.clearSent()
G.update(60)
check("no more hellos once someone answered", [m for m in sent_list(G) if m.startswith("H")], [])

# ---------------------------------------------------------------------------
print("== sending ==")
lua, G, party = new()
G.update(0.25)        # the hello query goes out first
receive(G, "H;1;a")  # Warlock has the option on
G.clearSent()
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, 101.4, 113.4, 3)], "plate:nameplate1": [dot(lua, 589, 32, 50, 101, 110, 3)],
                 "target": [dot(lua, 589, 32, 50, 101, 110, 3)]})
G.update(0.25)
out = sent_list(G)
check("own DoTs on a GUID mob are sent, with time to next tick", len(out), 1)
p = party.decode(out[0])[1].dots[1] if out else None
check("  payload: spell, school, damage, ticks left, interval", p and (p.spellID, p.school, p.damage, p.ticksLeft,
      p.interval), (594, 32, 180, 5, 3))
check("  payload: next tick in ~1.2 s (sent within a tick of the change)", p and 0.9 <= p.nextTickIn <= 1.3, True)
check("  on PARTY with our prefix", (G.sent[1].channel, G.sent[1].prefix), ("PARTY", "DoesItDie"))
G.clearSent()
G.update(3)
check("no change: not sent again", sent_list(G), [])
G.update(3.5)
check("a refresh goes out every few seconds while DoTs remain", len(sent_list(G)), 1)
G.clearSent()
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 3, G.now + 18, 3)]})  # recast
G.update(0.3)
check("a recast (new expiry) is sent right away", len(sent_list(G)), 1)
G.clearSent()
recast_at = G.now
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, recast_at + 3.3, recast_at + 18.3, 3)]})  # a tick re-anchored it
G.update(0.3)
check("an expiry nudged by a fraction of a second is not resent", sent_list(G), [])
set_own(lua, G, {GUID: [dot(lua, 594, 32, 260, recast_at + 3.3, recast_at + 18.3, 3)]})  # learned a bigger tick
G.update(0.3)
check("a new damage estimate is sent right away", len(sent_list(G)), 1)
G.clearSent()
set_own(lua, G, {})
G.update(0.3)
check("DoTs gone: an empty set is sent once", sent_list(G), [f"M;1;{GUID};"])
G.clearSent()
G.update(10)
check("  ...and then nothing", sent_list(G), [])

set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 1, G.now + 13, 3)]})
G.inInstance = True
G.update(1)
check("nothing is sent in an instance", sent_list(G), [])
G.inInstance = False
G.encounter = True
G.update(1)
check("nothing is sent during a boss encounter", sent_list(G), [])
G.encounter = False
G.update(0.3)
check("sent once it's allowed again", len(sent_list(G)), 1)
G.clearSent()
G.inRaid = True
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 2, G.now + 14, 3)]})
G.update(0.3)
check("in a raid group it goes to RAID", G.sent[1].channel if len(sent_list(G)) else None, "RAID")
G.inRaid = False
G.clearSent()

# Throttle: ten mobs change at once.
many_mobs = {f"Creature-0-1-2-3-4-{i:010d}": [dot(lua, 594, 32, 180, G.now + 2, G.now + 14, 3)] for i in range(10)}
G.update(8)  # refill the bucket
G.clearSent()
set_own(lua, G, many_mobs)
G.update(0.25)
first = len(sent_list(G))
check("a burst is capped below the client's limit of 10", first <= 6 and first >= 1, True)
G.update(1.0)
check("  ...about one more per second", len(sent_list(G)) - first in (1, 2), True)
G.update(5)
check("  ...and everything goes out eventually",
      len({m for m in sent_list(G) if m.startswith("M;1;Creature-0-1-2-3-4-")}), 10)
G.clearSent()

# Result 3 (throttled): kept and sent later.
G.sendResult = 3
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 2, G.now + 20, 3)]})
G.update(0.3)
tries = len(sent_list(G))
G.sendResult = 0
G.update(3)
check("a throttled send is retried", len(sent_list(G)) > tries, True)
G.clearSent()

# Result 11 (encounter lockdown) pauses sending.
G.sendResult = 11
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 2, G.now + 25, 3)]})
G.update(0.3)
G.update(2)
check("result 11 pauses sending (no hammering)", len(sent_list(G)), 1)
G.sendResult = 0
G.update(5)
check("  ...and resumes after the pause", len(sent_list(G)) >= 2, True)
G.clearSent()

# Turning the option off stops sending; turning it on asks who's there.
G.ns.db.partyDots = False
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 2, G.now + 30, 3)]})
G.update(1)
check("option off: nothing sent", sent_list(G), [])
G.ns.db.partyDots = True
G.update(0.3)
check("option on again: hello query first", sent_list(G)[:1], ["H;1;q"])
G.clearSent()

# Not in a group: nothing at all.
G.inGroup = False
G.fire("GROUP_ROSTER_UPDATE")
set_own(lua, G, {GUID: [dot(lua, 594, 32, 180, G.now + 2, G.now + 33, 3)]})
G.update(2)
check("not in a group: nothing sent", sent_list(G), [])

print()
if failures:
    print(f"{len(failures)} FAILED")
    sys.exit(1)
print("All passed.")
