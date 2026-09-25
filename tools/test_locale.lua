-- Feeds every English and German description in tools/data/locale_cases.lua through the addon's real parser
-- (parseDot and the name-keyed tables, cut out of DoesItDie/DoesItDie.lua, with Locale.lua and the languages
-- loaded first) and checks total, school, duration, tick interval, ignore list and tick shape against the values
-- stated there. Also checks that every English description parses exactly as the v0.5.0 parser
-- (tools/data/upstream_parser_v0.5.0.lua) did, and that a second registered language is consulted too.
--
--     lua tools/test_locale.lua                      (any Lua 5.1+; WoW runs 5.1: python tools/test_locale.py)
--     lua tools/test_locale.lua path/to/DoesItDie.lua   (another copy of the addon, e.g. the unmodified one)

local root = TEST_ROOT or ((arg and arg[0] or ""):match("^(.*)[/\\]tools[/\\][^/\\]*$") or ".")
local source = TEST_SOURCE or (arg and arg[1]) or (root .. "/DoesItDie/DoesItDie.lua")
local loadString = loadstring or load

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return (text:gsub("\r\n", "\n"))
end

local function run(code, name, ...)
    return assert(loadString(code, "@" .. name))(...)
end

-- The addon: the files before DoesItDie.lua in the .toc (Locale.lua and the languages), then the parser chunks of
-- DoesItDie.lua (same cut as tools/test_parse.py).
local ns = {}
for line in readFile(root .. "/DoesItDie/DoesItDie.toc"):gmatch("[^\n]+") do
    local name = line:match("^%s*(.-%.lua)%s*$")
    if name == "DoesItDie.lua" then break end
    if name then run(readFile(root .. "/DoesItDie/" .. name), name, "DoesItDie", ns) end
end
local src = readFile(source)
local function chunk(startMarker, endMarker)
    local first = assert(src:find(startMarker, 1, true), startMarker)
    local last = assert(src:find(endMarker, first, true), endMarker)
    return src:sub(first, last - 1)
end
local addon = run(table.concat({
    "local ns = ...",
    "local function isSecret(v) return false end",
    chunk("local DEFAULT_TICK_INTERVAL", "local TICK_MATCH_WINDOW"),
    chunk("-- Tick intervals that differ", "-- User options"),
    chunk("local function schoolFromWords", "---------------------------------------------------------------------------\n-- DoT tracking"),
    "return { parseDot = parseDot, intervals = KNOWN_TICK_INTERVALS, shapes = TICK_SHAPES,",
    "    schools = SCHOOL_BY_NAME, ignored = IGNORED_SPELLS, defaultInterval = DEFAULT_TICK_INTERVAL,",
    "    nameTables = NAME_TABLES }",
}, "\n"), "DoesItDie.lua", ns)
local upstreamParse = run(readFile(root .. "/tools/data/upstream_parser_v0.5.0.lua"), "upstream_parser_v0.5.0.lua")
local cases = run(readFile(root .. "/tools/data/locale_cases.lua"), "locale_cases.lua")

local passed, failed, shown = 0, 0, 0
local failedByLang = { en = 0, de = 0, other = 0 }
local function check(case, what, actual, expected)
    if actual == expected then
        passed = passed + 1
        return
    end
    failed = failed + 1
    failedByLang[case.lang] = failedByLang[case.lang] + 1
    shown = shown + 1
    if shown <= 40 then
        print(string.format("FAIL  %s %s %s (%d): %s = %s, expected %s", case.lang, case.source, case.name, case.id,
            what, tostring(actual), tostring(expected)))
    end
end

-- What the addon would track for this cast: onPlayerCast's use of parseDot and the name tables.
local function track(case, comboPoints)
    local total, school, duration, stated = addon.parseDot(case.desc, comboPoints)
    if not total then return nil end
    return {
        total = total,
        school = addon.schools[case.name] or school,
        duration = duration,
        interval = stated or addon.intervals[case.name] or addon.defaultInterval,
    }
end

local function checkReading(case, label, got, want)
    if not want then
        check(case, label .. " parsed", got and "a DoT" or "nothing", "nothing")
    elseif not got then
        check(case, label .. " parsed", "nothing", "a DoT")
    else
        for _, field in ipairs({ "total", "school", "duration", "interval" }) do
            check(case, label .. " " .. field, got[field], want[field])
        end
    end
end

local counts = { en = 0, de = 0 }
for _, case in ipairs(cases) do
    counts[case.lang] = counts[case.lang] + 1
    if case.fin then
        for points = 1, 5 do
            local want = case.fin[points]
            local got = track(case, points)
            check(case, points .. " points parsed", got ~= nil, true)
            if got then
                check(case, points .. " points total", got.total, want[1])
                check(case, points .. " points duration", got.duration, want[2])
                check(case, points .. " points school", got.school, 1)
                check(case, points .. " points interval", got.interval, case.interval)
            end
        end
    else
        checkReading(case, "", track(case), case.expect)
    end
    check(case, "ignored", addon.ignored[case.name] == true, case.ignored)
    check(case, "tick shape", addon.shapes[case.name] ~= nil, case.shaped)
    if case.lang == "de" then
        check(case, "finisher", ns.locale.isFinisher(case.desc), case.finisher)
        check(case, "combo points awarded", ns.locale.comboPointsAwarded(case.desc) or false, case.awarded)
    else
        -- English must read exactly as before, for every combo point count.
        for points = 0, 5 do
            local before = { upstreamParse(case.desc, points > 0 and points or nil) }
            local now = { addon.parseDot(case.desc, points > 0 and points or nil) }
            for i = 1, 4 do
                check(case, "same as v0.5.0 (" .. points .. " points, value " .. i .. ")", now[i], before[i])
            end
        end
    end
end

-- Names the client reports for the spell IDs (here: made-up French ones) join the tables too, and never replace
-- an entry that is already there.
if addon.nameTables then
    local french = { [5570] = "Essaim d'insectes", [980] = "Malédiction d'agonie", [1943] = "Rupture", [10] = "Blizzard" }
    local added = ns.locale.addClientNames(addon.nameTables, function(id) return french[id] end)
    local case = { lang = "en", source = "stub", name = "client names", id = 0 }
    check(case, "Essaim d'insectes interval", addon.intervals["Essaim d'insectes"], 2)
    check(case, "Malédiction d'agonie shape", addon.shapes["Malédiction d'agonie"] ~= nil, true)
    check(case, "names added", #added, 2)
else
    failed, failedByLang.de = failed + 1, failedByLang.de + 1
    print("FAIL  no NAME_TABLES in " .. source)
end

-- German buffs and debuffs whose duration stands before direct damage aren't DoTs (Classic Era deDE, Wowhead).
-- Their English text isn't read either.
for _, case in ipairs({
    { lang = "de", source = "wowhead", name = "Donnerknall", id = 11581,
      desc = "Dröhnt in der Nähe befindliche Feinde mit Donner zu, erhöht die Zeit zwischen ihren Angriffen 30 Sek. lang um 10% und fügt ihnen 103 Schaden zu. Wirkt auf maximal 4 Ziele." },
    { lang = "de", source = "wowhead", name = "Heiliger Schild", id = 20928,
      desc = "Erhöht die Blockchance 10 Sek. lang um 30% und verursacht, solange aktiv, mit jedem geblockten Angriff 130 Heiligschaden. Durch 'Heiliger Schild' verursachter Schaden verursacht 20% zusätzliche Bedrohung. Jedes Blocken verbraucht eine Aufladung. 4 Aufladungen." },
}) do
    checkReading(case, "", track(case), nil)
end

-- Unread descriptions are logged by their text, not by GetLocale(): Forever answers enUS with German text.
-- English ones never are (Fireball isn't a DoT and shouldn't fill the log), every German one is, once per spell.
local logId = 0
for _, locale in ipairs({ "enUS", "deDE" }) do
    GetLocale = function() return locale end
    for _, case in ipairs(cases) do
        logId = logId + 1
        check(case, "logged if unread (GetLocale " .. locale .. ")", ns.locale.shouldLogUnread(logId, case.desc),
            case.lang ~= "en")
        if case.lang ~= "en" then
            check(case, "logged only once", ns.locale.shouldLogUnread(logId, case.desc), false)
        end
    end
end
GetLocale = nil

-- The registry isn't bound to German: a second language registered after it is consulted too, for descriptions,
-- finishers, combo points and names, and German still reads its own text.
ns.locale.register({
    tag = "xxXX",
    parseDot = function(desc)
        local total, secs = desc:match("^Zorg (%d+) blub (%d+)$")
        if total then return tonumber(total), 4, tonumber(secs) end
    end,
    isFinisher = function(desc) return desc:find("^Zorgfinish") ~= nil end,
    comboPointsAwarded = function(desc) return tonumber(desc:match("Zorgpunkt (%d+)")) end,
    names = { ["Insect Swarm"] = { "Zwarm" }, ["Mind Flay"] = { "Zinnschinden" } },
})
do
    local case = { lang = "other", source = "stub", name = "second language", id = 0 }
    local total, school, duration = addon.parseDot("Zorg 50 blub 10")
    check(case, "total", total, 50)
    check(case, "school", school, 4)
    check(case, "duration", duration, 10)
    check(case, "German still read", (addon.parseDot("verursacht 12 Sek. lang 40 Punkt(e) Schattenschaden.")), 40)
    check(case, "English still read", (addon.parseDot("causing 72 Shadow damage over 24 sec.")), 72)
    check(case, "finisher", ns.locale.isFinisher("Zorgfinish 3"), true)
    check(case, "not a finisher", ns.locale.isFinisher("Zorg 50 blub 10"), false)
    check(case, "combo points awarded", ns.locale.comboPointsAwarded("Zorgpunkt 2"), 2)
    check(case, "German combo points", ns.locale.comboPointsAwarded("Gewährt 1 Combopunkt."), 1)
    ns.locale.addNames(addon.nameTables)
    check(case, "Zwarm interval", addon.intervals["Zwarm"], 2)
    check(case, "Zinnschinden ignored", addon.ignored["Zinnschinden"], true)
    check(case, "unread text logged", ns.locale.shouldLogUnread(-1, "Zorg ohne Zahlen"), true)
end

if shown > 40 then print(string.format("... and %d more failures", shown - 40)) end
print(string.format("%d English and %d German descriptions from %s", counts.en, counts.de, source))
print(string.format("%d checks passed, %d failed (English %d, German %d, registry %d)", passed, failed,
    failedByLang.en, failedByLang.de, failedByLang.other))
if TEST_NO_EXIT then return failed end
os.exit(failed == 0 and 0 or 1)
