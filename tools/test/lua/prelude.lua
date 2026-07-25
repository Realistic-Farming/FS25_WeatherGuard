-- prelude.lua - minimal FS25 engine mock + tiny test framework.
-- Loaded first by run-tests.mjs, before any src module and the test file itself.
-- Only stubs what module load + the functions under test actually touch; extend as
-- new tests need more of the engine surface.

-- ── Lua 5.1 ↔ fengari (5.3) shims ──────────────────────────
unpack = unpack or table.unpack

-- getfenv was removed in 5.2. WeatherGuard uses getfenv(0) to reach the true
-- global table (the cross-mod handle publish + the RealisticWeather probe), so
-- the shim has to return a real table that reads and writes globals.
if getfenv == nil then
  function getfenv(_level) return _G end
end

-- ── FS25 engine globals (stubs) ────────────────────────────
-- Class(base): FS25's OO helper. Returns a metatable whose __index chains to base,
-- which is enough for `setmetatable({}, Class(Foo))` and method dispatch in tests.
function Class(base)
  local mt = {}
  mt.__index = base or mt
  return mt
end

-- Logging: the engine's log sink that the mod Logger wraps. Captured rather than
-- printed so log noise never collides with the ##TEST_ markers.
_LOG = { info = {}, warning = {}, error = {} }
Logging = {
  info    = function(msg, ...) table.insert(_LOG.info, tostring(msg)) end,
  warning = function(msg, ...) table.insert(_LOG.warning, tostring(msg)) end,
  error   = function(msg, ...) table.insert(_LOG.error, tostring(msg)) end,
}

-- WeatherType: a global enum of NUMBERS plus a name lookup, matching the engine
-- shape RealisticWeather compares against (WeatherType.SNOW / SUN / RAIN) and
-- converts with (FogSettings.lua getByName / getName).
WeatherType = {
  SUN = 1, RAIN = 2, CLOUDY = 3, SNOW = 4, HAIL = 5, FOG = 6,
}
local _weatherTypeNames = {
  [1] = "SUN", [2] = "RAIN", [3] = "CLOUDY", [4] = "SNOW", [5] = "HAIL", [6] = "FOG",
}
function WeatherType.getName(t) return _weatherTypeNames[t] end
function WeatherType.getByName(n)
  for k, v in pairs(_weatherTypeNames) do if v == n then return k end end
end

g_currentMission = nil   -- each test builds the world it needs
g_modIsLoaded = {}

g_i18n = { getText = function(_self, key) return key end }
g_messageCenter = { subscribe = function() end, unsubscribe = function() end, publish = function() end }

-- Minimal in-memory XMLFile mock: one shared store keyed by file path, so a
-- save followed by a load round-trips exactly like the real file would.
_XML_STORE = {}
XMLFile = {}
function XMLFile.create(_name, path, _root)
  _XML_STORE[path] = {}
  return setmetatable({ _path = path }, { __index = XMLFile })
end
function XMLFile.loadIfExists(_name, path, _root)
  if _XML_STORE[path] == nil then return nil end
  return setmetatable({ _path = path }, { __index = XMLFile })
end
function XMLFile:setInt(key, value)   _XML_STORE[self._path][key] = value end
function XMLFile:setFloat(key, value) _XML_STORE[self._path][key] = value end
function XMLFile:setBool(key, value)  _XML_STORE[self._path][key] = value end
function XMLFile:setString(key, value) _XML_STORE[self._path][key] = value end
function XMLFile:getInt(key, default)
  local v = _XML_STORE[self._path][key]
  if v == nil then return default end
  return v
end
function XMLFile:save() end
function XMLFile:delete() end

-- ── tiny test framework ────────────────────────────────────
-- Results are emitted as ##TEST_ lines that run-tests.mjs parses out of stdout, so
-- ordinary log noise is ignored.
T = { _pass = 0, _fail = 0 }

local function _pass(name)
  T._pass = T._pass + 1
  print("##TEST_PASS " .. name)
end
local function _fail(name, msg)
  T._fail = T._fail + 1
  print("##TEST_FAIL " .. name .. " :: " .. tostring(msg))
end

function T.ok(name, cond, msg)
  if cond then _pass(name) else _fail(name, msg or "expected truthy, got " .. tostring(cond)) end
end

function T.eq(name, got, want)
  if got == want then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want " .. tostring(want)) end
end

function T.near(name, got, want, tol)
  tol = tol or 1e-6
  if type(got) == "number" and math.abs(got - want) <= tol then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want ~" .. tostring(want) .. " (tol " .. tol .. ")") end
end

function T.isNil(name, got)
  if got == nil then _pass(name)
  else _fail(name, "expected nil, got " .. tostring(got)) end
end

function T.summary()
  print("##TEST_SUMMARY " .. T._pass .. " " .. T._fail)
end
