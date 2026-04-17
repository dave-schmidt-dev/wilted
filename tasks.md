# Lilt — Tasks

## Current Status

- [x] Unified `lilt` entry point for CLI + TUI
- [x] Shared `AudioEngine` path for playback and WAV export
- [x] Reading-list persistence in project-local `data/`
- [x] Background MP3 cache generation + hybrid cached/live playback
- [x] TUI playback controls: pause/resume, skip/rewind paragraph, transcript pane, voice/speed controls
- [x] Regression coverage for CLI, engine, ingest, cache, TUI, and configuration guardrails
- [ ] Manual audio-device playback verification is still missing for the true speaker output path

## Now

- [x] **Define a repeatable validation target**: `make validate` runs lint plus the guarded fast test suite via `uv run`
- [ ] **Run a packaging/install pass**: verify the current install flow on the supported Python/venv path and document any non-editable-install caveats cleanly
- [ ] **Manual playback check**: verify actual speaker output, pause/resume, stop, and status updates on a machine with a working audio device

## Next

- [ ] **RSS Phase 1 — data model**: add `data/feeds.json` plus feed metadata (`id`, title, feed URL, site URL, last checked, etag/last-modified, enabled)
- [ ] **RSS Phase 2 — fetch/sync**: poll feeds, dedupe entries by canonical URL/GUID, and convert new entries into normal queued articles
- [ ] **RSS Phase 3 — UX**: CLI/TUI flows for add/list/remove/refresh feeds and review newly imported entries before auto-queueing
- [ ] **Playback observability**: add lightweight file logging under `/tmp/lilt.log` with `RotatingFileHandler` and a `--debug` path, per project conventions
- [ ] **Release hygiene**: align `README.md`, `HISTORY.md`, and task tracking after each meaningful change so roadmap drift does not recur

## Later

- [ ] **Apple Podcast integration**: ingest from a private feed or exported subscription source, likely reusing the RSS feed plumbing
- [ ] **Unified private feed**: merge saved articles and podcast episodes into one ad-free listening queue/feed once feed ingestion is stable
- [ ] **Ad stripping / enrichment pipeline**: evaluate whether this belongs in Lilt or a separate feeder project before implementation

## Notes

- Backlog items from the April 7 code-quality pass are complete and no longer tracked here: shared ingest helper, shared WAV export, dead-code cleanup, redundant import cleanup, expanded Ruff rules, and queue/state type validation.
- The main open risk is now actual audio-device playback verification in the TUI/CLI path, not safe-path configuration inside the codebase.
- RSS work should reuse the existing queue/article cache model instead of creating a second content pipeline.
- Future tests should validate only the guarded paths we rely on. Native crash-probe tests do not belong in routine project validation.
