# FS25_WeatherGuard

**Realistic Farming - Weather Guard** is the shared weather truth for the Realistic Farming mod ecosystem. It is the 6th core service, alongside StateLedger, NetworkSync, MasterHUD, SettingsHub, and Time Guard.

**Version:** 1.0.0.0

## What it does

Six mods in the suite each read the sky privately and disagree with each other: the crop-stress forecast, the soil rain reads, the drilling advisory, the FarmTablet weather app, the hired-labor rain premium, and the NPC work factor. Weather Guard replaces those private guesses with one reading:

- **The current sky** in one call: rain scale, is-it-raining, cloud cover, temperature, humidity, and the weather *category* (a rain scalar cannot tell you "fog").
- **The forward forecast**, which FS25 really does expose. The base game fills about 9 days ahead and returns an honest `nil` past that edge.
- **One weather-mode dial** the whole suite shares, admin-gated and server-owned.

It centralizes the awkward parts too: the multi-field humidity probe that SeasonalCropStress carries today, the cloud-updater that lives on two different objects depending on who you ask, and the weather-type lookup that NPCFavor has been getting wrong since it was written.

## The one law: TRUTH, never CONSEQUENCE

Weather Guard **publishes the sky and never acts on it**. It never writes a consumer's state and never applies an effect. Every consumer keeps its own leaching, its own rain premium, its own price move, its own crop stress. This is the exact mirror of Time Guard's money fence: Time Guard owns *when*, never *how much*; Weather Guard owns *what the weather is*, never *what it does to you*.

## Handles

```
g_currentMission.weatherGuard   -- cross-mod handle, set in Mission00.load, nil on delete
g_weatherGuard                  -- getfenv(0) same-mod fallback for early-load access
g_WeatherGuard                  -- alias, the spelling the service brief uses
```

Consumers bind through the mission handle, neutral when absent:

```lua
local wg = (g_currentMission ~= nil and g_currentMission.weatherGuard) or g_weatherGuard
if wg ~= nil then
    local sky = wg:getCurrentSky()
    ...
end
```

## Public surface

| Method | Returns |
|--------|---------|
| `wg:getCurrentSky()` | `{ rainScale, isRaining, cloudCoverage, temperature, humidity, humidityDefaulted, weatherType, weatherTypeId }`, or `nil` when there is no environment |
| `wg:getForecastRain(daysAhead)` | forward rain intensity sampled at the current time of day, `nil` past the filled horizon |
| `wg:getForecastTemperature(daysAhead)` | forward temperature, `nil` past the filled horizon |
| `wg:getWeatherMode()` | the dial: `1` Real weather only, `2` Arid, `3` Normal (default), `4` Wet |
| `wg:getContext()` | `{ currentSky, mode, modeName, forecastHorizonDays, forecastHorizonMeasured, rwEnriching }` |
| `wg:getForecastHorizonDays()` | how many days are actually filled right now, `nil` when unmeasurable |
| `wg:isRealisticWeatherActive()` | whether RealisticWeather is running |
| `wg:requestWeatherMode(mode)` | ask the server to change the dial (admin-gated) |

**Deliberately absent** until their own feature ships, so a consumer falls back rather than trusting a stub: `getClimate(season)`, `getEffectiveRain(daysAhead)`, `getDroughtOutlook()` / `isDrySpell()`.

### Two rules the surface keeps

1. **Publish the real surface.** Nothing is advertised that is not built and certified against shipping source.
2. **No silent default on a load-bearing value.** An unreadable field returns `nil` and warns once; it never quietly reads as "dry" or "calm". The one exception is humidity's ruled `0.5` floor, and even that is flagged in the return as `humidityDefaulted`.

## The weather-mode dial

One setting, four positions, admin-only and server-authoritative because it is a shared-world control: one player's choice changes everyone's weather.

| Value | Meaning |
|-------|---------|
| 1 | Real weather only. Opts out of the grounded climate entirely. |
| 2 | Arid |
| 3 | Normal (default) |
| 4 | Wet |

Positions 2/3/4 mean the **real sky leads** and a grounded climate fills only the gaps (short months, past the forecast, no RealisticWeather). There is deliberately no "grounded only" position, because it would make the visible weather lie to the player.

## Core API connections (delegate-when-present, neutral when absent)

- **StateLedger** persists the weather mode when present; own XML fallback (`RealisticFarming_WeatherGuard.xml`) when absent.
- **NetworkSync** syncs the mode to clients, and carries the server-authoritative edit action (`WeatherGuard_SetMode`, admin-gated).
- **SettingsHub** the admin `weatherMode` dial via `registerModule` (`selfPersisted`, since Weather Guard owns its own save).
- **MasterHUD** not required (no overlay of its own).
- **Time Guard** not required. A future per-day forecast cache may ride `subscribeTick("day")` as a read-only subscriber.

## Console command

```
wgStatus    Show the mode, the live sky, the measured horizon, and 5 days of forecast reads
```

## Where the engine facts come from

FS25 withholds `Weather.lua`, `WeatherForecast.lua` and `Environment.lua` from the SDK dump, the Community LUADOC and FS25-lua-scripting. Every engine read in this mod is therefore certified against code that ships and runs:

- **RealisticWeather** (`Arrow-kb/FS25_RealisticWeather`, cloned locally as `../RealisticWeather-reference`) reimplements and overwrites the withheld classes, so anything it *uses* but never *defines* across its 42 source files is base game.
- **FS25_WeatherForecastHUD** declares no dependencies at all, so it runs against base-game methods with no RealisticWeather involved.

Two facts worth carrying forward:

- **The forecast is engine-synced to clients.** `Weather:sendInitialState` ships the whole `forecastItems` array to a joining client, and `fillWeatherForecast` broadcasts new items to everyone, both via `WeatherAddObjectEvent`. So the forecast getters are safe to read on any peer, and Weather Guard holding no forecast state of its own is the right design rather than a risk.
- **The native horizon is about 9 days, and RealisticWeather does not deepen it.** Confirmed from source (the fill loop runs to `currentMonotonicDay + 9`) and independently from measurement (9.29 to 9.71 days across four savegames carrying 26-36 mods and no RealisticWeather).

The forecast rides its own `WeatherAddObjectEvent`, *not* `WeatherStateEvent` (whose base payload is only `snowHeight` and `timeSinceLastRain`). A consumer should not expect forecast data on the state event.

## Self-test suite

```bash
bash tools/test/run.sh      # syntax + lint + the contract test suite
```

The contract suite locks the pure-logic half: neutral-when-absent returns, the horizon-nil edge, absent-getter fallbacks, mode gating, persistence and sync round-trips, and the read-only fence (a test that calls every getter and asserts the engine state is byte-identical afterwards). `tools/` is excluded from the mod zip.

## Build

```bash
bash build.sh           # build zip only
bash build.sh --deploy  # build and copy to the active mods directory
```
