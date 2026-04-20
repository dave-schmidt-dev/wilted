# Wilted — Tasks

## Current Status

- [x] Unified `wilted` entry point for CLI + TUI
- [x] Shared `AudioEngine` path for playback and WAV export
- [x] Reading-list persistence in project-local `data/`
- [x] Background MP3 cache generation + hybrid cached/live playback
- [x] TUI playback controls: pause/resume, skip/rewind paragraph, transcript pane, voice/speed controls
- [x] Regression coverage for CLI, engine, ingest, cache, TUI, and configuration guardrails
- [x] Product direction clarified: Wilted is intended to become the primary personal audio surface for news, entertainment, and learning content
- [x] Subprocess e2e test suite (19 tests), real-DB TUI tests, ffmpeg round-trip, slow TTS tests
- [x] Manual audio-device playback verified (2026-04-19): TTS engine, audio pipeline, sounddevice output all confirmed working

## Now

- [ ] **Phase 5: Playlists + Polish** — dynamic/static playlists, TUI navigation, email report, nightly wrapper

## Done (previously "Now")

- [x] **Phase 4: Content Preparation** — podcast download (`download.py`), three-tier transcript ingestion (`transcribe.py` — RSS VTT/SRT/JSON, web page, local Parakeet), LLM ad detection with sliding window + ffmpeg cutting (`ads.py`), article promo removal, article TTS generation, `AudioEngine.play_file()` for podcast playback, `prepare.py` orchestrator with `wilted prepare` CLI. 573 tests green.
- [x] **Phase 3: Morning Report** — report assembly, TUI ReportScreen, selection history, source stats, CLI `wilted report` + `wilted feed stats`. Implemented by Vibe/Devstral-2, reviewed and bug-fixed by Claude Opus 4.6. Additional TUI bugs fixed 2026-04-20 (see HISTORY.md). 467 tests green.

- [x] **Define a repeatable validation target**: `make validate` runs lint plus the guarded fast test suite via `uv run`
- [x] **Dependency audit and install fix**: added missing deps (tqdm, rich), created `[llm]` optional extra, simplified install docs
- [x] **Manual playback check**: verified speaker output on 2026-04-19 — TTS generation, sounddevice playback, paragraph streaming all working
- [x] **Define a unified content model**: answered by v2 design spec (`plans/wilted-v2-design.md` §2). Schema implemented in `db.py`.
- [x] **Define playlist rules**: answered by v2 design spec (§7). Dynamic playlists (Work/Fun/Education) with 7-day expiry, static playlists with position ordering, keep flag on items.

## Next

- [ ] **Release hygiene**: align `README.md`, `HISTORY.md`, and task tracking after each meaningful change so roadmap drift does not recur
- [ ] **Release hygiene**: align `README.md`, `HISTORY.md`, and task tracking after each meaningful change so roadmap drift does not recur

## Later

- [ ] **Major-source curation**: identify which news sources should be pulled in automatically and what makes an article important enough to become audio
- [ ] **Dynamic playlisting**: let playlists build up and break down automatically based on freshness, source priority, listening history, and user overrides
- [ ] **Unified private feed**: merge saved articles, feeds, and podcast episodes into one listening system once ingest is stable
- [ ] **Cross-device briefing/export**: evaluate whether morning reports should remain local-only or optionally export/share to another surface

## Radio Mode (concept)

Always-on personal radio station that plays continuously throughout the day.

**Core behavior:**
- Continuous playback — fills airtime from queue, feeds, and discovered content so it never goes silent
- Priority interrupts — breaking/viral/important stories preempt current playback like a news bulletin, then resume where it left off
- Regular scans — poll feeds every ~15 minutes (tunable down to ~5 min depending on resource usage) for new content
- Auto-fill — when the queue runs dry, pull from discovered content to keep the stream going; prefer subscribed feeds, allow some broader discovery
- Time-of-day awareness — morning = news-heavy briefing, midday = lighter content, evening = education/entertainment

**Open design questions:**
- Interrupt threshold: what makes something interrupt-worthy? Relevance score, keywords, source reputation, LLM judgment, or a combination?
- Fill ranking: how to order auto-fill content when no explicit queue exists — freshness, relevance, source diversity?
- Resource budget: background scanning + TTS pre-generation needs to stay within reasonable CPU/memory/Metal GPU limits
- UI: how does the TUI represent radio mode vs. manual queue mode? Toggle? Separate screen?

## Notes

- Backlog items from the April 7 code-quality pass are complete and no longer tracked here: shared ingest helper, shared WAV export, dead-code cleanup, redundant import cleanup, expanded Ruff rules, and queue/state type validation.
- Audio playback verified on 2026-04-19 — TTS, sounddevice, and speaker output all confirmed working.
- Feed and podcast work should reuse a single listenable-item pipeline instead of creating parallel article and podcast subsystems.
- Playlisting and the morning report are now first-class roadmap items, not afterthoughts on top of a flat queue.
- Radio mode is the long-term vision — the feature that makes Wilted a personal audio experience rather than an article reader.
- Future tests should validate only the guarded paths we rely on. Native crash-probe tests do not belong in routine project validation.
