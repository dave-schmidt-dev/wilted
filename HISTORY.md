## 2026-04-20 — Onboarding and ingestion commands

- **`wilted setup`** (`src/wilted/onboard.py`): Interactive first-run onboarding. Walks through: browsable starter feed suggestions (tech, security, science, podcasts — pick by number, 'all', or 'none'), custom feed URL entry, relevance keyword configuration, and optional first ingestion run. Handles Ctrl+C gracefully.
- **`wilted ingest`**: Runs the full nightly pipeline in sequence — discover → classify → report — with stage headers, progress output, and per-stage error isolation (one stage failing doesn't block the next). Supports `--skip-discover`, `--skip-classify`, `--skip-report` flags for partial runs.
- **`scripts/wilted-nightly.sh`**: Cron-ready wrapper with `flock`-based locking, project root detection, and `/tmp/wilted-nightly.log` summary logging. Drop into crontab as `0 2 * * * /path/to/scripts/wilted-nightly.sh`.
- **Starter feed catalog**: 9 curated feeds (Ars Technica, The Verge, Simon Willison, Pragmatic Engineer, Krebs, Schneier, Quanta, Darknet Diaries, Lex Fridman) with default playlist assignments.
- 12 new tests covering: starter feed data integrity, ingest pipeline stage execution/skipping/failure isolation, CLI dispatch and flag passthrough. 580 tests green.

## 2026-04-20 — Test suite audit, tiering, and native-lane isolation

- **Suite review artifact**: Added `plans/test-suite-review.md` with the recorded before/after baseline, lane timings, file-by-file inventory, hotspot notes, and keep/merge/eliminate decisions.
- **Tier markers + commands**: Added central `unit`, `integration`, `e2e`, `tui`, `slow`, and `native` markers in `tests/conftest.py` plus `Makefile` targets for `test-unit`, `test-integration`, `test-e2e`, `test-tui`, and `test-native`.
- **Collection-time pollution removed**: Stopped `tests/test_engine.py`, `tests/test_edge_cases.py`, and `tests/test_ingest.py` from mutating `sys.modules` at import time. Replaced them with opt-in fixtures so isolated lanes behave the same way as the full suite.
- **TUI lane fixed in isolation**: `tests/test_tui.py` now explicitly uses the audio-module stub fixture instead of depending on leaked `mlx_audio` stubs from unrelated test files.
- **Slow/native lane made safe**: Rewrote `tests/test_slow.py` to run real MLX/Kokoro probes in subprocesses. On this machine the native stack aborts during `mlx_audio.tts.utils` import, so the slow/native lane now fails explicitly instead of crashing Python or reporting masked empty-audio failures.
- **Minor streamlining**: Collapsed a handful of repetitive negative-case tests in `tests/test_cache.py` and `tests/test_preferences.py`, reducing the collected count from `576` to `571`.
- **Post-change baseline**:
  - `make validate`: `568 passed, 3 deselected` in `18.96s` wall clock
  - `make test-unit`: `197 passed` in `1.88s`
  - `make test-integration`: `293 passed` in `2.22s`
  - `make test-e2e`: `22 passed` in `5.37s`
  - `make test-tui`: `56 passed` in `11.18s`
  - `make test-slow` / `make test-native`: explicit failures with captured native crash details

## 2026-04-20 — Phase 4: Content Preparation pipeline

- **Podcast audio download** (`src/wilted/download.py`): HTTP streaming download for podcast enclosures with resume support via Range headers, Content-Type validation, Content-Disposition filename extraction, and 64KB chunked streaming. `DownloadError` exception. 14 tests.
- **Three-tier transcript ingestion** (`src/wilted/transcribe.py`): Cascading transcript sourcing — (1) RSS `podcast:transcript` tag with VTT/SRT/JSON parsers, (2) publisher website extraction via trafilatura with word-count heuristic to filter show notes, (3) local Parakeet 1.1B model fallback. `TranscriptSegment` dataclass (`start_s`, `end_s`, `text`). Save/load/text-join utilities. 36 tests.
- **Ad detection + cutting** (`src/wilted/ads.py`): LLM-based sliding window analysis with configurable chunk size and overlap, majority-vote overlap resolution, confidence threshold filtering, and adjacent segment merging. ffmpeg lossless audio cutting with concat demuxer. Article promotional content removal via LLM paragraph classification. 29 tests.
- **AudioEngine.play_file()** (`src/wilted/engine.py`): Multi-format podcast audio playback using ffmpeg as universal decoder to raw PCM float32 at 24kHz. Segment-level transcript tracking for TUI sync. `get_file_duration()` via ffprobe. Inherits existing pause/resume/stop controls. 7 new tests (50 total engine tests).
- **Prepare orchestrator** (`src/wilted/prepare.py`): `wilted prepare` CLI command. Processes selected items through the content preparation pipeline — podcasts (download → transcribe → ad detect → cut) and articles (promo removal → TTS generation). LLM loaded once for all items, unloaded after. Sequential model lifecycle. Status transitions: `selected → processing → ready` (or `error`). 16 tests.
- **CLI wiring**: `wilted prepare` command with `--no-llm`, `--model`, `--backend` flags. Removed `prepare` from stub subcommands.
- Total: 573 tests (up from 467), `make validate` green.

## 2026-04-20 — Phase 3 TUI bug fixes: ReportScreen footer, report→queue pipeline

- **ReportScreen footer missing**: Modal screen covered the main app's `Footer`. Replaced the inline `#report-help` label with a proper `yield Footer()` outside the dialog so key bindings are visible in the standard footer bar (`src/wilted/tui/screens/report.py`).
- **Accepted stories not appearing in queue** (two-part bug):
  1. `push_screen` was called without a dismiss callback — queue never refreshed after accepting. Added `_on_report_dismissed(accepted)` to `WiltedApp` and wired it as the callback (`src/wilted/tui/__init__.py`).
  2. `load_queue()` only fetched `status='ready'` items. Morning-report-accepted items are set to `status='selected'` by `_save_selections`. Fixed `load_queue()` to also include `selected` articles (not podcast episodes, which need Phase 4 audio download + transcription first) (`src/wilted/queue.py`).
- **Root cause of no transcript**: Confirmed via DB inspection that "selected" podcast episodes have `item_type='podcast_episode'` and no `transcript_file`. Article-type selected items do have transcripts from the discovery stage. The `item_type` guard in `load_queue()` prevents podcast episodes from appearing until Phase 4 prepares them.
- **6 new tests** added to `tests/test_queue.py` and `tests/test_tui.py` covering: selected article inclusion, selected podcast exclusion, ready podcast inclusion, dismiss callback behavior, and ReportScreen Footer presence. 467 tests green.

## 2026-04-19 — Post-commit fixes: ReportScreen UX, mlx_vlm compat, podcast discovery

- **ReportScreen UX overhaul**: Removed Score column (internal LLM metric, not user-facing) and empty first column. Widened dialog to 90%. Replaced `[x]`/`[ ]` checkboxes with `✓` marks. Added `priority=True` to key bindings to override parent app bindings (`s`=stop, `a`=add, `n`=next, `q`=quit were intercepting). Hooked `on_data_table_row_selected` for enter/space toggle since DataTable consumes those keys before screen bindings fire. Removed confusing Playlist cycling shortcut. Added in-dialog help line since the modal covers the app's Footer.
- **mlx_vlm GenerationResult compat**: `mlx_vlm.generate()` now returns a `GenerationResult` dataclass instead of a plain string. Fixed `MlxBackend.generate()` to extract `.text` and `.total_tokens` with fallback for older versions.
- **Default classification model**: Changed from nonexistent `gemma-4-12b-a4b-it-4bit` to `gemma-4-e4b-it-4bit` (cached locally, 4B params, sufficient for playlist/relevance/summary classification).
- **Podcast discovery limit**: Initial discovery of podcast feeds now caps at 5 most recent episodes to avoid ingesting hundreds of backlog episodes. Subsequent polls process all new entries normally.

## 2026-04-19 — Phase 3: Morning Report

- **Phase 3 implementation plan** (`plans/phase3-implementation.md`): Wrote detailed handoff spec for morning report (Tasks 3.1-3.4). Covers API contracts, TUI ReportScreen UX, selection history, source stats, test requirements, quality gates, and explicit "What NOT to do" guardrails.
- **Multi-agent tooling setup**: Configured Vibe, Cursor, Copilot CLI, and Gemini with shared instructions. Single canonical `~/.agent/AGENTS.md` (with YAML frontmatter for Cursor `.mdc` compat) symlinked to all six agents. Context7 MCP configured in Vibe, Cursor, and Copilot CLI. Project-level `AGENTS.md`, `.vibeignore`, `.cursorignore` created (all gitignored). Bash allowlists updated for `make validate`, `uv run`, `ruff` in Vibe and Cursor.
- **v2 task tracking updated**: Marked all 16 Phase 1 tasks as done in `plans/wilted-v2-tasks.md` (were stale/pending). Updated `tasks.md` to point at Phase 3 as current work.
- **Vibe Phase 3 implementation** (Mistral Vibe / Devstral-2): `report.py` (report assembly, selection history, source stats), `tui/screens/report.py` (ReportScreen), CLI wiring (`cmd_report`, `cmd_feed stats`), 20 unit tests, 3 e2e tests. 456 tests green, `make validate` passes.
- **Code review** (Claude Opus 4.6): Found 4 critical, 6 important, 4 minor issues across ReportScreen and report.py.
- **Bug fixes** (Claude Opus 4.6, parallel subagents): Fixed all critical and important issues:
  - C1: `_rebuild_table()` duplicated DataTable columns on every toggle (called `add_columns` after `clear()` which preserves columns)
  - C2: `get_report()` filtered items by `discovered_at` date instead of matching `run_report()`'s `status='classified'` criteria
  - C3: `_get_item_at_cursor()` didn't guard against playlist header rows — cursor actions affected wrong items
  - C4: `_save_selections()` always wrote `playlist_override` because `_original_playlist` was declared but never populated
  - I1: Deleted dead `src/wilted/tui.py` (1370-line monolithic duplicate of the decomposed `tui/` package)
  - I2: `_rebuild_table()` didn't preserve cursor position after toggle/cycle
  - I3: `_local_date_str()` used UTC instead of local timezone for report dates
  - I4: `test_accept_promotes_selected_items` mocked DB instead of using real SQLite per project convention
  - I6: `_check_unread_report_worker` called `run_report()` on every TUI launch instead of only when no report exists for today
- Total: 461 fast tests + 3 slow tests. `make validate` green.

## 2026-04-19 — E2e tests, test gap closure, trafilatura 2.0 fix, dependency audit

- **Subprocess e2e test suite** (`tests/test_e2e.py`): 19 tests that run `wilted` as a real subprocess with isolated `WILTED_PROJECT_ROOT`. Covers: CLI basics (version, list, voices, doctor, clear, remove), text processing (file and stdin), feed lifecycle (add/list/remove/duplicate), keyword lifecycle (add/list/remove), article lifecycle (add/list/remove/clear via local HTTP server), and discovery pipeline (no feeds, local RSS polling, dedup verification). Each test gets a fresh temp directory and SQLite database.
- **Real TTS + cache slow tests** (`tests/test_slow.py`): 3 tests requiring the Kokoro model and Apple Silicon. Verifies real audio generation returns non-empty float32, speed parameter affects output length, and full pipeline (TTS → MP3 → read back) with manifest validation. Run via `make test-slow`, excluded from `make validate`.
- **TUI real-DB tests**: 3 tests in `test_tui.py` that launch the TUI against a real (isolated) SQLite database without mocking `load_queue`. Verifies empty-state display, article rendering from DB, and clean quit.
- **ffmpeg round-trip test**: Direct subprocess ffmpeg encode/decode in `test_cache.py`. Verifies PCM → MP3 → PCM preserves audio energy and approximate length.
- **Trafilatura 2.0 compatibility fix**: `bare_extraction()` now returns a `Document` object instead of a dict. Fixed `ingest.py` and `discover.py` to use `getattr()` instead of `.get()`. Updated unit test mocks to use `SimpleNamespace` matching the new API. Bug was invisible to unit tests (mocked) but caught immediately by the e2e suite.
- **Dependency audit**: Added `tqdm` and `rich>=13.0` to core dependencies (were relied on but only present as transitive deps). Added `[llm]` optional extra for `mlx-vlm` and `llama-cpp-python`. Simplified README install instructions.
- **`make test-slow` target**: Runs slow tests in the mlx-audio venv with real model and hardware. `make validate` now uses `-m "not slow"` to exclude them.
- Total: 433 fast tests + 3 slow tests. `make validate` green.

## 2026-04-17 — Phase 2: Discovery + Classification pipeline

- **Feed management** (`src/wilted/feeds.py`): Full CRUD for RSS/Atom feed subscriptions. `wilted feed add/list/remove` CLI commands. Supports article and podcast feed types with optional default playlist assignment.
- **RSS discovery** (`src/wilted/discover.py`): Stage 1 pipeline — polls all enabled feeds via feedparser with conditional GET (ETag/If-Modified-Since). Three-tier dedup: GUID, canonical URL, SHA-256 content hash. Articles: full text fetched via trafilatura with RSS summary fallback. Podcasts: audio enclosure URL extracted from RSS. Partial failures (individual feed errors) logged and skipped without stopping other feeds.
- **LLM backend interface** (`src/wilted/llm.py`): `LLMBackend` Protocol with `MlxBackend` (mlx-vlm) and `GgufBackend` (llama-cpp-python) implementations. Load/generate/close lifecycle with explicit Metal GPU memory reclamation (`del model; gc.collect(); mx.metal.clear_cache()`). JSON response parser handles markdown fences, surrounding text, and nested objects.
- **Classification stage** (`src/wilted/classify.py`): Stage 2 pipeline — loads LLM once, classifies all fetched items. Each item receives: playlist assignment (Work/Fun/Education), relevance score (0.0-1.0), and 2-3 sentence summary. System prompt with few-shot examples. User preference keywords integrated into relevance scoring.
- **Preference keywords** (`src/wilted/preferences.py`): Keyword CRUD with weighted relevance scoring. `wilted keyword add/list/remove` CLI commands. Keywords formatted into LLM classification prompts.
- **LLM benchmarking** (`wilted benchmark classify --models "model1,model2"`): Runs multiple models against a labeled 10-item test set. Reports accuracy, latency, and token counts in tabular format.
- **CLI wiring**: Removed `discover`, `classify`, `feed`, `keyword`, `benchmark` from Phase 2+ stubs. Real dispatch to implemented modules.
- **Tests**: 122 new tests covering feeds CRUD, RSS polling with mocked feeds, dedup logic, entry extractors, LLM protocol conformance, JSON parsing, classification output validation, keyword integration, CLI subcommands. Total: 409 tests, `make validate` green.

## 2026-04-17 — Salad Palette theme and NerdFont icon system

- Applied the **Salad Palette** custom Textual theme: Dark Sea Green primary, Sage secondary, Cream accent, Ebony background, Muted Red errors, Bright Lime success. Registered as a named theme via `register_theme()` so all Textual widgets pick up the palette automatically.
- Added **NerdFont icon system** with Unicode fallback. `ICONS` dict in `__init__.py` resolves at import time based on `NERD_FONTS=1` env var. TUI code references semantic icon names (`ICONS["playing"]`), not raw codepoints.
- Renamed TUI panels: "Reading List" → **The Larder**, "Now Playing" → **The Plate**. Thematic naming from the Wilted design language.
- Upgraded progress bar from `━╌` segments to **fractional block characters** (`▏▎▍▌▋▊▉█░`) for smooth visual fill.
- Styled transcript pane: current paragraph highlighted in Cream (`#F2E8CF`), surrounding paragraphs in Sage (`#A9BA9D`).
- Added `🥬` lettuce emoji to app title bar and article-add toast messages.
- Updated footer key colors and panel borders to use the Salad Palette via Textual theme variables.
- Updated tests to reference `ICONS` dict instead of hardcoded Unicode codepoints.
- Updated README with theme documentation and NerdFont setup instructions.

## 2026-04-17 — Rename project from lilt to wilted

- Renamed the package, CLI entry point, root shim, docs, tests, and repo references from `lilt` to `wilted`.
- Renamed the shared Python package path from `src/lilt/` to `src/wilted/` and updated imports throughout the project.
- Renamed internal app and environment-variable references so the codebase no longer carries `lilt` identifiers.
- Updated local project paths and Git remote references to match the renamed GitHub repository.
- Validation after the rename passed with `263` tests green.

## 2026-04-17 — Product vision rewrite and roadmap realignment

- Rewrote the top-level product framing in `README.md` from a narrow local article reader into a broader local-first personal audio system for news, entertainment, and learning.
- Added explicit vision and product-direction language covering unified ingest, playlist-based organization, podcast inclusion, article-to-audio conversion, and a morning report that surfaces the most interesting items first.
- Realigned `tasks.md` around the new north star: unified content model, playlist rules, podcast ingest, daily briefing, dynamic playlists, and major-source curation.
- Kept current implementation status explicit so the docs still reflect reality: Wilted is article-first today, with the broader personal-audio workflow still ahead on the roadmap.

## 2026-04-17 — Validation surface cleanup

- Removed `tests/test_e2e.py` from routine project validation. The file had become a native-runtime probe rather than a guardrail for the safe paths Wilted actually uses.
- Simplified `Makefile` targets so `make validate` now means lint plus the guarded fast suite only.
- Updated project docs to make the validation policy explicit: test the serialized MLX access path, the in-lock generator materialization path, and the main-thread `tqdm` initialization path; avoid adding default tests that only probe known-bad native MLX failure modes.

## 2026-04-17 — TUI startup hardening and bug-record correction

- Added a main-thread `tqdm.tqdm.get_lock()` initialization in `wilted.cli:main()` before `WiltedApp().run()`. This prevents first-run Hugging Face downloads from initializing `tqdm`'s multiprocessing lock inside a Textual worker thread.
- Split the crash diagnosis into two bug classes in project tracking:
  - concurrent MLX/Metal access, mitigated by `_model_lock` and in-lock generator materialization
  - `fds_to_keep` failure during worker-thread download setup, caused by `tqdm`/`multiprocessing.resource_tracker`
- Corrected the earlier root-cause attribution for the `fds_to_keep` issue: the subprocess is spawned by Python's multiprocessing lock initialization through `tqdm`, not by `hf_xet`. The xet-specific guards remain as defense-in-depth rather than the primary fix.

## 2026-04-17 — Docs sync and roadmap cleanup

- Synced project tracking docs with the actual code state after the April 7-8 implementation work.
- Removed stale completed items from `tasks.md` that were already shipped: shared ingest helper, shared WAV export path, queue type validation, dead-code cleanup, redundant import cleanup, and expanded Ruff rules.
- Reframed the roadmap around the real remaining work: end-to-end playback validation, validation parity/repeatability, RSS subscriptions, and podcast/private-feed follow-ons.
- Updated `README.md` roadmap language to match the current implementation status and avoid keeping a stale hard-coded test-count claim in the project structure section.

## 2026-04-17 — Validation target + roadmap cleanup

- Added a repeatable repo-local validation entry point in `Makefile` using `uv run`.
- Updated roadmap/task docs to distinguish guarded routine validation from separate manual playback checks.
- Expanded the RSS roadmap into phased work: feed data model, polling/dedupe/import, and CLI/TUI management.

## 2026-04-08 — Fix segfault + voice modal UX

- **Segfault fix**: Resolved crash caused by MLX thread-safety issues. Three changes in `engine.py`:
  1. `load_model()` now uses double-checked locking with `_model_lock` — prevents two workers from simultaneously initializing the Metal GPU model.
  2. Segment iteration and `np.array(segment.audio)` conversion moved inside `_model_lock` in `generate_and_play()`, `play_article()`, and `generate_audio()` — prevents concurrent Metal access when background generation and playback overlap.
  3. Generators from `_normalize_segments()` are now materialized (as lists) inside the lock, ensuring lazy MLX computation doesn't escape the critical section.
- **Voice modal UX**: Arrow keys now work — `table.focus()` on mount gives the DataTable keyboard focus. Up/down navigates voices, left/right adjusts speed. Enter confirms (via `on_data_table_row_selected` handler, since DataTable consumes Enter before screen-level binding).
- **Speed change feedback**: Status message during playback shows "Speed: 1.3x — next paragraph" to indicate the change isn't immediate.
- **Post-commit hook**: Added `.git/hooks/post-commit` to auto-reinstall the package after each commit (workaround for non-editable install requirement on Python 3.13).
- Test count: 258 (253 fast + 5 slow).

## 2026-04-08 — Hybrid playback + enhanced TUI (Phases 3-4)

- **Hybrid playback**: Playback loop checks per-paragraph MP3 cache before generating TTS. Cache hit plays via `engine.play_audio()` (status: "Playing (cached)"); miss falls back to `generate_and_play()`. New `is_paragraph_cached()` validates manifest params AND file existence, works with both "generating" and "complete" cache status for mid-generation hits.
- **While-loop refactor**: Replaced `for` loop in `_play_article` with `while` loop to support backward navigation. `_rewind_to` instance variable set by rewind action, picked up at loop top.
- **Paragraph navigation**: `[` rewinds to previous paragraph, `]` / `right` skips forward. Rewind sets `_rewind_to` and stops current audio; while loop jumps to target index.
- **Generation pausing**: `_generation_paused` now wired: set `True` in `_start_playback`, `False` in `action_stop` and `_on_article_completed`. Background generation worker spin-waits while flag is set, avoiding model lock contention during playback. `_trigger_generation()` restarts worker on stop/completion.
- **Inline speed keys**: `-` and `+`/`=` adjust speed 0.1x directly from the main app (0.5x-2.0x range), no modal needed.
- **PlaybackBar widget**: Replaced `ProgressBar` + time_remaining label with a single Static-based bar showing state icon (▶/⏸), text progress bar (━/╌), paragraph counter (42/120), and mm:ss countdown timer.
- **Live progress timer**: 1-second `set_interval` ticks down `_estimated_remaining_secs` and refreshes the PlaybackBar. Resyncs at each paragraph boundary from word count. Pauses when playback paused.
- **Transcript pane**: Shows context window (1 prev dimmed, current bold, 2 next dim italic) with Rich markup. Text escaped via `rich.markup.escape()`. Transcript area uses `height: 1fr` for flexible sizing.
- **Status line priority system**: `_set_status()` accepts priority (`_STATUS_LOW`/`_STATUS_MEDIUM`/`_STATUS_HIGH`). Higher-priority messages hold for 2 seconds, blocking lower-priority overwrites. All 30+ calls updated: errors=HIGH, user actions=MEDIUM, routine=LOW.
- **Engine**: Added `play_audio(audio_np)` public method for playing pre-generated/cached audio with pause/resume/stop support.
- Test count: 257 (252 fast + 5 slow). 33 new tests covering all Phase 3-4 features.

## 2026-04-08 — Audio cache infrastructure + engine refactor (Phases 1-2)

- **Audio cache module** (`src/wilted/cache.py`): Per-paragraph MP3 caching with atomic manifest tracking. Functions: `check_ffmpeg`, `save_audio`/`load_audio`, `save_manifest`/`load_manifest`, `is_cache_valid`, `clear_cache`, `generate_article_cache`. Requires ffmpeg for MP3 encoding via mlx_audio.
- **Engine refactor**: Added `threading.Lock` (`_model_lock`) to serialize all `_model.generate()` calls — prevents race conditions between playback and background generation. `generate_audio()` now accepts optional explicit `voice`, `lang`, `speed` keyword params (falls back to instance attrs for CLI compatibility). `_sample_offset` reset to 0 at start of each `_play_audio()` call for accurate progress tracking.
- **Queue cleanup hooks**: `remove_article()`, `mark_completed()`, and `clear_queue()` now call `clear_cache()` to remove audio files when articles are removed.
- **Background generation worker**: TUI spawns `_generate_cache()` worker after model preload and on article add. Iterates queue, generates MP3 cache for uncached articles. Supports cancellation and pause coordination via `_generation_paused` flag (wired in Phase 3). Status line shows generation progress when playback is idle.
- **Dead code removal**: Removed unused `resume_seg` parameter from `_start_playback()` and `_play_article()`. Removed `_segment_in_paragraph` instance variable.
- **Test fixtures**: `AUDIO_DIR` redirected to temp directory in `conftest.py`. 37 new tests covering cache functions, `generate_article_cache`, explicit engine params, model lock, and queue cleanup integration.
- Test count: 224 (219 fast + 5 slow). Reviewed by contrarian; 6 findings fixed (variable shadowing, incomplete cache validation, redundant MP3 re-read, missing ffmpeg check, stale import, dead `import time`).

## 2026-04-07 — Fix PROJECT_ROOT resolution for non-editable installs

- **Bug**: TUI showed empty queue despite `data/queue.json` containing 3 articles. Root cause: `PROJECT_ROOT` in `__init__.py` used a hardcoded `Path(__file__).parent.parent.parent` traversal that only works from `src/wilted/`. When installed to `.venv/lib/python3.13/site-packages/wilted/`, the three-parent walk resolves to `.venv/lib/python3.13/` — wrong directory.
- **Fix**: Replaced hardcoded parent traversal with upward walk that searches for `pyproject.toml` as the project root marker. Works from both `src/wilted/` (development) and `site-packages/wilted/` (installed) because `.venv/` is a subdirectory of the project root.
- **Env var override**: Added `WILTED_PROJECT_ROOT` for explicit override when auto-detection isn't viable.
- **Python 3.13 `.pth` bug**: Editable installs (`pip install -e .`) are broken on Homebrew Python 3.13 — the interpreter skips ALL `.pth` files during site initialization ("Skipping hidden .pth file" in verbose output), so the `__editable__.wilted-0.2.0.pth` file is never processed. Workaround: use regular `pip install --no-deps .` (non-editable). The upward `pyproject.toml` walk makes this work correctly.
- Added 3 regression tests for `PROJECT_ROOT` resolution (pyproject.toml detection, DATA_DIR derivation, env var override). Added `.python-version` to `.gitignore`. Deleted stray `=0.9.4` junk file.
- Test count: 188 (183 fast + 5 slow).

## 2026-04-07 — Backlog Phases 1-3 (code quality)

- **Phase 1 — Quick fixes**: Deleted dead `entry.get("words", 0)` expression in tui.py `_play_article()`. Added `isinstance` type validation to `load_queue()` (returns `[]` for non-list JSON) and `load_state()` (returns `{}` for non-dict JSON). Removed 3 redundant local imports in tui.py (2x `import re`, 1x `import time`), added `import re` at module top. Expanded ruff rules with `"UP"` (pyupgrade) and `"TCH"` (type-checking imports).
- **Phase 2 — Refactoring**: Extracted `isolated_data` test fixture to shared `tests/conftest.py`, removing duplicates from 4 test files. Created `src/wilted/ingest.py` with `resolve_article()` and `ArticleResult` — shared ingest helper used by both CLI `cmd_add` and TUI `_fetch_article`. Eliminates double HTTP fetch for title by using `trafilatura.bare_extraction()`. Created `export_to_wav()` in engine.py — shared WAV export used by both CLI `--save` and TUI export. Both callers now delegate chunking strategy to the shared function.
- **Phase 3 — Safe-path validation**: Added validation around the guarded application paths and kept the default suite on fast, deterministic checks instead of native crash probing.
- Test count: 165 at the time. Ruff clean. Phase 4 (roadmap features) deferred to future sessions.

## 2026-04-07 (v0.2.0)

- **CLI consolidation**: Extracted all CLI logic from root `wilted` script into `src/wilted/cli.py`. CLI now uses `AudioEngine.play_article()` for playback and `AudioEngine.generate_audio()` per chunk for `--save` mode. Eliminated: afplay subprocess, temp file creation/cleanup, direct mlx_audio imports, atexit handler. Root `wilted` script reduced to a thin shim.
- **Packaged entry point**: Added `[project.scripts] wilted = "wilted.cli:main"` to pyproject.toml. Users get a proper pip-installed `wilted` command with the correct Python interpreter. Shell alias still works for backward compat.
- **CLI test coverage**: 27 new tests in `tests/test_cli.py` covering all commands (add, list, remove, clear, play, next, direct), playback/save modes, KeyboardInterrupt handling, argparse dispatch, and CLIError conversion. Total test count: 172.
- **Hardcoded WPM fix**: Replaced all four `/ 150` literals in CLI with `WPM_ESTIMATE` constant. Extended consistency test to scan both tui.py and cli.py.
- **Shebang fix**: Replaced hardcoded `#!/Users/dave/.venvs/mlx-audio/bin/python3` with `#!/usr/bin/env python3`.
- **sounddevice to core deps**: Moved from `[project.optional-dependencies] tui` to `[project] dependencies`. It's ~170KB with PortAudio bundled on macOS, and engine.py imports it unconditionally.
- **XDG data directory**: Implemented then reverted. Data stays in project-relative `data/` by design — everything lives in one project folder.
- **Version tracking**: Added `__version__ = "0.2.0"` to `src/wilted/__init__.py` and `--version` flag to CLI.
- **Callable annotation**: Fixed deprecated lowercase `callable` type hint in `engine.py:play_article()` to `Callable | None`.
- **CLIError pattern**: CLI commands now raise `CLIError` instead of calling `sys.exit(1)` deep in business logic. `run_cli()` catches at the top level and converts to sys.exit.
- Plan reviewed by contrarian (2 rounds) and Codex (GPT-5.4 xhigh). 34 findings evaluated across all reviews; 20 accepted, 14 rejected.

## 2026-04-07

- Fixed persistent `bad value(s) in fds_to_keep` playback error. Root cause: the first-time Hugging Face download path entered `snapshot_download()` inside a Textual worker, which initialized `tqdm`'s multiprocessing lock and spawned Python's `resource_tracker` subprocess from the worker thread. That fork/exec path failed on the inherited file-descriptor set. Mitigation at the time was a layered approach: (1) `HF_HUB_OFFLINE=1` when the model is cached, bypassing the download stack; (2) `HF_HUB_DISABLE_XET=1`; (3) `sys.modules["hf_xet"] = None` to block import; (4) patching `huggingface_hub.constants`. The xet layers were retained as defense-in-depth, but the primary causal fix was bypassing the worker-thread download path. Also fixed the CLI `_play_text()` path which was missing the workaround entirely.
- Added 2 regression tests for offline-mode model loading (cached and uncached paths). 139 total tests.
- Added ruff as a dev dependency. Ran lint + format across entire codebase — fixed import ordering, removed unused imports/variables, formatted all files. Added `[tool.ruff]` config to `pyproject.toml`.
- Created `tasks.md` with ASAP tech debt items from contrarian review (CLI consolidation, CLI tests, hardcoded WPM, shebang, sounddevice dep, XDG data dir).

## 2026-04-06

- Created wilted project (renamed from readarticle).
- Consolidated all files into `~/Documents/Projects/wilted/` — script, docs, and runtime data in one place.
- Runtime data lives in `data/` (gitignored). No more scattered files across `~/.local/`.
- CLI accessible via shell alias (`alias wilted='~/Documents/Projects/wilted/wilted'`).
- Created GitHub repo at dave-schmidt-dev/wilted.
- Textual TUI plan reviewed by contrarian (2 rounds) and Codex (GPT-5.4). Full plan at TUI_PLAN.md.
- Phase 1: Extracted shared library (`src/wilted/`) from monolithic script. Four modules: `text.py`, `fetch.py`, `queue.py`, `state.py`. Added `pyproject.toml` for editable install. Atomic writes for queue and state persistence. 59 unit tests.
- Phase 2: Built AudioEngine (`src/wilted/engine.py`) with sounddevice OutputStream playback, pause/resume/stop via threading events, paragraph-based TTS generation, and progress tracking. Built Textual TUI (`wilted-tui`) with two-panel layout, all key bindings, voice settings modal, resume support, and clipboard add. 19 additional tests (78 total).
- Phase 3: Hardened error handling across all modules. Added corrupt JSON recovery in `load_queue()`. Added `generate_and_play()` method to AudioEngine (fixes TUI integration bug). Wrapped sounddevice operations with PortAudioError catch. Wrapped model loading with descriptive error propagation. 24 edge case tests covering corrupt files, missing articles, concurrent access, and engine errors (102 total).
- TUI feature parity: Made the TUI a complete CLI replacement. Fixed `lang_code` bug (engine was silently ignoring language setting). Extracted `_normalize_segments` helper. Added `generate_audio()` method for WAV export. Added `LANGUAGES` and `WPM_ESTIMATE` constants. Extended VoiceSettingsScreen with language selector (American, British, Japanese, Chinese). Added AddArticleScreen modal for URL-based article fetching with progress indicators and add-and-play (ctrl+p). Added TextPreviewScreen for viewing article text. Added ConfirmScreen (used by delete and clear-all). Added WAV export with paragraph-level progress. Fixed cursor preservation in queue refresh. Plan reviewed by contrarian; 16 findings evaluated (12 accepted, 1 rejected, 3 noted). 127 total tests.
- Merged CLI and TUI into single entry point: `wilted` with no args launches the TUI, with flags runs CLI commands. Moved TUI code into `src/wilted/tui.py`. Eliminated `wilted-tui` standalone script and SourceFileLoader test hack. One command, one alias.
- Fixed AddArticleScreen bug: `ModalScreen` doesn't have `call_from_thread` (only `App` does). Worker silently crashed. Fixed with `self.app.call_from_thread()`. Changed `p` binding to `ctrl+p` since Input widget captures bare letter keys.
- Fixed modal click handling in the Textual TUI. Replaced keyboard-hint `Label` pseudo-buttons with real `Button` widgets in add, confirm, voice, and preview dialogs; kept keyboard bindings intact; disabled add-dialog controls during background fetches. Constrained the voice settings modal so its action buttons stay inside the visible dialog on smaller terminals. Added pilot click regression tests for modal buttons. `tests/test_tui.py`: 21 passed under Python 3.13 with `PYTHONPATH=src /tmp/wilted-test-env/bin/pytest tests/test_tui.py`.
- Cleaned up the text preview footer to avoid duplicate close affordances. The preview modal now shows a single clickable `Close` button plus the word count, instead of repeating “Close” in the adjacent label.
- Hardened model loading against Hugging Face Xet download issues. `AudioEngine.load_model()` now disables Xet-backed Hub downloads by default before importing `mlx_audio`, forcing standard HTTP downloads unless `WILTED_ENABLE_HF_XET=1` is set. This was driven by repeated playback failures showing `bad value(s) in fds_to_keep` and two Python interpreter crashes during direct `mlx_audio` model-load probes before the workaround was added.
- Fixed a second audio-path bug exposed by real runtime testing: `mlx_audio` returns a generator from `model.generate()`, but `wilted` was treating that like a single segment object. `_normalize_segments()` now preserves generator/iterable segment streams, and engine tests cover generator output for both `generate_audio()` and `generate_and_play()`.
- Validation completed tonight:
  - `PYTHONPATH=src ~/.venvs/mlx-audio/bin/python3 -m pytest tests/test_engine.py` -> 25 passed
  - `PYTHONPATH=src /tmp/wilted-test-env/bin/pytest tests/test_tui.py` -> 21 passed
  - Direct fresh-process smoke check in the real `mlx-audio` venv: `AudioEngine.generate_audio("Hello world. This is a short test.")` succeeded and returned 67200 `float32` samples.
- Validation debt remains and needs full end-to-end coverage ASAP. The current suite was too mocked around the real failure boundaries:
  - TUI tests originally verified modal opening/keyboard flows but not actual button clicks.
  - Engine tests originally mocked `model.generate()` with a plain segment object, not the generator shape returned by real `mlx_audio`.
  - There is still no true end-to-end smoke test that launches a fresh `wilted` process, loads the real model, synthesizes a short clip, and confirms playback-path behavior without heavy mocking.
