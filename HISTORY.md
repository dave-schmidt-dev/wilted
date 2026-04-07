## 2026-04-07 — Fix PROJECT_ROOT resolution for non-editable installs

- **Bug**: TUI showed empty queue despite `data/queue.json` containing 3 articles. Root cause: `PROJECT_ROOT` in `__init__.py` used a hardcoded `Path(__file__).parent.parent.parent` traversal that only works from `src/lilt/`. When installed to `.venv/lib/python3.13/site-packages/lilt/`, the three-parent walk resolves to `.venv/lib/python3.13/` — wrong directory.
- **Fix**: Replaced hardcoded parent traversal with upward walk that searches for `pyproject.toml` as the project root marker. Works from both `src/lilt/` (development) and `site-packages/lilt/` (installed) because `.venv/` is a subdirectory of the project root.
- **Env var override**: Added `LILT_PROJECT_ROOT` for explicit override when auto-detection isn't viable.
- **Python 3.13 `.pth` bug**: Editable installs (`pip install -e .`) are broken on Homebrew Python 3.13 — the interpreter skips ALL `.pth` files during site initialization ("Skipping hidden .pth file" in verbose output), so the `__editable__.lilt-0.2.0.pth` file is never processed. Workaround: use regular `pip install --no-deps .` (non-editable). The upward `pyproject.toml` walk makes this work correctly.
- Added 3 regression tests for `PROJECT_ROOT` resolution (pyproject.toml detection, DATA_DIR derivation, env var override). Added `.python-version` to `.gitignore`. Deleted stray `=0.9.4` junk file.
- Test count: 188 (183 fast + 5 slow).

## 2026-04-07 — Backlog Phases 1-3 (code quality)

- **Phase 1 — Quick fixes**: Deleted dead `entry.get("words", 0)` expression in tui.py `_play_article()`. Added `isinstance` type validation to `load_queue()` (returns `[]` for non-list JSON) and `load_state()` (returns `{}` for non-dict JSON). Removed 3 redundant local imports in tui.py (2x `import re`, 1x `import time`), added `import re` at module top. Expanded ruff rules with `"UP"` (pyupgrade) and `"TCH"` (type-checking imports).
- **Phase 2 — Refactoring**: Extracted `isolated_data` test fixture to shared `tests/conftest.py`, removing duplicates from 4 test files. Created `src/lilt/ingest.py` with `resolve_article()` and `ArticleResult` — shared ingest helper used by both CLI `cmd_add` and TUI `_fetch_article`. Eliminates double HTTP fetch for title by using `trafilatura.bare_extraction()`. Created `export_to_wav()` in engine.py — shared WAV export used by both CLI `--save` and TUI export. Both callers now delegate chunking strategy to the shared function.
- **Phase 3 — E2E smoke tests**: Created `tests/test_e2e.py` with 5 `@pytest.mark.slow` tests: subprocess smoke (stdin + version), real model load, short clip generation (validates non-silence float32), duration bounds check. Default `pytest` skips slow tests via `addopts = "-m 'not slow'"`.
- Test count: 165 (160 fast + 5 slow). Ruff clean. Phase 4 (roadmap features) deferred to future sessions.

## 2026-04-07 (v0.2.0)

- **CLI consolidation**: Extracted all CLI logic from root `lilt` script into `src/lilt/cli.py`. CLI now uses `AudioEngine.play_article()` for playback and `AudioEngine.generate_audio()` per chunk for `--save` mode. Eliminated: afplay subprocess, temp file creation/cleanup, direct mlx_audio imports, atexit handler. Root `lilt` script reduced to a thin shim.
- **Packaged entry point**: Added `[project.scripts] lilt = "lilt.cli:main"` to pyproject.toml. Users get a proper pip-installed `lilt` command with the correct Python interpreter. Shell alias still works for backward compat.
- **CLI test coverage**: 27 new tests in `tests/test_cli.py` covering all commands (add, list, remove, clear, play, next, direct), playback/save modes, KeyboardInterrupt handling, argparse dispatch, and CLIError conversion. Total test count: 172.
- **Hardcoded WPM fix**: Replaced all four `/ 150` literals in CLI with `WPM_ESTIMATE` constant. Extended consistency test to scan both tui.py and cli.py.
- **Shebang fix**: Replaced hardcoded `#!/Users/dave/.venvs/mlx-audio/bin/python3` with `#!/usr/bin/env python3`.
- **sounddevice to core deps**: Moved from `[project.optional-dependencies] tui` to `[project] dependencies`. It's ~170KB with PortAudio bundled on macOS, and engine.py imports it unconditionally.
- **XDG data directory**: Implemented then reverted. Data stays in project-relative `data/` by design — everything lives in one project folder.
- **Version tracking**: Added `__version__ = "0.2.0"` to `src/lilt/__init__.py` and `--version` flag to CLI.
- **Callable annotation**: Fixed deprecated lowercase `callable` type hint in `engine.py:play_article()` to `Callable | None`.
- **CLIError pattern**: CLI commands now raise `CLIError` instead of calling `sys.exit(1)` deep in business logic. `run_cli()` catches at the top level and converts to sys.exit.
- Plan reviewed by contrarian (2 rounds) and Codex (GPT-5.4 xhigh). 34 findings evaluated across all reviews; 20 accepted, 14 rejected.

## 2026-04-07

- Fixed persistent `bad value(s) in fds_to_keep` playback error. The `hf_xet` Rust extension (hard dependency of `huggingface_hub` 1.9.0) spawns subprocesses that fail when Textual's event loop has open file descriptors. Previous env-var-only workaround (`HF_HUB_DISABLE_XET=1`) was insufficient — `hf_xet` native code could still trigger forking during the download-stack initialization. Replaced with a layered approach: (1) `HF_HUB_OFFLINE=1` when model is cached, bypassing the entire download stack; (2) `HF_HUB_DISABLE_XET=1`; (3) `sys.modules["hf_xet"] = None` to block import; (4) patching `huggingface_hub.constants`. Also fixed the CLI `_play_text()` path which was missing the workaround entirely.
- Added 2 regression tests for offline-mode model loading (cached and uncached paths). 139 total tests.
- Added ruff as a dev dependency. Ran lint + format across entire codebase — fixed import ordering, removed unused imports/variables, formatted all files. Added `[tool.ruff]` config to `pyproject.toml`.
- Created `tasks.md` with ASAP tech debt items from contrarian review (CLI consolidation, CLI tests, hardcoded WPM, shebang, sounddevice dep, XDG data dir).

## 2026-04-06

- Created lilt project (renamed from readarticle).
- Consolidated all files into `~/Documents/Projects/lilt/` — script, docs, and runtime data in one place.
- Runtime data lives in `data/` (gitignored). No more scattered files across `~/.local/`.
- CLI accessible via shell alias (`alias lilt='~/Documents/Projects/lilt/lilt'`).
- Created GitHub repo at dave-schmidt-dev/lilt.
- Textual TUI plan reviewed by contrarian (2 rounds) and Codex (GPT-5.4). Full plan at TUI_PLAN.md.
- Phase 1: Extracted shared library (`src/lilt/`) from monolithic script. Four modules: `text.py`, `fetch.py`, `queue.py`, `state.py`. Added `pyproject.toml` for editable install. Atomic writes for queue and state persistence. 59 unit tests.
- Phase 2: Built AudioEngine (`src/lilt/engine.py`) with sounddevice OutputStream playback, pause/resume/stop via threading events, paragraph-based TTS generation, and progress tracking. Built Textual TUI (`lilt-tui`) with two-panel layout, all key bindings, voice settings modal, resume support, and clipboard add. 19 additional tests (78 total).
- Phase 3: Hardened error handling across all modules. Added corrupt JSON recovery in `load_queue()`. Added `generate_and_play()` method to AudioEngine (fixes TUI integration bug). Wrapped sounddevice operations with PortAudioError catch. Wrapped model loading with descriptive error propagation. 24 edge case tests covering corrupt files, missing articles, concurrent access, and engine errors (102 total).
- TUI feature parity: Made the TUI a complete CLI replacement. Fixed `lang_code` bug (engine was silently ignoring language setting). Extracted `_normalize_segments` helper. Added `generate_audio()` method for WAV export. Added `LANGUAGES` and `WPM_ESTIMATE` constants. Extended VoiceSettingsScreen with language selector (American, British, Japanese, Chinese). Added AddArticleScreen modal for URL-based article fetching with progress indicators and add-and-play (ctrl+p). Added TextPreviewScreen for viewing article text. Added ConfirmScreen (used by delete and clear-all). Added WAV export with paragraph-level progress. Fixed cursor preservation in queue refresh. Plan reviewed by contrarian; 16 findings evaluated (12 accepted, 1 rejected, 3 noted). 127 total tests.
- Merged CLI and TUI into single entry point: `lilt` with no args launches the TUI, with flags runs CLI commands. Moved TUI code into `src/lilt/tui.py`. Eliminated `lilt-tui` standalone script and SourceFileLoader test hack. One command, one alias.
- Fixed AddArticleScreen bug: `ModalScreen` doesn't have `call_from_thread` (only `App` does). Worker silently crashed. Fixed with `self.app.call_from_thread()`. Changed `p` binding to `ctrl+p` since Input widget captures bare letter keys.
- Fixed modal click handling in the Textual TUI. Replaced keyboard-hint `Label` pseudo-buttons with real `Button` widgets in add, confirm, voice, and preview dialogs; kept keyboard bindings intact; disabled add-dialog controls during background fetches. Constrained the voice settings modal so its action buttons stay inside the visible dialog on smaller terminals. Added pilot click regression tests for modal buttons. `tests/test_tui.py`: 21 passed under Python 3.13 with `PYTHONPATH=src /tmp/lilt-test-env/bin/pytest tests/test_tui.py`.
- Cleaned up the text preview footer to avoid duplicate close affordances. The preview modal now shows a single clickable `Close` button plus the word count, instead of repeating “Close” in the adjacent label.
- Hardened model loading against Hugging Face Xet download issues. `AudioEngine.load_model()` now disables Xet-backed Hub downloads by default before importing `mlx_audio`, forcing standard HTTP downloads unless `LILT_ENABLE_HF_XET=1` is set. This was driven by repeated playback failures showing `bad value(s) in fds_to_keep` and two Python interpreter crashes during direct `mlx_audio` model-load probes before the workaround was added.
- Fixed a second audio-path bug exposed by real runtime testing: `mlx_audio` returns a generator from `model.generate()`, but `lilt` was treating that like a single segment object. `_normalize_segments()` now preserves generator/iterable segment streams, and engine tests cover generator output for both `generate_audio()` and `generate_and_play()`.
- Validation completed tonight:
  - `PYTHONPATH=src ~/.venvs/mlx-audio/bin/python3 -m pytest tests/test_engine.py` -> 25 passed
  - `PYTHONPATH=src /tmp/lilt-test-env/bin/pytest tests/test_tui.py` -> 21 passed
  - Direct fresh-process smoke check in the real `mlx-audio` venv: `AudioEngine.generate_audio("Hello world. This is a short test.")` succeeded and returned 67200 `float32` samples.
- Validation debt remains and needs full end-to-end coverage ASAP. The current suite was too mocked around the real failure boundaries:
  - TUI tests originally verified modal opening/keyboard flows but not actual button clicks.
  - Engine tests originally mocked `model.generate()` with a plain segment object, not the generator shape returned by real `mlx_audio`.
  - There is still no true end-to-end smoke test that launches a fresh `lilt` process, loads the real model, synthesizes a short clip, and confirms playback-path behavior without heavy mocking.
