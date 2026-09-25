-- DoesItDie nameplates: the damage marker (and optionally the kill icon) on every enemy nameplate that has your
-- DoTs on it, using the per-mob tracking in DoesItDie.lua (ns.dotBreakdownForUnit). Same secret-value trick as
-- the target frame: StatusBars are fed the mob's hidden health and do the comparing.
--
-- Widgets are created per Blizzard nameplate frame (which WoW recycles between mobs) and parented to it, so
-- they move, scale and hide with the plate. They're lighter than the target marker: fill, per-DoT segments and a
-- thin outline in the Marker tab's style; no glow, shine, spark or animation.
--
-- Also the probe (/did plates): what the addon can reach on nameplates, logged, with a test bar on each.

local ADDON_NAME, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local MAX_PLATES = 40
local UPDATE_INTERVAL = 0.1
local MAX_SEGMENTS = 4
local OUTLINE_THICKNESS = 1
local ICON_BAR_LENGTH = 10000 -- see the kill icon notes in DoesItDie.lua
local FALLBACK_LEVEL = 200    -- frame level when the plate's own level can't be read
local TEST_SECONDS = 8
local TEST_BAR_WIDTH, TEST_BAR_HEIGHT = 90, 6

ns.lists.nameplateModes = {
    { id = "off",        label = "Off" },
    { id = "marker",     label = "Marker only" },
    { id = "markerIcon", label = "Marker and kill icon" },
}
ns.lists.nameplateIconPositions = {
    { id = "right", label = "Right of the health bar" },
    { id = "left",  label = "Left of the health bar" },
    { id = "above", label = "Above the health bar" },
}

local testBars = {}
local hideTestBarsAt = 0

local function isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

-- "secret", "nil", "error: ...", or the value.
local function describe(ok, value)
    if not ok then return "error: " .. tostring(value) end
    if value == nil then return "nil" end
    if isSecret(value) then return "secret" end
    return tostring(value)
end

local function call(fn, ...)
    if type(fn) ~= "function" then return "missing" end
    return describe(pcall(fn, ...))
end

-- Platynator hides Blizzard's UnitFrame and draws its own display frames (40 per style, preallocated),
-- parented to "NamePlate<i>" or, when that doesn't exist yet at creation (as in Forever), to UIParent. The
-- active one for a unit is shown with .unit = the nameplate unit token; its .widgets list holds the health
-- widget (details.kind == "health") with the real StatusBar in .statusBar. Displays are found by scanning
-- UIParent's and the plate's children, cached, and rescanned (throttled) when a unit has none.
local platyDisplays = {}
local platyLastScan = -math.huge
local PLATY_RESCAN_INTERVAL = 2

local function isPlatyDisplay(frame)
    return type(frame.widgets) == "table" and type(frame.Install) == "function" and type(frame.SetUnit) == "function"
end

local function scanPlatyDisplays(plate)
    for _, parent in ipairs({ UIParent, plate }) do
        for _, child in ipairs({ parent:GetChildren() }) do
            if not platyDisplays[child] and isPlatyDisplay(child) then platyDisplays[child] = true end
        end
    end
end

local function platyBarFor(unit)
    for display in pairs(platyDisplays) do
        if display.unit == unit and display:IsShown() and type(display.widgets) == "table" then
            for _, widget in ipairs(display.widgets) do
                if type(widget.details) == "table" and widget.details.kind == "health" and widget.statusBar then
                    return widget.statusBar
                end
            end
        end
    end
end

local function findPlatynatorBar(plate, unit)
    if not (Platynator and unit) then return nil end
    local bar = platyBarFor(unit)
    if bar then return bar end
    local now = GetTime()
    if now - platyLastScan < PLATY_RESCAN_INTERVAL then return nil end
    platyLastScan = now
    scanPlatyDisplays(plate)
    return platyBarFor(unit)
end

-- The health bar of a nameplate (Platynator's if it's drawing the plate, else Blizzard's), and the path
-- it was found under.
local function findHealthBar(plate, unit)
    local ok, platyBar = pcall(findPlatynatorBar, plate, unit)
    if ok and platyBar then return platyBar, "Platynator health widget" end
    local unitFrame = plate.UnitFrame
    if not unitFrame then return nil, "no UnitFrame" end
    if unitFrame.healthBar then return unitFrame.healthBar, "UnitFrame.healthBar" end
    local container = unitFrame.HealthBarsContainer
    if container and container.healthBar then return container.healthBar, "UnitFrame.HealthBarsContainer.healthBar" end
    if unitFrame.HealthBar then return unitFrame.HealthBar, "UnitFrame.HealthBar" end
    return nil, "no health bar found"
end

---------------------------------------------------------------------------
-- Nameplate display
---------------------------------------------------------------------------

local widgetsByPlate = {} -- Blizzard nameplate frame -> our widgets

local function coverSpan(texture, span)
    texture:SetPoint("TOPLEFT", span, "TOPLEFT")
    texture:SetPoint("BOTTOMRIGHT", span, "BOTTOMRIGHT")
end

local function invisibleBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetStatusBarColor(0, 0, 0, 0)
    return bar
end

-- Anchors the widgets to a health bar and layers them above it (same strata: Platynator's bars are MEDIUM,
-- above the plate's own). Its level/strata can be secret in Forever; then use fixed ones.
local function attachWidgets(w, healthBar)
    w.healthBar = healthBar
    w.signature = nil -- the icon position is anchored to the bar in applyStyle
    w.marker:ClearAllPoints()
    w.marker:SetAllPoints(healthBar)

    local okStrata, strata = pcall(healthBar.GetFrameStrata, healthBar)
    if okStrata and type(strata) == "string" and not isSecret(strata) then
        w.marker:SetFrameStrata(strata)
        w.iconWindow:SetFrameStrata(strata)
        w.iconBar:SetFrameStrata(strata)
    end
    local ok, level = pcall(healthBar.GetFrameLevel, healthBar)
    if not ok or isSecret(level) or type(level) ~= "number" then level = FALLBACK_LEVEL end
    -- The icon sits well above: plate decorations beside the bar (the level badge) must not cover it.
    w.marker:SetFrameLevel(level + 5)
    w.iconWindow:SetFrameLevel(level + 20)
    w.iconBar:SetFrameLevel(level + 21)
end

local function createWidgets(plate, healthBar)
    local w = {}

    -- Marker: filled from the bar's left edge to the remaining DoT damage, on the mob's (secret) health scale.
    w.marker = invisibleBar(plate)
    w.span = w.marker:GetStatusBarTexture()
    w.fill = w.marker:CreateTexture(nil, "ARTWORK")
    coverSpan(w.fill, w.span)

    -- Per-DoT segments: running-total bars, each segment between the previous bar's fill end and its own.
    w.segments = {}
    for i = 1, MAX_SEGMENTS do
        local bar = invisibleBar(w.marker)
        bar:SetAllPoints(w.marker)
        local fillEnd = bar:GetStatusBarTexture()
        local texture = w.marker:CreateTexture(nil, "ARTWORK", nil, 1)
        if i == 1 then
            texture:SetPoint("TOPLEFT", w.marker, "TOPLEFT")
        else
            texture:SetPoint("TOPLEFT", w.segments[i - 1].fillEnd, "TOPRIGHT")
        end
        texture:SetPoint("BOTTOMRIGHT", fillEnd, "BOTTOMRIGHT")
        w.segments[i] = { bar = bar, fillEnd = fillEnd, texture = texture }
    end

    w.edges = {}
    for _, points in ipairs({ { true, "TOPLEFT", "TOPRIGHT" }, { true, "BOTTOMLEFT", "BOTTOMRIGHT" },
        { false, "TOPLEFT", "BOTTOMLEFT" }, { false, "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local edge = w.marker:CreateTexture(nil, "OVERLAY")
        edge:SetPoint(points[2], w.span, points[2])
        edge:SetPoint(points[3], w.span, points[3])
        if points[1] then edge:SetHeight(OUTLINE_THICKNESS) else edge:SetWidth(OUTLINE_THICKNESS) end
        table.insert(w.edges, { texture = edge, horizontal = points[1] })
    end

    -- Kill icon: a clipped window; the icon rides the end of a very long bar with max = current health and
    -- value = remaining damage, so it only slides into the window when damage >= health.
    w.iconWindow = CreateFrame("Frame", nil, plate)
    w.iconWindow:SetClipsChildren(true)
    w.iconBar = invisibleBar(w.iconWindow)
    w.iconBar:SetPoint("RIGHT", w.iconWindow, "RIGHT")
    w.icon = w.iconBar:CreateTexture(nil, "OVERLAY")
    w.icon:SetPoint("RIGHT", w.iconBar:GetStatusBarTexture(), "RIGHT")

    attachWidgets(w, healthBar)
    widgetsByPlate[plate] = w
    return w
end

-- Nameplates have their own look (plate* settings), separate from the target marker: enemy plates are red.
local STYLE_KEYS = {
    "plateFillTexture", "plateFillColor", "plateFillOpacity", "plateDotColors", "plateOutlineStyle",
    "plateDashLength", "plateOutlineThickness", "plateOutlineColor", "plateOutlineOpacity", "plateIcon",
    "nameplateIconSize", "nameplateIconPosition", "plateIconOffsetX", "plateIconOffsetY",
}

-- Pushes the look settings onto one plate's widgets when any of them changed since the last time.
local function applyStyle(w, db)
    local parts = {}
    for i, key in ipairs(STYLE_KEYS) do parts[i] = tostring(db[key]) end
    local signature = table.concat(parts, "|")
    if signature == w.signature then return end
    w.signature = signature

    local lists = ns.lists
    local style = ns.findById(lists.fills, db.plateFillTexture)
    local path = (style.path and not style.gradient) and style.path or nil
    local wrap = style.tiled and "REPEAT" or nil
    w.fill:SetShown(path ~= nil and db.plateDotColors == "single")
    if path then
        w.fill:SetTexture(path, wrap, wrap)
        w.fill:SetHorizTile(style.tiled or false)
        w.fill:SetVertTile(style.tiled or false)
        w.fill:SetVertexColor(ns.colorOf(db.plateFillColor, db.plateFillOpacity))
    end
    for _, segment in ipairs(w.segments) do
        segment.texture:SetTexture(path or WHITE, wrap, wrap)
        segment.texture:SetHorizTile(style.tiled or false)
        segment.texture:SetVertTile(style.tiled or false)
    end

    local r, g, b, a = ns.colorOf(db.plateOutlineColor, db.plateOutlineOpacity)
    for _, edge in ipairs(w.edges) do
        if db.plateOutlineStyle == "dashed" then
            local file = (edge.horizontal and "DashH" or "DashV") .. db.plateDashLength
            edge.texture:SetTexture(ns.textureDir .. file, "REPEAT", "REPEAT")
            edge.texture:SetHorizTile(edge.horizontal)
            edge.texture:SetVertTile(not edge.horizontal)
        else
            edge.texture:SetTexture(WHITE)
            edge.texture:SetHorizTile(false)
            edge.texture:SetVertTile(false)
        end
        if edge.horizontal then
            edge.texture:SetHeight(db.plateOutlineThickness)
        else
            edge.texture:SetWidth(db.plateOutlineThickness)
        end
        edge.texture:SetVertexColor(r, g, b, a)
        edge.texture:SetShown(db.plateOutlineStyle ~= "none")
    end

    local size = db.nameplateIconSize
    w.iconWindow:SetSize(size, size)
    w.iconBar:SetSize(ICON_BAR_LENGTH, size)
    w.icon:SetSize(size, size)
    w.icon:SetTexture(ns.findById(lists.icons, db.plateIcon).path)
    w.iconWindow:ClearAllPoints()
    local x, y = db.plateIconOffsetX, db.plateIconOffsetY
    if db.nameplateIconPosition == "left" then
        w.iconWindow:SetPoint("RIGHT", w.healthBar, "LEFT", -4 + x, y)
    elseif db.nameplateIconPosition == "above" then
        w.iconWindow:SetPoint("BOTTOM", w.healthBar, "TOP", x, 4 + y)
    else
        w.iconWindow:SetPoint("LEFT", w.healthBar, "RIGHT", 4 + x, y)
    end
end

local function hideWidgets(w)
    w.marker:Hide()
    w.iconWindow:Hide()
end

-- Draws one plate's widgets. maxHealth and health may be secret (real plates) or plain (the options preview):
-- they only ever go into StatusBar min/max, never into Lua math. Returns false if drawing failed.
local function drawPlate(w, entries, total, maxHealth, health, db)
    applyStyle(w, db)
    local perDot = db.plateDotColors ~= "single"
    local count = perDot and math.min(#entries, MAX_SEGMENTS) or 0
    local ok = pcall(function()
        w.marker:SetMinMaxValues(0, maxHealth)
        w.marker:SetValue(total)
        local running = 0
        for i, segment in ipairs(w.segments) do
            local entry = entries[i]
            if i <= count then
                running = running + entry.damage
                -- The last segment also covers any DoTs beyond MAX_SEGMENTS.
                if i == count then running = total end
                local color = ns.dotColor(entry, db.plateDotColors)
                segment.texture:SetVertexColor(color[1], color[2], color[3], db.plateFillOpacity / 100)
            end
            segment.bar:SetMinMaxValues(0, maxHealth)
            segment.bar:SetValue(i <= count and running or total)
            segment.texture:SetShown(i <= count)
        end
        w.iconBar:SetMinMaxValues(0, health)
        w.iconBar:SetValue(total)
    end)
    if not ok then
        hideWidgets(w)
        return false
    end
    w.marker:SetShown(db.showMarkers)
    w.iconWindow:SetShown(db.nameplateMode == "markerIcon")
    return true
end

local function widgetsFor(plate, healthBar)
    local w = widgetsByPlate[plate]
    if not w then
        w = createWidgets(plate, healthBar)
    elseif w.healthBar ~= healthBar then
        attachWidgets(w, healthBar) -- e.g. Platynator switched the plate's style
    end
    return w
end

local function updatePlate(unit, plate, db)
    local entries, total = ns.dotBreakdownForUnit(unit)
    if total <= 0 then
        local w = widgetsByPlate[plate]
        if w then hideWidgets(w) end
        return
    end
    local healthBar = findHealthBar(plate, unit)
    if not healthBar then return end
    drawPlate(widgetsFor(plate, healthBar), entries, total, UnitHealthMax(unit), UnitHealth(unit), db)
end

-- The options window's mock nameplate: { plate, healthBar } plus its preview state ({ health, dots } in % of
-- max health), or nil. Drawn by the same code as real plates, with plain numbers.
local previewPlate, previewState

function ns.setPlatePreview(host, state)
    local old = previewPlate
    previewPlate, previewState = host, state
    if old and not host then
        local w = widgetsByPlate[old.plate]
        if w then hideWidgets(w) end
    end
end

local function updatePreviewPlate(db)
    local entries, total = {}, 0
    for _, dot in ipairs(previewState.dots) do
        if dot.damage > 0 then
            table.insert(entries, dot)
            total = total + dot.damage
        end
    end
    local w = widgetsFor(previewPlate.plate, previewPlate.healthBar)
    if total <= 0 or db.nameplateMode == "off" then return hideWidgets(w) end
    drawPlate(w, entries, total, 100, math.max(previewState.health, 0.01), db)
end

local seenPlates = {}
local function refreshPlates()
    local db = ns.db
    wipe(seenPlates)
    if db and previewPlate and previewState then
        seenPlates[previewPlate.plate] = true
        updatePreviewPlate(db)
    end
    if db and db.nameplateMode ~= "off" and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        for i = 1, MAX_PLATES do
            local unit = "nameplate" .. i
            if UnitExists(unit) then
                local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
                local forbidden = ok and plate and plate.IsForbidden and plate:IsForbidden()
                if ok and plate and not forbidden then
                    seenPlates[plate] = true
                    updatePlate(unit, plate, db)
                end
            end
        end
    end
    for plate, w in pairs(widgetsByPlate) do
        if not seenPlates[plate] then hideWidgets(w) end
    end
end

local driver = CreateFrame("Frame")
local sinceUpdate = 0
local reportedError = false
driver:SetScript("OnUpdate", function(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < UPDATE_INTERVAL then return end
    sinceUpdate = 0
    local ok, err = pcall(refreshPlates)
    if not ok and not reportedError and ns.trace then
        reportedError = true
        ns.trace("ERROR in nameplate update: " .. tostring(err))
        ns.print("Nameplate display error (logged): " .. tostring(err))
    end
end)

local function testBar(i)
    if not testBars[i] then
        local bar = CreateFrame("StatusBar", nil, UIParent)
        bar:SetSize(TEST_BAR_WIDTH, TEST_BAR_HEIGHT)
        bar:SetStatusBarTexture(WHITE)
        bar:SetStatusBarColor(1, 0, 1, 1)
        bar:SetFrameStrata("HIGH")
        local back = bar:CreateTexture(nil, "BACKGROUND")
        back:SetAllPoints()
        back:SetColorTexture(0, 0, 0, 0.8)
        bar:Hide()
        testBars[i] = bar
    end
    return testBars[i]
end

local hider = CreateFrame("Frame")
hider:Hide()
hider:SetScript("OnUpdate", function(self)
    if GetTime() < hideTestBarsAt then return end
    for _, bar in ipairs(testBars) do bar:Hide() end
    self:Hide()
end)

-- Checks one nameplate unit; returns a log line and whether the test bar could be shown.
local function probePlate(unit, index)
    local parts = { unit }
    table.insert(parts, "guid=" .. call(UnitGUID, unit))
    table.insert(parts, "attackable=" .. call(UnitCanAttack, "player", unit))
    table.insert(parts, "health=" .. call(UnitHealth, unit))
    table.insert(parts, "max=" .. call(UnitHealthMax, unit))

    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
        table.insert(parts, "plate API missing")
        return table.concat(parts, " "), false
    end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok then
        table.insert(parts, "plate: error " .. tostring(plate))
        return table.concat(parts, " "), false
    end
    if not plate then
        table.insert(parts, "plate: nil")
        return table.concat(parts, " "), false
    end
    local forbidden = plate.IsForbidden and plate:IsForbidden()
    table.insert(parts, "forbidden=" .. tostring(forbidden))
    if forbidden then return table.concat(parts, " "), false end

    local healthBar, path = findHealthBar(plate, unit)
    table.insert(parts, "healthBar=" .. path)
    if healthBar then
        table.insert(parts, "barForbidden=" .. tostring(healthBar.IsForbidden and healthBar:IsForbidden() or false))
        table.insert(parts, "barRect=" .. call(healthBar.GetRect, healthBar))
        table.insert(parts, "barScale=" .. call(healthBar.GetEffectiveScale, healthBar))
    end
    -- Platynator: which display frames we know of, and which unit each shows.
    if Platynator then
        pcall(scanPlatyDisplays, plate)
        local known, units = 0, {}
        for display in pairs(platyDisplays) do
            known = known + 1
            if display.unit then table.insert(units, tostring(display.unit) .. (display:IsShown() and "" or "(hidden)")) end
        end
        table.insert(parts, "platyDisplays=" .. known .. " units=" .. table.concat(units, ","))
        local childCount = select("#", plate:GetChildren())
        table.insert(parts, "plateChildren=" .. childCount)
    end
    local w = widgetsByPlate[plate]
    if w then
        table.insert(parts, "markerRect=" .. call(w.marker.GetRect, w.marker))
        table.insert(parts, "markerOnBar=" .. tostring(w.healthBar == healthBar))
    end

    local bar = testBar(index)
    bar:ClearAllPoints()
    local anchorOK, anchorErr = pcall(bar.SetPoint, bar, "BOTTOM", plate, "TOP", 0, 2)
    table.insert(parts, "anchorPlate=" .. (anchorOK and "ok" or ("error " .. tostring(anchorErr))))
    if healthBar then
        local probeAnchor = testBar(MAX_PLATES + 1)
        probeAnchor:ClearAllPoints()
        local ok2, err2 = pcall(probeAnchor.SetPoint, probeAnchor, "TOPLEFT", healthBar, "TOPLEFT")
        table.insert(parts, "anchorHealthBar=" .. (ok2 and "ok" or ("error " .. tostring(err2))))
        probeAnchor:ClearAllPoints()
        probeAnchor:Hide()
    end
    local feedOK, feedErr = pcall(function()
        bar:SetMinMaxValues(0, UnitHealthMax(unit))
        bar:SetValue(UnitHealth(unit))
    end)
    table.insert(parts, "feedHealth=" .. (feedOK and "ok" or ("error " .. tostring(feedErr))))

    local shown = anchorOK and feedOK
    if shown then bar:Show() end
    return table.concat(parts, " "), shown
end

function ns.probeNameplates()
    local inInstance, instanceType = IsInInstance()
    ns.trace(string.format("PLATES probe: C_NamePlate=%s GetNamePlateForUnit=%s instance=%s (%s) inCombat=%s",
        tostring(C_NamePlate ~= nil), tostring(C_NamePlate ~= nil and C_NamePlate.GetNamePlateForUnit ~= nil),
        tostring(inInstance), tostring(instanceType), call(UnitAffectingCombat, "player")))
    for _, bar in ipairs(testBars) do bar:Hide() end

    local found, shown = 0, 0
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            found = found + 1
            local line, ok = probePlate(unit, found)
            ns.trace("PLATES " .. line)
            if ok then shown = shown + 1 end
        end
    end

    hideTestBarsAt = GetTime() + TEST_SECONDS
    hider:Show()
    ns.trace(string.format("PLATES probe done: %d nameplates, %d test bars shown", found, shown))
    ns.print(string.format("Nameplate probe: %d nameplates found, %d magenta test bars shown for %d seconds. "
        .. "Results are in the log (/reload to save it).", found, shown, TEST_SECONDS))
end
