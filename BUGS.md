# Bugs

## Active Bugs

### BUG-1 — Concurrent MLX Metal access crashes the process

- Trigger: two threads enter MLX GPU work concurrently (`load_model()`, `model.generate()`, or lazy generator materialization).
- Failure mode: `SIGABRT` / `SIGSEGV` in Metal-backed MLX code.
- Status: mitigated in Lilt. `AudioEngine` serializes MLX access with `_model_lock`, materializes generators inside the lock, and double-check-locks model loading.
- Follow-up: keep concurrency guards intact and treat any future unlocked MLX access as a regression.

### BUG-2 — `fds_to_keep` failure from Textual worker download path

- Trigger: first-time model download from inside a Textual worker thread.
- Root cause: Hugging Face `snapshot_download()` creates a `tqdm` progress bar, which initializes a `multiprocessing.RLock`; that spawns Python's `resource_tracker` subprocess from the worker thread and can fail with invalid `fds_to_keep`.
- Status: mitigated in two places:
  - cached-model path sets `HF_HUB_OFFLINE=1`, bypassing `snapshot_download()`
  - TUI startup now pre-initializes `tqdm.tqdm.get_lock()` on the main thread before `Textual` starts
- Follow-up: if the failure reappears, verify whether a new download path bypasses the main-thread `tqdm` lock initialization.

## Validation Debt

- The routine automated suite covers the safe, guarded paths that Lilt actually uses.
- Manual audio-device playback verification is still required when changing playback UX or output-device behavior.
- Recommended next validation task:
  - Launch a fresh `lilt` process on a machine with a working output device.
  - Add a short source.
  - Play a short clip through the real `mlx-audio` stack.
  - Confirm speaker output, pause/resume, stop, and TUI status updates without mocks.
