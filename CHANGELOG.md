# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Session details now show a duration line (recorded generation time, or the
  created→updated span for completed sessions), matching the web details.

### Fixed

- **Token Usage never moved** — the report reads a server-side fact store that
  lags the conversation list until a sync re-parses transcripts. The screen now
  checks `token_usage_status` on load and runs a silent incremental
  `token_usage_sync` when conversations are stale, mirroring the web
  dashboard's auto-sync, so numbers track new sessions.
- Session details token section web parity: the context window shows `— / max`
  when the cap is known but the used count is not (never a bogus `0 / max`),
  shows the used figure alone when there is no cap, and renders the percentage
  with one decimal place (`87.3%`).

### Changed

- Apple signing now uses an ignored local configuration instead of a committed
  development team identifier.
### Fixed

- Removed the transcript's temporary inset-calibration readout (the yellow
  overlay under the navigation bar) — the screenshots confirmed both the
  short-transcript gap and the head overlap are fixed, so the diagnostic
  shipped in v1.0.13 comes out.

## [1.0.1] - 2026-07-07

### Added

- **New agent types** — CodeBuddy, Kimi Code, and Pi.
- One-command release automation: `scripts/release.sh` bumps the version, files
  the release notes, tags, pushes, and creates a GitHub Release (with an
  optional `--archive` App Store Connect upload leg).
- This `CHANGELOG.md` as the home for version notes.

### Changed

- The app version is now single-sourced from `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in `project.yml`.

### Fixed

- Streaming no longer rebuilds the entire transcript on every token, keeping
  long sessions smooth.
- The pending approval card is restored after a mid-turn stream reconnect.
- `Info.plist` no longer hardcodes `CFBundleShortVersionString`, which had
  silently overridden `MARKETING_VERSION` so version bumps didn't take effect.

## [1.0.0] - 2026-06-07

### Added

- Initial Codeg for iOS release.
