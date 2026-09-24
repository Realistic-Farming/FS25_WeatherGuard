-- PR-120-positional_action_args_test.lua
--
-- PLAYER-REPORTS rows 120 (FarmTablet #140, J. Duke: "Real world weather does nothing on
-- a dedicated server") and 199 (keyed NetworkSync args): the weather-mode request sent a
-- keyed table, and NetworkSync's action event writes args[1..#args], which for a keyed
-- table is nothing; the server's handler then applied nil, which returns false with no
-- log. FarmTablet #150 fixed the tablet's silence; the request itself never carried the
-- mode until now. A host never saw it (requestAction applies in memory). The sender now
-- sends a positional array, the handler reads args[1], and the console says the mode
-- was requested when this machine is not the host.
--
-- THE ENTRY-POINT BAR DRIVES THE REAL TRANSPORT: a pure client's requestAction, then the
-- real RealisticFarmingActionEvent:writeStream into readStream on the server, then run,
-- then NetworkSync:_applyAction (its admin gate), then the handler WeatherGuard
-- registered. The transport is FS25_NetworkSync's own code, verbatim at 9e599be
-- (tools/test/lua/networksync_fixture). No row hands a table to a handler.
--
--!load: tools/test/lua/networksync_fixture/engine_stubs.lua, tools/test/lua/networksync_fixture/Logger.lua, tools/test/lua/networksync_fixture/RealisticFarmingSyncEvent.lua, tools/test/lua/networksync_fixture/NetworkSync.lua, src/Logger.lua, src/WeatherGuard.lua, src/weather/DroughtScanner.lua

local WARN = {}
WGLogger.warning = function(fmt, ...) WARN[#WARN + 1] = string.format(fmt, ...) end
WGLogger.info = function() end
WGLogger.debug = function() end
NSLogger.warning = function(fmt, ...) WARN[#WARN + 1] = "NS " .. string.format(fmt, ...) end
NSLogger.debug = function() end
NSLogger.error = function(fmt, ...) WARN[#WARN + 1] = "NS " .. string.format(fmt, ...) end

local function group(name, fn)
    local ok, err = pcall(fn)
    if not ok then T.ok(name .. " [group raised: " .. tostring(err) .. "]", false) end
end
local function warned(needle)
    local n = 0
    for _, l in ipairs(WARN) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ── engine state ────────────────────────────────────────────────────────────
local function user(id, master)
    return { id = id, master = master == true,
        getId = function(self) return self.id end,
        getIsMasterUser = function(self) return self.master end,
        getNickname = function(self) return "user" .. self.id end }
end
local ADMIN, PLAYER = user(1, true), user(2, false)
local function conn(u) return { user = u } end
local FROM_ADMIN, FROM_PLAYER, UNPLAYERED = conn(ADMIN), conn(PLAYER), conn(nil)

local W = {}
--- The server world: NetworkSync's core with WeatherGuard bound to it, its users.
local function serverWorld()
    W.sent, W.dirty = {}, {}
    W.nsServer = NetworkSync.new()
    g_currentMission = {
        _isServer = true, getIsServer = function(self) return self._isServer end,
        missionInfo = { savegameDirectory = "/save" },
        userManager = { getUserByConnection = function(_, c) return c and c.user or nil end },
        networkSync = W.nsServer,
    }
    g_networkSync = W.nsServer
    g_server = { broadcastEvent = function() end }
    g_client = nil
    g_stateLedger, g_settingsHub = nil, nil
    local wg = WeatherGuard.new()
    wg:_bindBedrock()
    W.wg = wg
    return wg
end
--- A pure client: its own NetworkSync core and guard; what it sends is recorded.
local function asClient(fn)
    local nsClient = NetworkSync.new()
    local mission = { _isServer = false, getIsServer = function(self) return self._isServer end,
                      missionInfo = { savegameDirectory = "/save" }, networkSync = nsClient }
    local saved = { g_currentMission, g_networkSync, g_server, g_client }
    g_currentMission, g_networkSync, g_server = mission, nsClient, nil
    g_client = { getServerConnection = function() return { sendEvent = function(_, ev) W.sent[#W.sent + 1] = ev end } end }
    local wgC = WeatherGuard.new()
    wgC:_bindBedrock()
    local ok, err = pcall(fn, wgC)
    g_currentMission, g_networkSync, g_server, g_client = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(err, 0) end
end
--- The engine's delivery: the sender's writeStream, the server's readStream (which
--- runs, applies through NetworkSync's admin gate and reaches the handler).
local function deliver(ev, connection)
    local s = NewTypedStream()
    ev:writeStream(s, nil)
    local rx = RealisticFarmingActionEvent.emptyNew()
    rx:readStream(s, connection)
    return rx, TypedStreamFaults(s)
end

-- ══════════════════════════════════════════════════════════════════════════
-- A. THE WIRE CARRIES THE MODE
-- ══════════════════════════════════════════════════════════════════════════
group("A", function()
    serverWorld()
    local clientDial = nil
    asClient(function(wgC) wgC:requestWeatherMode(2) clientDial = wgC:getWeatherMode() end)
    local ev = W.sent[1]
    T.eq("A1 a client's mode request sends one action event whose args are a positional array of one mode, and its own dial does not move",
        #W.sent .. "/" .. tostring(ev and ev.actionId) .. "/" .. tostring(ev and #ev.args) .. "/" .. tostring(ev and ev.args[1]) .. "/" .. tostring(clientDial), "1/" .. WeatherGuard.ACTION_MODE .. "/1/2/3")
    local s = NewTypedStream()
    ev:writeStream(s, nil)
    streamReadString(s)
    local n = streamReadInt32(s)
    T.eq("A2 the transport writes that one value (a keyed table wrote none)", n .. "/" .. tostring(RealisticFarmingSyncEvent.readValue(s)) .. "/" .. TypedStreamFaults(s), "1/2/0")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- B. THE MODE THROUGH THE REAL TRANSPORT
-- ══════════════════════════════════════════════════════════════════════════
group("B", function()
    local wg = serverWorld()
    asClient(function(wgC) wgC:requestWeatherMode(2) end)
    local _, faults = deliver(W.sent[1], FROM_ADMIN)
    T.eq("B1 an admin client's mode is applied on the server", wg:getWeatherMode() .. "/" .. faults, "2/0")
    asClient(function(wgC) wgC:requestWeatherMode(4) end)
    deliver(W.sent[2], FROM_PLAYER)
    T.eq("B2 a non-admin client's mode is denied by NetworkSync's admin gate, and logged", wg:getWeatherMode() .. "/" .. warned("denied"), "2/1")
    deliver(W.sent[2], UNPLAYERED)
    T.eq("B3 a connection with no user is denied", wg:getWeatherMode(), 2)
    wg:requestWeatherMode(4)
    T.eq("B4 the host's own path is unchanged: applied in memory, no event", wg:getWeatherMode() .. "/" .. #W.sent, "4/2")
    deliver(RealisticFarmingActionEvent.new(WeatherGuard.ACTION_MODE, {}), FROM_ADMIN)
    T.eq("B5 an empty array (what a keyed sender produced) applies nothing", wg:getWeatherMode(), 4)
    deliver(RealisticFarmingActionEvent.new(WeatherGuard.ACTION_MODE, { 9 }), FROM_ADMIN)
    T.eq("B6 a mode outside the dial's range is refused as before", wg:getWeatherMode() .. "/" .. warned("Rejected weather mode"), "4/1")
end)

-- ══════════════════════════════════════════════════════════════════════════
-- C. THE CONSOLE SAYS WHAT HAPPENED
-- ══════════════════════════════════════════════════════════════════════════
group("C", function()
    local wg = serverWorld()
    local out, dial = nil, nil
    asClient(function(wgC) out = wgC:consoleCommandSetMode("2") dial = wgC:getWeatherMode() end)
    T.eq("C1 on a pure client the console says the mode was requested, not applied, and the local dial still reads the old mode",
        tostring(out) .. "/" .. tostring(dial) .. "/" .. #W.sent, "Weather mode 2 requested; the server applies it if you are an admin, and every client follows/3/1")
    out = wg:consoleCommandSetMode("2")
    T.eq("C2 on the host the console applies and says so", tostring(out):sub(1, 17) .. "/" .. wg:getWeatherMode(), "Weather mode -> 2/2")
end)

T.summary()
