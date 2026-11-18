-- Party DoTs (issue #25): share DoT estimates with party members who run DoesItDie with "Share DoTs with party" on,
-- so the marker and kill icon count everyone's DoTs on a mob.
--
-- Why messages: Forever hides party members' casts from addons (instant casts fire no UNIT_SPELLCAST_* event at
-- all; cast-time spells fire with spell ID, name and cast GUID secret), and target auras can't be read in combat.
-- So each client sends what its own tracking already knows. Verified with a probe on 1.60.1 (2026-11-15):
-- - SendAddonMessage on PARTY works in combat in the open world (~0.4-0.7 s to arrive).
-- - It returns 3 after a burst of 10 (throttled) and 11 during boss encounters (refused).
-- - Messages over 255 bytes are truncated without an error.
-- - Mob GUIDs are readable in the open world and match across clients; in instances they're secret, and so are
--   UnitIsUnit(target, party1target) and raid marker indexes, so there's no shared mob key there.
-- Hence: open world only, GUID keys only, one message per mob, a token bucket below the throttle.
--
-- Messages (prefix "DoesItDie"):
--   M;1;<guid>;<dots>  my DoTs on that mob, replacing what I sent before; dots = spellID:school:damage:nextTickIn:
--                      ticksLeft:interval, comma-separated; empty = none left
--   H;1;q / H;1;a      hello query (I just turned it on or joined) / answer. Nothing is sent until someone answers,
--                      so a party without the addon costs nothing.
-- Times travel as seconds from now (GetTime() differs per machine); the receiver anchors them to its own clock on
-- arrival and steps the damage down tick by tick.

local _, ns = ...

local PREFIX = "DoesItDie"
local VERSION = 1
local MAX_BYTES = 255
local TICK_SECONDS = 0.2         -- how often the sender looks at its own DoTs
local REFRESH_SECONDS = 6        -- resend a mob's unchanged DoTs this often (covers a lost message)
local BUCKET_SIZE, BUCKET_RATE = 6, 1 -- burst / per second; the client refuses after a burst of 10
local THROTTLE_BACKOFF = 1       -- result 3: wait this long
local REFUSED_PAUSE = 5          -- result 11 (boss encounter) or any other error: pause this long
local ANSWER_GAP = 5             -- answer one sender's hello query at most this often
local HELLO_RETRY = 20           -- ask again this often while no party member has answered
local EXPIRY_TOLERANCE = 1       -- seconds: tick re-anchoring nudges expiries; a recast moves them more
local TICK_TOLERANCE = 0.05      -- a learned tick size within 5% isn't worth a message

local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end

local party = { remote = {}, peers = {} }
ns.party = party

local sent = {}          -- guid -> { shape = spellID -> { expiresAt, perTick }, at = GetTime() } as last sent
local pending = {}       -- guid -> true: send this mob's current set when the bucket allows
local answeredAt = {}    -- sender -> GetTime() of my last hello answer
local tokens, tokensAt = BUCKET_SIZE, nil
local pausedUntil = 0
local wasEnabled = false
local helloAt = -math.huge       -- when my last hello query went out
local prefixRegistered = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r == true
end

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r, r2 = pcall(fn, ...)
    if ok and not isSecret(r) then return r, r2 end
end

local function trace(msg)
    if ns.trace then ns.trace(msg) end
end

local function enabled()
    return ns.db ~= nil and ns.db.partyDots == true
end

-- A creature GUID ("Creature-0-6826-..."), the only mob key both clients share. Not plate:nameplateN or target.
local function isGuid(key)
    return type(key) == "string" and not isSecret(key) and key:match("^%a+%-%d+%-") ~= nil
end

-- A sender's name without the realm: Forever has given both "Name Realm" and "Name-Realm".
local function baseName(name)
    if type(name) ~= "string" or isSecret(name) then return nil end
    return name:match("^[^%-%s]+")
end

local function myName()
    return baseName(call(UnitName, "player"))
end

local function formatNumber(v)
    if v == math.floor(v) then return string.format("%d", v) end
    return (string.format("%.1f", v):gsub("%.0$", ""))
end

local function finite(v)
    return type(v) == "number" and not isSecret(v) and v == v and v ~= math.huge and v ~= -math.huge
end

---------------------------------------------------------------------------
-- Codec
---------------------------------------------------------------------------

-- dots: { spellID, school, damage, nextTickIn, ticksLeft, interval } each. Dots with unreadable fields are skipped;
-- dots that don't fit in 255 bytes are left out.
function party.encode(guid, dots)
    local msg = "M;" .. VERSION .. ";" .. guid .. ";"
    local first = true
    for _, d in ipairs(dots) do
        if finite(d.spellID) and finite(d.school) and finite(d.damage) and finite(d.nextTickIn)
            and finite(d.ticksLeft) and finite(d.interval) then
            local item = string.format("%d:%d:%d:%s:%d:%s", d.spellID, d.school, math.floor(d.damage + 0.5),
                formatNumber(math.max(0, d.nextTickIn)), d.ticksLeft, formatNumber(d.interval))
            local candidate = msg .. (first and "" or ",") .. item
            if #candidate > MAX_BYTES then break end
            msg, first = candidate, false
        end
    end
    return msg
end

-- kind, payload (M: { guid, dots }; H: { query = bool }) or nil.
function party.decode(msg)
    if isSecret(msg) or type(msg) ~= "string" then return nil, "not a string" end
    local kind, version, rest = msg:match("^(%a);(%d+);?(.*)$")
    if not kind or tonumber(version) ~= VERSION then return nil, "not ours or another version" end
    if kind == "H" then return "H", { query = rest == "q" } end
    if kind ~= "M" then return nil, "unknown kind" end
    local guid, list = rest:match("^([^;]+);(.*)$")
    if not isGuid(guid) then return nil, "bad mob key" end
    local dots = {}
    for item in list:gmatch("[^,]+") do
        local a, b, c, d, e, f = item:match("^(%d+):(%d+):(%d+):([%d%.]+):(%d+):([%d%.]+)$")
        local dot = { spellID = tonumber(a), school = tonumber(b), damage = tonumber(c), nextTickIn = tonumber(d),
            ticksLeft = tonumber(e), interval = tonumber(f) }
        if not (dot.spellID and dot.school and dot.damage and dot.nextTickIn and dot.ticksLeft and dot.interval)
            or dot.ticksLeft < 1 or dot.interval <= 0 then
            return nil, "bad dot"
        end
        dots[#dots + 1] = dot
    end
    return "M", { guid = guid, dots = dots }
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Ticks still to come at `now`: the next tick was due at nextTickAt, then one every interval.
local function ticksLeftAt(d, now)
    if now < d.nextTickAt then return d.ticksLeft end
    return math.max(0, d.ticksLeft - (math.floor((now - d.nextTickAt) / d.interval) + 1))
end

local function store(sender, guid, dots, now)
    local mobs = party.remote[sender]
    if #dots == 0 then
        if mobs then mobs[guid] = nil end
        return
    end
    if not mobs then
        mobs = {}
        party.remote[sender] = mobs
    end
    local list = {}
    for _, d in ipairs(dots) do
        local nextTickAt = now + d.nextTickIn
        list[#list + 1] = { spellID = d.spellID, school = d.school, perTick = d.damage / d.ticksLeft,
            ticksLeft = d.ticksLeft, interval = d.interval, nextTickAt = nextTickAt, receivedAt = now,
            expiresAt = nextTickAt + (d.ticksLeft - 1) * d.interval }
    end
    mobs[guid] = list
end

-- Adds party members' DoTs on the mob behind `key` to `list` (DoesItDie.lua's dotBreakdown calls this).
function party.addRemote(key, list)
    if not enabled() or not isGuid(key) then return end
    local now = GetTime()
    for sender, mobs in pairs(party.remote) do
        local dots = mobs[key]
        if dots then
            local any = false
            for _, d in ipairs(dots) do
                local left = ticksLeftAt(d, now)
                if left > 0 then
                    any = true
                    local name = C_Spell and call(C_Spell.GetSpellName, d.spellID)
                    list[#list + 1] = { name = name or ("Spell " .. d.spellID), spellID = d.spellID,
                        school = d.school, appliedAt = d.receivedAt, expiresAt = d.expiresAt,
                        damage = d.perTick * left, remote = true, sender = sender }
                end
            end
            if not any then mobs[key] = nil end
        end
    end
end

local function forgetAll()
    wipe(party.remote)
    wipe(party.peers)
    wipe(sent)
    wipe(pending)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function channel()
    return call(IsInRaid) == true and "RAID" or "PARTY"
end

local function refill(now)
    if tokensAt then tokens = math.min(BUCKET_SIZE, tokens + (now - tokensAt) * BUCKET_RATE) end
    tokensAt = now
end

-- One send through the bucket. True when the client accepted it.
-- At load, and again before sending in case C_ChatInfo wasn't there yet.
local function ensurePrefix()
    if prefixRegistered or not (C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function") then
        return
    end
    prefixRegistered = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
end
ensurePrefix()

local function send(msg, now)
    if not (C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function") then return false end
    ensurePrefix()
    refill(now)
    if now < pausedUntil or tokens < 1 then return false end
    tokens = tokens - 1
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel())
    if ok and (result == nil or result == 0 or result == true) then return true end
    if ok and result == 3 then
        tokens, pausedUntil = 0, now + THROTTLE_BACKOFF
    else
        pausedUntil = now + REFUSED_PAUSE
    end
    trace("PARTY send refused (" .. tostring(ok and result or "error") .. "): " .. msg:sub(1, 60))
    return false
end

local function canSend()
    if call(IsInGroup) ~= true then return false end
    if call(IsInInstance) == true then return false end
    if call(IsEncounterInProgress) == true then return false end
    return true
end

-- My DoTs on a mob as message dots, plus what the receiver's estimate depends on (spell -> expiry, tick size), to
-- tell a real change (recast, new or dropped DoT, new tick size) from the damage running down.
local function outgoing(list, now)
    local dots, shape = {}, {}
    for _, d in ipairs(list or {}) do
        if finite(d.nextTickAt) and finite(d.expiresAt) and finite(d.interval) and d.interval > 0
            and finite(d.damage) and d.damage > 0 and d.nextTickAt <= d.expiresAt + d.interval / 2 then
            local ticksLeft = math.floor((d.expiresAt - d.nextTickAt) / d.interval + 0.5) + 1
            dots[#dots + 1] = { spellID = d.spellID, school = d.school, damage = d.damage,
                nextTickIn = d.nextTickAt - now, ticksLeft = ticksLeft, interval = d.interval }
            shape[d.spellID] = { expiresAt = d.expiresAt, perTick = d.damage / ticksLeft }
        end
    end
    return dots, shape
end

local function changed(shape, last)
    for spellID, s in pairs(shape) do
        local l = last[spellID]
        if not l or math.abs(s.expiresAt - l.expiresAt) > EXPIRY_TOLERANCE
            or math.abs(s.perTick - l.perTick) > math.max(1, l.perTick * TICK_TOLERANCE) then
            return true
        end
    end
    for spellID in pairs(last) do
        if not shape[spellID] then return true end
    end
    return false
end

local function sendHello(query, now)
    local ok = send("H;" .. VERSION .. ";" .. (query and "q" or "a"), now)
    if ok and query then helloAt = now end
    return ok
end

local function senderTick(now)
    local own = ns.tracking and ns.tracking.ownDots and ns.tracking.ownDots() or {}
    local current = {}
    for key, list in pairs(own) do
        if isGuid(key) then
            local dots, shape = outgoing(list, now)
            if #dots > 0 then
                current[key] = { dots = dots, shape = shape }
                local last = sent[key]
                if not last or changed(shape, last.shape) or now - last.at >= REFRESH_SECONDS then
                    pending[key] = true
                end
            end
        end
    end
    for key in pairs(sent) do
        if not current[key] then pending[key] = true end -- gone: tell them once
    end
    for key in pairs(pending) do
        local c = current[key]
        local msg = party.encode(key, c and c.dots or {})
        if not send(msg, now) then break end
        pending[key] = nil
        sent[key] = c and { shape = c.shape, at = now } or nil
        trace("PARTY send " .. msg)
    end
end

local function tick(now)
    local on = enabled()
    if on ~= wasEnabled then
        wasEnabled = on
        forgetAll()
        helloAt = -math.huge
    end
    if not on or not canSend() then return end
    if next(party.peers) == nil then
        -- Nobody known yet: ask (now, then every HELLO_RETRY). Covers a /reload inside a dungeon, a loading screen,
        -- or a throttled query.
        if now - helloAt >= HELLO_RETRY then sendHello(true, now) end
        return
    end
    senderTick(now)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function onMessage(prefix, text, _, sender)
    if isSecret(prefix) or prefix ~= PREFIX or not enabled() then return end
    local who = baseName(sender)
    if not who or who == myName() then return end
    local kind, payload = party.decode(text)
    if not kind then return end
    local now = GetTime()
    party.peers[who] = true
    if kind == "H" then
        if payload.query and now - (answeredAt[who] or -math.huge) >= ANSWER_GAP and canSend() then
            answeredAt[who] = now
            sendHello(false, now)
        end
    else
        store(who, payload.guid, payload.dots, now)
        trace(string.format("PARTY recv from %s: %s", who, text))
    end
end

-- Who's in the group now (names without realm).
local function groupNames()
    local names = {}
    local raid = call(IsInRaid) == true
    for i = 1, raid and 40 or 4 do
        local name = baseName(call(UnitName, (raid and "raid" or "party") .. i))
        if name then names[name] = true end
    end
    return names
end

local function onRoster()
    if call(IsInGroup) ~= true then
        forgetAll()
        return
    end
    local names = groupNames()
    for who in pairs(party.peers) do
        if not names[who] then party.peers[who] = nil end
    end
    for who in pairs(party.remote) do
        if not names[who] then party.remote[who] = nil end
    end
    if next(party.peers) == nil then helloAt = -math.huge end -- ask on the next tick
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        onMessage(...)
    else
        onRoster()
    end
end)
local elapsedSince = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < TICK_SECONDS - 0.001 then return end
    elapsedSince = 0
    tick(GetTime())
end)
