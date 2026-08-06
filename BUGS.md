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

### BUG-5 — `play_file` hangs forever on `stop()` when a blocking syscall is in flight

- Trigger: `AudioEngine.stop()` (TUI stop/skip, or a measurement watchdog) called while `play_file` is blocked inside `proc.stdout.read()` (ffmpeg stalled) or `sd.OutputStream.write()` (CoreAudio device wedged). Introduced by the 2026-07-10 streaming rework.
- Failure mode: `play_file` never returns; the calling thread (TUI `@work` worker, or the harness main thread) freezes. Surfaced in the hardware harness `walkthrough.sh` resume-fidelity step, whose rapid OutputStream open/close cycling wedged the audio device.
- Root cause: `_stream_pcm` only checks `_stop_event` *between* 1024-sample blocks, and `stop()` had no handle to the ffmpeg process — so a syscall blocked mid-block was uninterruptible. The test suite missed it because `_FakeStdout.read()` returns instantly and never simulates a blocking read.
- Status: **resolved (2026-07-10)**. Engine: `stop()` now kills the tracked `self._current_proc` (guarded by `_proc_lock`), so a blocked read returns EOF and `play_file` unwinds. Regression lock: `tests/test_engine.py::TestPlayFileStreaming::test_stop_interrupts_blocked_read` (blocking-read fake; revert-proven). Harness `measure_playback.py`: incremental `results.log` writes + a daemon-thread `install_hang_guard` backstop for the write-block/device-wedge case that killing ffmpeg cannot interrupt.
- Follow-up: killing ffmpeg does not interrupt a `stream.write()` blocked on a genuinely wedged device — the engine relies on the block-boundary check there. If the route-recovery measurement (Task 0.3) shows real-world device-wedge hangs in the TUI, consider a write-side timeout or persistent-stream design.

### BUG-6 — Morning report silently stamps `playlist_override = "Work"` on every uncategorized item

- Trigger: Save & Close in the morning-report modal, for any item whose group is not one of `Work` / `Fun` / `Education` — in practice every item with `playlist_assigned IS NULL`, which renders under the `Uncategorized` group header. Applies to dismissed items as well as accepted ones.
- Failure mode: the item silently acquires a user-intent playlist the user never chose. No prompt, no visible change in the modal, no log line.
- Root cause: two halves of `src/wilted/tui/screens/report.py` disagree about what index `0` means.
  - `report.py:154` — `self._playlist_index[item_id] = self._playlists.index(playlist) if playlist in self._playlists else 0`. `"Uncategorized"` is not in `self._playlists`, so it falls to `0`, which *is* a real playlist (`"Work"`), not a sentinel.
  - `report.py:340-345` — on save, reads that index back, resolves it to `"Work"`, compares against `self._original_playlist[item_id]` (`"Uncategorized"`), sees a mismatch, and writes `db_item.playlist_override = "Work"`.
  - Nothing ever *changes* `_playlist_index`: the screen has no binding that cycles playlists (`BINDINGS` is only `a` / `n` / `escape,q,s`). The index is therefore always `0`, so the "did the user change it?" comparison is guaranteed to fire for uncategorized items and never fires for anything else.
- Diagnosis: `tui/screens/report.py:345` is the only writer of `playlist_override` anywhere in `src/` (`wilted playlist add` writes `playlist_items`, a different table). Live DB at 2026-08-06 showed 14 rows with `playlist_assigned IS NULL AND playlist_override = 'Work'`, all `preparation_state='not_queued'` — i.e. items that were *dismissed* in the modal and stamped on the way out.
- Live reproduction (2026-08-06 09:55): closing the morning report without selecting anything recorded all 15 report items as `dismissed` and stamped the 7 uncategorized ones, taking the affected count from 14 to **21**. Predicted before the close, confirmed after — no test needed to trigger it, it fires on every ordinary close.
- Interaction with `wilted report --reset`: reset reverts `ReportItem.decision` to `PENDING` and re-assembles, but it does **not** clear `playlist_override`. Dismissed items come back; the bogus overrides do not go away, and a subsequent close re-applies them. Any cleanup has to clear the column explicitly.
- Related inconsistency worth checking when fixing: report grouping keys off `playlist_assigned` alone (`report.py:62`, `report.py:247`), while playlist membership resolves `COALESCE(playlist_override, playlist_assigned)` (`content_state.py:348`). A stamped item therefore still shows under `Uncategorized` in the next report while belonging to `Work` for playlist purposes.
- Impact today: latent, not visible. `items_for_playlist_dynamic` (`content_state.py:346-352`) requires `preparation_state IN ('ready','queued')`, and all 14 affected rows are `not_queued`, so they are not currently showing up in the Work playlist. Any of them that is later queued would silently appear there.
- Status: **fixed** 2026-08-06.
- Fix: `_playlist_index` now stores `None` — a real sentinel — for any item whose playlist is not in `_playlists`, and the save site skips the write when the index is `None`. The dangerous default (`0` silently meaning `"Work"`) is gone from the data structure itself, not merely from the write path. Deliberately *not* implemented as a guard on `_original_playlist not in self._playlists`: that silently drops a real choice the moment a playlist-cycling binding is added (cycle an `Uncategorized` item to `Fun`, guard fires, selection discarded) — the same class of defect. A future cycling binding sets the index, which is exactly what makes the `new != original` comparison mean "the user chose".
  - An explicit `_playlist_changed` set was considered as a second barrier and rejected: with no UI that changes a playlist, it would have had no writer, and `make deadcode` (vulture, `min_confidence 60`) would flag it. Baselining new dead code in `vulture_allowlist.py` launders it past the gate.
- Cleanup: the 21 stamped rows were cleared 2026-08-06 (`UPDATE items SET playlist_override = NULL WHERE playlist_override = 'Work' AND (playlist_assigned IS NULL OR playlist_assigned = '')` — the exact bug signature; `report.py` is the only writer of that column, and all 21 had no `playlist_assigned`). DB backed up to `data/backups/wilted-pre-bug6-cleanup.db` first. Zero overrides remain.
- Regression tests (`tests/test_tui.py`): `test_save_does_not_stamp_playlist_override_on_uncategorized_items` asserts against `Item.get_by_id(...).playlist_override` read back from the DB, not in-memory state — the bug was a write that happened *despite* correct in-memory state, so an in-memory assertion passes against the buggy code. Verified by reverting the fix: the test fails with `assert 'Work' is None`. `test_unknown_playlist_maps_to_sentinel_not_index_zero` covers the sentinel separately.

### BUG-7 — Mouse input does not reach Wilted at all in the real terminal

- Trigger: any mouse interaction with a Wilted popup (morning report, add article, voice settings, confirm) in an actual terminal session. Long-standing; previously filed in `tasks.md` as "Modal screen buttons inoperable … buttons work in tests but not in terminal". Re-reported by David 2026-08-06: "the Morning Report popup doesn't respond to mouse input at all. I don't think any of the wilted popups do."
- Failure mode: clicks appear to do nothing. Keyboard bindings work normally in the same session.
- Status: **active, root cause unknown.** The evidence points *away* from Wilted's own code, but delivery has not been observed end-to-end in a real terminal.
- Ruled out so far:
  - *App-side click handling.* Under headless Pilot (Textual 8.2.3) a single click on `#done-button` reaches its handler, and clicks on the report `DataTable` do move the cursor. The app handles mouse events correctly when it receives them.
  - *The launcher's environment stripping.* A PTY capture of a trivial Textual app under the full environment and under `scripts/wilted-runtime.sh`'s `env -i` allowlist produced byte-identical output, including the mouse-tracking enables `?1000h ?1003h ?1006h ?1015h` and `?1049h`. Textual asks for mouse tracking in both.
  - *Wilted disabling mouse mid-session.* `_restore_terminal()` / `_emit_terminal_restore()` are only reachable from the post-`run()` `finally` (`cli.py:1498`) and the SIGTERM/SIGHUP handler (`cli.py:1465`), which re-raises and exits. Nothing under `src/wilted/tui/` touches mouse state.
- **Answered 2026-08-06** (David, at the terminal): the mouse does nothing on the **main** Wilted screen either. This rules out the `ModalScreen` layer — the title is now inaccurate, the failure is app-wide.
  - Key narrowing: mouse events and key events arrive on the *same* file descriptor and are decoded by the same input parser. The keyboard works. So either the terminal never emits the mouse sequences, or they are dropped before Textual's parser — not a widget/screen-layer problem.
- Checked since, without the terminal:
  - Not `tmux`: no `tmux` process running and no `~/.tmux.conf`.
  - iTerm2 preferences have `Mouse Reporting = true` on the profiles, and `NoSyncNeverAskAboutMouseReportingFrustration = true` (the "stop asking me about mouse reporting" prompt was dismissed at some point). **This does not clear iTerm2**: mouse reporting is also togglable per session at runtime, and that state never lands in the plist.
- **iTerm2 is emitting mouse events — confirmed 2026-08-06 by raw stdin capture.** A probe that bypasses Textual entirely (enable mouse tracking, dump stdin) captured ~2400 bytes of motion and button reports from a single session: `\x1b[64;116;19M` (motion — `64 - 32 = 32`, the motion bit) through `\x1b[35;98;29M` (`35 - 32 = 3`, button release). The terminal side is therefore **exonerated**; the fault is downstream of iTerm2.
  - Correction, so the capture is not misread later: the probe's own first-run verdict said "no mouse bytes arrived". That was a defect in the probe, which classified reports by the SGR `\x1b[<` prefix only and counted every urxvt-format report as a keystroke. The bytes were there all along.
- Live lead — **encoding mismatch between what iTerm2 replies with and what Textual can parse**:
  - Textual's `linux_driver._enable_mouse_support` writes `?1000h ?1003h ?1015h ?1006h` — 1015 (urxvt) *then* 1006 (SGR), so under last-one-wins SGR should be selected.
  - Textual's parser recognises both encodings but only decodes one:
    ```python
    _re_mouse_event = re.compile("^\x1b\[" + r"(<?[-\d;]+[mM]|M...)\Z")  # '<' optional: matches urxvt
    _re_sgr_mouse   = re.compile(r"\x1b\[<(\d+);(-?\d+);(-?\d+)([Mm])")  # SGR only
    ```
    `parse_mouse_code` tries `_re_sgr_mouse` and returns `None` when it fails. So a urxvt-format report is *recognised as a mouse sequence, consumed, and silently dropped* — a dead mouse alongside a perfectly live keyboard, which is exactly the reported symptom.
  - The original probe requested 1006 then 1015 and got urxvt back, which confirms iTerm2 honours last-one-wins. It does **not** yet establish what iTerm2 replies with under Textual's ordering — that is the open question.
  - Ruled out as the cause of a mid-session encoding change: Wilted only ever writes mouse *disable* sequences (`_TERMINAL_RESTORE_SEQ`, `cli.py:1369`), and only from exit paths.
- Next diagnostic step (needs a real interactive window — not a `!` command inside Claude Code, which is not a TTY that can be clicked into):
  1. Re-run the corrected probe, which now uses Textual's exact enable order and reports which encoding comes back. urxvt → root cause found, and the fix is a Wilted-side workaround. SGR → encoding is fine and the fault is further downstream.
  2. `~/.venvs/wilted/bin/python -m textual` (the demo, on the same Textual 8.2.3 in the same venv) to split "Textual's fault" from "Wilted's fault".
- Note: BUG-8 below is a *separate* defect in the report table's click semantics, now fixed. Fixing it did not fix this one, and this one still masks it — clicking rows will do nothing until mouse events reach the process.

### BUG-8 — A single mouse click never selects a row in the report table

- Trigger: clicking an item row in the morning-report modal to accept/dismiss it (assuming mouse events reach the app at all — see BUG-7).
- Failure mode: clicking a row moves the cursor but does not toggle selection. Clicking down a list, a different row each time, selects nothing. Only a second click on the *same* row registers.
- Root cause (confirmed): Textual's `DataTable._on_click` only posts `RowSelected` when the clicked coordinate *already equals* `self.cursor_coordinate`:
  ```python
  highlight_click = new_coordinate == self.cursor_coordinate
  self.cursor_coordinate = new_coordinate
  if highlight_click:
      self._post_selected_message()
  ```
  So the first click on a row only moves the cursor; a second click on the same row selects it. `ReportScreen` hangs its entire toggle behavior off `on_data_table_row_selected` (`report.py:240`), so one click per row is a no-op by construction. Browsing down a list — clicking a different row each time — never selects anything.
- Diagnosis (headless Pilot, Textual 8.2.3, fake data, no DB writes):
  - click a not-yet-highlighted row → cursor moves `1 → 2`, `RowSelected` never fires, `_selected` unchanged.
  - click the *same* row again → `_selected` toggles to `True`.
  - `enter` on a row → toggles correctly (keyboard path is fine).
  - `#done-button` → responds to a **single** click and reaches its handler.
- Scope note: this is independent of BUG-7. It is confirmed and fixable inside Wilted, but it is invisible until mouse events actually reach the process.
- Status: **fixed** 2026-08-06 — but **not observable to the user until BUG-7 is fixed**, because no mouse event reaches the app in David's terminal at all.
- Fix: `ClickSelectDataTable` (`report.py`), a `DataTable` subclass that moves the cursor to the clicked row *before* Textual's own handler runs, so Textual's `new_coordinate == self.cursor_coordinate` check comes out true for the row the user actually clicked and `DataTable` posts `RowSelected` itself. Chosen over posting `RowSelected` by hand (couples to the private `_post_selected_message`) and over `RowHighlighted` (fires on keyboard navigation too, so every arrow key would toggle).
- Why the public `on_click`, not an `_on_click` override: `MessagePump._get_dispatch_methods` walks the MRO taking `cls.__dict__["_on_click"] or cls.__dict__["on_click"]` *per class*, so an `_on_click` override is dispatched **in addition to** `DataTable`'s — a `super()._on_click(event)` inside it would run Textual's handler twice. Public handlers on a subclass are dispatched first, which is the ordering this fix needs.
- Verified assumptions: `validate_cursor_coordinate` only clamps to valid ranges, so the assigned coordinate survives to Textual's equality check; and `_css_type_names` includes base-class names, so the `DataTable { border: none; }` type selector still matches the subclass (a regained border would have moved both `CHROME_ROWS` and the 93-cell width floor — the 3 snapshot tests confirm it did not).
- Regression test: `test_single_click_selects_a_fresh_report_row` — clicks a row that is *not* under the cursor exactly once and asserts it toggles, that the cursor stays on it through `_rebuild_table()`, that only that row changed, that clicking a group header is a clean no-op, and that a second click deselects. Verified to fail against a plain `DataTable`: `one click on row 2 (cursor started on 1) did not select it`.
- Known behavior: a double-click toggles twice (net zero), the normal outcome for a checkbox list. Not special-cased.

### BUG-9 — Report modal reads as a flat list: group headers and item rows are indistinguishable

- Trigger: opening the morning report with more than one playlist group.
- Failure mode: `Uncategorized (7)` and `Work (8)` are rendered as ordinary table rows in the Title column, visually identical to the item rows beneath them. The report reads as a list of counts rather than as grouped items, and the cursor lands on header rows as if they were selectable. Surfaced 2026-08-06 when the group header was mistaken for an item with no title.
- Contributing details:
  - `report.py:139-145` adds headers via `table.add_row("", f"[bold $primary]{playlist}[/bold $primary]", "", "")`. `DataTable` cells go through *Rich* markup, not Textual content markup, and `$primary` is a Textual CSS variable that Rich cannot resolve — verified: `Style.parse("bold $primary")` raises `StyleSyntaxError: '$primary' is not a valid color`. Rich does not crash on render, it drops the style, so the intended bold/primary header styling never lands and headers render identically to item titles.
  - The selection column is a single space (`" "`) with values `"   "` / `"  ✓"` (`report.py:120`, `report.py:162`). With nothing selected there is no visible column at all, so there is no affordance showing that rows are selectable or what is currently selected.
  - The `Category` column is pushed off the right edge — the four auto-sized columns exceed `#report-dialog`'s `max-width: 120`, leaving a horizontal scrollbar and a truncated `Source` column.
  - `#report-table { height: auto; }` inside a `1fr` scroll container leaves a large blank area under short reports.
- Status: **fixed** 2026-08-06 (cursor still lands on header rows — see remaining gap below).
- Fix:
  - Headers are built as Rich `Text` with a literal `style="bold"` plus a `▼` marker and an uppercased label (`UNCATEGORIZED  (2)`), so they no longer depend on a theme colour Rich cannot resolve. Building cells as `Text` rather than markup strings also removes markup-parsing ambiguity for titles containing `[`.
  - The selection column has a real header (`Sel`) and renders `[ ]` / `[x]`, so it reads as a checkbox even when nothing is selected.
  - Columns now have explicit widths (`Sel` 3, `Title` 52, `Source` 18, `Category` 12 — `ReportScreen.COLUMNS`) instead of auto-sizing, so `Category` stays on screen. `Category` was kept, not dropped: it is the only feedback surface for the `_playlist_index` state a future playlist-cycling binding drives.
  - `#report-dialog` is `height: auto` with `max-height: 80%` so a 3-item report renders a 16-row dialog instead of a mostly-blank 32-row one.
- Layout trap found while fixing: Textual's `height: auto` container *clips* at `max-height` without re-distributing space to siblings, so an unbounded table pushed the Save & Close button outside the dialog border — and entirely off screen on an 80×24 terminal. Neither `max-height: 100%` nor `height: 1fr` on the scroll region fixes it (`1fr` does not collapse to content inside an `auto` parent, which is what caused the blank area to begin with). Resolved by sizing the scroll region at runtime in `_fit_scroll_height()`: `min(content_rows, 80% of screen - CHROME_ROWS)`, recomputed on resize.
- Refactor: `_populate_table` and `_rebuild_table` were near-duplicate renderers, which is how they could drift on the `_header_rows` bookkeeping that `_get_item_at_cursor` depends on for row→item mapping. Both now delegate to a single `_fill_table`.
- Regression tests (`tests/test_tui.py`): `test_report_rows_are_visually_distinguishable` (header carries a Rich-resolvable style, item titles do not, checkbox visible in both states, `Category` populated), `test_report_dialog_keeps_actions_on_screen` (parametrised 120×40 / 100×24 / 80×24 — asserts the button and help line stay inside the dialog and the last row is still scrollable; this is what locks `CHROME_ROWS`), and `test_short_report_dialog_shrinks_to_content`.
- Width floor — **BUG-9 is fixed from 110 columns up, not at 80.** The four fixed columns want 93 cells (85 declared + `DataTable`'s 1-cell padding either side of each) and the dialog offers 90% of the screen less 6 for border and padding, so `Category` is still clipped below ~110 columns. Measured: 120 cols → 102 available (fits), 100 → 84, 80 → 66. The layout test asserts this boundary both ways against `REPORT_WIDTH_FLOOR` rather than leaving the narrow cases silently uncovered. The equivalent short-screen floor is in `_fit_scroll_height`'s docstring: the `max(3, ...)` guarantee re-creates the overflow below ~14 rows, deliberately.
- `on_resize` coverage — the resize path initially shipped with zero execution (every test pushes the screen at a fixed size), so it was a vulture-baselined handler that nothing ran. The layout test now resizes and asserts the *recomputed scroll height* against `_fit_scroll_height`'s own formula. The obvious weaker assertion — "the dialog got taller" — is worthless here: with `on_resize` removed the dialog still drifts +1–2 rows from auto-layout alone, so that version passed against the broken code. Verified by disabling the handler: `got 21, expected 30`.
- Checked and *not* guarded: a `Resize` arriving mid-dismiss would make `_fit_scroll_height`'s `query_one` raise. Probed by posting `Resize` directly at a dismissed screen's message pump (6 push/dismiss cycles × 3 resizes) — no exception, because Textual stops dispatching to a dismissed screen. No `is_running` guard added; it would be untestable defensive code.
- Remaining gap: the cursor still lands on header rows. `_get_item_at_cursor` returns `None` there so nothing breaks, but the rows are not skipped during navigation. Not addressed here.

## Validation Debt

- The routine automated suite covers the safe, guarded paths that Wilted actually uses.
- Manual audio-device playback verification is still required when changing playback UX or output-device behavior.
- Recommended next validation task:
  - Launch a fresh `wilted` process on a machine with a working output device.
  - Add a short source.
  - Play a short clip through the real `mlx-audio` stack.
  - Confirm speaker output, pause/resume, stop, and TUI status updates without mocks.
