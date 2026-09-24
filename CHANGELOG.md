# Changelog

All notable changes to FS25_WeatherGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Added
- Changelog file established (suite ruling 2026-08-22).

### Fixed
- **The weather mode can now be changed by an admin on a dedicated server or from a joined client.** The request reached the server empty, so choosing a mode (Real world weather included) silently did nothing unless you were the host; this was the server half of the report FarmTablet fixed its tablet half of. The request now carries the mode the way the shared transport reads it; the console says the mode was requested when you are not the host.

## [1.0.0.0] - 2026-08-22

- First entry under changelog tracking.
