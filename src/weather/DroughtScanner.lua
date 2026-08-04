-- =========================================================
-- FS25_WeatherGuard - DroughtScanner (WG-4)
-- =========================================================
-- Reads from the WeatherGuard instance (WG-2 getClimate,
-- WG-3 getEffectiveRain) to compute a drought outlook.
-- =========================================================

DroughtScanner = {}
local DroughtScanner_mt = Class(DroughtScanner)

local function clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

function DroughtScanner.new(wg)
    local self = setmetatable({}, DroughtScanner_mt)
    self._wg = wg
    return self
end

function DroughtScanner:scan()
    local wg = self._wg
    if wg == nil then
        return { isDrySpell = false, severity = 0, dryDays = 0, source = "forecast" }
    end

    local env = wg:_env()
    if env == nil then
        return { isDrySpell = false, severity = 0, dryDays = 0, source = "forecast" }
    end

    local season = env.currentSeason
    if season == nil then
        return { isDrySpell = false, severity = 0, dryDays = 0, source = "forecast" }
    end

    local climate = wg:getClimate(season)
    if climate == nil then
        return { isDrySpell = false, severity = 0, dryDays = 0, source = "forecast" }
    end

    local rainDayFraction = climate.rainDayFraction
    if rainDayFraction == nil or rainDayFraction <= 0 then
        return { isDrySpell = false, severity = 0, dryDays = 0, source = "forecast" }
    end

    local THRESHOLD_DAYS = clamp(math.floor(3 / rainDayFraction + 0.5), 6, 21)

    local dryDays = 0
    local source = "forecast"

    local horizon = wg:getForecastHorizonDays() or WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS
    local maxScan = horizon + 2

    for n = 0, maxScan do
        local ok, day = pcall(wg.getEffectiveRain, wg, n)
        if not ok or day == nil then
            break
        end
        if day.isRaining then
            break
        end
        if day.rainScale ~= nil and day.rainScale <= WeatherGuard.MIN_RAIN_THRESHOLD then
            dryDays = dryDays + 1
            if day.source == "climate" or day.source == "blend" then
                source = "blend"
            end
        else
            break
        end
    end

    local isDrySpell = false
    local severity = 0

    if dryDays >= THRESHOLD_DAYS then
        isDrySpell = true
        severity = clamp((dryDays - THRESHOLD_DAYS) / THRESHOLD_DAYS, 0, 1)
    end

    local isDraught = false
    local env2 = wg:_env()
    if env2 ~= nil then
        local day0 = env2.currentMonotonicDay
        if day0 ~= nil then
            local ok0, item0 = pcall(wg._forecastItemAt, wg, day0, 0)
            if ok0 and item0 ~= nil and item0.isDraught then
                isDraught = true
            end
        end
        local day1 = (env2.currentMonotonicDay or 0) + 1
        local ok1, item1 = pcall(wg._forecastItemAt, wg, day1, 0)
        if ok1 and item1 ~= nil and item1.isDraught then
            isDraught = true
        end
    end

    if isDraught and not isDrySpell then
        severity = 0.1
    end

    if isDraught and isDrySpell then
        severity = math.min(1.0, severity * 1.2)
    end

    return {
        isDrySpell = isDrySpell,
        severity = severity,
        dryDays = dryDays,
        source = source,
    }
end
