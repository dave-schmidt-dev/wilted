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

### BUG-4 — Local Parakeet transcription tier crashed / produced garbage on any real episode

- Trigger: `transcribe_audio()` (ADR Tier 3 fallback) on a full-length podcast — i.e. any episode with no external RSS/web transcript.
- Root cause: three compounding defects behind a code path that shipped with **zero tests**.
  1. No chunking — `model.transcribe(str(audio_path))` decoded the whole file in one Metal computation; a 94-min episode overran GPU memory and aborted the process with a Metal command-buffer page fault (`GPU Address Fault (PageFault)`, exit 134 / SIGABRT).
  2. Wrong result attribute — parser read `result.segments`; `parakeet-mlx` returns an `AlignedResult` whose timestamped units are `.sentences`, so every run produced 0 segments and raised "Transcription produced no segments" (exit 1).
  3. Default split config — parakeet's default `SentenceConfig` disables all splitting (`max_words`/`silence_gap`/`max_duration` all None), returning the whole episode as ONE segment (useless for seek/resume + transcript display).
- Diagnosis: pulling one 94-min 404 Media episode through the tier for the hardware harness reproduced all three in sequence (SIGABRT → zero segments → single segment) as each was fixed.
- Status: **resolved (2026-07-10)**. Fixes in `src/wilted/transcribe.py`: bounded `chunk_duration=120.0` + `overlap_duration=15.0`; parser reads `.sentences` first (falls back to `.segments`/dict); new `_sentence_split_config(model)` rebuilds the model's default decoding config with `silence_gap=0.5` / `max_duration=20.0` and degrades to the library default on API drift. Verified: 756 segments over the full 93.9-min episode (15,849 words). Regression lock: `tests/test_transcribe.py::TestTranscribeAudioLocalTier` (5 tests, each fix revert-proven).
- Follow-up: none for the tier itself. The tier now has coverage where it previously had none; treat any future `AlignedResult` shape change as a regression caught by the `.sentences`-parsing test.

## Validation Debt

- The routine automated suite covers the safe, guarded paths that Wilted actually uses.
- Manual audio-device playback verification is still required when changing playback UX or output-device behavior.
- Recommended next validation task:
  - Launch a fresh `wilted` process on a machine with a working output device.
  - Add a short source.
  - Play a short clip through the real `mlx-audio` stack.
  - Confirm speaker output, pause/resume, stop, and TUI status updates without mocks.
