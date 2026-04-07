# Lilt — Tasks

## ASAP

- [x] **Consolidate CLI audio path**: Extracted CLI to `src/lilt/cli.py`, uses `AudioEngine.play_article()` for playback, `generate_audio()` per chunk for `--save`. Eliminated afplay subprocess, temp files, direct mlx_audio imports.
- [x] **Add CLI test coverage**: 27 tests in `tests/test_cli.py` covering all commands, playback, save mode, argparse, error handling.
- [x] **Replace hardcoded WPM 150 in CLI**: All four occurrences replaced with `WPM_ESTIMATE`. Consistency test covers both tui.py and cli.py.
- [x] **Use `#!/usr/bin/env python3` shebang**: Fixed. Also added `[project.scripts]` pip entry point in pyproject.toml.
- [x] **Move `sounddevice` to core deps**: Moved from `[tui]` optional to core dependencies.
- [x] ~~**Use XDG data directory**~~: Reverted — data stays in project-relative `data/` by design (everything in one project folder).

## Backlog

- [ ] End-to-end smoke test: launch fresh `lilt` process, load real model, synthesize short clip, confirm playback
- [ ] **TUI dead code**: `tui.py:723` `entry.get("words", 0)` is a standalone expression (return value discarded). Likely should be `word_count = entry.get("words", 0)`.
- [ ] **TUI WAV export deduplication**: `tui.py:1023-1098` manually loops paragraphs and calls `generate_audio()`. Share logic with CLI `--save` path.
- [ ] **Shared ingest helper**: CLI `cmd_add` and TUI `_fetch_article` both implement URL-vs-clipboard ingest, title extraction, Apple News handling separately. Extract shared function.
- [ ] **Redundant imports in tui.py**: `import time` at line 5 (top-level) and again at line 342. `import re` inside method bodies at lines 331, 1026.
- [ ] **Expand ruff rules**: Current `["E", "F", "W", "I"]` misses deprecated annotations and redundant imports. Add `"UP"` (pyupgrade), `"TCH"` (type checking).
- [ ] **load_queue type validation**: `queue.py:16-17` returns raw JSON without validating it's a list.
- [ ] Pre-generated audio for instant playback
- [ ] Custom RSS feed subscriptions
- [ ] Apple Podcast integration (private feed)
- [ ] Unified ad-free feed (download existing podcasts, strip ads, merge into private feed)
