# Changelog

All notable changes to this project are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Negative caching: stable provider misses (`not_found`, `private`, `unauthorized`) are now cached for 5 minutes and transient ones (`rate_limited`, `cloudflare_required`) for 2 minutes, so private or missing profiles no longer refetch on every render.
- Stale-while-revalidate coalescing: when an identical provider fetch is already in flight (e.g. a profile re-render while the first batch is still loading), the backend serves the last cached response instead of duplicating the network work.
- Cloudflare fail-fast: when a provider hits a Cloudflare challenge and FlareSolverr is unavailable, the backend now returns a structured `cloudflare_required` response immediately instead of handing the challenge page to the HTML parsers.

### Fixed

- Stop discarding provider responses that arrive after the frontend's initial 15s wait: slow providers are now only flagged as slow, and their data appears as soon as the backend finishes fetching it — no page refresh needed.
- Only request providers the backend actually has registered and enabled (via `get_provider_configs`), so unimplemented or disabled providers no longer hang or pollute the loading state.

### Changed

- Provider fetches now run in a fixed priority order (Leetify, FACEIT, CSRep, CSTracker, CSStats — fast APIs first, scrapers last) on every backend path, matching the frontend's loading-segment order.
- Replace the generic loading bar with a segmented progress indicator: one segment per provider that fills in as its data arrives, with the next segment animating while the backend (which fetches serially on a single Lua thread) works on it. Hovering a segment shows the provider name and its current state.

## [0.4.5] - 2026-08-15

### Added

- Show the FACEIT nickname, lifetime match count, ELO, and K/D in a two-line compact profile summary.
- Replace the rectangular FACEIT level badge with a colored circular level indicator.

### Fixed

- Parse FACEIT's compact lifetime-stat keys so match count, K/D, ADR, headshots, win rate, and recent results continue to load.
- Keep the HTML lifetime-stat fallback available when the expected official API fields are missing.
- Position the FACEIT level-ring opening at the bottom to match FACEIT's visual language.

## [0.4.4] - 2026-08-14

### Fixed

- Point the plugin manifest at Millennium's current JSON schema location.

### Changed

- Replace cropped card previews with full Steam profile screenshots for the public listing.

## [0.4.3] - 2026-08-14

### Fixed

- Treat unavailable optional enrichment as informational output instead of a plugin warning.
- Prevent normal SCOPE.GG, FACEIT lifetime-stat, and recent K/D gaps from showing a yellow warning in Millennium.

### Added

- Public release documentation, real Steam screenshots, CI, and an installable archive script.

## [0.4.2] - 2026-08-14

### Fixed

- Keep match count and K/D inside narrow profile cards with responsive wrapping.

## [0.4.1] - 2026-08-14

### Changed

- Refined Aim presentation: `85–92` uses a target marker and values above `92` use an anomalous-rating marker.

## [0.4.0] - 2026-08-14

### Added

- Recent K/D and tracked-match count in the compact card.
- FACEIT level, match count, and rank colors.
- Premier rank colors and Aim rating markers.
- On-demand public CS2 inventory estimates using Steam Market prices.

### Fixed

- FACEIT lifetime-stat lookup now uses the discovered FACEIT nickname.

## [0.3.0] - 2026-08-14

### Changed

- Rebuilt the profile card with a Steam-native compact summary and detail tabs.

### Added

- Recent match form and match history.
- Graceful empty and partial-data states.
