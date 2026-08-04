-- WG-4-getDroughtOutlook-isDrySpell_spec_test.lua
--
-- Spec test for DroughtScanner (WG-4). Exercises the drought outlook
-- algorithm against a controlled mock WeatherGuard instance.
--
-- Run:  node tools/test/run-tests.mjs
-- (after copying to tools/test/lua/ and adding --!load above)

--!load: src/weather/DroughtScanner.lua

-- WeatherGuard constants
WeatherGuard = WeatherGuard or {}
WeatherGuard.MIN_RAIN_THRESHOLD = 0.1
WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS = 9
WeatherGuard.CLIMATE = {}
WeatherGuard.SEASON_TEMP = {}
WeatherGuard.MODE_NORMAL = 3

-- ── Mock builder ────────────────────────────────────────
-- config fields:
--   season (number, default 1)
--   today (number, default 100)
--   climate (table, default Normal spring { rainDayFraction = 0.40, ... })
--   horizon (number, default 9)
--   days (table keyed by daysAhead, each value a getEffectiveRain result)
--   draughtItems (table of startDay values that have isDraught = true)
local function makeMockWg(config)
    config = config or {}
    local env = {
        currentSeason       = config.season or 1,
        currentMonotonicDay = config.today or 100,
        dayTime             = 0,
    }
    local days = config.days or {}
    local draughtSet = {}
    if config.draughtItems then
        for _, d in ipairs(config.draughtItems) do
            draughtSet[d] = true
        end
    end

    local mock = {}

    function mock:_env()
        return env
    end

    function mock:getClimate(_season)
        if config.climate then return config.climate end
        return { rainDayFraction = 0.40, intensity = 0.55, meanTemp = 12, biasDefaulted = false }
    end

    function mock:getEffectiveRain(n)
        local r = days[n]
        if r ~= nil then return r end
        return { rainScale = 0, isRaining = false, source = "real", rainWasFilled = false }
    end

    function mock:getForecastHorizonDays()
        return config.horizon or 9
    end

    function mock:_forecastItemAt(day, _dayTime)
        if draughtSet[day] then
            return { isDraught = true }
        end
        return nil
    end

    return mock
end

-- ── Helpers ─────────────────────────────────────────────
local function dry(scale, src)
    return { rainScale = scale or 0, isRaining = false, source = src or "real", rainWasFilled = false }
end

local function wet(scale, src)
    return { rainScale = scale or 0.5, isRaining = true, source = src or "real", rainWasFilled = false }
end

local function makeDays(...)
    local t = {}
    for i, v in ipairs({ ... }) do
        t[i - 1] = v
    end
    return t
end

-- ══════════════════════════════════════════════════════════
-- 1. No dry days
-- ══════════════════════════════════════════════════════════
do
    local wg = makeMockWg({
        days = makeDays(wet(0.5)),
        climate = { rainDayFraction = 0.40 },
    })
    local scanner = DroughtScanner(wg)
    local r = scanner:scan()
    T.ok("1a: returns a table", type(r) == "table")
    T.eq("1b: isDrySpell is false with no dry days", r.isDrySpell, false)
    T.eq("1c: dryDays is 0", r.dryDays, 0)
    T.eq("1d: severity is 0", r.severity, 0)
    T.eq("1e: source is forecast", r.source, "forecast")
end

-- ══════════════════════════════════════════════════════════
-- 2. Below threshold dry days
--    Normal spring: rainDayFraction = 0.40 -> THRESHOLD_DAYS = 8
--    3 dry days then rain -> < threshold
-- ══════════════════════════════════════════════════════════
do
    local wg = makeMockWg({
        days = makeDays(dry(0), dry(0), dry(0), wet(0.5)),
        climate = { rainDayFraction = 0.40 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("2a: dryDays is 3 below threshold", r.dryDays, 3)
    T.eq("2b: isDrySpell is false", r.isDrySpell, false)
    T.eq("2c: severity is 0", r.severity, 0)
end

-- ══════════════════════════════════════════════════════════
-- 3. At-threshold dry days
--    Arid spring: rainDayFraction = 0.20 -> THRESHOLD_DAYS = 15
--    15 dry days then rain -> at threshold -> severity = 0
-- ══════════════════════════════════════════════════════════
do
    local days = {}
    for n = 0, 14 do days[n] = dry(0) end
    days[15] = wet(0.5)
    local wg = makeMockWg({
        days = days,
        climate = { rainDayFraction = 0.20 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("3a: dryDays is 15 at threshold", r.dryDays, 15)
    T.eq("3b: isDrySpell is true", r.isDrySpell, true)
    T.near("3c: severity is 0 at threshold", r.severity, 0)
end

-- ══════════════════════════════════════════════════════════
-- 4. Above threshold
--    Arid spring: THRESHOLD_DAYS = 15, 20 dry days
--    severity = clamp((20-15)/15, 0, 1) = 0.3333...
-- ══════════════════════════════════════════════════════════
do
    local days = {}
    for n = 0, 19 do days[n] = dry(0) end
    days[20] = wet(0.5)
    local wg = makeMockWg({
        days = days,
        climate = { rainDayFraction = 0.20 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("4a: dryDays is 20 above threshold", r.dryDays, 20)
    T.eq("4b: isDrySpell is true", r.isDrySpell, true)
    T.near("4c: severity = (20-15)/15", r.severity, 5/15)
end

-- ══════════════════════════════════════════════════════════
-- 5. Engine-only isDraught (below threshold)
--    Normal spring: THRESHOLD_DAYS = 8, 5 dry days
--    isDraught = true on day 0 -> severity = 0.1 (minimum)
-- ══════════════════════════════════════════════════════════
do
    local wg = makeMockWg({
        days = makeDays(dry(0), dry(0), dry(0), dry(0), dry(0), wet(0.5)),
        climate = { rainDayFraction = 0.40 },
        draughtItems = { 100 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("5a: isDrySpell is false (below threshold)", r.isDrySpell, false)
    T.near("5b: severity is minimum 0.1 for engine-only draught", r.severity, 0.1)
    T.eq("5c: dryDays is 5", r.dryDays, 5)
end

-- ══════════════════════════════════════════════════════════
-- 6. Both-agree boost (isDraught + above threshold)
--    Arid spring: THRESHOLD_DAYS = 15, 20 dry days
--    severity = min(1.0, 0.3333 * 1.2) = 0.4
-- ══════════════════════════════════════════════════════════
do
    local days = {}
    for n = 0, 19 do days[n] = dry(0) end
    days[20] = wet(0.5)
    local wg = makeMockWg({
        days = days,
        climate = { rainDayFraction = 0.20 },
        draughtItems = { 100 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("6a: isDrySpell is true", r.isDrySpell, true)
    T.near("6b: severity after 1.2 boost", r.severity, math.min(1.0, (5/15) * 1.2))
end

-- ══════════════════════════════════════════════════════════
-- 7. Source label mapping
--    7a: All dry days from "real" -> source = "forecast"
--    7b: Some dry days from "climate" -> source = "blend"
-- ══════════════════════════════════════════════════════════
do
    local wg = makeMockWg({
        days = makeDays(dry(0, "real"), dry(0, "real"), dry(0, "real"), wet(0.5)),
        climate = { rainDayFraction = 0.40 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("7a: all real dry days -> source forecast", r.source, "forecast")
end

do
    local wg = makeMockWg({
        days = makeDays(dry(0, "real"), dry(0, "climate"), dry(0, "real"), wet(0.5)),
        climate = { rainDayFraction = 0.40 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("7b: a climate dry day -> source blend", r.source, "blend")
end

do
    local wg = makeMockWg({
        days = makeDays(dry(0, "blend"), dry(0, "real"), dry(0, "real"), wet(0.5)),
        climate = { rainDayFraction = 0.40 },
    })
    local r = DroughtScanner(wg):scan()
    T.eq("7c: a blend dry day -> source blend", r.source, "blend")
end

-- ══════════════════════════════════════════════════════════
-- 8. Neutral when absent (no env)
-- ══════════════════════════════════════════════════════════
do
    local mock = {}
    function mock:_env() return nil end
    function mock:getClimate(_s) return nil end
    function mock:getEffectiveRain(_n) return nil end
    function mock:getForecastHorizonDays() return nil end
    function mock:_forecastItemAt(_d, _t) return nil end

    local r = DroughtScanner(mock):scan()
    T.ok("8a: absent env returns a table", type(r) == "table")
    T.eq("8b: isDrySpell is false", r.isDrySpell, false)
    T.eq("8c: severity is 0", r.severity, 0)
    T.eq("8d: dryDays is 0", r.dryDays, 0)
end

-- ══════════════════════════════════════════════════════════
-- 9. isDraught is OR-gated across day 0 and day 1
--    9a: isDraught on day 1 (startDay = 101) triggers engine-only
-- ══════════════════════════════════════════════════════════
do
    local wg = makeMockWg({
        days = makeDays(dry(0), dry(0), dry(0), dry(0), dry(0), wet(0.5)),
        climate = { rainDayFraction = 0.40 },
        draughtItems = { 101 },
        today = 100,
    })
    local r = DroughtScanner(wg):scan()
    T.eq("9a: isDrySpell is false (below threshold)", r.isDrySpell, false)
    T.near("9b: day 1 isDraught triggers severity 0.1", r.severity, 0.1)
end

-- ══════════════════════════════════════════════════════════
-- 10. nil WeatherGuard instance -> neutral return
-- ══════════════════════════════════════════════════════════
do
    local r = DroughtScanner(nil):scan()
    T.ok("10a: nil wg returns a table", type(r) == "table")
    T.eq("10b: isDrySpell is false", r.isDrySpell, false)
end

-- ══════════════════════════════════════════════════════════
-- 11. maxScan: stops at horizon + 2
--     Normal spring: THRESHOLD_DAYS = 8
--     horizon = 3, so maxScan = 5
--     Days 0-5 all dry, day 6 is rainy but should not be scanned
-- ══════════════════════════════════════════════════════════
do
    local days = {}
    for n = 0, 5 do days[n] = dry(0) end
    days[6] = wet(0.5)
    local wg = makeMockWg({
        days = days,
        climate = { rainDayFraction = 0.40 },
        horizon = 3,
    })
    local r = DroughtScanner(wg):scan()
    T.eq("11a: scans up to horizon+2 (6 days)", r.dryDays, 6)
    T.eq("11b: isDrySpell is false (6 < 8)", r.isDrySpell, false)
end
