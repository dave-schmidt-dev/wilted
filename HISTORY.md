## 2026-04-06

- Created lilt project (renamed from readarticle).
- Consolidated all files into `~/Documents/Projects/lilt/` — script, docs, and runtime data in one place.
- Runtime data lives in `data/` (gitignored). No more scattered files across `~/.local/`.
- CLI accessible via shell alias (`alias lilt='~/Documents/Projects/lilt/lilt'`).
- Created GitHub repo at dave-schmidt-dev/lilt.
- Textual TUI plan reviewed by contrarian (2 rounds) and Codex (GPT-5.4). Full plan at TUI_PLAN.md.
- Phase 1: Extracted shared library (`src/lilt/`) from monolithic script. Four modules: `text.py`, `fetch.py`, `queue.py`, `state.py`. Added `pyproject.toml` for editable install. Atomic writes for queue and state persistence. 59 unit tests.
- Phase 2: Built AudioEngine (`src/lilt/engine.py`) with sounddevice OutputStream playback, pause/resume/stop via threading events, paragraph-based TTS generation, and progress tracking. Built Textual TUI (`lilt-tui`) with two-panel layout, all key bindings, voice settings modal, resume support, and clipboard add. 19 additional tests (78 total).
- Phase 3 (remaining): Edge case handling, clean shutdown hardening, docs finalization.
