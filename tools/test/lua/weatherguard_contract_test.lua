-- weatherguard_contract_test.lua - WG-1: the service + its published read-contract.
--
-- Locks the pure-logic half of the contract the build brief specifies:
--   * neutral-when-absent returns (no mission, no environment, no weather)
--   * the forecast horizon-nil edge (honest nil past the fill, never a fake 0)
--   * the absent-getter fallback (a missing engine method degrades, never crashes)
--   * the mode dial gating (1-4, server-owned, default Normal)
--   * the read-only fence (TRUTH never CONSEQUENCE: no getter writes the engine)
-- plus the routing the certification turned up: forecastItems first with a
-- dataForTime fallback, and two paths to a forward rain scale.
--!load: src/Logger.lua, src/WeatherGuard.lua, src/weather/DroughtScanner.lua

local DAY_MS = 24 * 60 * 60 * 1000
local NOON   = 12 * 60 * 60 * 1000
local TODAY  = 100

-- ── world builders ─────────────────────────────────────────

-- Ten one-day forecast items starting today, so the measured horizon is 9 days.
local function buildItems(n)
  local items = {}
  for i = 0, (n or 9) do
    table.insert(items, {
      startDay     = TODAY + i,
      startDayTime = 0,
      duration     = DAY_MS,
      season       = 1,
      objectIndex  = i + 1,
    })
  end
  return items
end

-- A forecast object that answers only for a day an item actually covers, the way
-- the engine's own fill does. Anything past the horizon is nil, not a guess.
-- Compares (day, time) as a pair for the same reason the source does: fengari's
-- integers wrap at 32 bits, so an absolute day*86,400,000 scalar silently
-- overflows here even though FS25's Lua 5.1 (doubles only) would not.
local function buildForecast(items, sentinelDay)
  return {
    dataForTime = function(_self, day, dayTime)
      for _, it in ipairs(items) do
        local afterStart = day > it.startDay
          or (day == it.startDay and dayTime >= it.startDayTime)
        local rawEnd  = it.startDayTime + it.duration
        local endDay  = it.startDay + math.floor(rawEnd / DAY_MS)
        local endTime = rawEnd % DAY_MS
        local beforeEnd = day < endDay or (day == endDay and dayTime < endTime)
        if afterStart and beforeEnd then
          return nil, it
        end
      end
      return nil, nil
    end,
    getHourlyForecast = function(_self, hour)
      if hour > 9 * 24 then return nil end
      return { temperature = 15 + hour * 0.5 }
    end,
    getDailyForecast = function(_self, daysFromToday)
      -- Mirror the engine: an uncovered day returns -math.huge / math.huge
      -- sentinels in a normal-looking table (WeatherForecast.lua:67-131), not
      -- a nil. The getter must reject them before computing.
      if daysFromToday > 9 or sentinelDay then
        return { day = TODAY + daysFromToday, highTemperature = -math.huge, lowTemperature = math.huge }
      end
      return { day = TODAY + daysFromToday, highTemperature = 25, lowTemperature = 15 }
    end,
  }
end

---@param o table  opt-outs: dropRainFallScale, dropIsRaining, dropCloud, dropTemp,
---                dropMinMax, dropTimeSinceRain, dropForecastItems, dropForecast,
---                dropVariationRain, dropWeatherObjects, dropWeatherTypeAtTime;
---                overrides: minMax = {lo, hi}, timeSinceRain = minutes, season = n
local function newWorld(o)
  o = o or {}
  local items = o.items or buildItems(9)

  -- One weather object per forecast item; rain rises with the index so a test can
  -- prove the walk landed on the right day rather than always item 1.
  local objects = {}
  for i = 1, #items do
    objects[i] = {
      weatherType = (i % 2 == 0) and WeatherType.RAIN or WeatherType.SUN,
      season      = 1,
      rainUpdater = { rainfallScale = i * 0.01 },
    }
  end

  local weather = {}
  if not o.dropForecastItems then weather.forecastItems = items end
  if not o.dropForecast      then weather.forecast      = buildForecast(items, o.sentinelDay) end
  if not o.dropTemp then
    weather.temperatureUpdater = {
      getTemperatureAtTime = function(_self, t) return 18 + (t / DAY_MS) end,
    }
  end
  if not o.dropMinMax then
    weather.getCurrentMinMaxTemperatures = function()
      local mm = o.minMax or { 10, 20 }
      return mm[1], mm[2]
    end
  end
  if not o.dropTimeSinceRain then
    weather.getTimeSinceLastRain = function() return o.timeSinceRain or 0 end
  end
  if o.weatherCloud then
    weather.cloudUpdater = { getCloudCoverage = function() return 0.31 end }
  end
  if not o.dropRainFallScale then
    weather.getRainFallScale = function() return 0.4 end
  end
  if not o.dropIsRaining then
    weather.getIsRaining = function() return true end
  end
  if not o.dropWeatherObjects then
    weather.getWeatherObjectByIndex = function(_self, _season, idx) return objects[idx] end
  end
  if not o.dropVariation then
    weather.getForecastInstanceVariation = function(_self, item)
      if o.dropVariationRain then return { rain = {} } end
      return { rain = { rainfallScale = (item.objectIndex or 0) * 0.1, snowfallScale = 0 } }
    end
  end
  if not o.dropWeatherTypeAtTime then
    weather.getWeatherTypeAtTime = function() return WeatherType.FOG end
  end

  local env = {
    weather             = weather,
    currentMonotonicDay = TODAY,
    dayTime             = NOON,
    currentSeason       = o.season or 1,
  }
  if not o.dropCloud then
    env.cloudUpdater = { getCloudCoverage = function() return 0.62 end }
  end

  g_currentMission = {
    environment = env,
    missionInfo = { savegameDirectory = "/save" },
    getIsServer = function() return o.isClient ~= true end,
  }
  return env, weather, objects, items
end

local function clearWorld()
  g_currentMission = nil
  g_stateLedger    = nil
  g_networkSync    = nil
  g_settingsHub    = nil
end

local function newGuard()
  return WeatherGuard.new()
end

-- ══════════════════════════════════════════════════════════
-- A. Neutral when absent
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  local wg = newGuard()

  T.isNil("absent: getCurrentSky is nil with no mission", wg:getCurrentSky())
  T.isNil("absent: getForecastRain is nil with no mission", wg:getForecastRain(1))
  T.isNil("absent: getForecastTemperature is nil with no mission", wg:getForecastTemperature(1))
  T.isNil("absent: getForecastHorizonDays is nil with no mission", wg:getForecastHorizonDays())

  -- The dial is WeatherGuard's OWN state, not an engine read, so it survives.
  T.eq("absent: the mode dial still answers", wg:getWeatherMode(), WeatherGuard.MODE_NORMAL)

  local ctx = wg:getContext()
  T.ok("absent: getContext still returns a table", type(ctx) == "table")
  T.isNil("absent: getContext currentSky is nil", ctx.currentSky)
  T.eq("absent: getContext falls back to the native horizon",
       ctx.forecastHorizonDays, WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS)
  T.eq("absent: getContext flags the horizon as unmeasured", ctx.forecastHorizonMeasured, false)
end

-- An environment with no weather at all (an early load frame).
do
  clearWorld()
  g_currentMission = { environment = {}, getIsServer = function() return true end }
  local wg = newGuard()
  T.isNil("absent: no weather object means no sky", wg:getCurrentSky())
  T.isNil("absent: no weather object means no forecast rain", wg:getForecastRain(0))
end

-- ══════════════════════════════════════════════════════════
-- B. The current sky, fully readable
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local sky = newGuard():getCurrentSky()

  T.ok("sky: returns a table", type(sky) == "table")
  T.near("sky: rainScale from getRainFallScale", sky.rainScale, 0.4)
  T.eq("sky: isRaining from getIsRaining", sky.isRaining, true)
  T.near("sky: cloudCoverage from environment.cloudUpdater", sky.cloudCoverage, 0.62)
  T.near("sky: temperature from weather.temperatureUpdater", sky.temperature, 18.5)
  T.near("sky: temperature from weather.temperatureUpdater", sky.temperature, 18.5)
  T.near("sky: humidity is 0.98 flat while precipitating (the rain gate)", sky.humidity, 0.98)
  T.eq("sky: a live rain-gate humidity is not flagged as defaulted", sky.humidityDefaulted, false)
  -- Today is item 1 -> objectIndex 1 -> odd -> SUN.
  T.eq("sky: weatherType is the lowercase category name", sky.weatherType, "sun")
  T.eq("sky: weatherTypeId is the raw WeatherType enum", sky.weatherTypeId, WeatherType.SUN)
end

-- cloudCoverage falls back from the environment to the weather object.
do
  clearWorld()
  newWorld({ dropCloud = true, weatherCloud = true })
  T.near("sky: cloudCoverage falls back to weather.cloudUpdater",
         newGuard():getCurrentSky().cloudCoverage, 0.31)
end

-- ══════════════════════════════════════════════════════════
-- C. NO SILENT DEFAULT on a load-bearing value
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld({ dropRainFallScale = true })
  local sky = newGuard():getCurrentSky()
  T.isNil("no-default: an unreadable rainScale reports nil, never a dry 0", sky.rainScale)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true })
  local sky = newGuard():getCurrentSky()
  T.eq("no-default: isRaining derives from rainScale when the method is absent",
       sky.isRaining, true)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true })
  local sky = newGuard():getCurrentSky()
  T.isNil("no-default: isRaining is nil when neither source exists", sky.isRaining)
end

do
  clearWorld()
  newWorld({ dropCloud = true })
  T.isNil("no-default: unreadable cloudCoverage reports nil",
          newGuard():getCurrentSky().cloudCoverage)
end

do
  clearWorld()
  newWorld({ dropTemp = true })
  T.isNil("no-default: unreadable temperature reports nil",
          newGuard():getCurrentSky().temperature)
end

-- WG-12 closed-form humidity. With the rain gate off and min=max=T_current the
-- model collapses to the blend itself, so the assertions are clean numbers:
--   t=0         -> e = eWet  -> humidity = HUMIDITY_WET          (0.98)
--   t->inf      -> e = eDry  -> humidity = spring baseline        (0.70)
--   t=tau*ln2   -> e midpoint -> humidity = (0.70 + 0.98)/2      (0.84)
do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true,
             minMax = { 18.5, 18.5 }, timeSinceRain = 0 })
  local sky = newGuard():getCurrentSky()
  T.near("humidity: just rained, still saturated at the wet end", sky.humidity, 0.98)
  T.eq("humidity: a live closed-form value is not flagged", sky.humidityDefaulted, false)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true,
             minMax = { 18.5, 18.5 }, timeSinceRain = 1e9 })
  local sky = newGuard():getCurrentSky()
  T.near("humidity: long dry, decays to the spring dry baseline", sky.humidity, 0.70)
  T.eq("humidity: the dry-end baseline is still a live value", sky.humidityDefaulted, false)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true,
             minMax = { 18.5, 18.5 }, timeSinceRain = 480 * math.log(2) })
  local sky = newGuard():getCurrentSky()
  T.near("humidity: at the tau midpoint the blend is half-way", sky.humidity, 0.84)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true,
             minMax = { 18.5, 18.5 }, timeSinceRain = 1e9, season = 2 })
  local sky = newGuard():getCurrentSky()
  T.near("humidity: summer dry baseline decays to 0.55", sky.humidity, 0.55)
  T.eq("humidity: season 2 uses the summer dry end", sky.humidityDefaulted, false)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true,
             minMax = { 18.5, 18.5 }, timeSinceRain = 1e9, season = 3 })
  local sky = newGuard():getCurrentSky()
  T.near("humidity: autumn dry baseline decays to 0.75", sky.humidity, 0.75)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true, dropTimeSinceRain = true })
  local sky = newGuard():getCurrentSky()
  T.near("humidity-defaulted: a nil rain clock falls to the ruled 0.5 floor", sky.humidity, 0.5)
  T.eq("humidity-defaulted: the nil-rain-clock floor IS flagged", sky.humidityDefaulted, true)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true, dropMinMax = true })
  local sky = newGuard():getCurrentSky()
  T.near("humidity-defaulted: a nil day mean falls to the ruled 0.5 floor", sky.humidity, 0.5)
  T.eq("humidity-defaulted: the nil-mean floor IS flagged", sky.humidityDefaulted, true)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true, dropTemp = true })
  local sky = newGuard():getCurrentSky()
  T.near("humidity-defaulted: a nil current temperature falls to the ruled 0.5 floor",
         sky.humidity, 0.5)
  T.eq("humidity-defaulted: the nil-temperature floor IS flagged", sky.humidityDefaulted, true)
end

do
  clearWorld()
  newWorld({ dropIsRaining = true, dropRainFallScale = true, season = 0 })
  local sky = newGuard():getCurrentSky()
  T.near("humidity-defaulted: an unreadable season falls to the ruled 0.5 floor",
         sky.humidity, 0.5)
  T.eq("humidity-defaulted: the unreadable-season floor IS flagged", sky.humidityDefaulted, true)
end

do
  clearWorld()
  newWorld({ dropWeatherObjects = true, dropWeatherTypeAtTime = true })
  local sky = newGuard():getCurrentSky()
  T.isNil("no-default: an unresolvable weather type reports nil", sky.weatherType)
  T.isNil("no-default: and its raw id reports nil too", sky.weatherTypeId)
end

-- The weather-type fallback route, the one FS25_WeatherForecastHUD walks on maps
-- without forecastItems.
do
  clearWorld()
  newWorld({ dropWeatherObjects = true })
  local sky = newGuard():getCurrentSky()
  T.eq("sky: weatherType falls back to getWeatherTypeAtTime", sky.weatherType, "fog")
end

-- ══════════════════════════════════════════════════════════
-- D. Forward rain
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local wg = newGuard()

  -- Today is item 1 (objectIndex 1) -> variation rain 0.1.
  T.near("rain: day 0 reads today's forecast item", wg:getForecastRain(0), 0.1)
  -- Three days out is item 4 (objectIndex 4) -> 0.4. Proves the walk, not items[1].
  T.near("rain: day 3 walks to the right item", wg:getForecastRain(3), 0.4)
  T.near("rain: day 9 is the last filled day", wg:getForecastRain(9), 1.0)

  T.isNil("rain: past the filled horizon returns nil (the honest edge)", wg:getForecastRain(10))
  T.isNil("rain: far past the horizon returns nil", wg:getForecastRain(400))
  T.isNil("rain: a negative daysAhead returns nil", wg:getForecastRain(-1))

  T.near("rain: a fractional daysAhead floors to the day", wg:getForecastRain(3.7), 0.4)
end

-- Path 2: when the per-instance variation carries no rainfallScale, fall through
-- to the weather object's own rainUpdater rather than reporting a dry 0.
do
  clearWorld()
  newWorld({ dropVariationRain = true })
  T.near("rain: falls back to weatherObject.rainUpdater.rainfallScale",
         newGuard():getForecastRain(2), 0.03)
end

-- Route B: no forecastItems array at all (the per-map absence WeatherForecastHUD
-- guards against), so dataForTime carries the read.
do
  clearWorld()
  newWorld({ dropForecastItems = true })
  local wg = newGuard()
  T.near("rain: resolves through dataForTime when forecastItems is absent",
         wg:getForecastRain(3), 0.4)
  T.isNil("rain: the dataForTime route still honours the horizon", wg:getForecastRain(12))
end

-- Neither route present: nil, and no crash.
do
  clearWorld()
  newWorld({ dropForecastItems = true, dropForecast = true })
  T.isNil("rain: nil when neither forecast route exists", newGuard():getForecastRain(1))
end

-- The rain scale itself is unreadable on both paths.
do
  clearWorld()
  newWorld({ dropVariationRain = true, dropWeatherObjects = true })
  T.isNil("rain: nil when no rain field is readable on either path",
          newGuard():getForecastRain(1))
end

-- ══════════════════════════════════════════════════════════
-- E. Forward temperature
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local wg = newGuard()

  T.near("temp: day 0 reads hour 0", wg:getForecastTemperature(0), 15)
  -- The engine argument is an offset in HOURS from now, so 2 days = hour 48.
  T.near("temp: day 2 reads hour 48", wg:getForecastTemperature(2), 15 + 48 * 0.5)
  T.isNil("temp: past the filled horizon returns nil", wg:getForecastTemperature(10))
  T.isNil("temp: a negative daysAhead returns nil", wg:getForecastTemperature(-2))
end

do
  clearWorld()
  newWorld({ dropForecast = true })
  T.isNil("temp: nil when weather.forecast is absent", newGuard():getForecastTemperature(1))
end

-- ══════════════════════════════════════════════════════════
-- E2. Forward humidity (WG-12): the day's MINIMUM, the drying window
-- ══════════════════════════════════════════════════════════
-- The mock getDailyForecast returns high=25, low=15, so T_mean = 20. With the
-- rain clock at 0 the blend sits at the wet end: humidity = 0.98 * esat(20) /
-- esat(25). The engine's own formula is the reference, computed in-test so the
-- assertion locks the model rather than a stale constant.
do
  clearWorld()
  newWorld({ timeSinceRain = 0 })
  local wg = newGuard()
  local function esat(T) return 6.1078 * math.exp(17.27 * T / (237.3 + T)) end
  local want = 0.98 * esat(20) / esat(25)
  T.near("fhum: day 0 is the forecast day's drying window", wg:getForecastHumidity(0), want)
  T.near("fhum: day 3 uses the same forecast day's window", wg:getForecastHumidity(3), want)
  T.isNil("fhum: past the filled horizon returns nil (the honest edge)",
          wg:getForecastHumidity(10))
  T.isNil("fhum: far past the horizon returns nil", wg:getForecastHumidity(400))
  T.isNil("fhum: a negative daysAhead returns nil", wg:getForecastHumidity(-1))
end

do
  clearWorld()
  newWorld({ sentinelDay = true })
  local wg = newGuard()
  T.isNil("fhum: a sentinel (uncovered) forecast day is rejected, never math.huge",
          wg:getForecastHumidity(2))
end

do
  clearWorld()
  newWorld({ dropForecast = true })
  T.isNil("fhum: nil when weather.forecast is absent", newGuard():getForecastHumidity(1))
end

do
  clearWorld()
  newWorld({ timeSinceRain = 1e9 })
  local wg = newGuard()
  local function esat(T) return 6.1078 * math.exp(17.27 * T / (237.3 + T)) end
  local want = 0.70 * esat(20) / esat(25)
  T.near("fhum: long dry, the window is the spring dry end", wg:getForecastHumidity(2), want)
end

-- ══════════════════════════════════════════════════════════
-- F. The horizon
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  T.eq("horizon: measured from the last filled item", wg:getForecastHorizonDays(), 9)

  local ctx = wg:getContext()
  T.eq("horizon: getContext reports the measured value", ctx.forecastHorizonDays, 9)
  T.eq("horizon: and flags it as measured", ctx.forecastHorizonMeasured, true)
end

do
  clearWorld()
  newWorld({ items = buildItems(3) })   -- only 4 days filled
  T.eq("horizon: a short fill measures short", newGuard():getForecastHorizonDays(), 3)
end

do
  clearWorld()
  newWorld({ dropForecastItems = true })
  local wg = newGuard()
  T.isNil("horizon: unmeasurable without forecastItems", wg:getForecastHorizonDays())
  T.eq("horizon: getContext then falls back to the native constant",
       wg:getContext().forecastHorizonDays, WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS)
end

-- The certified native horizon, so a future edit cannot quietly drift it.
T.eq("horizon: the native constant is the source-confirmed 9 days",
     WeatherGuard.NATIVE_FORECAST_HORIZON_DAYS, 9)

-- ══════════════════════════════════════════════════════════
-- G. The weather-mode dial
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  local wg = newGuard()

  T.eq("mode: the default is 3 (Normal)", wg:getWeatherMode(), 3)
  T.eq("mode: the ruled positions are 1..4", WeatherGuard.MODE_MIN .. "-" .. WeatherGuard.MODE_MAX, "1-4")
  T.eq("mode: 1 is real weather only", WeatherGuard.MODE_REAL, 1)
  T.eq("mode: names map to the ruled dial", wg:getWeatherModeName(), "normal")

  for mode, name in pairs({ [1] = "real", [2] = "arid", [3] = "normal", [4] = "wet" }) do
    wg:_applyWeatherMode(mode)
    T.eq("mode: " .. mode .. " accepted as " .. name, wg:getWeatherModeName(), name)
  end

  wg:_applyWeatherMode(4)
  T.eq("mode: 0 is rejected", wg:_applyWeatherMode(0), false)
  T.eq("mode: and the dial is unchanged after a rejection", wg:getWeatherMode(), 4)
  T.eq("mode: 5 is rejected", wg:_applyWeatherMode(5), false)
  T.eq("mode: a non-number is rejected", wg:_applyWeatherMode("wet"), false)
  T.eq("mode: the dial survives every rejection", wg:getWeatherMode(), 4)

  wg:_applyWeatherMode(2.9)
  T.eq("mode: a fractional value floors into the dial", wg:getWeatherMode(), 2)
end

-- A client with no NetworkSync cannot move a shared-world control.
do
  clearWorld()
  newWorld({ isClient = true })
  local wg = newGuard()
  T.eq("mode: a client without NetworkSync cannot change the world weather",
       wg:requestWeatherMode(1), false)
  T.eq("mode: and its own dial did not desync", wg:getWeatherMode(), 3)
end

-- With NetworkSync the request goes through the server-authoritative action path.
do
  clearWorld()
  newWorld({ isClient = true })
  local sent = {}
  g_networkSync = {
    registerModule = function() return true end,
    registerAction = function(_self, id, spec) sent.actionId = id; sent.spec = spec; return true end,
    markDirty      = function() end,
    requestAction  = function(_self, id, args) sent.requested = { id = id, args = args }; return true end,
  }
  local wg = newGuard()
  wg:_bindBedrock()

  T.eq("mode: the edit action is registered", sent.actionId, WeatherGuard.ACTION_MODE)
  T.eq("mode: and it is admin-gated", sent.spec.adminOnly, true)

  T.eq("mode: a client request is forwarded to the server", wg:requestWeatherMode(2), true)
  T.eq("mode: the forwarded action carries the mode", sent.requested.args.mode, 2)
  T.eq("mode: the client did NOT apply it locally", wg:getWeatherMode(), 3)

  -- The server side of the same action does apply it.
  sent.spec.onAction(nil, { mode = 2 })
  T.eq("mode: the server action handler applies the mode", wg:getWeatherMode(), 2)
end

-- ══════════════════════════════════════════════════════════
-- H. Persistence
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_ARID)
  wg:save()

  local wg2 = newGuard()
  T.eq("persist: a fresh instance starts at the default", wg2:getWeatherMode(), 3)
  wg2:_loadOwnFile()
  T.eq("persist: the own-file fallback round-trips the mode", wg2:getWeatherMode(), 2)
  T.eq("persist: and marks the mode as restored", wg2.modeRestored, true)
end

do
  clearWorld()
  newWorld()
  local stored = nil
  g_stateLedger = {
    registerModule = function(_self, _id, spec) stored = spec end,
  }
  local wg = newGuard()
  wg:_bindBedrock()
  wg:_applyWeatherMode(WeatherGuard.MODE_WET)

  local blob = stored.serialize()
  T.eq("persist: StateLedger serialize carries the mode", blob.weatherMode, 4)

  local wg2 = newGuard()
  g_stateLedger = { registerModule = function(_self, _id, spec) stored = spec end }
  wg2:_bindBedrock()
  stored.deserialize(blob)
  T.eq("persist: StateLedger deserialize restores the mode", wg2:getWeatherMode(), 4)
  T.eq("persist: a nil blob is survivable", pcall(stored.deserialize, nil), true)
end

-- With StateLedger present the own file must NOT also be written (one owner).
do
  clearWorld()
  newWorld()
  _XML_STORE["/save/" .. WeatherGuard.SAVE_FILE] = nil
  g_stateLedger = { registerModule = function() end }
  local wg = newGuard()
  wg:_bindBedrock()
  wg:save()
  T.isNil("persist: StateLedger present means no duplicate own file",
          _XML_STORE["/save/" .. WeatherGuard.SAVE_FILE])
end

-- ══════════════════════════════════════════════════════════
-- I. NetworkSync state round-trip
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local schema = nil
  g_networkSync = {
    registerModule = function(_self, _id, s) schema = s end,
    registerAction = function() end,
    markDirty      = function() end,
  }
  local server = newGuard()
  server:_bindBedrock()
  server:_applyWeatherMode(WeatherGuard.MODE_ARID)

  local wire = schema.onWriteState()
  T.eq("sync: the server writes the mode to the wire", wire[1], 2)

  local clientSchema = nil
  g_networkSync = {
    registerModule = function(_self, _id, s) clientSchema = s end,
    registerAction = function() end,
    markDirty      = function() end,
  }
  local client = newGuard()
  client:_bindBedrock()
  clientSchema.onReadState(wire)
  T.eq("sync: the client applies the server's mode", client:getWeatherMode(), 2)

  clientSchema.onReadState(nil)
  T.eq("sync: a malformed frame leaves the mode alone", client:getWeatherMode(), 2)
end

-- The SettingsHub registration must declare the shared-world fence.
do
  clearWorld()
  newWorld()
  local spec = nil
  g_settingsHub = { registerModule = function(_self, _id, s) spec = s end }
  local wg = newGuard()
  wg:_bindBedrock()

  T.ok("hub: a settings module is registered", type(spec) == "table")
  T.eq("hub: WeatherGuard owns its own persistence", spec.selfPersisted, true)
  local def = spec.adminSettings[1]
  T.eq("hub: the dial is the weatherMode setting", def.id, "weatherMode")
  T.eq("hub: it is admin only (a shared-world control)", def.adminOnly, true)
  T.eq("hub: its range is the ruled 1..4", def.min .. "-" .. def.max, "1-4")
  T.eq("hub: it defaults to Normal", def.default, 3)

  spec.onChange("weatherMode", 4)
  T.eq("hub: an admin edit applies the mode", wg:getWeatherMode(), 4)
end

-- ══════════════════════════════════════════════════════════
-- J. The read-only fence: TRUTH, never CONSEQUENCE
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  local env = newWorld()

  -- Deep snapshot of every value the getters can reach. Keys are kept in their
  -- real type (a stringified key would miss array entries entirely) and sorted
  -- by their text form so the two renderings are comparable.
  local function snapshot(t, depth, seen)
    depth, seen = depth or 0, seen or {}
    if type(t) ~= "table" or depth > 6 or seen[t] then return tostring(t) end
    seen[t] = true
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, tostring(k) .. "=" .. snapshot(t[k], depth + 1, seen))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local before = snapshot(env)

  local wg = newGuard()
  wg:getCurrentSky()
  for d = 0, 11 do
    wg:getForecastRain(d)
    wg:getForecastTemperature(d)
    wg:getForecastHumidity(d)
    wg:getEffectiveRain(d)
  end
  wg:getForecastHorizonDays()
  wg:getContext()
  wg:getWeatherMode()
  wg:isRealisticWeatherActive()
  wg:consoleCommandStatus()

  T.eq("fence: no getter wrote anything into the engine state", snapshot(env), before)
end

-- The published surface (WG-4 drought outlook is now built).
do
  local wg = newGuard()

  -- The published functions are all really here.
  for _, name in ipairs({ "getClimate", "getCurrentSky", "getDroughtOutlook",
                          "getEffectiveRain", "getForecastRain",
                          "getForecastTemperature", "getForecastHumidity",
                          "getWeatherMode", "getContext", "isDrySpell" }) do
    T.eq("surface: " .. name .. " is published", type(wg[name]), "function")
  end
end

-- WG-4 DROUGHT OUTLOOK: the method is CALLED, not merely counted.
--
-- The block above asserts these nine names exist, and that is all it ever did. It
-- passed for the entire life of a feature that could not run: DroughtScanner was
-- loaded by a bare relative `source("src/weather/DroughtScanner.lua")` the engine
-- cannot resolve, guarded by a `source = source or function() end` stub that kept the
-- offline suite quiet, and the constructor was called as `DroughtScanner(self)` on a
-- plain table with no __call. Three faults stacked, in a feature with a green test.
--
-- Existence is not behaviour. These call it.
do
  T.eq("the DroughtScanner module is actually loaded", type(DroughtScanner), "table")
  T.eq("and it constructs with .new, not by calling the table",
       type(DroughtScanner.new), "function")

  local wg = newGuard()

  -- Neutral when absent: no mission, no environment, so the scan must REFUSE with a
  -- shaped answer rather than raise or invent a dry spell.
  clearWorld()
  local outlook = wg:getDroughtOutlook()
  T.eq("getDroughtOutlook returns a table with no world at all", type(outlook), "table")
  T.eq("and reports no dry spell rather than guessing one", outlook.isDrySpell, false)
  T.eq("with zero severity", outlook.severity, 0)
  T.eq("and zero dry days", outlook.dryDays, 0)

  T.eq("isDrySpell rides it and answers false", wg:isDrySpell(), false)

  -- The scanner is built once and reused, not rebuilt per call.
  local first = wg._droughtScanner
  wg:getDroughtOutlook()
  T.ok("the scanner instance is cached", wg._droughtScanner == first)
  T.ok("and it is a real instance, not the class table", first ~= DroughtScanner)
end

-- ══════════════════════════════════════════════════════════
-- K. Lifecycle safety
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  T.eq("lifecycle: onMissionLoaded survives a bare world", pcall(wg.onMissionLoaded, wg), true)
  T.eq("lifecycle: update survives before any bedrock exists", pcall(wg.update, wg, 16), true)
  T.eq("lifecycle: onMissionDelete clears the bedrock flag",
       (function() wg:onMissionDelete(); return wg.bedrockBound end)(), false)

  clearWorld()
  T.eq("lifecycle: onMissionLoaded survives with no mission at all",
       pcall(wg.onMissionLoaded, wg), true)
  T.eq("lifecycle: save is a no-op with no mission", pcall(wg.save, wg), true)
end

-- ══════════════════════════════════════════════════════════
-- L. getClimate (WG-2 Grounded Climate)
-- ══════════════════════════════════════════════════════════
do
  clearWorld()
  newWorld()
  local wg = newGuard()

  T.ok("climate: getClimate is published", type(wg.getClimate) == "function")

  -- Normal bias (default) — the mode is MODE_NORMAL and not restored.
  local r = wg:getClimate(1)
  T.ok("climate: returns a table for season 1", type(r) == "table")
  T.near("climate: spring rainDayFraction (Normal)", r.rainDayFraction, 0.40)
  T.near("climate: spring intensity (Normal)", r.intensity, 0.55)
  T.eq("climate: spring meanTemp", r.meanTemp, 12)
  T.eq("climate: biasDefaulted=true when mode is default Normal", r.biasDefaulted, true)

  local r2 = wg:getClimate(2)
  T.near("climate: summer rainDayFraction (Normal)", r2.rainDayFraction, 0.20)
  T.eq("climate: summer meanTemp", r2.meanTemp, 22)

  local r3 = wg:getClimate(3)
  T.near("climate: autumn rainDayFraction (Normal)", r3.rainDayFraction, 0.38)
  T.eq("climate: autumn meanTemp", r3.meanTemp, 10)

  local r4 = wg:getClimate(4)
  T.near("climate: winter rainDayFraction (Normal)", r4.rainDayFraction, 0.32)
  T.eq("climate: winter meanTemp", r4.meanTemp, 2)
end

-- Arid bias (explicitly set, not defaulted).
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_ARID)

  local r = wg:getClimate(1)
  T.near("climate: spring rainDayFraction (Arid)", r.rainDayFraction, 0.20)
  T.near("climate: spring intensity (Arid)", r.intensity, 0.40)
  T.eq("climate: biasDefaulted=false when Arid was chosen", r.biasDefaulted, false)
end

-- Wet bias.
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_WET)

  local r = wg:getClimate(1)
  T.near("climate: spring rainDayFraction (Wet)", r.rainDayFraction, 0.65)
  T.near("climate: spring intensity (Wet)", r.intensity, 0.80)
  T.eq("climate: biasDefaulted=false when Wet was chosen", r.biasDefaulted, false)
end

-- Normal bias explicitly chosen (not defaulted).
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_NORMAL)
  wg.modeRestored = true

  local r = wg:getClimate(1)
  T.near("climate: Normal still returns correct data when explicitly chosen", r.rainDayFraction, 0.40)
  T.eq("climate: biasDefaulted=false when mode was explicitly restored", r.biasDefaulted, false)
end

-- MODE_REAL (1) defaults to Normal and flags it.
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_REAL)

  local r = wg:getClimate(1)
  T.near("climate: MODE_REAL defaults to Normal rainDayFraction", r.rainDayFraction, 0.40)
  T.eq("climate: MODE_REAL flags biasDefaulted=true", r.biasDefaulted, true)
end

-- Nil / out-of-range season safety.
do
  clearWorld()
  newWorld()
  local wg = newGuard()

  T.isNil("climate: nil season returns nil", wg:getClimate(nil))
  T.isNil("climate: season 0 returns nil", wg:getClimate(0))
  T.isNil("climate: season 5 returns nil", wg:getClimate(5))
  T.isNil("climate: string season returns nil", wg:getClimate("spring"))
  T.isNil("climate: no argument returns nil", wg:getClimate())
end

-- Determinism: same season + same bias always returns the same numbers.
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_ARID)

  local a = wg:getClimate(2)
  local b = wg:getClimate(2)
  T.eq("climate: deterministic (same season + bias = same result)", a.rainDayFraction == b.rainDayFraction
       and a.intensity == b.intensity and a.meanTemp == b.meanTemp and a.biasDefaulted == b.biasDefaulted, true)
end

-- Read-only fence: getClimate must not write anything into the engine.
do
  clearWorld()
  local env = newWorld()

  local function snapshot(t, depth, seen)
    depth, seen = depth or 0, seen or {}
    if type(t) ~= "table" or depth > 6 or seen[t] then return tostring(t) end
    seen[t] = true
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, tostring(k) .. "=" .. snapshot(t[k], depth + 1, seen))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local before = snapshot(env)
  local wg = newGuard()
  wg:getClimate(1)
  wg:getClimate(2)
  wg:getClimate(3)
  wg:getClimate(4)
  T.eq("climate: no getter wrote anything into the engine state", snapshot(env), before)
end

-- ══════════════════════════════════════════════════════════
-- M. getEffectiveRain (WG-3 Both-Face Resolution)
-- ══════════════════════════════════════════════════════════

-- Returns a table with all 4 fields.
do
  clearWorld()
  newWorld()
  local r = newGuard():getEffectiveRain(1)
  T.ok("wg3: returns a table", type(r) == "table")
  T.ok("wg3: has rainScale", type(r.rainScale) == "number")
  T.ok("wg3: has isRaining", type(r.isRaining) == "boolean")
  T.ok("wg3: has source", type(r.source) == "string")
  T.ok("wg3: has rainWasFilled", type(r.rainWasFilled) == "boolean")
end

-- rainScale is always a number (never nil).
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  for d = -1, 12 do
    local r = wg:getEffectiveRain(d)
    T.ok("wg3: rainScale is a number for daysAhead=" .. d, type(r.rainScale) == "number")
  end
end

-- isRaining matches rainScale > MIN_RAIN_THRESHOLD.
do
  clearWorld()
  -- Custom items with objectIndex mapping to known rain scales.
  local items = {
    { startDay = 100, startDayTime = 0, duration = 86400000, season = 1, objectIndex = 1 },
    { startDay = 101, startDayTime = 0, duration = 86400000, season = 1, objectIndex = 2 },
  }
  newWorld({ items = items })
  local wg = newGuard()
  local r0 = wg:getEffectiveRain(0)  -- objectIndex 1 -> 0.1, NOT > 0.1
  T.eq("wg3: day 0 (0.1) isRaining matches threshold", r0.isRaining, r0.rainScale > 0.1)
  local r1 = wg:getEffectiveRain(1)  -- objectIndex 2 -> 0.2, > 0.1
  T.eq("wg3: day 1 (0.2) isRaining matches threshold", r1.isRaining, r1.rainScale > 0.1)
end

-- Mode 1 opt-out: climate fill never engages.
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  wg:_applyWeatherMode(WeatherGuard.MODE_REAL)

  -- Past horizon: mode 1 returns dry-real.
  local rPast = wg:getEffectiveRain(10)
  T.eq("wg3: mode=1 past horizon source=real", rPast.source, "real")
  T.eq("wg3: mode=1 past horizon rainWasFilled=false", rPast.rainWasFilled, false)
  T.near("wg3: mode=1 past horizon rainScale=0", rPast.rainScale, 0)

  -- In horizon, dry forecast: mode 1 returns real, never fills.
  local rDry = wg:getEffectiveRain(0)
  T.eq("wg3: mode=1 dry horizon source=real", rDry.source, "real")
  T.eq("wg3: mode=1 dry horizon rainWasFilled=false", rDry.rainWasFilled, false)

  -- In horizon, wet forecast (> 0.1): mode 1 returns real with scale.
  local rWet = wg:getEffectiveRain(1)
  T.eq("wg3: mode=1 wet horizon source=real", rWet.source, "real")
  T.near("wg3: mode=1 wet horizon rainScale=0.2", rWet.rainScale, 0.2)
end

-- Source label: real rain present (forecast > 0.1).
do
  clearWorld()
  newWorld()
  local r = newGuard():getEffectiveRain(1)
  T.eq("wg3: real rain present source=real", r.source, "real")
  T.eq("wg3: real rain present rainWasFilled=false", r.rainWasFilled, false)
end

-- Source label: no fill when daysPerPeriod >= 15 (w = 0).
do
  clearWorld()
  local env = newWorld()
  env.daysPerPeriod = 15
  local r = newGuard():getEffectiveRain(0)
  T.eq("wg3: long month (dpm=15) source=real", r.source, "real")
  T.eq("wg3: long month (dpm=15) rainWasFilled=false", r.rainWasFilled, false)
end

-- Source label: past-horizon climate fill (no forecast, step 5).
do
  clearWorld()
  local env = newWorld({ dropForecastItems = true, dropForecast = true })
  local wg = newGuard()
  -- In Normal mode, spring: rainDayFraction = 0.40, intensity = 0.55.
  -- Compute the seeded roll to know which sub-path the fill takes.
  local function seededRoll(day)
    local s = math.sin(day * 12.9898 + 78.233) * 43758.5453
    return s - math.floor(s)
  end
  local targetDay = (env.currentMonotonicDay or 0) + 0
  local roll = seededRoll(targetDay)
  local prob = 0.40

  local r = wg:getEffectiveRain(0)
  if roll < prob then
    T.eq("wg3: past-horizon fill wet source=climate", r.source, "climate")
    T.near("wg3: past-horizon fill wet rainScale", r.rainScale, 0.55)
    T.eq("wg3: past-horizon fill wet rainWasFilled=true", r.rainWasFilled, true)
    T.eq("wg3: past-horizon fill wet isRaining=true", r.isRaining, true)
  else
    T.eq("wg3: past-horizon fill dry source=real", r.source, "real")
    T.near("wg3: past-horizon fill dry rainScale", r.rainScale, 0)
    T.eq("wg3: past-horizon fill dry rainWasFilled=false", r.rainWasFilled, false)
    T.eq("wg3: past-horizon fill dry isRaining=false", r.isRaining, false)
  end
end

-- Source label: short-month blend (in-horizon dry, step 4 fill wet).
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  local env = g_currentMission.environment
  -- Day 0: forecastRain = 0.1 (dry), triggers step 4 (short-month fill).
  local function seededRoll(day)
    local s = math.sin(day * 12.9898 + 78.233) * 43758.5453
    return s - math.floor(s)
  end
  local targetDay = (env.currentMonotonicDay or 0) + 0
  local roll = seededRoll(targetDay)
  local dpm = env.daysPerPeriod or 1
  local w = math.max(0, math.min(1, (15 - dpm) / 14)) ^ 2.5
  local prob = 0.40 * w  -- Normal, spring

  local r = wg:getEffectiveRain(0)
  if roll < prob then
    T.eq("wg3: short-month fill wet source=blend", r.source, "blend")
    T.near("wg3: short-month fill wet rainScale", r.rainScale, 0.55)
    T.eq("wg3: short-month fill wet rainWasFilled=true", r.rainWasFilled, true)
  else
    T.eq("wg3: short-month fill dry source=real", r.source, "real")
    T.near("wg3: short-month fill dry rainScale", r.rainScale, 0)
    T.eq("wg3: short-month fill dry rainWasFilled=false", r.rainWasFilled, false)
  end
end

-- Nil-safety: no args, nil args, non-number args.
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  local r1 = wg:getEffectiveRain()
  T.ok("wg3: no args returns a table", type(r1) == "table")
  T.ok("wg3: no args rainScale is a number", type(r1.rainScale) == "number")

  local r2 = wg:getEffectiveRain(nil)
  T.ok("wg3: nil arg returns a table", type(r2) == "table")
  T.ok("wg3: nil arg rainScale is a number", type(r2.rainScale) == "number")

  local r3 = wg:getEffectiveRain("string")
  T.ok("wg3: string arg returns a table", type(r3) == "table")
  T.ok("wg3: string arg rainScale is a number", type(r3.rainScale) == "number")
end

-- Determinism: same daysAhead always returns the same struct.
do
  clearWorld()
  newWorld()
  local wg = newGuard()
  local a = wg:getEffectiveRain(2)
  local b = wg:getEffectiveRain(2)
  T.eq("wg3: deterministic rainScale", a.rainScale == b.rainScale, true)
  T.eq("wg3: deterministic isRaining", a.isRaining == b.isRaining, true)
  T.eq("wg3: deterministic source", a.source == b.source, true)
  T.eq("wg3: deterministic rainWasFilled", a.rainWasFilled == b.rainWasFilled, true)
end

-- Neutral-when-absent: no environment returns dry-real.
do
  clearWorld()
  local wg = newGuard()
  local r = wg:getEffectiveRain(0)
  T.ok("wg3: absent env returns a table", type(r) == "table")
  T.near("wg3: absent env rainScale=0", r.rainScale, 0)
  T.eq("wg3: absent env source=real", r.source, "real")
  T.eq("wg3: absent env rainWasFilled=false", r.rainWasFilled, false)
end

-- No season on env returns dry-real.
do
  clearWorld()
  g_currentMission = { environment = { weather = {} }, getIsServer = function() return true end }
  local r = newGuard():getEffectiveRain(0)
  T.ok("wg3: no season returns a table", type(r) == "table")
  T.near("wg3: no season rainScale=0", r.rainScale, 0)
  T.eq("wg3: no season source=real", r.source, "real")
end
