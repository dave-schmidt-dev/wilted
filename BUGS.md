# Bugs

## Active Bugs

### BUG-1 — Concurrent MLX Metal access crashes the process

- Trigger: two threads enter MLX GPU work concurrently (`load_model()`, `model.generate()`, or lazy generator materialization).
- Failure mode: `SIGABRT` / `SIGSEGV` in Metal-backed MLX code.
- Status: mitigated in Wilted. `AudioEngine` serializes MLX access with `_model_lock`, materializes generators inside the lock, and double-check-locks model loading.
- Follow-up: keep concurrency guards intact and treat any future unlocked MLX access as a regression.

### BUG-2 — `fds_to_keep` failure from Textual worker download path

- Trigger: first-time model download from inside a Textual worker thread.
- Root cause: Hugging Face `snapshot_download()` creates a `tqdm` progress bar, which initializes a `multiprocessing.RLock`; that spawns Python's `resource_tracker` subprocess from the worker thread and can fail with invalid `fds_to_keep`.
- Status: mitigated in two places:
  - cached-model path sets `HF_HUB_OFFLINE=1`, bypassing `snapshot_download()`
  - TUI startup now pre-initializes `tqdm.tqdm.get_lock()` on the main thread before `Textual` starts
- Follow-up: if the failure reappears, verify whether a new download path bypasses the main-thread `tqdm` lock initialization.

### BUG-3 — `ModuleNotFoundError: No module named 'wilted'` after venv rebuild on macOS

- Trigger: launching `wilted` from the entry-point shim after `uv sync` (or any operation that recreates `.venv/`) on macOS, when the project lives under `~/Documents/`.
- Root cause: macOS sets the `UF_HIDDEN` filesystem flag on the newly installed `.pth` files inside `.venv/lib/python*/site-packages/`. CPython 3.13's `site.py` silently skips hidden `.pth` files, so `__editable__.wilted-0.2.0.pth` is not processed and `src/` never lands on `sys.path`. Likely upstream causes: iCloud Drive sync, a Finder "Keep Both" merge (leaves telltale `lib 2/`/`include 2/` empty dirs), or backup tooling under `~/Documents/`.
- Diagnosis: `python -v -c "pass" 2>&1 | grep .pth` shows `Skipping hidden .pth file:` lines. `ls -lO <venv>/lib/python*/site-packages/*.pth` shows `hidden` in the flags column. Confirmed 2026-05-25: all 20,384 files under the in-`~/Documents` `.venv` carried `UF_HIDDEN`, while `src/` (no leading dot) did not — iCloud hides the `.venv` dot-directory and its entire subtree.
- Status: **resolved (2026-05-25)** — durable fix applied. The project venv now lives at `~/.venvs/wilted` (outside iCloud) via `UV_PROJECT_ENVIRONMENT`, wired into the `~/.zshrc` alias, the `Makefile` (`export UV_PROJECT_ENVIRONMENT := $(HOME)/.venvs/wilted`), and `scripts/wilted-nightly.sh`. iCloud cannot reach `~/.venvs`, so the `.pth` files are never hidden and the bug cannot recur. The old in-project `.venv` was removed.
- Follow-up: none. If a venv is ever recreated inside `~/Documents/` again, the `chflags nohidden` one-liner in the README remains the manual escape hatch.

## Validation Debt

- The routine automated suite covers the safe, guarded paths that Wilted actually uses.
- Manual audio-device playback verification is still required when changing playback UX or output-device behavior.
- Recommended next validation task:
  - Launch a fresh `wilted` process on a machine with a working output device.
  - Add a short source.
  - Play a short clip through the real `mlx-audio` stack.
  - Confirm speaker output, pause/resume, stop, and TUI status updates without mocks.
