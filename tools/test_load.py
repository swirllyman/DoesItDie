"""Smoke test: loads the whole addon (every file in the .toc) in Lua with a fake WoW environment, then drives it
like a player: ADDON_LOADED, /did, every tab, every preset, checkboxes, sliders, dropdowns, Simulate fight,
closing the window. Fails on any Lua error and checks a few results.

    pip install lupa
    python tools/test_load.py

The fake frames accept any method (unknown ones do nothing) and record what matters: scripts, text, values,
shown state. It catches runtime mistakes (nil calls, typos, wrong arguments to our own functions), not
visual ones.
"""
import os
import sys

from lupa.lua51 import LuaRuntime  # WoW runs Lua 5.1

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "DoesItDie")

FAKE_WOW = r"""
now = 1000
chat = {}
frames = {}
tickers = {}

local methods = {}
local function mock(kind, parent)
    local o = { kind = kind, parent = parent, scripts = {}, shown = true, width = 100, height = 20, children = {} }
    if parent and type(parent) == "table" and parent.children then table.insert(parent.children, o) end
    table.insert(frames, o)
    -- Unknown methods (CamelCase, like WoW's) do nothing; unknown fields are nil like a real table.
    return setmetatable(o, { __index = function(t, k)
        if methods[k] then return methods[k] end
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end
FakeMock = mock

function methods.SetScript(self, name, fn) self.scripts[name] = fn end
function methods.GetScript(self, name) return self.scripts[name] end
function methods.HookScript(self, name, fn) self.scripts[name] = fn end
function methods.Show(self)
    local was = self.shown
    self.shown = true
    if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods.Hide(self)
    local was = self.shown
    self.shown = false
    if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods.SetShown(self, v) if v then self:Show() else self:Hide() end end
function methods.IsShown(self) return self.shown end
function methods.IsVisible(self) return self.shown end
function methods.SetText(self, t) self.text = t end
function methods.GetText(self) return self.text end
function methods.SetSize(self, w, h) self.width, self.height = w, h end
function methods.SetWidth(self, w) self.width = w end
function methods.SetHeight(self, h) self.height = h end
function methods.GetWidth(self) return self.width end
function methods.GetHeight(self) return self.height end
function methods.GetStringWidth(self) return #(self.text or "") * 6 end
function methods.GetFont(self) return "Fonts\\FRIZQT__.TTF", 12, "" end
function methods.SetFrameStrata(self, v) self.strata = v end
function methods.GetFrameStrata(self) return self.strata or "MEDIUM" end
function methods.SetFrameLevel(self, v) self.level = v end
function methods.GetFrameLevel(self) return self.level or 5 end
function methods.GetChildren(self) return end
function methods.SetClipsChildren(self, v) self.clips = v end
function methods.IsMouseOver(self) return false end
function methods.GetStatusBarTexture(self) self._tex = self._tex or mock("tex", self); return self._tex end
function methods.GetThumbTexture(self) self._thumb = self._thumb or mock("thumb", self); return self._thumb end
function methods.CreateTexture(self) return mock("texture", self) end
function methods.CreateMaskTexture(self) return mock("mask", self) end
function methods.CreateFontString(self) return mock("fontstring", self) end
function methods.CreateAnimationGroup(self) return mock("animgroup", self) end
function methods.CreateAnimation(self) return mock("anim", self) end
function methods.SetChecked(self, v) self.checked = v end
function methods.GetChecked(self) return self.checked end
function methods.SetMinMaxValues(self, a, b) self.min, self.max = a, b end
function methods.GetMinMaxValues(self) return self.min, self.max end
function methods.SetValue(self, v)
    if self.min and type(v) == "number" then v = math.max(self.min, math.min(self.max, v)) end
    self.value = v
    if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v, false) end
end
function methods.GetValue(self) return self.value or 0 end
function methods.RegisterEvent(self, e) self.events = self.events or {}; self.events[e] = true end
function methods.RegisterUnitEvent(self, e) self.events = self.events or {}; self.events[e] = true end
function methods.GetDebugName(self) return self.name or "mock" end

function CreateFrame(kind, name, parent, template)
    local f = mock(kind, parent)
    f.name, f.template = name, template
    if kind ~= "Frame" or name then f.shown = true end
    if name then _G[name] = f end
    return f
end
UIParent = mock("UIParent")
GameTooltip = mock("GameTooltip")
GameFontNormalSmall = mock("font")
DEFAULT_CHAT_FRAME = mock("chat")
function DEFAULT_CHAT_FRAME.AddMessage(self, msg) table.insert(chat, msg) end
SlashCmdList = {}
UISpecialFrames = {}
Settings = {
    RegisterCanvasLayoutCategory = function() return mock("category") end,
    RegisterAddOnCategory = function() end,
}
C_Timer = {
    After = function(t, fn) end,
    NewTicker = function(t, fn)
        local ticker = { fn = fn, cancelled = false }
        function ticker:Cancel() self.cancelled = true end
        table.insert(tickers, ticker)
        return ticker
    end,
}
local SPELLS = {
    [172] = { "Corruption", "Corrupts the target, causing 40 Shadow damage over 12 sec." },
    [348] = { "Immolate", "Burns the enemy for 11 Fire damage and then an additional 20 Fire damage over 15 sec." },
}
C_Spell = {
    GetSpellName = function(id) return SPELLS[id] and SPELLS[id][1] or "Spell" end,
    GetSpellDescription = function(id) return SPELLS[id] and SPELLS[id][2] or "" end,
}
Enum = { PowerType = { ComboPoints = 4 } }
function GetTime() return now end
targetGuid = nil -- set later: the target and nameplate1 are then the same mob
function UnitExists(unit) return unit == "nameplate1" or (unit == "target" and targetGuid ~= nil) end
function UnitCanAttack() return true end
function IsInInstance() return false, "none" end
local plate = mock("Frame")
FakePlate = plate
plate.UnitFrame = mock("Frame", plate)
plate.UnitFrame.healthBar = mock("StatusBar", plate.UnitFrame)
C_NamePlate = { GetNamePlateForUnit = function(unit) if unit == "nameplate1" then return plate end end }
function UnitGUID(unit) if unit == "target" or unit == "nameplate1" then return targetGuid end end
function UnitIsDead() return false end
combat = false
function UnitAffectingCombat() return combat end
function InCombatLockdown() return combat end
function UnitHealth() return 100 end
function UnitHealthMax() return 100 end
function hooksecurefunc() end
function HideUIPanel() end
function CreateColor(...) return { ... } end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strlower(s) return string.lower(s) end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function date() return "12:00:00" end
unpack = unpack or table.unpack
"""

HELPERS = r"""
local H = {}
function H.load(path, src, ns)
    local fn, err = (loadstring or load)(src, "@" .. path)
    if not fn then error(err) end
    fn("DoesItDie", ns)
end
function H.fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events and f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end
function H.update(elapsed)
    now = now + elapsed
    for _, f in ipairs(frames) do
        if f.scripts.OnUpdate then f.scripts.OnUpdate(f, elapsed) end
    end
end
-- The clickable owner of a visible text (buttons with SetText, or a button whose child font string has it).
function H.clickText(text)
    for _, f in ipairs(frames) do
        if f.text == text then
            local target = f.scripts.OnClick and f or f.parent
            if target and target.scripts and target.scripts.OnClick then
                target.scripts.OnClick(target)
                return true
            end
        end
    end
    error("nothing clickable with text: " .. text)
end
-- The row whose label is `text`: returns its first child widget of the given kind.
function H.rowWidget(text, kind)
    for _, f in ipairs(frames) do
        if f.kind == "fontstring" and f.text == text and f.parent then
            for _, child in ipairs(f.parent.children) do
                if child.kind == kind then return child end
            end
        end
    end
    error("no " .. kind .. " in row " .. text)
end
function H.shownMenuEntries()
    local out = {}
    for _, f in ipairs(frames) do
        if f.kind == "Button" and f.swatch and f.shown and f.scripts.OnClick then table.insert(out, f) end
    end
    return out
end
function H.runTickers(times)
    for _ = 1, times do
        for _, t in ipairs(tickers) do if not t.cancelled then now = now + 0.5; t.fn() end end
    end
end
return H
"""

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(FAKE_WOW)
H = lua.execute(HELPERS)
G = lua.globals()
failures = 0


def check(label, actual, expected):
    global failures
    ok = actual == expected
    failures += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {label:<60} {actual}" + ("" if ok else f"   (expected {expected})"))


def step(label, fn):
    global failures
    try:
        fn()
        print(f"PASS  {label}")
    except Exception as e:  # a Lua error surfaces here
        failures += 1
        print(f"FAIL  {label}\n      {e}")


ns = lua.table()
toc = open(os.path.join(ADDON, "DoesItDie.toc"), encoding="utf-8").read().splitlines()
files = [line.strip() for line in toc if line.strip().endswith(".lua")]
for name in files:
    step(f"load {name}", lambda name=name: H.load(name, open(os.path.join(ADDON, name), encoding="utf-8").read(), ns))

step("ADDON_LOADED", lambda: H.fire("ADDON_LOADED", "DoesItDie"))
check("defaults applied", G.DoesItDieDB.skullIcon, "cross")
step("run the display loop with no target", lambda: H.update(0.2))
step("/did opens the window", lambda: G.SlashCmdList.DOESITDIE(""))
check("window shown", G.DoesItDieOptions.shown, True)
step("display loop with the window's preview", lambda: H.update(0.2))

for tab in ("Kill icon", "Marker", "Effects", "Text", "Nameplates", "Behavior"):
    step(f"open tab {tab}", lambda tab=tab: H.clickText(tab))


def copy_marker_look():
    H.clickText("Nameplates")
    G.DoesItDieDB.fillColor = "gold"
    H.clickText("Copy from Marker tab")


step("Nameplates: Copy from Marker tab", copy_marker_look)
check("  plate fill color copied from the marker", G.DoesItDieDB.plateFillColor, "gold")

for preset in ("Minimal", "Classic", "Debug", "Juicy"):
    step(f"apply preset {preset}", lambda p=preset: H.clickText(p))
    step(f"  display loop after {preset}", lambda: H.update(0.2))
check("Juicy preset set the fill", G.DoesItDieDB.fillTexture, "stripes")


def toggle_glow():
    box = H.rowWidget("Glow", "CheckButton")
    box.checked = False
    box.scripts.OnClick(box)


step("untick Glow", toggle_glow)
check("  glow setting off", G.DoesItDieDB.showGlow, False)


def set_slider(label, value):
    def run():
        H.rowWidget(label, "Slider").SetValue(H.rowWidget(label, "Slider"), value)
    return run


step("drag Size slider to 40", set_slider("Size", 40))
check("  icon size saved", G.DoesItDieDB.skullSize, 40)
step("drag Target health to 30", set_slider("Target health", 30))
step("drag DoT damage to 50", set_slider("DoT damage", 50))
step("display loop with a lethal preview", lambda: H.update(1.2))
check("  marker frame shown", G.DoesItDieRemaining.shown, True)
check("  marker filled to the DoT damage", round(G.DoesItDieRemaining.value or -1), 50)
check("  kill icon frame shown", G.DoesItDieSkull.shown, True)
check("  marker layered above the window's strata", G.DoesItDieRemaining.strata, "FULLSCREEN")


def preview_plate_markers():
    # The mock nameplate is the window's only frame whose child StatusBar is sized 140x10.
    for f in G.frames.values():
        if f.kind == "Frame" and f.width == 140 and f.height == 26:
            return [c for c in f.children.values() if c.kind == "StatusBar" and c.width != 140]
    return []


markers_on_preview_plate = preview_plate_markers()
check("  preview nameplate got a marker", len(markers_on_preview_plate) >= 1, True)
check("  preview nameplate marker filled to the DoT damage",
      round(markers_on_preview_plate[0].value) if markers_on_preview_plate else None, 50)


def pick_outline_none():
    H.clickText("Marker")
    button = H.rowWidget("Outline", "Button")
    button.scripts.OnClick(button)
    entries = H.shownMenuEntries()
    for entry in entries.values():
        if entry.text and "None" in entry.text.text:
            entry.scripts.OnClick(entry)
            return
    raise AssertionError("no None entry in the outline menu")


step("pick Outline: None from the dropdown", pick_outline_none)
check("  outline style saved", G.DoesItDieDB.outlineStyle, "none")
step("display loop without outline", lambda: H.update(0.2))

step("Reset this tab (Marker)", lambda: H.clickText("Reset this tab"))
check("  outline back to default", G.DoesItDieDB.outlineStyle, "dashed")

def enter_combat():
    G.combat = True
    H.fire("PLAYER_REGEN_DISABLED")
    H.update(1.2)


def leave_combat():
    G.combat = False
    H.fire("PLAYER_REGEN_ENABLED")
    H.update(1.2)


step("enter combat with the window open", enter_combat)
check("  display back on the target frame (not the window's strata)", G.DoesItDieRemaining.strata != "FULLSCREEN", True)
check("  log says the preview stepped aside",
      any("PREVIEW off" in line for line in list(G.DoesItDieDB.log.values())[-5:]), True)
step("leave combat", leave_combat)
check("  preview has the display again", G.DoesItDieRemaining.strata, "FULLSCREEN")

step("start Simulate fight", lambda: H.clickText("Simulate fight"))
step("run the simulated fight", lambda: (H.runTickers(25), H.update(0.2)))
step("Flash button", lambda: H.clickText("Flash"))
step("Reset learned tick sizes", lambda: H.clickText("Reset"))
step("close the window", lambda: G.DoesItDieOptions.Hide(G.DoesItDieOptions))
check("window hidden", G.DoesItDieOptions.shown, False)
step("display loop back on the (absent) target", lambda: H.update(0.2))
step("/did help", lambda: G.SlashCmdList.DOESITDIE("help"))
step("/did plates", lambda: G.SlashCmdList.DOESITDIE("plates"))
plate_lines = [line for line in G.DoesItDieDB.log.values() if "PLATES" in line]
check("  probe logged the fake nameplate", any("nameplate1" in line and "healthBar=UnitFrame.healthBar" in line
                                                and "anchorPlate=ok" in line for line in plate_lines), True)
check("  probe summary", plate_lines[-1].split("PLATES ")[1], "probe done: 1 nameplates, 1 test bars shown")
step("test bars hide after 8 seconds", lambda: H.update(9))


def plate_children(kind):
    return [c for c in G.FakePlate.children.values() if c.kind == kind]


def dot_the_mob():
    G.targetGuid = "Creature-0-1-2-3-3099-000001"
    H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 172)
    H.update(0.2)


step("cast Corruption on the mob behind nameplate1", dot_the_mob)
markers = plate_children("StatusBar")
check("  nameplate got a marker", len(markers), 1)
check("  marker filled to Corruption's 40", markers[0].value if markers else None, 40)
check("  marker shown", markers[0].shown if markers else None, True)
icon_windows = [f for f in plate_children("Frame") if f.clips]  # the clipped kill icon window
check("  kill icon window shown", icon_windows[0].shown if icon_windows else None, True)


def fire_and_update(event, *args):
    def run():
        H.fire(event, "player", *args)
        H.update(0.2)
    return run


step("start casting Immolate (cast time) on it", fire_and_update("UNIT_SPELLCAST_START", "cast-2", 348))
check("  nameplate marker counts it while casting: 40 + 20", markers[0].value if markers else None, 60)
step("the cast is interrupted", fire_and_update("UNIT_SPELLCAST_INTERRUPTED", "cast-2", 348))
check("  back to Corruption alone", markers[0].value if markers else None, 40)


def set_estimate(on):
    def run():
        H.clickText("Behavior")
        box = H.rowWidget("Estimate during casting", "CheckButton")
        box.checked = on
        box.scripts.OnClick(box)
    return run


step("untick Estimate during casting", set_estimate(False))
check("  setting off", G.DoesItDieDB.estimateDuringCast, False)
step("start casting Immolate with it off", fire_and_update("UNIT_SPELLCAST_START", "cast-3", 348))
check("  nothing added while casting", markers[0].value if markers else None, 40)
step("  and interrupted", fire_and_update("UNIT_SPELLCAST_INTERRUPTED", "cast-3", 348))
step("tick it again", set_estimate(True))
check("  setting on", G.DoesItDieDB.estimateDuringCast, True)
step("cast Immolate again", fire_and_update("UNIT_SPELLCAST_START", "cast-4", 348))
step("  it lands (SUCCEEDED, then STOP)", lambda: (H.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-4", 348),
                                                   H.fire("UNIT_SPELLCAST_STOP", "player", "cast-4", 348),
                                                   H.update(1.0)))
check("  counted once: 40 + 20", markers[0].value if markers else None, 60)


def plates_off():
    G.DoesItDieDB.nameplateMode = "off"
    H.update(0.2)


step("switch nameplates off", plates_off)
check("  marker hidden", markers[0].shown if markers else None, False)
check("  kill icon hidden", icon_windows[0].shown if icon_windows else None, False)

print(f"\n{'all passed' if not failures else str(failures) + ' FAILED'}")
sys.exit(1 if failures else 0)
