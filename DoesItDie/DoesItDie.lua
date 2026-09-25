-- DoesItDie
-- Tracks your DoTs on the target and shows the damage they still have to deal as a marker on its health
-- bar (if the health ends inside the marker, the DoTs will kill it), plus a skull on the portrait when
-- they're lethal. Look and animation are configurable in the options panel (/did).
--
-- In WoW: Forever, target health, player stats and auras are secret in combat, so addon code can
-- never compare "health vs DoT damage" itself. What stays readable:
--   * our own casts (UNIT_SPELLCAST_SUCCEEDED) and spell descriptions -> which DoT, base damage, duration
--   * UNIT_COMBAT damage amounts on units -> actual tick sizes (already include resists/reductions)
-- StatusBars accept secret values, so the "damage >= health" comparison is done by the widget, not
-- by Lua: see the skull notes in the Display section.

local ADDON_NAME, ns = ... -- ns is shared with Options.lua

local UPDATE_INTERVAL = 0.1
local DEFAULT_TICK_INTERVAL = 3
-- Seconds either side of an expected tick time. Observed on Forever: the first tick lands within ~0.1s of one
-- interval after the cast, and later ticks within ~0.1s of the first tick's rhythm. Tight windows keep melee
-- auto-attacks (same Physical school as bleeds, similar size, ~1s rhythm) from passing as ticks.
local TICK_MATCH_WINDOW = 0.45
local TICK_MATCH_WINDOW_ANCHORED = 0.25
local MISSED_TICKS_BEFORE_DROP = 2  -- a DoT that never ticks was resisted/immune
-- Once a DoT's tick size is known, same-school hits further off than this are someone else's (the Imp's
-- Firebolt next to Immolate, white hits next to Rip). Ticks within one cast barely vary (15,15,15,16);
-- the minimum slack of 1 covers rounding (3 vs 4).
local TICK_AMOUNT_TOLERANCE = 0.25
-- Check for the first tick against a size learned on an earlier cast (gear/AP may have changed a little).
local FIRST_TICK_AMOUNT_TOLERANCE = 0.3
-- A crit tick is 1.5-2x a normal one; anything else flagged as a crit (white-hit crits) isn't this DoT.
local CRIT_MIN_RATIO, CRIT_MAX_RATIO = 1.3, 2.3
local DB_VERSION = 5                -- bump to discard learned data from older, buggier versions

-- Tick intervals that differ from the 3s default and aren't stated in the description.
local KNOWN_TICK_INTERVALS = {
    ["Insect Swarm"] = 2,
    ["Curse of Agony"] = 2,
    ["Bane of Agony"] = 2, -- Forever's name for Curse of Agony
    ["Fireball"] = 2,
    ["Holy Fire"] = 2,
    ["Rip"] = 2,
    ["Rupture"] = 2,
}

-- DoTs whose ticks aren't even: each tick is the average tick times its factor (factors average 1, so the
-- tooltip total still holds). Agony is back-loaded; seen in-game on Forever (log 166015.8, 72 over 24s):
-- ticks 3,3,3,3 then 6,6,... then 9s. Everything else ticks evenly.
local AGONY_SHAPE = { 0.5, 0.5, 0.5, 0.5, 1, 1, 1, 1, 1.5, 1.5, 1.5, 1.5 }
local TICK_SHAPES = {
    ["Bane of Agony"] = AGONY_SHAPE, -- Forever's name
    ["Curse of Agony"] = AGONY_SHAPE,
}

-- Descriptions that don't name their school.
local SCHOOL_BY_NAME = {
    ["Siphon Life"] = 32,
}

-- Read like DoTs but aren't one on the current target: ground/area effects, channels, traps, and
-- delayed damage (Wyvern Sting only starts after the sleep).
local IGNORED_SPELLS = {
    ["Rain of Fire"] = true, ["Hellfire"] = true, ["Blizzard"] = true, ["Flamestrike"] = true,
    ["Consecration"] = true, ["Hurricane"] = true, ["Volley"] = true,
    ["Drain Life"] = true, ["Drain Soul"] = true, ["Drain Mana"] = true, ["Health Funnel"] = true,
    ["Mind Flay"] = true, ["Arcane Missiles"] = true, ["Starshards"] = true,
    ["Immolation Trap"] = true, ["Explosive Trap"] = true, ["Wyvern Sting"] = true,
}

local SCHOOL_MASKS = {
    Physical = 1, Holy = 2, Fire = 4, Nature = 8, Frost = 16, Shadow = 32, Arcane = 64,
    Frostfire = 4 + 16, -- Forever's Frostfire Bolt: combined schools report as the OR of their masks
}

-- User options (edited in the options panel, saved in DoesItDieDB).
local DEFAULTS = {
    -- Skull
    showSkull = true,
    skullIcon = "cross",
    skullSize = 64,
    skullPulse = true,
    skullOffsetX = 0,
    skullOffsetY = 0,
    -- Damage marker
    showMarkers = true,
    fillTexture = "stripes",
    fillColor = "red",
    fillOpacity = 100,
    dotColors = "each",
    segmentDividers = true,
    outlineStyle = "dashed",
    dashLength = 4,
    outlineThickness = 1,
    outlineColor = "red",
    outlineOpacity = 85,
    -- Animation
    smoothMotion = true,
    flashOnApply = true,
    pulseOutline = true,
    -- Effects
    showSpark = true,
    showGlow = true,
    glowSize = 7,
    showShine = true,
    shineInterval = 3,
    scrollStripes = true,
    -- Damage text
    showLabel = false,
    labelPosition = "center",
    labelSize = 10,
    labelColor = "white",
    -- Misc
    debug = false,
    -- Accuracy
    waitFirstTick = "off",
    estimateDuringCast = true,
    -- Nameplates (Nameplates.lua): their own look, since enemy plates are red. Defaults read well on red.
    nameplateMode = "markerIcon",
    nameplateIconSize = 18,
    nameplateIconPosition = "left", -- the level badge sits right of the bar on Forever's plates
    plateIconOffsetX = 0,
    plateIconOffsetY = 15,          -- clear of the level number, which draws over the icon
    plateIcon = "skull",
    plateDotColors = "single",
    plateFillTexture = "flat",
    plateFillColor = "white",
    plateFillOpacity = 45,
    plateOutlineStyle = "solid",
    plateDashLength = 2,
    plateOutlineThickness = 1,
    plateOutlineColor = "white",
    plateOutlineOpacity = 100,
}

-- "Wait for first tick": whether a DoT counts toward the marker before its first tick has landed.
-- "unsure" = only when the starting estimate is shaky (finisher with unknown combo points, or no tick size
-- learned yet for that spell).
local WAIT_MODES = {
    { id = "off",    label = "Never (estimate straight away)" },
    { id = "unsure", label = "When unsure" },
    { id = "always", label = "Always (real ticks only)" },
}

local COLOR_PRESETS = {
    { id = "purple", label = "Purple", rgb = { 0.7, 0.3, 1 } },
    { id = "gold",   label = "Gold",   rgb = { 1, 0.85, 0.1 } },
    { id = "white",  label = "White",  rgb = { 1, 1, 1 } },
    { id = "red",    label = "Red",    rgb = { 1, 0.2, 0.2 } },
    { id = "orange", label = "Orange", rgb = { 1, 0.55, 0.1 } },
    { id = "green",  label = "Green",  rgb = { 0.3, 1, 0.3 } },
    { id = "cyan",   label = "Cyan",   rgb = { 0.2, 0.9, 1 } },
    { id = "pink",   label = "Pink",   rgb = { 1, 0.45, 0.6 } },
    { id = "black",  label = "Black",  rgb = { 0, 0, 0 } },
}
local COLOR_BY_ID = {}
for _, preset in ipairs(COLOR_PRESETS) do COLOR_BY_ID[preset.id] = preset.rgb end

local MAX_TRACE_LINES = 500

local db
local dotsByTarget = {}     -- targetKey -> { [spellName] = dot }
local warnedSecretGuid = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff6666DoesItDie|r " .. msg)
end

-- Always recorded to SavedVariables (db.log) for diagnosing accuracy; echoed to chat with /did debug.
local function trace(msg)
    if not db then return end
    table.insert(db.log, string.format("%.1f %s", GetTime(), msg))
    if #db.log > MAX_TRACE_LINES then table.remove(db.log, 1) end
    if db.debug then print("|cff888888" .. msg .. "|r") end
end

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

-- Stable key for the mob behind a unit token, or nil if the unit can't be tracked.
-- The same hit arrives for target, nameplateN and softenemy, and their GUIDs may not all be readable,
-- so a hidden GUID only affects that one unit token.
local function unitKey(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if ok and not isSecret(guid) then return guid end
    if unit ~= "target" then return nil end
    if not warnedSecretGuid then
        warnedSecretGuid = true
        trace("Target GUID is secret; tracking DoTs on the current target only")
    end
    return "target"
end

local function spellNameAndDescription(spellID)
    local name, desc
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(spellID)
    else
        name = GetSpellInfo(spellID)
    end
    local descFn = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
    if descFn then desc = descFn(spellID) end
    return name, desc
end

local function schoolFromWords(words)
    local school = SCHOOL_MASKS.Physical
    for word in words:gmatch("%a+") do
        if SCHOOL_MASKS[word] then school = SCHOOL_MASKS[word] end
    end
    return school
end

-- Finishers (Rip, Rupture) list their DoT per combo point:
--   "1 point : 243 damage over 12 sec. 2 points: 396 damage over 12 sec. ..."   (Rip; note the stray space)
--   "1 point: 25 damage over 8 secs\n ... 5 points: 87 damage over 16 secs"      (Rupture)
-- Returns total, school, duration for the given points (clamped to the listed range), or nil if the
-- finisher has no per-point DoT (e.g. Eviscerate).
local function parseFinisher(desc, comboPoints)
    local byPoints, highest = {}, 0
    for pointsText, amount, secs in desc:gmatch("(%d+) points?%s*:%s*(%d+) damage over (%d+%.?%d*) sec") do
        local points = tonumber(pointsText)
        byPoints[points] = { total = tonumber(amount), duration = tonumber(secs) }
        highest = math.max(highest, points)
    end
    if highest == 0 then return nil end
    local entry = byPoints[math.max(1, math.min(comboPoints, highest))] or byPoints[highest]
    return entry.total, SCHOOL_MASKS.Physical, entry.duration
end

-- Returns total damage, school mask, duration and (if the description states it) tick interval.
--   "... 10 Nature damage over 15 sec."  Takes the last such clause, so Immolate's
--       "11 Fire damage and then an additional 20 Fire damage over 15 sec" yields the periodic part.
--   "Transfers 15 health from the target to the caster every 3 sec. Lasts 30 sec."  (Siphon Life)
-- comboPoints is only used for finishers. (Rake/Garrote merely award a combo point, so finishers are
-- recognised by "Finishing move", not "combo point".)
local function parseDot(desc, comboPoints)
    if type(desc) ~= "string" or isSecret(desc) then return nil end
    if desc:find("Finishing move") then return parseFinisher(desc, comboPoints or 5) end
    -- Weapon enchants (rogue poisons) describe a proc DoT but aren't cast on the target. Match the enchant
    -- wording only: Lacerate's tooltip also mentions "weapon damage".
    if desc:find("[Cc]oats a weapon") then return nil end
    -- Heals over time: Forever's Renew reads "Heals the target of 830 damage over 15 sec".
    if desc:find("^Heals") then return nil end

    local total, school, duration
    for amount, words, secs in desc:gmatch("(%d+)%s*([%a ]-)%s*damage over (%d+%.?%d*) sec") do
        total, school, duration = tonumber(amount), schoolFromWords(words), tonumber(secs)
    end
    if total and duration > 0 then return total, school, duration end

    local amount, words, every = desc:match("(%d+)%s*([%a ]-)%s*damage every (%d+%.?%d*) sec")
    if not amount then
        amount, every = desc:match("(%d+) health.-every (%d+%.?%d*) sec")
        words = ""
    end
    local lasts = desc:match("[Ll]asts (%d+%.?%d*) sec")
    if amount and every and lasts then
        every, lasts = tonumber(every), tonumber(lasts)
        if every > 0 and lasts > 0 then
            return tonumber(amount) * math.floor(lasts / every + 0.5), schoolFromWords(words), lasts, every
        end
    end
end

---------------------------------------------------------------------------
-- DoT tracking
---------------------------------------------------------------------------

-- Best known average damage per tick: observed average of non-crit ticks, else learned from earlier casts,
-- else the description. Crits are one-offs, so they never raise the expectation for later ticks. For shaped
-- DoTs (TICK_SHAPES) ticks are stored divided by their factor, so this is the average tick, not the latest.
local function expectedTick(dot)
    if dot.normalTicks > 0 then return dot.tickSum / dot.normalTicks end
    return (dot.tickKey and db.ticks[dot.tickKey]) or (dot.total / dot.totalTicks)
end

-- Which tick of the DoT (1 = first) lands around `when`.
local function tickNumberAt(dot, when)
    return math.max(1, math.floor((when - dot.appliedAt) / dot.interval + 0.5))
end

-- The factor for tick `number` (1 for evenly ticking DoTs). Shapes are stretched to the DoT's tick count.
local function tickShape(dot, number)
    local shape = dot.shape
    if not shape then return 1 end
    local i = math.ceil(math.min(math.max(number, 1), dot.totalTicks) / dot.totalTicks * #shape)
    return shape[math.max(1, math.min(i, #shape))]
end

-- A waiting DoT doesn't count toward the marker until its first tick lands (see WAIT_MODES).
local function isWaiting(dot)
    if dot.ticksSeen > 0 then return false end
    if db.waitFirstTick == "always" then return true end
    return db.waitFirstTick == "unsure" and dot.unsure
end

-- Combo points, for finishers. By UNIT_SPELLCAST_SUCCEEDED they're already spent, so they're read when the
-- cast is sent. They were unreadable in combat on the Forever beta, so the addon also counts them itself:
-- builders say "Awards N combo point(s)" in their tooltips; a dodge/parry/miss right after takes them back;
-- a finisher or a target change resets the count. If neither source knows, finishers assume the lowest
-- entry, so the estimate errs low (no false skull) and nothing is learned from that cast.
local COMBO_CAP = 5
local COMBO_CACHE_SECONDS = 3
local comboAtSend, lastComboPoints, lastComboAt = nil, nil, 0
local countedPoints = 0

-- Cast outcomes. UNIT_COMBAT reports a dodge/parry/miss/resist/immune on the target, but not which attack it
-- belongs to. A cast's own result arrives almost at once (same frame in the logs), so the first outcome on the
-- target right after a cast decides: a hit means it landed, an avoid means it didn't. A melee auto-attack
-- avoided in that instant is rare; it makes the addon drop a DoT that landed, which errs low (never a false
-- kill). Results can also arrive just before the cast event, hence the short look-back.
local OUTCOME_WINDOW = 0.4
local OUTCOME_LOOKBACK = 0.25
local AVOIDED_ACTIONS = {
    MISS = true, DODGE = true, PARRY = true, EVADE = true, IMMUNE = true, DEFLECT = true, RESIST = true, REFLECT = true,
}
local lastBuilder    -- { points, at }: builder whose outcome isn't known yet
local lastDotCast    -- { key, name, dot, previous, at }: DoT cast whose outcome isn't known yet
local lastOutcome    -- { avoided, action, at }: most recent outcome on the target

local function describeReading(ok, value)
    if not ok then return "error" end
    if value == nil then return "nil" end
    if isSecret(value) then return "secret" end
    return tostring(value)
end

-- Returns the best plain reading (or nil) and a description of what each API returned, for the log.
local function readComboPoints()
    local best, parts = nil, {}
    local function consider(label, ok, points)
        table.insert(parts, label .. "=" .. describeReading(ok, points))
        if ok and type(points) == "number" and not isSecret(points) then best = math.max(best or 0, points) end
    end
    if GetComboPoints then consider("GetComboPoints", pcall(GetComboPoints, "player", "target")) end
    if UnitPower and Enum and Enum.PowerType and Enum.PowerType.ComboPoints then
        consider("UnitPower", pcall(UnitPower, "player", Enum.PowerType.ComboPoints))
    end
    return best, table.concat(parts, " ")
end

local function rememberComboPoints()
    local points = readComboPoints()
    if points and points > 0 then lastComboPoints, lastComboAt = points, GetTime() end
    return points
end

local function isFinisherDescription(desc)
    return type(desc) == "string" and not isSecret(desc) and desc:find("Finishing move") ~= nil
end

local function onCastSent(spellID)
    local ok, _, desc = pcall(spellNameAndDescription, spellID)
    if not ok or not isFinisherDescription(desc) then return end
    local points, readings = readComboPoints()
    comboAtSend = points
    trace("COMBO at send: " .. readings .. ", counted=" .. countedPoints)
end

-- An avoid that arrived just before the cast event (see OUTCOME_LOOKBACK), or nil.
local function avoidJustBefore()
    if lastOutcome and lastOutcome.avoided and GetTime() - lastOutcome.at <= OUTCOME_LOOKBACK then
        return lastOutcome.action
    end
end

-- A builder was cast: count its points unless it was already avoided, else wait for its outcome.
local function onBuilderCast(points)
    local avoided = avoidJustBefore()
    if avoided then
        trace("COMBO builder " .. avoided .. " (before cast event), counted=" .. countedPoints)
        return
    end
    countedPoints = math.min(COMBO_CAP, countedPoints + points)
    lastBuilder = { points = points, at = GetTime() }
end

-- A DoT cast whose result was avoided isn't on the target: drop it. (Waiting for a first tick to prove it
-- instead doesn't work for bleeds: melee white hits look just like ticks.) A recast replaced a DoT that is
-- still ticking, so that one is put back.
local function removeAvoidedDot(cast, action)
    local dots = dotsByTarget[cast.key]
    if not dots or dots[cast.name] ~= cast.dot then return end
    if cast.previous then
        dots[cast.name] = cast.previous
        trace("AVOID " .. action .. " right after " .. cast.name .. " recast; keeping the earlier one")
    else
        dots[cast.name] = nil
        trace("AVOID " .. action .. " right after " .. cast.name .. "; dropped")
    end
end

local function onTargetAvoided(action)
    local now = GetTime()
    lastOutcome = { avoided = true, action = action, at = now }
    if lastBuilder and now - lastBuilder.at <= OUTCOME_WINDOW then
        countedPoints = math.max(0, countedPoints - lastBuilder.points)
        trace("COMBO builder " .. action .. ", counted=" .. countedPoints)
    end
    if lastDotCast and now - lastDotCast.at <= OUTCOME_WINDOW then
        removeAvoidedDot(lastDotCast, action)
    end
    lastBuilder, lastDotCast = nil, nil
end

-- A hit on the target: the pending casts landed (a later avoid belongs to something else).
local function onTargetHit()
    lastOutcome = { avoided = false, at = GetTime() }
    lastBuilder, lastDotCast = nil, nil
end

local function resetComboCount()
    countedPoints, lastBuilder = 0, nil
end

local function forgetPendingOutcomes()
    lastBuilder, lastDotCast, lastOutcome = nil, nil, nil
end

-- Returns points and where they came from, or nil and "unknown".
local function comboPointsForCast()
    local points, source = comboAtSend, "read"
    if not (points and points > 0) then
        if lastComboPoints and GetTime() - lastComboAt <= COMBO_CACHE_SECONDS then
            points, source = lastComboPoints, "cached"
        elseif countedPoints > 0 then
            points, source = countedPoints, "counted"
        else
            points, source = nil, "unknown"
        end
    end
    comboAtSend = nil
    resetComboCount()
    return points, source
end

-- A DoT as it stands the moment it's applied, before any tick.
local function newDot(spellID, tickKey, name, total, school, duration, statedInterval, now)
    local interval = statedInterval or KNOWN_TICK_INTERVALS[name] or DEFAULT_TICK_INTERVAL
    return {
        spellID = spellID,
        tickKey = tickKey,
        school = SCHOOL_BY_NAME[name] or school,
        total = total,
        duration = duration,
        interval = interval,
        totalTicks = math.max(1, math.floor(duration / interval + 0.5)),
        shape = TICK_SHAPES[name],
        appliedAt = now,
        expiresAt = now + duration,
        nextTickAt = now + interval,
        tickSum = 0,        -- non-crit ticks only
        normalTicks = 0,
        ticksSeen = 0,      -- including crits
        missed = 0,
    }
end

-- Returns the target key the DoT was applied to, or nil if the cast wasn't a tracked DoT.
local function onPlayerCast(spellID)
    local ok, name, desc = pcall(spellNameAndDescription, spellID)
    if not ok or not name or isSecret(name) then return end
    if type(desc) == "string" and not isSecret(desc) then
        local awarded = tonumber(desc:match("Awards (%d+) combo point"))
        if awarded then onBuilderCast(awarded) end
    end
    if IGNORED_SPELLS[name] then return end
    local isFinisher = isFinisherDescription(desc)
    local comboPoints, comboSource
    if isFinisher then comboPoints, comboSource = comboPointsForCast() end
    -- Unknown points: parse the lowest entry (errs low), and don't use or teach learned tick sizes.
    local total, school, duration, statedInterval = parseDot(desc, comboPoints or 1)
    if not total then return end
    -- A finisher's tick size depends on the points spent, so learned sizes are kept per point count.
    local tickKey = spellID
    if isFinisher then tickKey = comboPoints and (spellID .. "x" .. comboPoints) or nil end

    local key = unitKey("target")
    if not key then return end

    local now = GetTime()
    dotsByTarget[key] = dotsByTarget[key] or {}
    local previous = dotsByTarget[key][name]
    local dot = newDot(spellID, tickKey, name, total, school, duration, statedInterval, now)
    dotsByTarget[key][name] = dot
    lastDotCast = { key = key, name = name, dot = dot, previous = previous, at = now }
    local learned = tickKey and db.ticks[tickKey]
    -- The starting estimate is shaky without a learned tick size (description numbers leave out spell power
    -- and attack power) or, for finishers, without knowing the combo points.
    dot.unsure = not learned
    trace(string.format("CAST %s (id %d)%s: %d dmg over %ss, school %d, tick every %ss, per-tick %s%s", name, spellID,
        isFinisher and string.format(" %s combo points (%s)", comboPoints or "?", comboSource) or "",
        total, duration, dot.school, dot.interval, learned and ("learned " .. learned) or "from description",
        isWaiting(dot) and ", waiting for first tick" or ""))
    local avoided = avoidJustBefore()
    if avoided then
        removeAvoidedDot(lastDotCast, avoided)
        lastDotCast = nil
        return nil
    end
    return key, isWaiting(dot)
end

-- "Estimate during casting": a DoT with a cast time shows from UNIT_SPELLCAST_START, with the estimate its
-- cast would make. It's kept out of dotsByTarget, so ticks never match it and housekeeping leaves it alone,
-- and it stands in for a DoT of the same name that the cast would refresh (replaces, never adds). On success
-- onPlayerCast takes over exactly as without it. A failed or interrupted cast, or a target change, just drops
-- it, so a DoT it was about to refresh keeps ticking as if nothing happened. STOP ends every cast, successful
-- or not, and may come just before SUCCEEDED, so a stopped cast is only dropped if no success follows shortly.
local CAST_STOP_GRACE = 0.5
local CAST_MAX_SECONDS = 15 -- a lost end event never leaves an estimate behind
local castInProgress -- { key, name, dot, castGUID, spellID, startedAt, stoppedAt }

-- Whether an event's castGUID (or, when either GUID is unreadable, its spell ID) is the cast in progress.
local function sameCast(cast, castGUID, spellID)
    if cast.castGUID and castGUID ~= nil and not isSecret(castGUID) then return castGUID == cast.castGUID end
    return not isSecret(spellID) and spellID == cast.spellID
end

local function dropCastInProgress(reason)
    if not castInProgress then return end
    trace("CASTING " .. castInProgress.name .. " " .. reason .. "; estimate removed")
    castInProgress = nil
end

-- UNIT_SPELLCAST_START (player). Returns the target key when a DoT now shows for the cast.
local function onCastStart(castGUID, spellID)
    castInProgress = nil
    if not db.estimateDuringCast or isSecret(spellID) then return end
    local ok, name, desc = pcall(spellNameAndDescription, spellID)
    if not ok or not name or isSecret(name) or IGNORED_SPELLS[name] or isFinisherDescription(desc) then return end
    local total, school, duration, statedInterval = parseDot(desc, 1)
    if not total then return end
    local key = unitKey("target")
    if not key then return end
    local now = GetTime()
    local dot = newDot(spellID, spellID, name, total, school, duration, statedInterval, now)
    local learned = db.ticks[spellID]
    dot.unsure = not learned
    dot.provisional = true
    castInProgress = { key = key, name = name, dot = dot, spellID = spellID, startedAt = now,
        castGUID = not isSecret(castGUID) and castGUID or nil }
    trace(string.format("CASTING %s (id %d): %d dmg over %ss, per-tick %s%s", name, spellID, total, duration,
        learned and ("learned " .. learned) or "from description", isWaiting(dot) and ", waiting for first tick" or ""))
    return key
end

-- UNIT_SPELLCAST_SUCCEEDED (player), just before onPlayerCast: the cast's own DoT replaces the estimate.
local function onCastSucceeded(castGUID, spellID)
    if castInProgress and sameCast(castInProgress, castGUID, spellID) then castInProgress = nil end
end

-- UNIT_SPELLCAST_STOP / FAILED / INTERRUPTED (player). Returns true when the estimate was removed.
local function onCastEnded(event, castGUID, spellID)
    if not castInProgress or not sameCast(castInProgress, castGUID, spellID) then return end
    if event == "UNIT_SPELLCAST_STOP" then
        castInProgress.stoppedAt = castInProgress.stoppedAt or GetTime()
        return
    end
    dropCastInProgress(event == "UNIT_SPELLCAST_INTERRUPTED" and "interrupted" or "failed")
    return true
end

-- Seconds between now and the nearest expected tick time, and that tick's index. Anchored on the first tick
-- once seen (ticks keep its rhythm; anchoring on the latest tick would let jitter add up), else on the cast.
-- Using the nearest multiple of the interval means one missed tick doesn't lose the DoT.
local function distanceToExpectedTick(dot, now)
    local anchor = dot.firstTickAt or dot.appliedAt
    local k = math.max(1, math.floor((now - anchor) / dot.interval + 0.5))
    return math.abs(now - (anchor + k * dot.interval)), k
end

local function plausibleTickAmount(dot, amount, isCrit, number)
    local known, tolerance
    if dot.normalTicks > 0 then
        known, tolerance = dot.tickSum / dot.normalTicks, TICK_AMOUNT_TOLERANCE
    else
        known, tolerance = dot.tickKey and db.ticks[dot.tickKey], FIRST_TICK_AMOUNT_TOLERANCE
    end
    if not known then return true end
    known = known * tickShape(dot, number)
    if isCrit then
        return amount >= known * CRIT_MIN_RATIO - 1 and amount <= known * CRIT_MAX_RATIO + 1
    end
    return math.abs(amount - known) <= math.max(1, known * tolerance)
end

-- Tick size to judge a same-slot collision by: the average of the DoT's earlier ticks, or with fewer than two
-- ticks the description's per-tick share. Deliberately not the learned size, which is what a collision can
-- corrupt.
local function referenceTickSize(dot)
    if dot.normalTicks > 1 then
        return (dot.tickSum - dot.lastTickAmount / dot.lastTickShape) / (dot.normalTicks - 1)
    end
    return dot.total / dot.totalTicks
end

local function saveLearnedTick(dot)
    if dot.tickKey and dot.normalTicks > 0 then
        db.ticks[dot.tickKey] = math.floor(dot.tickSum / dot.normalTicks * 10 + 0.5) / 10
    end
end

-- Moves a DoT's tick bookkeeping to the tick in slot `index` that landed at `now`.
local function anchorTick(dot, index, now)
    dot.missed = 0
    if dot.firstTickAt then
        dot.lastTickIndex = index
    else
        dot.firstTickAt, dot.lastTickIndex = now, 0
    end
    dot.lastTickAt = now
    dot.nextTickAt = now + dot.interval
    -- Re-anchor expiry on the observed tick: ticks arrive slightly after their nominal time, and an
    -- expiry based on the cast event would otherwise cut off the final tick.
    local tickIndex = math.max(1, math.floor((now - dot.appliedAt) / dot.interval + 0.5))
    dot.expiresAt = now + (dot.totalTicks - tickIndex) * dot.interval
    return tickIndex
end

-- Two same-school hits in one tick slot (e.g. Shadow Bolt landing with a Corruption tick, log 123506.4): the
-- first one was taken as the tick. If this one is closer to the expected size, it was the real tick.
local SAME_SLOT_SECONDS = 0.2
local function trySwapSameSlot(dot, name, amount, isCrit, now)
    if isCrit or dot.lastTickCrit or not dot.lastTickAt or now - dot.lastTickAt > SAME_SLOT_SECONDS then
        return false
    end
    local factor = dot.lastTickShape
    local reference = referenceTickSize(dot) * factor
    if math.abs(amount - reference) >= math.abs(dot.lastTickAmount - reference) then return false end
    trace(string.format("SWAP %s tick: %d was another hit, %d is the tick", name, dot.lastTickAmount, amount))
    dot.tickSum = dot.tickSum + (amount - dot.lastTickAmount) / factor
    dot.lastTickAmount = amount
    saveLearnedTick(dot)
    return true
end

-- A learned size that's wrong rejects every real tick (log: Corruption learned 29 from Shadow Bolts, real ticks
-- 10-11, every cast dropped). Hits rejected only on size, but landing on the DoT's rhythm in two consecutive
-- slots and agreeing with each other, are the real ticks: relearn from them.
local function tryRelearn(dot, name, amount, isCrit, index, distance, now)
    local window = dot.firstTickAt and TICK_MATCH_WINDOW_ANCHORED or TICK_MATCH_WINDOW
    local freshSlot = not dot.firstTickAt or index > dot.lastTickIndex
    if isCrit or not freshSlot or distance > window then return false end
    local previous = dot.offBeatCandidate
    local factor = tickShape(dot, tickNumberAt(dot, now))
    local average = amount / factor
    dot.offBeatCandidate = { index = index, amount = amount, average = average, at = now }
    if not previous or index ~= previous.index + 1
        or math.abs(average - previous.average) > math.max(1, previous.average * TICK_AMOUNT_TOLERANCE) then
        return false
    end
    trace(string.format("RELEARN %s: ticks of %d and %d on its rhythm didn't fit %.1f/tick", name,
        previous.amount, amount, expectedTick(dot)))
    dot.offBeatCandidate = nil
    dot.tickSum, dot.normalTicks = previous.average + average, 2
    dot.ticksSeen = dot.ticksSeen + 2
    dot.lastTickAmount, dot.lastTickShape, dot.lastTickCrit = amount, factor, false
    saveLearnedTick(dot)
    if not dot.firstTickAt then
        dot.firstTickAt, dot.lastTickIndex = previous.at, 0
        index = 1
    end
    anchorTick(dot, index, now)
    return true
end

-- Returns the target key when this hit was the first tick of a DoT that was waiting for it (so the display
-- can flash now that the DoT shows), else nil.
local lastCombatSignature
local function onUnitCombat(unit, action, flag, amount, school)
    if isSecret(action) then return end
    if unit == "target" then
        if AVOIDED_ACTIONS[action] then return onTargetAvoided(action) end
        if action == "WOUND" then onTargetHit() end
    end
    if action ~= "WOUND" or isSecret(amount) or isSecret(school) or type(amount) ~= "number" then return end
    local isCrit = not isSecret(flag) and flag == "CRITICAL"
    local key = unitKey(unit)
    if not key then return end
    local dots = dotsByTarget[key]
    if not dots then return end

    -- The same hit fires for target, nameplateN, softenemy...: handle it once.
    local now = GetTime()
    local signature = key .. ":" .. amount .. ":" .. school .. ":" .. now
    if signature == lastCombatSignature then return end
    lastCombatSignature = signature

    local best, bestName, bestDistance, bestIndex
    for name, dot in pairs(dots) do
        if dot.school == school and plausibleTickAmount(dot, amount, isCrit, tickNumberAt(dot, now)) then
            local distance, index = distanceToExpectedTick(dot, now)
            local window = dot.firstTickAt and TICK_MATCH_WINDOW_ANCHORED or TICK_MATCH_WINDOW
            -- Each tick slot takes one hit: a second hit near an already-matched tick is someone else's.
            local freshSlot = not dot.firstTickAt or index > dot.lastTickIndex
            if freshSlot and distance <= window and (not bestDistance or distance < bestDistance) then
                best, bestName, bestDistance, bestIndex = dot, name, distance, index
            end
        end
    end
    if not best then
        -- Not a tick as things stand; it may still correct one (same-slot swap, or a wrong learned size).
        for name, dot in pairs(dots) do
            if dot.school == school then
                local distance, index = distanceToExpectedTick(dot, now)
                local wasWaiting = isWaiting(dot)
                if trySwapSameSlot(dot, name, amount, isCrit, now) then return end
                if tryRelearn(dot, name, amount, isCrit, index, distance, now) then
                    return wasWaiting and key or nil
                end
            end
        end
        trace(string.format("HIT %d%s school %d on %s not matched to a DoT", amount, isCrit and " (crit)" or "",
            school, unit))
        return
    end

    local wasWaiting = isWaiting(best)
    local factor = tickShape(best, tickNumberAt(best, now))
    best.ticksSeen = best.ticksSeen + 1
    best.lastTickAmount, best.lastTickShape, best.lastTickCrit = amount, factor, isCrit
    best.offBeatCandidate = nil
    if not isCrit then
        best.tickSum = best.tickSum + amount / factor
        best.normalTicks = best.normalTicks + 1
        saveLearnedTick(best)
    end
    local tickIndex = anchorTick(best, bestIndex, now)
    trace(string.format("TICK %s %d%s on %s (tick %d/%d, expecting %.1f for this tick)%s", bestName, amount,
        isCrit and " CRIT" or "", unit, tickIndex, best.totalTicks, expectedTick(best) * factor,
        wasWaiting and ", now shown" or ""))
    if wasWaiting then return key end
end

local function housekeep(now)
    for key, dots in pairs(dotsByTarget) do
        for name, dot in pairs(dots) do
            while dot.nextTickAt < now - TICK_MATCH_WINDOW and dot.nextTickAt <= dot.expiresAt do
                dot.nextTickAt = dot.nextTickAt + dot.interval
                dot.missed = dot.missed + 1
            end
            if now > dot.expiresAt + TICK_MATCH_WINDOW then
                dots[name] = nil
                trace("EXPIRE " .. name)
            elseif dot.ticksSeen == 0 and dot.missed >= MISSED_TICKS_BEFORE_DROP then
                dots[name] = nil
                trace("DROP " .. name .. " never ticked (resisted or immune?)")
            end
        end
        if next(dots) == nil then dotsByTarget[key] = nil end
    end
    if castInProgress then
        if castInProgress.stoppedAt and now - castInProgress.stoppedAt > CAST_STOP_GRACE then
            dropCastInProgress("stopped without succeeding")
        elseif now - castInProgress.startedAt > CAST_MAX_SECONDS then
            dropCastInProgress("never finished")
        end
    end
end

local function remainingDamage(dot)
    if dot.nextTickAt > dot.expiresAt + dot.interval / 2 then return 0 end
    local ticksLeft = math.floor((dot.expiresAt - dot.nextTickAt) / dot.interval + 0.5) + 1
    if not dot.shape then return ticksLeft * expectedTick(dot) end
    local average, total = expectedTick(dot), 0
    for number = math.max(1, dot.totalTicks - ticksLeft + 1), dot.totalTicks do
        total = total + average * tickShape(dot, number)
    end
    return total
end

-- Remaining damage per DoT on a mob (by unitKey), oldest application first. DoTs still waiting for their first
-- tick are left out. A DoT being cast on the mob replaces the one of the same name it would refresh.
local function dotBreakdown(key)
    local dots = key and dotsByTarget[key]
    local cast = key and castInProgress and castInProgress.key == key and castInProgress or nil
    local list = {}
    if not dots and not cast then return list end
    for name, dot in pairs(dots or {}) do
        if not isWaiting(dot) and not (cast and name == cast.name) then
            table.insert(list, { name = name, school = dot.school, appliedAt = dot.appliedAt,
                damage = remainingDamage(dot) })
        end
    end
    if cast and not isWaiting(cast.dot) then
        table.insert(list, { name = cast.name, school = cast.dot.school, appliedAt = cast.dot.appliedAt,
            damage = remainingDamage(cast.dot), provisional = true })
    end
    table.sort(list, function(a, b) return a.appliedAt < b.appliedAt end)
    return list
end

-- Returns what the target's DoTs still have to deal, how many DoTs count toward it, and the per-DoT
-- breakdown (see dotBreakdown).
local function targetRemainingDamage()
    local list = dotBreakdown(unitKey("target"))
    local total = 0
    for _, entry in ipairs(list) do total = total + entry.damage end
    return math.floor(total + 0.5), #list, list
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local TEXTURE_DIR = "Interface\\AddOns\\DoesItDie\\Textures\\" -- generated by tools/make_textures.py

local SKULL_ICONS = {
    { id = "skull",  label = "Raid skull",      path = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { id = "cross",  label = "Red X",           path = "Interface\\RaidFrame\\ReadyCheck-NotReady" },
    { id = "check",  label = "Green checkmark", path = "Interface\\RaidFrame\\ReadyCheck-Ready" },
    { id = "boss",   label = "Boss skull",      path = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull" },
    { id = "shades", label = "Sunglasses",      path = TEXTURE_DIR .. "Sunglasses" },
}

local FILL_STYLES = {
    { id = "none",     label = "None" },
    { id = "flat",     label = "Flat",               path = WHITE },
    { id = "smooth",   label = "Health bar texture", path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { id = "raid",     label = "Raid bar texture",   path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { id = "stripes",  label = "Diagonal stripes",   path = TEXTURE_DIR .. "Stripes", tiled = true },
    { id = "gradient", label = "Fade in from left",  path = WHITE, gradient = true },
}

local OUTLINE_STYLES = {
    { id = "dashed", label = "Dashed" },
    { id = "solid",  label = "Solid" },
    { id = "none",   label = "None" },
}

local DASH_LENGTHS = { -- must match tools/make_textures.py
    { id = 1,  label = "Fine dots (1px)" },
    { id = 2,  label = "Dots (2px)" },
    { id = 4,  label = "Short dashes (4px)" },
    { id = 8,  label = "Dashes (8px)" },
    { id = 16, label = "Long dashes (16px)" },
}

local LABEL_POSITIONS = {
    { id = "left",   label = "Left of the bar" },
    { id = "center", label = "Centered on the bar" },
    { id = "right",  label = "Inside the bar, right end" },
}

local DOT_COLOR_MODES = {
    { id = "single", label = "One color (fill color)" },
    { id = "school", label = "By spell school" },
    { id = "each",   label = "Different color per DoT" },
}

-- "By spell school" colors, keyed by school mask (Frostfire = Fire + Frost).
local SCHOOL_COLORS = {
    [1] = { 1, 0.3, 0.3 },      -- Physical (bleeds)
    [2] = { 1, 0.9, 0.45 },     -- Holy
    [4] = { 1, 0.55, 0.15 },    -- Fire
    [8] = { 0.35, 1, 0.35 },    -- Nature
    [16] = { 0.45, 0.8, 1 },    -- Frost
    [20] = { 0.75, 0.6, 1 },    -- Frostfire
    [32] = { 0.7, 0.35, 1 },    -- Shadow
    [64] = { 1, 0.55, 1 },      -- Arcane
}

-- "Different color per DoT": each spell keeps the palette color it got when first seen this session, so
-- colors don't shuffle when DoTs are recast or expire.
local DOT_PALETTE = {
    { 0.95, 0.3, 0.3 }, { 0.3, 0.75, 1 }, { 1, 0.8, 0.2 }, { 0.45, 1, 0.45 },
    { 0.85, 0.4, 1 }, { 1, 0.55, 0.15 }, { 0.3, 1, 0.9 }, { 1, 0.45, 0.75 },
}
local paletteIndexByName, nextPaletteIndex = {}, 1

-- mode: "school" or "each"; defaults to the target marker's setting (nameplates pass their own).
local function dotColor(entry, mode)
    if (mode or db.dotColors) == "school" then
        return SCHOOL_COLORS[entry.school] or COLOR_BY_ID.white
    end
    local index = paletteIndexByName[entry.name]
    if not index then
        index = (nextPaletteIndex - 1) % #DOT_PALETTE + 1
        paletteIndexByName[entry.name], nextPaletteIndex = index, nextPaletteIndex + 1
    end
    return DOT_PALETTE[index]
end

local SMOOTH_RATE = 10 -- how fast the marker glides to a new value (higher = snappier)

local function findById(list, id)
    for _, entry in ipairs(list) do
        if entry.id == id then return entry end
    end
    return list[1]
end

local function colorOf(id, opacityPercent)
    local rgb = COLOR_BY_ID[id] or COLOR_BY_ID.white
    return rgb[1], rgb[2], rgb[3], (opacityPercent or 100) / 100
end

local healthBar -- nil if the target frame's health bar wasn't found (markers unavailable)
-- While the options window is open, the display is attached to its mock target frame (previewHost:
-- { healthBar, portrait, layerFrame }) and fed its plain numbers (previewState: { health, dots }) instead.
local previewHost, previewState
local skullTestUntil -- /did skull forces the skull visible until this time

-- Skull: addon code can't compare DoT damage with (secret) health, but a StatusBar can. We feed it
-- max = current health, value = remaining DoT damage; the fill only reaches the bar's right end when
-- damage >= health. The skull rides the fill's right edge, and only the last skull-width of the very
-- long bar is visible (clipped), so the skull appears over the portrait only when lethal.
-- It starts sliding in at skullSize / SKULL_BAR_LENGTH (~0.4%) short of lethal.
local SKULL_BAR_LENGTH = 10000

local skullWindow = CreateFrame("Frame", "DoesItDieSkull", UIParent)
skullWindow:SetClipsChildren(true)
skullWindow:Hide()

local skullBar = CreateFrame("StatusBar", nil, skullWindow)
skullBar:SetPoint("RIGHT", skullWindow, "RIGHT")
skullBar:SetStatusBarTexture(WHITE)
skullBar:SetStatusBarColor(0, 0, 0, 0)

local skull = skullBar:CreateTexture(nil, "OVERLAY")
skull:SetPoint("RIGHT", skullBar:GetStatusBarTexture(), "RIGHT")

local skullPulse = skull:CreateAnimationGroup()
skullPulse:SetLooping("BOUNCE")
local skullPulseAlpha = skullPulse:CreateAnimation("Alpha")
skullPulseAlpha:SetFromAlpha(1)
skullPulseAlpha:SetToAlpha(0.45)
skullPulseAlpha:SetDuration(0.7)
skullPulseAlpha:SetSmoothing("IN_OUT")

-- /did skull diagnostics: an unclipped skull just above the portrait, to tell a placement/strata
-- problem apart from a problem with the clipped status-bar trick.
local plainSkullFrame = CreateFrame("Frame", nil, UIParent)
plainSkullFrame:SetFrameStrata("HIGH")
plainSkullFrame:Hide()

local plainSkull = plainSkullFrame:CreateTexture(nil, "OVERLAY")
plainSkull:SetAllPoints()

-- Damage marker: a StatusBar laid over the whole health bar with max = max health (secret), so it shares
-- the health bar's scale. Its fill (invisible itself) spans the damage the DoTs still have to deal,
-- measured from the bar's left edge; the visible fill, outline and flash are drawn on top of that span.
-- If the green ends inside the marker, the current DoTs will kill the target.
local remainingBar = CreateFrame("StatusBar", "DoesItDieRemaining", UIParent)
remainingBar:SetStatusBarTexture(WHITE)
remainingBar:SetStatusBarColor(0, 0, 0, 0)
remainingBar:Hide()
local span = remainingBar:GetStatusBarTexture()

local function coverSpan(texture)
    texture:SetPoint("TOPLEFT", span, "TOPLEFT")
    texture:SetPoint("BOTTOMRIGHT", span, "BOTTOMRIGHT")
end

local fillLayer = CreateFrame("Frame", nil, remainingBar)
fillLayer:SetAllPoints()

local fillTex = fillLayer:CreateTexture(nil, "ARTWORK")
coverSpan(fillTex)

-- Per-DoT segments ("DoT colors" option): the remaining damage split into one colored segment per DoT, laid
-- end to end. Segment i runs from the end of running-total bar i-1's fill to the end of bar i's fill (bar i
-- filled to DoT 1 + ... + DoT i), so it's exactly that DoT's share on the (secret) health scale.
local MAX_SEGMENTS = 8
local segments = {}
for i = 1, MAX_SEGMENTS do
    local bar = CreateFrame("StatusBar", nil, remainingBar)
    bar:SetAllPoints(remainingBar)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    local fillEnd = bar:GetStatusBarTexture()

    local texture = fillLayer:CreateTexture(nil, "ARTWORK", nil, 1)
    if i == 1 then
        texture:SetPoint("TOPLEFT", remainingBar, "TOPLEFT")
    else
        texture:SetPoint("TOPLEFT", segments[i - 1].fillEnd, "TOPRIGHT")
    end
    texture:SetPoint("BOTTOMRIGHT", fillEnd, "BOTTOMRIGHT")
    texture:Hide()

    local divider = fillLayer:CreateTexture(nil, "OVERLAY", nil, 1)
    divider:SetColorTexture(0, 0, 0, 0.85)
    divider:SetWidth(1)
    divider:SetPoint("TOP", fillEnd, "TOPRIGHT")
    divider:SetPoint("BOTTOM", fillEnd, "BOTTOMRIGHT")
    divider:Hide()

    segments[i] = { bar = bar, fillEnd = fillEnd, texture = texture, divider = divider, target = 0, shown = 0 }
end

local flashTex = fillLayer:CreateTexture(nil, "OVERLAY")
coverSpan(flashTex)
flashTex:SetColorTexture(1, 1, 1, 1)
flashTex:SetBlendMode("ADD")
flashTex:SetAlpha(0)

local flashAnim = flashTex:CreateAnimationGroup()
local flashIn = flashAnim:CreateAnimation("Alpha")
flashIn:SetFromAlpha(0)
flashIn:SetToAlpha(0.8)
flashIn:SetDuration(0.08)
flashIn:SetOrder(1)
local flashOut = flashAnim:CreateAnimation("Alpha")
flashOut:SetFromAlpha(0.8)
flashOut:SetToAlpha(0)
flashOut:SetDuration(0.5)
flashOut:SetSmoothing("OUT")
flashOut:SetOrder(2)

-- The outline tiles its dash texture along each edge, so it works whatever the (secret) span length is.
local outlineLayer = CreateFrame("Frame", nil, remainingBar)
outlineLayer:SetAllPoints()

local edges = {} -- { texture, horizontal }
local function makeEdge(horizontal, point1, point2)
    local edge = outlineLayer:CreateTexture(nil, "OVERLAY", nil, 7)
    edge:SetPoint(point1, span, point1)
    edge:SetPoint(point2, span, point2)
    table.insert(edges, { texture = edge, horizontal = horizontal })
end
makeEdge(true, "TOPLEFT", "TOPRIGHT")
makeEdge(true, "BOTTOMLEFT", "BOTTOMRIGHT")
makeEdge(false, "TOPLEFT", "BOTTOMLEFT")
makeEdge(false, "TOPRIGHT", "BOTTOMRIGHT")

local outlinePulse = outlineLayer:CreateAnimationGroup()
outlinePulse:SetLooping("BOUNCE")
local outlinePulseAlpha = outlinePulse:CreateAnimation("Alpha")
outlinePulseAlpha:SetFromAlpha(1)
outlinePulseAlpha:SetToAlpha(0.3)
outlinePulseAlpha:SetDuration(0.9)
outlinePulseAlpha:SetSmoothing("IN_OUT")

-- Glow: soft halo around the span in the outline color, one gradient strip per side fading outward.
-- Lives on the outline layer so "Pulse outline" pulses it too.
local glows = {} -- { texture, side }
local function makeGlow(side)
    local glow = outlineLayer:CreateTexture(nil, "BORDER")
    glow:SetTexture(WHITE)
    glow:SetBlendMode("ADD")
    if side == "top" then
        glow:SetPoint("BOTTOMLEFT", span, "TOPLEFT")
        glow:SetPoint("BOTTOMRIGHT", span, "TOPRIGHT")
    elseif side == "bottom" then
        glow:SetPoint("TOPLEFT", span, "BOTTOMLEFT")
        glow:SetPoint("TOPRIGHT", span, "BOTTOMRIGHT")
    elseif side == "left" then
        glow:SetPoint("TOPRIGHT", span, "TOPLEFT")
        glow:SetPoint("BOTTOMRIGHT", span, "BOTTOMLEFT")
    else
        glow:SetPoint("TOPLEFT", span, "TOPRIGHT")
        glow:SetPoint("BOTTOMLEFT", span, "BOTTOMRIGHT")
    end
    table.insert(glows, { texture = glow, side = side })
end
makeGlow("top")
makeGlow("bottom")
makeGlow("left")
makeGlow("right")

-- Clipped to the span: effects that move across the whole health bar but should only show inside the
-- marker (scrolling stripes, the shine sweep). Clipping does the work Lua can't, since the span's width
-- comes from secret health.
local clipLayer = CreateFrame("Frame", nil, remainingBar)
clipLayer:SetPoint("TOPLEFT", span, "TOPLEFT")
clipLayer:SetPoint("BOTTOMRIGHT", span, "BOTTOMRIGHT")
clipLayer:SetClipsChildren(true)

local STRIPE_SCROLL_PERIOD = 8 -- px; the stripe pattern repeats every 8px horizontally (make_textures.py)

local scrollingStripes = clipLayer:CreateTexture(nil, "ARTWORK")
scrollingStripes:SetTexture(TEXTURE_DIR .. "Stripes", "REPEAT", "REPEAT")
scrollingStripes:SetHorizTile(true)
scrollingStripes:SetVertTile(true)
local stripeScroll = scrollingStripes:CreateAnimationGroup()
stripeScroll:SetLooping("REPEAT")
local stripeMove = stripeScroll:CreateAnimation("Translation")
stripeMove:SetOffset(STRIPE_SCROLL_PERIOD, 0)
stripeMove:SetDuration(0.6)

local SHINE_WIDTH = 36
local SHINE_DURATION = 0.9

local shine = clipLayer:CreateTexture(nil, "OVERLAY")
shine:SetTexture(TEXTURE_DIR .. "Shine")
shine:SetBlendMode("ADD")
shine:SetWidth(SHINE_WIDTH)
local shineSweep = shine:CreateAnimationGroup()
shineSweep:SetLooping("REPEAT")
local shineMove = shineSweep:CreateAnimation("Translation")
shineMove:SetDuration(SHINE_DURATION)
shineMove:SetSmoothing("IN_OUT")

-- Spark: bright flare on the span's right end that only appears when a DoT lands (a constant glow there
-- hides exactly the edge you need to read). Invisible at rest; the punch animation fades it in and out.
local sparkLayer = CreateFrame("Frame", nil, remainingBar)
sparkLayer:SetAllPoints()

local spark = sparkLayer:CreateTexture(nil, "OVERLAY")
spark:SetTexture(TEXTURE_DIR .. "Spark")
spark:SetBlendMode("ADD")
spark:SetWidth(14)
spark:SetPoint("TOP", span, "TOPRIGHT", 0, 7)
spark:SetPoint("BOTTOM", span, "BOTTOMRIGHT", 0, -7)
spark:SetAlpha(0)

-- Scale animations use SetScaleFrom/To on current clients; SetScale (relative) on older ones.
local function scaleStep(group, fromX, fromY, toX, toY, duration, order, smoothing)
    local anim = group:CreateAnimation("Scale")
    if anim.SetScaleFrom then
        anim:SetScaleFrom(fromX, fromY)
        anim:SetScaleTo(toX, toY)
    else
        anim:SetScale(toX / fromX, toY / fromY)
    end
    anim:SetDuration(duration)
    anim:SetOrder(order)
    if smoothing then anim:SetSmoothing(smoothing) end
end

local function alphaStep(group, from, to, duration, order, smoothing)
    local anim = group:CreateAnimation("Alpha")
    anim:SetFromAlpha(from)
    anim:SetToAlpha(to)
    anim:SetDuration(duration)
    anim:SetOrder(order)
    if smoothing then anim:SetSmoothing(smoothing) end
end

local sparkPunch = spark:CreateAnimationGroup()
scaleStep(sparkPunch, 1, 1, 1.9, 1.3, 0.08, 1)
alphaStep(sparkPunch, 0, 1, 0.08, 1)
scaleStep(sparkPunch, 1.9, 1.3, 1, 1, 0.45, 2, "OUT")
alphaStep(sparkPunch, 1, 0, 0.45, 2, "OUT")

local label = remainingBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

-- Pushes the options onto the widgets, but only when one of them changed since the last call, so it
-- can run on every refresh and option changes still show up immediately.
local APPEARANCE_KEYS = {
    "showMarkers", "skullIcon", "skullSize", "skullPulse", "skullOffsetX", "skullOffsetY",
    "showSpark", "showGlow", "glowSize", "showShine", "shineInterval", "scrollStripes",
    "fillTexture", "fillColor", "fillOpacity", "dotColors",
    "outlineStyle", "dashLength", "outlineThickness", "outlineColor", "outlineOpacity", "pulseOutline",
    "showLabel", "labelSize", "labelColor", "labelPosition",
}
local appliedSignature
local skullAnchor -- what the skull is centered on (portrait, else target frame, else screen)

local function positionSkull()
    skullWindow:ClearAllPoints()
    if skullAnchor == UIParent then
        skullWindow:SetPoint("CENTER", UIParent, "CENTER", db.skullOffsetX, 120 + db.skullOffsetY)
    elseif skullAnchor then
        skullWindow:SetPoint("CENTER", skullAnchor, "CENTER", db.skullOffsetX, db.skullOffsetY)
    end
end

-- Width of the health bar for the shine sweep; layout values are plain, but guard in case they aren't.
local function healthBarWidth()
    local ok, width = pcall(healthBar.GetWidth, healthBar)
    if ok and not isSecret(width) and type(width) == "number" and width > 0 then return width end
    return 150
end

local function applyAppearance()
    local parts = {}
    for i, key in ipairs(APPEARANCE_KEYS) do parts[i] = tostring(db[key]) end
    local signature = table.concat(parts, "|")
    if signature == appliedSignature then return end
    appliedSignature = signature

    -- Skull
    local size = db.skullSize
    skullWindow:SetSize(size, size)
    skullBar:SetSize(SKULL_BAR_LENGTH, size)
    skull:SetSize(size, size)
    plainSkullFrame:SetSize(size, size)
    local icon = findById(SKULL_ICONS, db.skullIcon).path
    skull:SetTexture(icon)
    plainSkull:SetTexture(icon)
    if db.skullPulse then skullPulse:Play() else skullPulse:Stop() end
    positionSkull()

    -- Fill. Per-DoT colors draw it as segments (same texture and opacity, flat if the style has none; no
    -- scrolling or fade). Otherwise one fill; stripes can scroll, drawn by the clipped, animated texture.
    local fill = findById(FILL_STYLES, db.fillTexture)
    local perDot = db.dotColors ~= "single"
    local segmentPath = (fill.path and not fill.gradient) and fill.path or WHITE
    for _, segment in ipairs(segments) do
        segment.texture:SetTexture(segmentPath, fill.tiled and "REPEAT" or nil, fill.tiled and "REPEAT" or nil)
        segment.texture:SetHorizTile(fill.tiled or false)
        segment.texture:SetVertTile(fill.tiled or false)
        if not perDot then
            segment.texture:Hide()
            segment.divider:Hide()
        end
    end
    if perDot then fill = FILL_STYLES[1] end -- "none": the segments are the fill
    local scrolling = fill.id == "stripes" and db.scrollStripes and healthBar ~= nil
    if scrolling then
        fillTex:Hide()
        scrollingStripes:ClearAllPoints()
        scrollingStripes:SetPoint("TOPLEFT", healthBar, "TOPLEFT", -STRIPE_SCROLL_PERIOD * 2, 0)
        scrollingStripes:SetPoint("BOTTOMRIGHT", healthBar, "BOTTOMRIGHT")
        scrollingStripes:SetVertexColor(colorOf(db.fillColor, db.fillOpacity))
        scrollingStripes:Show()
        stripeScroll:Play()
    else
        stripeScroll:Stop()
        scrollingStripes:Hide()
    end
    if fill.path and not scrolling then
        local r, g, b, a = colorOf(db.fillColor, db.fillOpacity)
        fillTex:SetTexture(fill.path, fill.tiled and "REPEAT" or nil, fill.tiled and "REPEAT" or nil)
        fillTex:SetHorizTile(fill.tiled or false)
        fillTex:SetVertTile(fill.tiled or false)
        if fill.gradient and CreateColor then
            fillTex:SetVertexColor(1, 1, 1, 1)
            fillTex:SetGradient("HORIZONTAL", CreateColor(r, g, b, 0), CreateColor(r, g, b, a))
        else
            fillTex:SetVertexColor(r, g, b, a)
        end
        fillTex:Show()
    else
        fillTex:Hide()
    end

    -- Outline
    local r, g, b, a = colorOf(db.outlineColor, db.outlineOpacity)
    for _, edge in ipairs(edges) do
        local texture = edge.texture
        if db.outlineStyle == "dashed" then
            local file = (edge.horizontal and "DashH" or "DashV") .. db.dashLength
            texture:SetTexture(TEXTURE_DIR .. file, "REPEAT", "REPEAT")
            texture:SetHorizTile(edge.horizontal)
            texture:SetVertTile(not edge.horizontal)
        else
            texture:SetTexture(WHITE)
            texture:SetHorizTile(false)
            texture:SetVertTile(false)
        end
        texture:SetVertexColor(r, g, b, a)
        if edge.horizontal then
            texture:SetHeight(db.outlineThickness)
        else
            texture:SetWidth(db.outlineThickness)
        end
        texture:SetShown(db.outlineStyle ~= "none")
    end
    if db.pulseOutline then outlinePulse:Play() else outlinePulse:Stop() end

    -- Glow (outline color, fading outward)
    local glowAlpha = a * 0.7
    for _, glow in ipairs(glows) do
        local texture = glow.texture
        local inner, outer = CreateColor(r, g, b, glowAlpha), CreateColor(r, g, b, 0)
        if glow.side == "top" then
            texture:SetHeight(db.glowSize)
            texture:SetGradient("VERTICAL", inner, outer)
        elseif glow.side == "bottom" then
            texture:SetHeight(db.glowSize)
            texture:SetGradient("VERTICAL", outer, inner)
        elseif glow.side == "left" then
            texture:SetWidth(db.glowSize)
            texture:SetGradient("HORIZONTAL", outer, inner)
        else
            texture:SetWidth(db.glowSize)
            texture:SetGradient("HORIZONTAL", inner, outer)
        end
        texture:SetShown(db.showGlow)
    end

    -- Spark (outline color, brightened)
    spark:SetVertexColor(math.min(1, r + 0.4), math.min(1, g + 0.4), math.min(1, b + 0.4), 1)
    spark:SetShown(db.showSpark)

    -- Shine sweep: starts just left of the bar, crosses it, then waits out the rest of the interval.
    shineSweep:Stop()
    if db.showShine and healthBar then
        shine:ClearAllPoints()
        shine:SetPoint("TOPRIGHT", healthBar, "TOPLEFT")
        shine:SetPoint("BOTTOMRIGHT", healthBar, "BOTTOMLEFT")
        shineMove:SetOffset(healthBarWidth() + SHINE_WIDTH, 0)
        shineMove:SetStartDelay(math.max(0, db.shineInterval - SHINE_DURATION))
        shine:Show()
        shineSweep:Play()
    else
        shine:Hide()
    end

    fillLayer:SetShown(db.showMarkers)
    clipLayer:SetShown(db.showMarkers)
    outlineLayer:SetShown(db.showMarkers)
    sparkLayer:SetShown(db.showMarkers)

    -- Text
    local fontPath = GameFontNormalSmall:GetFont()
    label:SetFont(fontPath, db.labelSize, "OUTLINE")
    label:SetTextColor(colorOf(db.labelColor))
    label:ClearAllPoints()
    if healthBar then
        if db.labelPosition == "center" then
            label:SetPoint("CENTER", healthBar, "CENTER")
        elseif db.labelPosition == "right" then
            label:SetPoint("RIGHT", healthBar, "RIGHT", -4, 0)
        else
            label:SetPoint("RIGHT", healthBar, "LEFT", -6, 0)
        end
    end
    label:SetShown(db.showLabel)
end

-- Smooth motion: the marker glides toward its value instead of jumping on each tick, and grows in from
-- zero when it first appears or switches target. Values are ours (plain), only the scale is secret.
local markerValue, markerShownValue, markerScale = 0, 0, nil

-- Max value (the scale) for the marker and every segment's running-total bar.
local function setMarkerScale(max)
    remainingBar:SetMinMaxValues(0, max)
    for _, segment in ipairs(segments) do segment.bar:SetMinMaxValues(0, max) end
end

-- value: total remaining damage. scale: identifies what's being shown (target, preview); a change grows the
-- marker in from zero. cumulative: running totals per DoT for the segments, or nil when not drawing them
-- (unused segments sit at the total, i.e. zero width).
local function setMarkerValue(value, scale, cumulative)
    local fresh = scale ~= markerScale
    markerScale, markerValue = scale, value
    if not db.smoothMotion then
        markerShownValue = value
    elseif fresh then
        markerShownValue = 0
    end
    remainingBar:SetValue(markerShownValue)
    for i, segment in ipairs(segments) do
        segment.target = cumulative and (cumulative[i] or value) or value
        if not db.smoothMotion then
            segment.shown = segment.target
        elseif fresh then
            segment.shown = 0
        end
        segment.bar:SetValue(segment.shown)
    end
end

local function approach(shown, target, elapsed)
    shown = shown + (target - shown) * math.min(1, elapsed * SMOOTH_RATE)
    if math.abs(target - shown) < math.max(0.05, math.abs(target) * 0.002) then return target end
    return shown
end

local function animateMarker(elapsed)
    if not remainingBar:IsShown() then return end
    if markerShownValue ~= markerValue then
        markerShownValue = approach(markerShownValue, markerValue, elapsed)
        remainingBar:SetValue(markerShownValue)
    end
    for _, segment in ipairs(segments) do
        if segment.shown ~= segment.target then
            segment.shown = approach(segment.shown, segment.target, elapsed)
            segment.bar:SetValue(segment.shown)
        end
    end
end

-- Shows and colors one segment per entry ({ name, school, damage }), or hides them all when entries is nil.
-- Returns the running totals to pass to setMarkerValue.
local function updateSegments(entries)
    local cumulative, running = {}, 0
    local count = entries and math.min(#entries, MAX_SEGMENTS) or 0
    local alpha = db.fillOpacity / 100
    for i, segment in ipairs(segments) do
        local entry = i <= count and entries[i]
        if entry then
            running = running + entry.damage
            cumulative[i] = running
            local color = dotColor(entry)
            segment.texture:SetVertexColor(color[1], color[2], color[3], alpha)
        end
        segment.texture:SetShown(entry and true or false)
        segment.divider:SetShown(entry and db.segmentDividers and i < count or false)
    end
    -- More DoTs than segments: the last segment also covers the rest.
    if entries and #entries > MAX_SEGMENTS then
        for i = MAX_SEGMENTS + 1, #entries do running = running + entries[i].damage end
        cumulative[MAX_SEGMENTS] = running
    end
    return entries and cumulative or nil
end

-- "DoTs: Corruption 60 · Immolate 45", each name in its segment's color.
local function breakdownText(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        local color = dotColor(entry)
        local function byte(v) return math.floor(v * 255 + 0.5) end
        table.insert(parts, string.format("|cff%02x%02x%02x%s %d|r", byte(color[1]), byte(color[2]),
            byte(color[3]), entry.name, math.floor(entry.damage + 0.5)))
    end
    return "DoTs: " .. table.concat(parts, " · ")
end

local function playFlash()
    if db.flashOnApply and db.showMarkers and remainingBar:IsShown() then
        flashAnim:Stop()
        flashAnim:Play()
        if db.showSpark then
            sparkPunch:Stop()
            sparkPunch:Play()
        end
    end
end

local function findTargetPortrait()
    local tf = TargetFrame
    return (tf and tf.TargetFrameContainer and tf.TargetFrameContainer.Portrait)
        or TargetFramePortrait
        or (tf and tf.portrait)
end

local function findTargetHealthBar()
    local tf = TargetFrame
    local main = tf and tf.TargetFrameContent and tf.TargetFrameContent.TargetFrameContentMain
    return (main and main.HealthBarsContainer and main.HealthBarsContainer.HealthBar)
        or (main and main.HealthBar)
        or TargetFrameHealthBar
        or (tf and tf.healthbar)
end

local function regionName(region)
    if not region then return "not found" end
    local ok, name = pcall(region.GetDebugName, region)
    return ok and tostring(name) or "found (unnamed)"
end

local function attach()
    local portrait, bar
    if previewHost then
        portrait, bar = previewHost.portrait, previewHost.healthBar
    else
        portrait, bar = findTargetPortrait(), findTargetHealthBar()
    end
    skullAnchor = portrait or TargetFrame or UIParent
    plainSkullFrame:ClearAllPoints()
    plainSkullFrame:SetPoint("BOTTOM", skullWindow, "TOP", 0, 4)

    healthBar = bar
    if healthBar then
        remainingBar:ClearAllPoints()
        remainingBar:SetAllPoints(healthBar)
    end
    appliedSignature = nil -- re-anchor the skull, label and effects against the (new) frames
    trace("ATTACH portrait: " .. regionName(portrait) .. " | health bar: " .. regionName(healthBar))
    return portrait ~= nil
end

local STRATA_RANK = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}
local LAYER_CHECK_INTERVAL = 1

-- Highest strata/level anywhere in the target frame's tree. Blizzard (Edit Mode) re-layers the target
-- frame after addons load, so a level picked once at load ends up underneath the health bar and portrait.
local function targetFrameTopLayer()
    local topStrata, topLevel = "BACKGROUND", 0
    local function visit(frame, depth)
        -- Some of Blizzard's frames report a secret strata/level in Forever; those can't be compared, so skip
        -- them (their children are still visited).
        local strata, level = frame:GetFrameStrata(), frame:GetFrameLevel()
        if not isSecret(strata) and not isSecret(level) then
            local rank, topRank = STRATA_RANK[strata] or 0, STRATA_RANK[topStrata] or 0
            if rank > topRank then
                topStrata, topLevel = strata, level
            elseif rank == topRank and level > topLevel then
                topLevel = level
            end
        end
        if depth < 6 then
            for _, child in ipairs({ frame:GetChildren() }) do visit(child, depth + 1) end
        end
    end
    visit(TargetFrame or healthBar or UIParent, 0)
    return topStrata, topLevel
end

-- Keeps our marker and skull above everything on the target frame. Checked while displaying (throttled)
-- because Blizzard can re-layer the frame at any time.
local layerCheckedAt, lastStrata, lastLevel, layerErrorLogged = 0, nil, nil, false
local function updateLayering(now)
    if now - layerCheckedAt < LAYER_CHECK_INTERVAL then return end
    layerCheckedAt = now
    local ok, strata, level
    if previewHost then
        -- One strata above the options window: it's a top-level frame, which WoW raises above everything else
        -- in its own strata (our frames included) when it's shown or clicked. Dropdowns and tooltips sit higher.
        ok, strata, level = true, "FULLSCREEN", 1
    else
        ok, strata, level = pcall(targetFrameTopLayer)
    end
    if not ok then
        if not layerErrorLogged then
            layerErrorLogged = true
            trace("LAYER check failed (logged once): " .. tostring(strata))
        end
        return
    end
    for i, frame in ipairs({ remainingBar, fillLayer, clipLayer, outlineLayer, sparkLayer, skullWindow, skullBar }) do
        frame:SetFrameStrata(strata)
        frame:SetFrameLevel(level + i)
    end
    if strata ~= lastStrata or level ~= lastLevel then
        lastStrata, lastLevel = strata, level
        trace(string.format("LAYER target frame top is %s/%d; marker and skull placed above it", strata, level))
    end
end

local function hideMarkers()
    remainingBar:Hide()
    markerScale = nil -- grow in again next time it appears
end

local function hideAll()
    skullWindow:Hide()
    hideMarkers()
end

-- The label lives on the marker bar, so the bar stays up if either is wanted.
local function showMarkers()
    if db.showMarkers or db.showLabel then
        remainingBar:Show()
    else
        hideMarkers()
    end
end

local function rectOf(region)
    if not region then return "nil" end
    local ok, left, bottom, width, height = pcall(region.GetRect, region)
    if not ok then return "error" end
    if left == nil then return "no rect" end
    if isSecret(left) or isSecret(width) then return "secret" end
    return string.format("%.0f,%.0f %.0fx%.0f", left, bottom, width, height)
end

local function describeFrame(frame)
    local ok, strata, level, visible = pcall(function()
        return frame:GetFrameStrata(), frame:GetFrameLevel(), frame:IsVisible()
    end)
    if not ok then return "error" end
    return string.format("%s %s/%d visible=%s", rectOf(frame), tostring(strata), level, tostring(visible))
end

local function traceSkullGeometry()
    local portrait = findTargetPortrait()
    trace("SKULLTEST portrait " .. rectOf(portrait) .. " | TargetFrame " .. (TargetFrame and describeFrame(TargetFrame) or "nil"))
    local clipsOK, clips = pcall(skullWindow.DoesClipChildren, skullWindow)
    trace("SKULLTEST window " .. describeFrame(skullWindow) .. " clips=" .. (clipsOK and tostring(clips) or "unknown"))
    trace("SKULLTEST bar " .. describeFrame(skullBar) .. " fill " .. rectOf(skullBar:GetStatusBarTexture()))
    trace("SKULLTEST skull " .. rectOf(skull) .. " visible=" .. tostring(skull:IsVisible()) .. " texture=" .. tostring(skull:GetTexture()))
    trace("SKULLTEST plain " .. describeFrame(plainSkullFrame) .. " texture=" .. tostring(plainSkull:GetTexture()))
end

local function targetIsDead()
    local ok, dead = pcall(UnitIsDead, "target")
    return ok and not isSecret(dead) and dead
end

local updateErrorShown = false
local lastTracedDamage
local function refresh()
    local now = GetTime()
    housekeep(now)
    updateLayering(now)
    applyAppearance()

    if skullTestUntil and now < skullTestUntil then
        skullBar:SetMinMaxValues(0, 1)
        skullBar:SetValue(1)
        skullWindow:Show()
        plainSkullFrame:Show()
        return
    end
    plainSkullFrame:Hide()

    -- Options window preview: the real widgets, attached to its mock target frame, fed its plain numbers.
    -- Same code path as combat, so what you tune there is exactly what you get.
    if previewHost and previewState then
        local entries, total = {}, 0
        for _, dot in ipairs(previewState.dots) do
            if dot.damage > 0 then
                table.insert(entries, dot)
                total = total + dot.damage
            end
        end
        if total <= 0 then return hideAll() end
        skullBar:SetMinMaxValues(0, math.max(previewState.health, 0.01))
        skullBar:SetValue(total)
        skullWindow:SetShown(db.showSkull)
        setMarkerScale(100)
        local perDot = db.dotColors ~= "single"
        setMarkerValue(total, "preview", updateSegments(perDot and entries or nil))
        label:SetText(perDot and breakdownText(entries) or string.format("DoTs: %d", math.floor(total + 0.5)))
        showMarkers()
        return
    end

    if not UnitExists("target") or targetIsDead() then return hideAll() end
    local damage, count, breakdown = targetRemainingDamage()
    if damage ~= lastTracedDamage then
        lastTracedDamage = damage
        trace(string.format("ESTIMATE %d remaining from %d DoT(s)", damage, count))
    end
    if count == 0 then return hideAll() end

    local perDot = db.dotColors ~= "single"
    local ok, err = pcall(function()
        skullBar:SetMinMaxValues(0, UnitHealth("target"))
        skullBar:SetValue(damage)
        if healthBar then
            setMarkerScale(UnitHealthMax("target"))
            setMarkerValue(damage, unitKey("target"), updateSegments(perDot and breakdown or nil))
        end
    end)
    if not ok then
        if not updateErrorShown then
            updateErrorShown = true
            print("Display update failed: " .. tostring(err))
        end
        return hideAll()
    end

    skullWindow:SetShown(db.showSkull)
    if healthBar then
        label:SetText(perDot and breakdownText(breakdown) or string.format("DoTs: %d", damage))
        showMarkers()
    else
        hideMarkers()
    end
end

-- Runs refresh and reports a Lua error once (log and chat) instead of failing silently every 0.1s: WoW hides
-- Lua errors by default, so a broken display would otherwise just not draw.
local reportedErrors = {}
local function safeRefresh()
    local ok, err = pcall(refresh)
    if not ok and not reportedErrors[err] then
        reportedErrors[err] = true
        trace("ERROR in display update: " .. tostring(err))
        print("Display error (logged): " .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- Settings, and what the options window (Options.lua) needs
---------------------------------------------------------------------------

local function applyDefaults()
    -- Settings from earlier versions.
    if db.showMarkers == nil and db.showLine ~= nil then db.showMarkers = db.showLine end
    db.showLine, db.showRemaining = nil, nil
    db.showFullLine, db.lineThickness, db.lineColor = nil, nil, nil
    db.preview, db.previewPercent, db.previewOffInCombat = nil, nil, nil
    for key, value in pairs(DEFAULTS) do
        if db[key] == nil then db[key] = value end
    end
end

-- ns.db is set on ADDON_LOADED.
ns.DEFAULTS = DEFAULTS
ns.lists = {
    colors = COLOR_PRESETS, icons = SKULL_ICONS, fills = FILL_STYLES, outlines = OUTLINE_STYLES,
    dashLengths = DASH_LENGTHS, labelPositions = LABEL_POSITIONS, dotColors = DOT_COLOR_MODES, waitModes = WAIT_MODES,
}
ns.refresh = safeRefresh
ns.playFlash = playFlash
ns.dotColor = dotColor
ns.colorOf = colorOf
ns.findById = findById
ns.textureDir = TEXTURE_DIR

-- The DoTs on the mob behind `unit` (e.g. "nameplate3"): per-DoT breakdown and total remaining damage.
function ns.dotBreakdownForUnit(unit)
    local list = dotBreakdown(unitKey(unit))
    local total = 0
    for _, entry in ipairs(list) do total = total + entry.damage end
    return list, total
end
ns.print = print
ns.trace = trace

function ns.resetLearnedTicks()
    wipe(db.ticks)
    print("Learned tick sizes cleared.")
end

-- host: { healthBar, portrait, layerFrame } to draw on the options window's mock target frame, or nil to go
-- back to the real target frame.
function ns.setDisplayHost(host)
    trace(host and "PREVIEW on: drawing on the options window" or "PREVIEW off: back on the target frame")
    previewHost = host
    layerCheckedAt = 0
    attach()
    safeRefresh()
    if host then
        -- Where things ended up on screen, once layout has settled (for diagnosing an invisible preview).
        C_Timer.After(0.5, function()
            if previewHost ~= host then return end
            trace("PREVIEW geometry: health bar " .. rectOf(host.healthBar) .. " | marker " .. describeFrame(remainingBar)
                .. " | icon " .. describeFrame(skullWindow) .. " | window " .. describeFrame(host.layerFrame))
        end)
    end
end

-- state: { health = 0-100, dots = { { name, school, damage }, ... } } (damage in % of max health), or nil.
function ns.setPreviewState(state)
    previewState = state
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")   -- combo points, before a finisher spends them
-- Estimate during casting: DoTs with a cast time show from the cast's start until it ends.
frame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")   -- keeps a recent combo point reading as backup
frame:RegisterEvent("UNIT_COMBAT")
-- Never register COMBAT_LOG_EVENT_UNFILTERED: Forever forbids it and shows a "blocked" popup.

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        DoesItDieDB = DoesItDieDB or {}
        db = DoesItDieDB
        if db.version ~= DB_VERSION then
            db.ticks, db.intervals, db.version = nil, nil, DB_VERSION
        end
        db.ticks = db.ticks or {}
        db.log = db.log or {}
        applyDefaults()
        ns.db = db
        trace("===== session start =====")
        local ok, err = pcall(ns.registerOptions)
        if not ok then
            trace("Options panel registration failed: " .. tostring(err))
            print("Couldn't create the options panel; slash commands still work (/did help).")
        end
        if not attach() then print("Target portrait not found; kill icon shown beside the target frame.") end
        self:UnregisterEvent("ADDON_LOADED")

    elseif not db then
        return

    elseif event == "PLAYER_TARGET_CHANGED" then
        dotsByTarget.target = nil -- only used when the target's GUID is secret
        resetComboCount() -- combo points belong to the target they were built on
        forgetPendingOutcomes()
        dropCastInProgress("target changed")
        lastTracedDamage = nil
        trace("TARGET changed to " .. (unitKey("target") or "none"))
        safeRefresh()

    elseif event == "UNIT_SPELLCAST_SENT" then
        local _, _, _, spellID = ...
        onCastSent(spellID)

    elseif event == "UNIT_POWER_FREQUENT" then
        local _, powerType = ...
        if not isSecret(powerType) and powerType == "COMBO_POINTS" then rememberComboPoints() end

    elseif event == "UNIT_SPELLCAST_START" then
        local _, castGUID, spellID = ...
        if onCastStart(castGUID, spellID) then safeRefresh() end

    elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then
        local _, castGUID, spellID = ...
        if onCastEnded(event, castGUID, spellID) then safeRefresh() end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, castGUID, spellID = ...
        onCastSucceeded(castGUID, spellID)
        local appliedTo, waiting = onPlayerCast(spellID)
        safeRefresh()
        -- A DoT waiting for its first tick isn't drawn yet; it flashes when that tick lands instead.
        if appliedTo and not waiting and appliedTo == unitKey("target") then playFlash() end

    elseif event == "UNIT_COMBAT" then
        local revealed = onUnitCombat(...)
        if revealed and revealed == unitKey("target") then
            safeRefresh()
            playFlash()
        end
    end
end)

local sinceUpdate = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    if db then animateMarker(elapsed) end
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < UPDATE_INTERVAL or not db then return end
    sinceUpdate = 0
    safeRefresh()
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_DOESITDIE1 = "/did"
SLASH_DOESITDIE2 = "/doesitdie"
SlashCmdList.DOESITDIE = function(msg)
    local cmd = strlower(strtrim(msg or ""))
    if cmd == "" or cmd == "options" or cmd == "config" then
        ns.openOptions()
    elseif cmd == "line" then
        db.showMarkers = not db.showMarkers
        if db.showMarkers and not healthBar then
            print("Target frame health bar not found; health bar markers unavailable.")
        else
            print("Health bar markers " .. (db.showMarkers and "ON" or "OFF") .. ".")
        end
    elseif cmd == "plates" then
        ns.probeNameplates()
    elseif cmd == "skull" then
        skullTestUntil = GetTime() + 5
        print("Kill icon test for 5 seconds: one icon ON the portrait (the real one) and one ABOVE it (plain test).")
        C_Timer.After(0.5, traceSkullGeometry)
    elseif cmd == "debug" then
        db.debug = not db.debug
        print("Debug " .. (db.debug and "ON" or "OFF") .. ".")
    elseif cmd == "reset" then
        wipe(db.ticks)
        print("Learned tick sizes cleared.")
    else
        print("The kill icon on the target's portrait means your DoTs will kill it.")
        print("/did - open the options window")
        print("/did line - toggle health bar markers on/off")
        print("/did skull - show the kill icon for 5 seconds to check its position")
        print("/did plates - check what the addon can reach on visible nameplates (logged)")
        print("/did debug - toggle echoing the trace log (casts, ticks, estimates) to chat")
        print("/did reset - forget learned tick sizes")
    end
end
