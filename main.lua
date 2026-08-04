-- =========================================================
-- FS25_WeatherGuard - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Loads the Weather Guard modules, publishes the handle, and hooks the FS25
-- mission lifecycle:
--   Mission00.load                     -> publish the cross-mod bridge handle
--   Mission00.loadMission00Finished    -> bind bedrock, restore the weather mode
--   FSBaseMission.update               -> retry a deferred bedrock bind
--   FSCareerMissionInfo.saveToXMLFile  -> persist the weather mode (own-file
--                                         fallback; StateLedger handles it when present)
--   FSBaseMission.delete               -> drop the handle
--
-- Load order: Weather Guard is the 6th core service (after StateLedger,
-- NetworkSync, MasterHUD, SettingsHub, TimeGuard). The handle is published as
-- soon as this file runs so companion mods that load after it can read the sky
-- during their own module load, before the mission exists.
-- =========================================================

local modDirectory = g_currentModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/WeatherGuard.lua")
-- WG-4. Sourced HERE, with the mod directory, rather than from a modDesc
-- extraSourceFiles entry or a bare relative source() inside WeatherGuard.lua. Both of
-- those were tried and neither worked, which is why the drought outlook has been dead
-- since it shipped. Every other module in this mod loads this way and always has.
source(modDirectory .. "src/weather/DroughtScanner.lua")

-- Create the instance and publish the handle immediately (before any mission
-- hook), so an early companion read is never missed.
local weatherGuard = WeatherGuard.new()

-- Two spellings on purpose. g_weatherGuard matches the rest of the core-service
-- family (g_stateLedger / g_networkSync / g_settingsHub / g_timeGuard);
-- g_WeatherGuard is the spelling the service brief names. Publishing both costs
-- one table slot and means neither convention breaks a consumer.
getfenv(0)["g_weatherGuard"] = weatherGuard
getfenv(0)["g_WeatherGuard"] = weatherGuard

-- ---------------------------------------------------------
-- Mission lifecycle hooks
-- ---------------------------------------------------------

local function onMissionLoad(mission)
    -- g_currentMission is a shared C++ object visible to all mods, unlike
    -- getfenv(0) which is per-mod scoped. Publish the cross-mod bridge here.
    if mission ~= nil then
        mission.weatherGuard = weatherGuard
    end
    WGLogger.info("Weather Guard loading (core service 6, the shared sky)")
end

local function onMissionLoadedFinished()
    weatherGuard:onMissionLoaded()
end

local function onMissionUpdate(mission, dt)
    weatherGuard:update(dt)
end

local function onMissionSave()
    weatherGuard:save()
end

local function onMissionDelete()
    weatherGuard:onMissionDelete()
    getfenv(0)["g_weatherGuard"] = nil
    getfenv(0)["g_WeatherGuard"] = nil
    if g_currentMission ~= nil then
        g_currentMission.weatherGuard = nil
    end
end

-- appendedFunction so the base game's own handler runs first.
Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoadedFinished)
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, onMissionUpdate)

-- Save via FSCareerMissionInfo:saveToXMLFile, the window where
-- savegameDirectory points at the tempsavegame that FS25 then copies over the
-- real savegame. Hooking the non-existent Mission00.saveToXMLFile is a known
-- trap that silently never fires.
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function() onMissionSave() end
    )
else
    WGLogger.warning("FSCareerMissionInfo.saveToXMLFile not found - the weather mode will NOT be saved")
end

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

-- ---------------------------------------------------------
-- Console command: wgStatus (target + method, the proven pattern)
-- ---------------------------------------------------------

if addConsoleCommand ~= nil then
    addConsoleCommand("wgStatus", "Show Weather Guard mode, the live sky, and the forecast reads",
        "consoleCommandStatus", weatherGuard)
end
