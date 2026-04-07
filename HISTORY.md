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
