# DoesItDie API

For addon authors: show DoesItDie's estimate (how much damage the player's DoTs still have to deal) on your own unit
frames or nameplates. Available from v0.9.0 when DoesItDie is installed and enabled. Add `## OptionalDeps: DoesItDie`
to your `.toc` and check that the global `DoesItDie` exists before using it.

```lua
if DoesItDie and DoesItDie.API_VERSION >= 1 then ... end
```

## Functions

### `DoesItDie.GetRemainingDamage(unit) -> damage, count`

The total damage the player's DoTs on the mob behind `unit` still have to deal (rounded), and how many DoTs that is.
`0, 0` when there are none or the unit can't be tracked. Any unit token works; `target`, `focus` and `nameplateN` are
the ones the tracking can keep up to date, since `UNIT_COMBAT` only reports hits on those.

### `DoesItDie.GetDoTs(unit) -> list`

The player's DoTs on that mob, oldest first. A new table on every call, safe to keep. Each entry:

| Field | |
|---|---|
| `name` | Spell name (as the client shows it) |
| `spellID` | Spell ID of the cast |
| `school` | School bit mask (1 Physical, 2 Holy, 4 Fire, 8 Nature, 16 Frost, 32 Shadow, 64 Arcane) |
| `damage` | Remaining damage (rounded) |
| `appliedAt`, `expiresAt` | `GetTime()` seconds |
| `provisional` | `true` while the spell is still being cast (it's dropped if the cast fails) |

DoTs waiting for their first tick (when DoesItDie isn't sure they landed) aren't listed.

### `DoesItDie.RegisterCallback(owner, func)` / `DoesItDie.UnregisterCallback(owner)`

`func(event, unit)` runs when the remaining damage on `target`, `focus` or a `nameplateN` changes, or that unit now
shows another mob. `event` is `"DOTS_CHANGED"`. `owner` is any value identifying you (your addon's name, a frame);
registering again with the same owner replaces the function. Changes are checked every 0.1 seconds and on casts and
ticks. Errors in your function are caught and logged in DoesItDie's log; they don't stop other callbacks.

## Drawing it: the health is secret

Forever keeps the target's health secret: addon code can pass it to widgets but can't compare it or do math with it.
So you can't write `if damage >= UnitHealth(unit)`. Let a `StatusBar` do the comparison instead.

**Marker on the health bar.** A transparent `StatusBar` laid over your health bar, with the mob's max health as its
max and the remaining damage as its value. Its fill texture spans the damage, from the bar's left edge, on the same
scale as the health. Draw your marker over that fill. If the health ends inside it, the DoTs will kill the mob.

```lua
local marker = CreateFrame("StatusBar", nil, healthBar)
marker:SetAllPoints(healthBar) -- the bar must fill left to right and be exactly the fill area
marker:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
marker:SetStatusBarColor(1, 0.8, 0, 0.5)

local function update(unit)
    marker:SetMinMaxValues(0, UnitHealthMax(unit)) -- secret is fine here
    marker:SetValue((DoesItDie.GetRemainingDamage(unit)))
end
```

**Kill icon (show something only when lethal).** A long `StatusBar` (say 10,000 px) inside a small frame that clips
its children, anchored at the frame's right edge, with max = current health and value = remaining damage. Put the
icon at the end of the bar's fill. The fill only reaches the visible window when damage ≥ health, so the icon slides
into view exactly then.

```lua
local window = CreateFrame("Frame", nil, portrait)
window:SetSize(24, 24)
window:SetPoint("CENTER", portrait)
window:SetClipsChildren(true)

local bar = CreateFrame("StatusBar", nil, window)
bar:SetSize(10000, 24)
bar:SetPoint("RIGHT", window, "RIGHT")
bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
bar:SetStatusBarColor(0, 0, 0, 0)

local icon = bar:CreateTexture(nil, "OVERLAY")
icon:SetSize(24, 24)
icon:SetPoint("RIGHT", bar:GetStatusBarTexture(), "RIGHT")
icon:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")

local function update(unit)
    bar:SetMinMaxValues(0, UnitHealth(unit))
    bar:SetValue((DoesItDie.GetRemainingDamage(unit)))
end
```

DoesItDie's own `Display.lua` and `Nameplates.lua` are full examples, with smoothing, per-DoT segments and layering.
