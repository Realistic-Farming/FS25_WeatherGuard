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
--!load: src/Logger.lua, src/WeatherGuard.lua

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
local function buildForecast(items)
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
  }
end

---@param o table  opt-outs: dropRainFallScale, dropIsRaining, dropCloud, dropTemp,
---                dropHumidity, dropForecastItems, dropForecast, dropVariationRain,
---                dropWeatherObjects, dropWeatherTypeAtTime
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
  if not o.dropForecast      then weather.forecast      = buildForecast(items) end
  if not o.dropTemp then
    weather.temperatureUpdater = {
      getTemperatureAtTime = function(_self, t) return 18 + (t / DAY_MS) end,
    }
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
    currentSeason       = 1,
  }
  if not o.dropCloud then
    env.cloudUpdater = { getCloudCoverage = function() return 0.62 end }
  end
  if not o.dropHumidity then
    env.weatherSystem = { relativeHumidity = 0.72 }
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
  T.near("sky: humidity from weatherSystem.relativeHumidity", sky.humidity, 0.72)
  T.eq("sky: humidity is not flagged as defaulted", sky.humidityDefaulted, false)
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

do
  clearWorld()
  newWorld({ dropHumidity = true })
  local sky = newGuard():getCurrentSky()
  T.near("no-default: humidity falls to the ruled 0.5 floor", sky.humidity, 0.5)
  T.eq("no-default: and the 0.5 floor is FLAGGED, not silent", sky.humidityDefaulted, true)
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
  end
  wg:getForecastHorizonDays()
  wg:getContext()
  wg:getWeatherMode()
  wg:isRealisticWeatherActive()
  wg:consoleCommandStatus()

  T.eq("fence: no getter wrote anything into the engine state", snapshot(env), before)
end

-- The forbidden surface: the later features must stay ABSENT so a consumer falls
-- back instead of trusting a stub (delivery discipline 1).
do
  local wg = newGuard()
  T.isNil("surface: getClimate is deliberately absent until WG-2", wg.getClimate)
  T.isNil("surface: getEffectiveRain is deliberately absent", wg.getEffectiveRain)
  T.isNil("surface: getDroughtOutlook is deliberately absent", wg.getDroughtOutlook)
  T.isNil("surface: isDrySpell is deliberately absent", wg.isDrySpell)

  -- And the published five are all really here.
  for _, name in ipairs({ "getCurrentSky", "getForecastRain", "getForecastTemperature",
                          "getWeatherMode", "getContext" }) do
    T.eq("surface: " .. name .. " is published", type(wg[name]), "function")
  end
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
