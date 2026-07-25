-- =========================================================
-- FS25_WeatherGuard - core class (the shared sky)
-- =========================================================
-- Author: TisonK
-- =========================================================
-- The 6th core service. Six mods in the suite each read the sky privately and
-- disagree with each other; WeatherGuard hands them ONE weather truth to read.
--
-- THE ONE LAW (the fence, mirrored from Time Guard's money fence):
--   WeatherGuard publishes TRUTH, never CONSEQUENCE.
--   It reads and republishes the sky. It NEVER writes a consumer's state and
--   NEVER applies an effect. Every consumer keeps its own leach, premium,
--   price and stress logic. Time Guard never calls addMoney; this class never
--   touches a field, a crop, a price or a wallet.
--
-- Every engine read below is certified against shipping source, not inferred.
-- The base Weather / WeatherForecast / Environment classes are WITHHELD from
-- the SDK dump, the Community LUADOC and FS25-lua-scripting, so the certifying
-- sources are the two mods that read them in shipping code:
--   RW  = Arrow-kb/FS25_RealisticWeather, cloned at ../RealisticWeather-reference.
--         It REIMPLEMENTS and overwrites the withheld classes, so anything it
--         USES but never DEFINES across its 42 source files is base game.
--   WFH = FS25_WeatherForecastHUD, which declares NO dependencies at all and so
--         runs against base-game methods with no RealisticWeather in the picture.
--
-- DELIVERY DISCIPLINE (two Time Guard scars):
--   1. Publish the REAL surface. Nothing is advertised here that is not built
--      and certified. getClimate / getEffectiveRain / getDroughtOutlook are
--      deliberately ABSENT until their own feature ships, so a consumer falls
--      back rather than trusting a stub.
--   2. NO SILENT DEFAULT on a load-bearing value. An unreadable field returns
--      nil and warns once; it never quietly reads as "dry" or "calm". The one
--      ruled exception is humidity's 0.5 floor, which is flagged in the return
--      as humidityDefaulted.
-- =========================================================

WeatherGuard = {}
local WeatherGuard_mt = Class(WeatherGuard)

local DAY_MS = 24 * 60 * 60 * 1000   -- 86,400,000 ms (RW Weather.lua:122 uses the literal)

WeatherGuard.SAVE_FILE   = "RealisticFarming_WeatherGuard.xml"   -- own-file fallback
WeatherGuard.MODULE_ID   = "FS25_WeatherGuard"                    -- id in StateLedger/NetworkSync/SettingsHub
WeatherGuard.ACTION_MODE = "WeatherGuard_SetMode"                 -- NetworkSync server-authoritative action

-- The weather-mode dial (RULED 2026-07-24). ONE setting, not two: picking a
-- climate means the real sky LEADS and the grounded climate fills only the gaps
-- (short months, past the forecast, no RealisticWeather). There is deliberately
-- NO "grounded only" position, because it would make the visible weather lie.
-- The climate model (a later feature) reads its bias from this same dial.
WeatherGuard.MODE_REAL    = 1   -- real weather only; opt out of the grounded climate
WeatherGuard.MODE_ARID    = 2
WeatherGuard.MODE_NORMAL  = 3   -- default
WeatherGuard.MODE_WET     = 4
WeatherGuard.MODE_MIN     = 1
WeatherGuard.MODE_MAX     = 4
WeatherGuard.MODE_DEFAULT = WeatherGuard.MODE_NORMAL

-- The native forecast horizon, confirmed twice from opposite directions:
--   source      - RW's fill loop is `lastItem.startDay < currentMonotonicDay + 9`
--                 (RealisticWeather Weather.lua:344)
--   measurement - 9.29 to 9.71 days across four savegames carrying 26-36 mods
--                 and NO RealisticWeather (environment.xml <weather><forecast>)
-- RealisticWeather does NOT deepen the horizon; this is what the base game fills.
-- Used only as the fallback when the live array cannot be measured.
WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS = 9

function WeatherGuard.new()
    local self = setmetatable({}, WeatherGuard_mt)

    self.weatherMode   = WeatherGuard.MODE_DEFAULT
    self.modeRestored  = false   -- true once a persisted mode has been applied

    -- Core-service state.
    self.bedrockBound  = false
    self.ledgerRestored = false

    return self
end

-- =========================================================
-- Engine handles (every read goes through these; nil-safe)
-- =========================================================

function WeatherGuard:_env()
    return g_currentMission ~= nil and g_currentMission.environment or nil
end

function WeatherGuard:_weather()
    local env = self:_env()
    return env ~= nil and env.weather or nil
end

-- Call obj:method(...) only if it really exists, and never let an engine read
-- throw into a consumer's frame. Returns nil on absence or on error.
local function tryCall(obj, methodName, ...)
    if type(obj) ~= "table" and type(obj) ~= "userdata" then
        return nil
    end
    local fn = obj[methodName]
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(fn, obj, ...)
    if not ok then
        return nil
    end
    return a, b
end

-- =========================================================
-- Lifecycle
-- =========================================================

function WeatherGuard:onMissionLoaded()
    self:_bindBedrock()

    -- Own-file fallback: only when StateLedger is absent (else it delivers the
    -- mode through the registered deserialize callback).
    if self:_getLedger() == nil then
        self:_loadOwnFile()
    end

    local sky = self:getCurrentSky()
    WGLogger.info("Weather Guard active: mode=%d (%s), forecast horizon=%s day(s), RealisticWeather=%s",
        self.weatherMode, self:getWeatherModeName(),
        tostring(self:getForecastHorizonDays() or "unmeasured"),
        tostring(self:isRealisticWeatherActive()))
    if sky == nil then
        WGLogger.warning("No environment at load; the sky getters stay neutral until one exists")
    end
end

function WeatherGuard:update(dt)
    -- Nothing is polled: every getter reads the engine live at call time. update
    -- only retries a deferred bedrock bind (a core service may finish loading
    -- after us).
    if not self.bedrockBound then
        self:_bindBedrock()
    end
end

function WeatherGuard:onMissionDelete()
    self.bedrockBound   = false
    self.ledgerRestored = false
end

function WeatherGuard:save()
    -- StateLedger, when present, persists the mode through its own save. Only
    -- write the own-file fallback when StateLedger is absent.
    if self:_getLedger() ~= nil then
        return
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    self:_saveOwnFile()
end

-- =========================================================
-- PUBLISHED READ-CONTRACT
-- =========================================================

--- The sky right now.
---@return table|nil { rainScale, isRaining, cloudCoverage, temperature, humidity,
---                    weatherType, weatherTypeId, humidityDefaulted }
--- nil when there is no environment at all. Individual fields are nil when the
--- engine cannot be read for them (never a quiet zero).
function WeatherGuard:getCurrentSky()
    local env     = self:_env()
    local weather = self:_weather()
    if env == nil or weather == nil then
        return nil
    end

    -- rainScale: certified. RW calls weather:getRainFallScale() in six places
    -- and defines it nowhere (Weather.lua:46,92,110,123,165 + AmbientSoundSystem:8).
    -- Already RealisticWeather-shaped when RW is present, because RW reimplements
    -- the class this method lives on.
    local rainScale = tryCall(weather, "getRainFallScale")
    if rainScale == nil then
        WGLogger.warnOnce("rainScale", "getCurrentSky: weather:getRainFallScale() unreadable; rainScale reports nil")
    end

    -- isRaining: certified (RW Weather.lua:52,110). Derived from rainScale only
    -- if the method itself is missing, and only then.
    local isRaining = tryCall(weather, "getIsRaining")
    if isRaining == nil and type(rainScale) == "number" then
        isRaining = rainScale > 0
    end

    local humidity, humidityDefaulted = self:_humidity()

    local weatherType, weatherTypeId = self:_currentWeatherType()

    return {
        rainScale        = rainScale,
        isRaining        = isRaining,
        cloudCoverage    = self:_cloudCoverage(),
        temperature      = self:_currentTemperature(),
        humidity         = humidity,
        humidityDefaulted = humidityDefaulted,
        weatherType      = weatherType,    -- lowercase category name, e.g. "rain"
        weatherTypeId    = weatherTypeId,  -- the raw WeatherType enum value
    }
end

--- Forward rain intensity, sampled at the current time of day.
---@param daysAhead number  0 = now. Fractional days are floored to whole days.
---@return number|nil  rain intensity, or nil past the filled horizon (the honest edge)
function WeatherGuard:getForecastRain(daysAhead)
    local env     = self:_env()
    local weather = self:_weather()
    if env == nil or weather == nil then
        return nil
    end
    daysAhead = tonumber(daysAhead) or 0
    if daysAhead < 0 then
        return nil
    end

    local day     = (env.currentMonotonicDay or 0) + math.floor(daysAhead)
    local dayTime = env.dayTime or 0

    local item = self:_forecastItemAt(day, dayTime)
    if item == nil then
        return nil   -- past the horizon, or a gap in the fill
    end
    return self:_rainScaleOfItem(item)
end

--- Forward temperature.
---@param daysAhead number  0 = now.
---@return number|nil  temperature, or nil past the filled horizon
function WeatherGuard:getForecastTemperature(daysAhead)
    local weather = self:_weather()
    if weather == nil then
        return nil
    end
    daysAhead = tonumber(daysAhead) or 0
    if daysAhead < 0 then
        return nil
    end

    local horizon = self:getForecastHorizonDays()
    if horizon ~= nil and daysAhead > horizon then
        return nil
    end

    -- certified: RW reads forecast:getHourlyForecast(hour).temperature
    -- (GameInfoDisplay.lua:163-164, 197-199) and defines no WeatherForecast class.
    -- The argument is an offset in hours FROM NOW: RW derives it from
    -- math.floor(minutesLeft / 60), minutes remaining rather than a clock hour.
    local forecast = weather.forecast
    if forecast == nil or type(forecast.getHourlyForecast) ~= "function" then
        WGLogger.warnOnce("hourlyForecast",
            "getForecastTemperature: weather.forecast:getHourlyForecast is absent; forward temperature reports nil")
        return nil
    end

    local ok, hourly = pcall(forecast.getHourlyForecast, forecast, math.floor(daysAhead * 24))
    if not ok or type(hourly) ~= "table" or type(hourly.temperature) ~= "number" then
        return nil
    end
    return hourly.temperature
end

--- The active weather-mode dial.
---@return number 1 Real weather only | 2 Arid | 3 Normal | 4 Wet
function WeatherGuard:getWeatherMode()
    return self.weatherMode
end

--- The Time Guard getContext analog.
---@return table { currentSky, mode, modeName, forecastHorizonDays,
---                forecastHorizonMeasured, rwEnriching }
function WeatherGuard:getContext()
    local measured = self:getForecastHorizonDays()
    return {
        currentSky              = self:getCurrentSky(),
        mode                    = self.weatherMode,
        modeName                = self:getWeatherModeName(),
        forecastHorizonDays     = measured or WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS,
        forecastHorizonMeasured = measured ~= nil,
        rwEnriching             = self:isRealisticWeatherActive(),
    }
end

-- =========================================================
-- Supporting reads (public; each certified, each nil-honest)
-- =========================================================

--- How many days ahead the forecast is actually filled right now.
---@return number|nil  measured from the live array; nil when it cannot be measured
function WeatherGuard:getForecastHorizonDays()
    local env     = self:_env()
    local weather = self:_weather()
    if env == nil or weather == nil then
        return nil
    end
    local items = weather.forecastItems
    if type(items) ~= "table" or #items == 0 then
        return nil
    end
    local last = items[#items]
    if type(last) ~= "table" or type(last.startDay) ~= "number" then
        return nil
    end
    local horizon = last.startDay - (env.currentMonotonicDay or 0)
    if horizon < 0 then
        return nil
    end
    return horizon
end

--- Is RealisticWeather running (so the sky is its reimplementation, not stock)?
--- Note it does NOT deepen the forecast horizon; see NATIVE_FORECAST_HORIZON_DAYS.
function WeatherGuard:isRealisticWeatherActive()
    -- g_modIsLoaded is the reliable route. A bare global published by another
    -- mod is not visible from this mod's environment, so a getfenv probe alone
    -- gives false negatives (the known SeasonalCropStress detection bug).
    if type(g_modIsLoaded) == "table" then
        if g_modIsLoaded["FS25_RealisticWeather"] then
            return true
        end
        for name, loaded in pairs(g_modIsLoaded) do
            if loaded and type(name) == "string" and string.find(name, "RealisticWeather", 1, true) ~= nil then
                return true
            end
        end
    end
    -- Last resort for a same-environment load order.
    return getfenv(0)["g_realisticWeather"] ~= nil
end

function WeatherGuard:getWeatherModeName()
    local mode = self.weatherMode
    if mode == WeatherGuard.MODE_REAL   then return "real"   end
    if mode == WeatherGuard.MODE_ARID   then return "arid"   end
    if mode == WeatherGuard.MODE_NORMAL then return "normal" end
    if mode == WeatherGuard.MODE_WET    then return "wet"    end
    return "unknown"
end

-- =========================================================
-- Internal engine reads
-- =========================================================

function WeatherGuard:_cloudCoverage()
    -- Two shipping consumers read it off the ENVIRONMENT
    -- (SeasonalCropStress WeatherIntegration.lua:398-400, FarmTablet
    -- DataProvider.lua:388-389), while RW reads self.cloudUpdater from inside
    -- Weather (Weather.lua:86). Try the environment first, then the weather.
    local env = self:_env()
    local v = tryCall(env ~= nil and env.cloudUpdater or nil, "getCloudCoverage")
    if v ~= nil then
        return v
    end
    local weather = self:_weather()
    v = tryCall(weather ~= nil and weather.cloudUpdater or nil, "getCloudCoverage")
    if v == nil then
        WGLogger.warnOnce("cloudCoverage",
            "getCurrentSky: cloudUpdater:getCloudCoverage() unreadable on environment or weather; cloudCoverage reports nil")
    end
    return v
end

function WeatherGuard:_currentTemperature()
    -- certified: weather.temperatureUpdater:getTemperatureAtTime(environment.dayTime)
    -- (RW Weather.lua:95,193 + FireSystem.lua:242 + GameInfoDisplay.lua:101)
    local env     = self:_env()
    local weather = self:_weather()
    if env == nil or weather == nil then
        return nil
    end
    local v = tryCall(weather.temperatureUpdater, "getTemperatureAtTime", env.dayTime or 0)
    if v == nil then
        WGLogger.warnOnce("temperature",
            "getCurrentSky: weather.temperatureUpdater:getTemperatureAtTime() unreadable; temperature reports nil")
    end
    return v
end

--- Centralizes the multi-field humidity probe SeasonalCropStress carries today
--- (WeatherIntegration.lua:197-235) so every consumer stops re-deriving it.
---@return number humidity, boolean defaulted
function WeatherGuard:_humidity()
    -- RealisticWeather's own reading first, when it is running.
    if self:isRealisticWeatherActive() then
        local rw = getfenv(0)["g_realisticWeather"] or getfenv(0)["g_weatherSystem"]
        if rw ~= nil then
            local v = tryCall(rw, "getHumidity")
            if v == nil then v = rw.humidity end
            if v == nil then v = rw.relativeHumidity end
            if type(v) == "number" then
                return v, false
            end
        end
    end

    local env = self:_env()
    if env ~= nil then
        local ws = env.weatherSystem
        if ws ~= nil then
            local v = tryCall(ws, "getHumidity")
            if v == nil then v = ws.relativeHumidity end
            if v == nil then v = ws.humidity end
            if type(v) == "number" then
                return v, false
            end
        end
        local weather = env.weather
        if weather ~= nil and type(weather.relativeHumidity) == "number" then
            return weather.relativeHumidity, false
        end
    end

    -- The one RULED default in the contract. Flagged rather than silent, so a
    -- consumer can tell "half humid" from "we could not read it".
    WGLogger.warnOnce("humidity",
        "getCurrentSky: no humidity source readable; reporting the ruled 0.5 floor with humidityDefaulted=true")
    return 0.5, true
end

--- Order two calendar points. Deliberately compares (day, time) as a PAIR rather
--- than collapsing to absolute milliseconds: day * 86,400,000 runs into the tens
--- of billions on a long save, and there is no reason to carry a magnitude that
--- large through a comparison that only needs an ordering.
---@return number -1 if A is earlier, 0 if equal, 1 if A is later
local function cmpDayTime(dayA, timeA, dayB, timeB)
    if dayA ~= dayB then
        return dayA < dayB and -1 or 1
    end
    if timeA == timeB then
        return 0
    end
    return timeA < timeB and -1 or 1
end

--- The day/time a forecast instance ends, with the past-midnight rollover
--- normalized the way the engine's own consumers do it (RW GameInfoDisplay.lua
--- :122-125 adds a day and subtracts 86,400,000).
local function itemEnd(item)
    local duration = type(item.duration) == "number" and item.duration or 0
    local raw = item.startDayTime + duration
    return item.startDay + math.floor(raw / DAY_MS), raw % DAY_MS
end

--- The forecast instance covering an absolute (day, dayTime), or nil past the
--- filled horizon. Two routes, because FS25_WeatherForecastHUD's own comment
--- warns forecastItems can be unavailable ON SOME MAPS.
---@return table|nil instance, string|nil route
function WeatherGuard:_forecastItemAt(day, dayTime)
    local weather = self:_weather()
    if weather == nil then
        return nil
    end

    -- Route A: the forecastItems array. Two independent sources agree on its
    -- shape: the live array RW walks (Weather.lua:24-41, fields startDay /
    -- startDayTime / duration / season / objectIndex) and the savegame
    -- environment.xml <weather><forecast> instances, where objectIndex persists
    -- as variationIndex. Items are in ascending start order.
    local items = weather.forecastItems
    if type(items) == "table" then
        for _, it in ipairs(items) do
            if type(it) == "table" and type(it.startDay) == "number"
                and type(it.startDayTime) == "number" then
                if cmpDayTime(it.startDay, it.startDayTime, day, dayTime) > 0 then
                    break   -- ascending: nothing later can cover an earlier target
                end
                local endDay, endTime = itemEnd(it)
                if cmpDayTime(day, dayTime, endDay, endTime) < 0 then
                    return it, "forecastItems"
                end
            end
        end
    end

    -- Route B: forecast:dataForTime(day, time). Base game by the same absence
    -- test: RW calls it (Weather.lua:70, GameInfoDisplay.lua:107,127) and ships
    -- no WeatherForecast class of its own. It returns (_, instance).
    local forecast = weather.forecast
    if forecast ~= nil and type(forecast.dataForTime) == "function" then
        local ok, _, instance = pcall(forecast.dataForTime, forecast, day, dayTime)
        if ok and type(instance) == "table" then
            return instance, "dataForTime"
        end
    end

    return nil
end

--- Rain intensity carried by one forecast instance.
function WeatherGuard:_rainScaleOfItem(item)
    local weather = self:_weather()
    if weather == nil or type(item) ~= "table" then
        return nil
    end

    -- Path 1: the per-instance variation. RW reads variation.rain.snowfallScale
    -- off exactly this call (GameInfoDisplay.lua:147+166); rainfallScale is its
    -- sibling on the same rain table.
    local variation = tryCall(weather, "getForecastInstanceVariation", item)
    if type(variation) == "table" and type(variation.rain) == "table"
        and type(variation.rain.rainfallScale) == "number" then
        return variation.rain.rainfallScale
    end

    -- Path 2: the weather object's own rain updater. RW WRITES
    -- object.rainUpdater.rainfallScale when it forces a drought
    -- (Weather.lua:378), so the field is certain to exist on the object.
    if type(item.season) == "number" and type(item.objectIndex) == "number" then
        local obj = tryCall(weather, "getWeatherObjectByIndex", item.season, item.objectIndex)
        if type(obj) == "table" and type(obj.rainUpdater) == "table"
            and type(obj.rainUpdater.rainfallScale) == "number" then
            return obj.rainUpdater.rainfallScale
        end
    end

    WGLogger.warnOnce("forecastRainShape",
        "getForecastRain: neither variation.rain.rainfallScale nor weatherObject.rainUpdater.rainfallScale is readable; forward rain reports nil")
    return nil
end

--- The current weather CATEGORY, which a rain scalar cannot give you. This is
--- what NPCFavor needs: its weather.currentWeather read is a confirmed no-op
--- (that field appears in zero of the 951 base-game scripts), so its work factor
--- has been weather-blind since it was written.
---@return string|nil lowercase name, number|nil raw WeatherType enum value
function WeatherGuard:_currentWeatherType()
    local env     = self:_env()
    local weather = self:_weather()
    if env == nil or weather == nil then
        return nil, nil
    end
    local day     = env.currentMonotonicDay or 0
    local dayTime = env.dayTime or 0

    local typeId = nil

    -- Primary: resolve the active instance, then its weather object.
    -- weatherObject.weatherType is certified (RW Weather.lua:359,368 +
    -- GameInfoDisplay.lua:146,180).
    local item = self:_forecastItemAt(day, dayTime)
    if item ~= nil and type(item.season) == "number" and type(item.objectIndex) == "number" then
        local obj = tryCall(weather, "getWeatherObjectByIndex", item.season, item.objectIndex)
        if type(obj) == "table" then
            typeId = obj.weatherType
        end
    end

    -- Fallback: getWeatherTypeAtTime, the route FS25_WeatherForecastHUD walks
    -- behind its own presence guard for maps without forecastItems.
    if typeId == nil then
        typeId = tryCall(weather, "getWeatherTypeAtTime", day, dayTime)
    end

    if typeId == nil then
        WGLogger.warnOnce("weatherType",
            "getCurrentSky: could not resolve a weather type from forecastItems, dataForTime or getWeatherTypeAtTime; weatherType reports nil")
        return nil, nil
    end

    -- WeatherType is a global enum of NUMBERS with a name lookup, not a string
    -- field (RW FogSettings.lua:20,47 use getByName / getName; Weather.lua
    -- compares against WeatherType.SNOW / SUN / RAIN).
    local name = nil
    if WeatherType ~= nil and type(WeatherType.getName) == "function" then
        local ok, n = pcall(WeatherType.getName, typeId)
        if ok and type(n) == "string" then
            name = string.lower(n)
        end
    end
    return name, typeId
end

-- =========================================================
-- The weather-mode setting (adminOnly + server-authoritative)
-- =========================================================

--- Apply a mode locally. Internal: everything that can be reached by a player
--- goes through requestWeatherMode so the server stays authoritative.
function WeatherGuard:_applyWeatherMode(mode, source)
    mode = tonumber(mode)
    if mode == nil then
        return false
    end
    mode = math.floor(mode)
    if mode < WeatherGuard.MODE_MIN or mode > WeatherGuard.MODE_MAX then
        WGLogger.warning("Rejected weather mode %s (valid range %d-%d)",
            tostring(mode), WeatherGuard.MODE_MIN, WeatherGuard.MODE_MAX)
        return false
    end
    if self.weatherMode == mode then
        return true
    end
    self.weatherMode = mode
    WGLogger.info("Weather mode -> %d (%s)%s", mode, self:getWeatherModeName(),
        source ~= nil and (" [" .. source .. "]") or "")

    -- Push to clients when NetworkSync is present and we are the server.
    local ns = self:_getNetworkSync()
    if ns ~= nil and g_currentMission ~= nil and g_currentMission:getIsServer() then
        ns:markDirty(WeatherGuard.MODULE_ID)
    end
    return true
end

--- The player-facing entry point. This is a SHARED-WORLD control: one player's
--- choice changes everyone's weather, so it is admin-gated and server-owned. On
--- a client this sends a request; the server decides and broadcasts. A client
--- can never desync its own mode.
function WeatherGuard:requestWeatherMode(mode)
    local ns = self:_getNetworkSync()
    if ns ~= nil then
        return ns:requestAction(WeatherGuard.ACTION_MODE, { mode = mode })
    end
    -- No NetworkSync: single player, or a server with no sync layer.
    if g_currentMission == nil or g_currentMission:getIsServer() then
        return self:_applyWeatherMode(mode, "local")
    end
    WGLogger.warning("Cannot change the weather mode from a client without NetworkSync")
    return false
end

-- =========================================================
-- Bedrock binding (delegate-when-present, idempotent)
-- =========================================================

function WeatherGuard:_getLedger()
    return (g_currentMission ~= nil and g_currentMission.stateLedger) or g_stateLedger
end

function WeatherGuard:_getNetworkSync()
    return (g_currentMission ~= nil and g_currentMission.networkSync) or g_networkSync
end

function WeatherGuard:_getSettingsHub()
    return (g_currentMission ~= nil and g_currentMission.settingsHub) or g_settingsHub
end

function WeatherGuard:_bindBedrock()
    if self.bedrockBound then
        return
    end
    local bound = false

    local ledger = self:_getLedger()
    if ledger ~= nil then
        ledger:registerModule(WeatherGuard.MODULE_ID, {
            serialize   = function() return { weatherMode = self.weatherMode } end,
            deserialize = function(data)
                if type(data) == "table" and data.weatherMode ~= nil then
                    self:_applyWeatherMode(data.weatherMode, "stateLedger")
                    self.modeRestored = true
                end
                self.ledgerRestored = true
            end,
        })
        bound = true
    end

    local ns = self:_getNetworkSync()
    if ns ~= nil then
        ns:registerModule(WeatherGuard.MODULE_ID, {
            channel      = "WeatherGuard_Sync",
            onWriteState = function() return { self.weatherMode } end,
            onReadState  = function(arr)
                if type(arr) == "table" and arr[1] ~= nil then
                    self:_applyWeatherMode(arr[1], "networkSync")
                end
            end,
        })
        -- Server-authoritative edit path. adminOnly defaults true in NetworkSync;
        -- named here so the fence is visible at the call site rather than inherited.
        ns:registerAction(WeatherGuard.ACTION_MODE, {
            adminOnly = true,
            onAction  = function(_, args)
                if type(args) == "table" then
                    self:_applyWeatherMode(args.mode, "admin request")
                end
            end,
        })
        bound = true
    end

    local hub = self:_getSettingsHub()
    if hub ~= nil then
        hub:registerModule(WeatherGuard.MODULE_ID, {
            selfPersisted = true,   -- WeatherGuard owns the mode; the hub is a mirror
            adminSettings = {
                { id = "weatherMode", type = "int", default = WeatherGuard.MODE_DEFAULT,
                  min = WeatherGuard.MODE_MIN, max = WeatherGuard.MODE_MAX, step = 1,
                  adminOnly = true, label = "World Weather" },
            },
            onChange = function(key, value)
                if key == "weatherMode" then
                    -- The hub only reaches here on the server for an adminOnly
                    -- setting, so applying locally and broadcasting is correct.
                    self:_applyWeatherMode(value, "settingsHub")
                end
            end,
        })
        bound = true
    end

    if bound then
        self.bedrockBound = true
    end
end

-- =========================================================
-- Own-file persistence fallback (only when StateLedger is absent)
-- =========================================================

function WeatherGuard:_saveFilePath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil
        or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. WeatherGuard.SAVE_FILE
end

function WeatherGuard:_saveOwnFile()
    local path = self:_saveFilePath()
    if path == nil then
        return
    end
    local xml = XMLFile.create("wg_SettingsXML", path, "weatherGuard")
    if xml == nil then
        return
    end
    xml:setInt("weatherGuard#weatherMode", self.weatherMode)
    xml:save()
    xml:delete()
end

function WeatherGuard:_loadOwnFile()
    local path = self:_saveFilePath()
    if path == nil then
        return
    end
    local xml = XMLFile.loadIfExists("wg_SettingsXML", path, "weatherGuard")
    if xml == nil then
        return
    end
    local mode = xml:getInt("weatherGuard#weatherMode", nil)
    xml:delete()
    if mode ~= nil then
        self:_applyWeatherMode(mode, "own file")
        self.modeRestored = true
    end
end

-- =========================================================
-- Console command (wgStatus)
-- =========================================================

function WeatherGuard:consoleCommandStatus()
    local role = "unknown"
    if g_currentMission ~= nil then
        role = g_currentMission:getIsServer() and "server" or "client"
    end

    local lines = {}
    table.insert(lines, string.format("Weather Guard: role=%s, mode=%d (%s), bedrock=%s, modeRestored=%s",
        role, self.weatherMode, self:getWeatherModeName(),
        tostring(self.bedrockBound), tostring(self.modeRestored)))

    local ctx = self:getContext()
    table.insert(lines, string.format("  forecast: horizon=%s day(s) (%s), RealisticWeather=%s",
        tostring(ctx.forecastHorizonDays),
        ctx.forecastHorizonMeasured and "measured" or "assumed native",
        tostring(ctx.rwEnriching)))

    local sky = ctx.currentSky
    if sky == nil then
        table.insert(lines, "  sky: no environment")
    else
        table.insert(lines, string.format("  sky: rain=%s raining=%s cloud=%s temp=%s humidity=%s%s type=%s (%s)",
            tostring(sky.rainScale), tostring(sky.isRaining), tostring(sky.cloudCoverage),
            tostring(sky.temperature), tostring(sky.humidity),
            sky.humidityDefaulted and " (defaulted)" or "",
            tostring(sky.weatherType), tostring(sky.weatherTypeId)))
    end

    local rain = {}
    for d = 0, 4 do
        table.insert(rain, string.format("d+%d=%s", d, tostring(self:getForecastRain(d))))
    end
    table.insert(lines, "  forecast rain: " .. table.concat(rain, " "))

    local temp = {}
    for d = 0, 4 do
        table.insert(temp, string.format("d+%d=%s", d, tostring(self:getForecastTemperature(d))))
    end
    table.insert(lines, "  forecast temp: " .. table.concat(temp, " "))

    return table.concat(lines, "\n")
end
