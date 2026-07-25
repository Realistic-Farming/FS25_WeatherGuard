-- =========================================================
-- FS25_WeatherGuard - Logger
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Small logging helper with a mod prefix and a debug gate.
-- Pattern mirrors the other Realistic Farming mods so log lines
-- are greppable by the "[WeatherGuard]" tag.
-- =========================================================

WGLogger = {}
WGLogger.PREFIX = "[WeatherGuard] "
WGLogger.debugEnabled = false

function WGLogger.info(msg, ...)
    if select("#", ...) > 0 then
        Logging.info(WGLogger.PREFIX .. msg, ...)
    else
        Logging.info(WGLogger.PREFIX .. msg)
    end
end

function WGLogger.warning(msg, ...)
    if select("#", ...) > 0 then
        Logging.warning(WGLogger.PREFIX .. msg, ...)
    else
        Logging.warning(WGLogger.PREFIX .. msg)
    end
end

function WGLogger.error(msg, ...)
    if select("#", ...) > 0 then
        Logging.error(WGLogger.PREFIX .. msg, ...)
    else
        Logging.error(WGLogger.PREFIX .. msg)
    end
end

function WGLogger.debug(msg, ...)
    if not WGLogger.debugEnabled then
        return
    end
    if select("#", ...) > 0 then
        Logging.info(WGLogger.PREFIX .. "[debug] " .. msg, ...)
    else
        Logging.info(WGLogger.PREFIX .. "[debug] " .. msg)
    end
end

-- One-shot warnings. A getter that cannot resolve a load-bearing engine field
-- must say so (delivery discipline: NO SILENT DEFAULT), but it must not spam a
-- per-frame consumer. Each distinct key logs once per session.
WGLogger._onceSeen = {}

function WGLogger.warnOnce(key, msg, ...)
    if WGLogger._onceSeen[key] then
        return
    end
    WGLogger._onceSeen[key] = true
    WGLogger.warning(msg, ...)
end
