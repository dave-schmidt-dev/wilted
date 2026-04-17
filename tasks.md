# Wilted — Tasks

## Current Status

- [x] Unified `wilted` entry point for CLI + TUI
- [x] Shared `AudioEngine` path for playback and WAV export
- [x] Reading-list persistence in project-local `data/`
- [x] Background MP3 cache generation + hybrid cached/live playback
- [x] TUI playback controls: pause/resume, skip/rewind paragraph, transcript pane, voice/speed controls
- [x] Regression coverage for CLI, engine, ingest, cache, TUI, and configuration guardrails
- [x] Product direction clarified: Wilted is intended to become the primary personal audio surface for news, entertainment, and learning content
- [ ] Manual audio-device playback verification is still missing for the true speaker output path

## Now

- [x] **Define a repeatable validation target**: `make validate` runs lint plus the guarded fast test suite via `uv run`
- [ ] **Run a packaging/install pass**: verify the current install flow on the supported Python/venv path and document any non-editable-install caveats cleanly
- [ ] **Manual playback check**: verify actual speaker output, pause/resume, stop, and status updates on a machine with a working audio device
- [ ] **Define a unified content model**: decide how articles, podcast episodes, playlists, and daily reports are represented in persistent storage before feed work begins
- [ ] **Define playlist rules**: specify how `News`, `Entertainment`, and `Learning` are assigned, overridden, and decayed over time

## Next

- [ ] **RSS/article feed Phase 1 — data model**: add `data/feeds.json` plus feed metadata (`id`, title, feed URL, site URL, last checked, etag/last-modified, enabled, default playlist`)
- [ ] **RSS/article feed Phase 2 — fetch/sync**: poll feeds, dedupe entries by canonical URL/GUID, convert new entries into normal listenable items, and tag them into playlists
- [ ] **RSS/article feed Phase 3 — UX**: CLI/TUI flows for add/list/remove/refresh feeds and review newly imported entries before queueing or playlist promotion
- [ ] **Podcast ingest Phase 1**: import existing podcast subscriptions through private feeds or exported subscriptions
- [ ] **Podcast ingest Phase 2**: store podcast episodes in the same listenable item pipeline as articles instead of a parallel subsystem
- [ ] **Ad stripping strategy**: decide whether ad removal happens in Wilted, in a feeder/importer layer, or not at all unless there is a clean and reliable path
- [ ] **Morning report Phase 1**: generate a daily summary of what arrived since yesterday, grouped by playlist, with direct jump targets to start playback
- [ ] **Morning report Phase 2**: rank items inside the report so the most important or interesting entries surface first
- [ ] **Playback observability**: add lightweight file logging under `/tmp/wilted.log` with `RotatingFileHandler` and a `--debug` path, per project conventions
- [ ] **Release hygiene**: align `README.md`, `HISTORY.md`, and task tracking after each meaningful change so roadmap drift does not recur

## Later

- [ ] **Major-source curation**: identify which news sources should be pulled in automatically and what makes an article important enough to become audio
- [ ] **Dynamic playlisting**: let playlists build up and break down automatically based on freshness, source priority, listening history, and user overrides
- [ ] **Unified private feed**: merge saved articles, feeds, and podcast episodes into one listening system once ingest is stable
- [ ] **Cross-device briefing/export**: evaluate whether morning reports should remain local-only or optionally export/share to another surface

## Notes

- Backlog items from the April 7 code-quality pass are complete and no longer tracked here: shared ingest helper, shared WAV export, dead-code cleanup, redundant import cleanup, expanded Ruff rules, and queue/state type validation.
- The main open risk is now actual audio-device playback verification in the TUI/CLI path, not safe-path configuration inside the codebase.
- Feed and podcast work should reuse a single listenable-item pipeline instead of creating parallel article and podcast subsystems.
- Playlisting and the morning report are now first-class roadmap items, not afterthoughts on top of a flat queue.
- Future tests should validate only the guarded paths we rely on. Native crash-probe tests do not belong in routine project validation.
