## 2026-04-06

- Created lilt project (renamed from readarticle).
- Consolidated all files into `~/Documents/Projects/lilt/` — script, docs, and runtime data in one place.
- Runtime data lives in `data/` (gitignored). No more scattered files across `~/.local/`.
- `DATA_DIR` now resolves relative to the script via `Path(__file__).resolve().parent / "data"`.
- CLI accessible via shell alias (`alias lilt='~/Documents/Projects/lilt/lilt'`).
- Created GitHub repo at dave-schmidt-dev/lilt.
- Textual TUI plan reviewed by contrarian (2 rounds) and Codex (GPT-5.4). Full plan at TUI_PLAN.md.
