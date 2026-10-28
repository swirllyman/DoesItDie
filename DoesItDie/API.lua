-- DoesItDie's public API: lets other addons (unit frames, nameplates, UI suites) show the estimate on their own
-- frames instead of DoesItDie attaching to every one of them (issue #24). Usage and the StatusBar trick a consumer
-- needs are in API.md at the repository root.
--
-- What it hands out is the tracking's own numbers: the remaining damage of the player's DoTs on the mob behind a
-- unit token. Those are plain numbers, but the mob's health is secret in Forever, so a consumer can't compare the
-- two either; it feeds both into a StatusBar, as Display.lua does.
--
-- Loaded last: it wraps ns.refresh (Display.lua) to notice changes.

local _, ns = ...

local API_VERSION = 1
local EVENT = "DOTS_CHANGED"
-- Unit tokens watched for changes while anyone is registered: what UNIT_COMBAT covers, so what tracking can update.
local WATCHED = { "target", "focus" }
for i = 1, 40 do WATCHED[#WATCHED + 1] = "nameplate" .. i end

local api = {}
local callbacks = {} -- owner -> function
local lastSeen = {} -- unit token -> "mob key|total|count" when last reported
local reportedErrors = {}

local function trackedKey(unit)
    if type(unit) ~= "string" then return nil end
    local ok, key = pcall(ns.tracking.unitKey, unit)
    return ok and key or nil
end

-- Total remaining damage of the player's DoTs on the mob behind `unit` (rounded), and how many DoTs that is.
-- 0, 0 when there are none or the unit can't be tracked.
function api.GetRemainingDamage(unit)
    if not trackedKey(unit) then return 0, 0 end
    local list, total = ns.dotBreakdownForUnit(unit)
    return math.floor(total + 0.5), #list
end

-- The player's DoTs on the mob behind `unit`, oldest first: a new list of new tables (safe to keep or change), each
-- { name, spellID, school (bit mask, 1 = Physical), damage (remaining), appliedAt, expiresAt (GetTime() seconds),
-- provisional (true while it's still being cast) }. DoTs still waiting for their first tick aren't in it.
function api.GetDoTs(unit)
    local result = {}
    if not trackedKey(unit) then return result end
    local list = ns.dotBreakdownForUnit(unit)
    for i, entry in ipairs(list) do
        result[i] = { name = entry.name, spellID = entry.spellID, school = entry.school,
            damage = math.floor(entry.damage + 0.5), appliedAt = entry.appliedAt, expiresAt = entry.expiresAt,
            provisional = entry.provisional or false }
    end
    return result
end

-- func(event, unit) runs whenever the remaining damage on `unit` (target, focus or nameplateN) changes, or the unit
-- now shows another mob; event is "DOTS_CHANGED". One function per owner (any value, e.g. your addon's name or
-- frame): registering again replaces it.
function api.RegisterCallback(owner, func)
    assert(owner ~= nil, "DoesItDie.RegisterCallback: owner is required")
    assert(type(func) == "function", "DoesItDie.RegisterCallback: func must be a function")
    callbacks[owner] = func
end

function api.UnregisterCallback(owner)
    if owner ~= nil then callbacks[owner] = nil end
end

local function fire(unit)
    for owner, func in pairs(callbacks) do
        local ok, err = pcall(func, EVENT, unit)
        if not ok and not reportedErrors[err] then
            reportedErrors[err] = true
            ns.trace("API callback error (" .. tostring(owner) .. "): " .. tostring(err))
        end
    end
end

-- After every refresh (0.1s, and on casts and ticks): report each watched unit whose numbers changed.
local function checkChanges()
    if next(callbacks) == nil then
        if next(lastSeen) then wipe(lastSeen) end
        return
    end
    for _, unit in ipairs(WATCHED) do
        local state
        local key = UnitExists(unit) and trackedKey(unit)
        if key then
            local total, count = api.GetRemainingDamage(unit)
            if count > 0 then state = key .. "|" .. total .. "|" .. count end
        end
        if state ~= lastSeen[unit] then
            lastSeen[unit] = state
            fire(unit)
        end
    end
end

local refresh = ns.refresh
ns.refresh = function()
    refresh()
    checkChanges()
end

api.API_VERSION = API_VERSION
DoesItDie = api
