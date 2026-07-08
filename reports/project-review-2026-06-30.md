# Whole-project review — wilted (2026-06-30)

**Source:** `/project-review` impulse-tier workflow (run `wf_22b70db9-5cb`) — 64 finder agents over 7 clusters, 249 candidates, 195 verified / 23 refuted.

**Caveat — synthesis died at the session limit.** The workflow's dedup, synthesis, and HTML-report steps all failed (`You've hit your session limit`), so the raw output has heavy duplication (the nightly `$?` bug appears 4×, the download temp-file leak 3×, `classify.load()` ~4×), **no severity labels**, and **no HTML report** (`reportPath: null`). Severity below is assigned by hand during the follow-up session; duplicates are merged. Raw output: `/private/tmp/claude-501/-Users-dave-Documents-Projects-wilted/e6414ee6-5b84-49f4-b921-03a513c00f4d/tasks/weshe67bc.output`.

**Scope of this doc:** the deduplicated **medium-and-higher** correctness findings (the set the follow-up plan targets). Low-severity items (cleanup, conventions, docs, test-gaps) are summarized at the bottom, not planned.

Severity key: **CRITICAL** = silent total failure / silent data destruction, no recovery · **HIGH** = user-facing data loss / core feature broken · **MEDIUM** = crash on plausible input, resource leak, wrong-but-recoverable behavior, scoped silent loss.

---

## CRITICAL

### PR-C1 · Nightly pipeline is a silent no-op every night
`scripts/wilted-nightly.sh:31` → `src/wilted/cli.py:1039`
The launchd job runs `uv run ... python -m wilted.cli`, but `cli.py` has **no `if __name__ == "__main__": main()` guard** (only `__main__.py`, used by `python -m wilted`, has one). `-m wilted.cli` defines `main()` and exits **without calling it** — exit 0. So discover/classify/report/email **never run**; the wrapper's `if $WILTED ingest; then log "completed successfully"` branch is taken and the log records a clean success every night. **Verified in this session** (grep: no `__main__` in cli.py; pyproject entry is `wilted.cli:main`). Self-reinforcing: nothing in the logs ever indicates a problem.
Fix: nightly should call `python -m wilted` (or `wilted ...` console script), and/or add a `__main__` guard to `cli.py`. Add a regression test that the nightly `$WILTED` invocation actually executes a subcommand.

---

## HIGH

### PR-H1 · Ad/promo removal can silently destroy the whole episode/article
`src/wilted/ads.py:446` (`cut_ads` → 0-byte file) + `src/wilted/ads.py:586` (`remove_promos` → empty string), consumed by `prepare.py`
When the LLM flags the entire clip as ad / every paragraph as promo, `cut_ads()` returns a 0-byte `touch()`'d file and `remove_promos()` returns `""`, and `prepare.py` **unconditionally overwrites the original audio/transcript** with the empty result. Silent total data loss of the prepared content.
Fix: treat "everything flagged" as a no-op (keep original) or hard error; never persist empty output over source.

### PR-H2 · `remove_promos()` paragraph split is broken for the primary article path
`src/wilted/ads.py:548`
Splits on `"\n\n"`, but trafilatura-extracted article text (the main fetch path) uses single `"\n"` between paragraphs → `split()` returns **one** "paragraph" containing the whole article. So promo removal is all-or-nothing, and combined with PR-H1 a single "promotional" verdict wipes the entire article.
Fix: normalize/΄split on the actual paragraph delimiter used by the fetch pipeline.

### PR-H3 · `wilted remove N` / `next` deletes the wrong article
`src/wilted/cli.py:160` (and `:271`) → `queue.py:84` vs `queue.py:151`
`cmd_list`/`load_queue()` selects `status=='ready' OR (status=='selected' AND item_type=='article')`, but `remove_article(index)` only selects `status=='ready'`. When a `selected` article is interleaved, the Nth item shown ≠ the Nth item deleted. **Reproduced by the verifier:** `wilted remove 2` deletes the item displayed as #3 — permanent removal of transcript + audio, no warning. `cmd_next()`'s `remove_article(0)` on a cache miss hits the same mismatch.
Fix: make removal operate on the same ordered set `load_queue()` presents (delete by resolved item id, not positional index into a different query).

### PR-H4 · Podcast backlog floods the queue on the second poll
`src/wilted/discover.py:241`
The `entries[:5]` backlog cap only applies when `existing_count == 0` (first poll). Poll #1 truncates the rest **without recording dedup hashes**, so on poll #2 `existing_count > 0`, the cap is skipped, and every previously-skipped backlog episode looks brand-new → hundreds of old episodes dumped into the queue with `status='selected'`. Exactly the failure the cap intends to prevent.
Fix: gate on `feed.last_checked_at is None` (already available) and/or record dedup markers for skipped entries so they don't resurface.

### PR-H5 · TUI auto-advance replays the same paragraph (verify-first)
`src/wilted/tui/__init__.py:599`
The playback loop resets `para_idx = self._paragraph_idx` at the top of **every** iteration, but normal advancement writes only the local `para_idx += 1` (660); `self._paragraph_idx` is advanced solely by manual skip (773) / rewind (605). Static analysis says auto-advance is broken (same paragraph replays). This is in recently-churned play/pause code and may relate to the "multiple voices" symptom (repeated paragraph + overlapping generate). **Plan must reproduce with a Pilot test before fixing** — confirm current behavior, then fix by advancing `self._paragraph_idx` (or only re-syncing from it when resuming from pause/skip).

### PR-H6 · `report --email` can hang forever and silently freeze all future nightly runs
`src/wilted/cli.py:750` (+`:746`)
`subprocess.run([... email-alert ...], check=True)` has **no `timeout=`**. If email-alert stalls (hung SMTP), the process blocks forever while `wilted-nightly.sh` still holds its `flock` (fd 200) — every subsequent launchd run then hits `SKIP: previous run still active` and no-ops indefinitely, with no alert (the alerting path is the thing that hung). Also: the `--email` branch `return`s exit 0 when email is unconfigured or there's no report, so the nightly log records a false "email report sent"; and a genuine email failure is mislabeled "Report generation failed" because the whole body is under one `except`.
Fix: add a timeout; distinguish report-vs-email failures; return non-zero (or emit a distinguishable signal) when nothing was sent.

---

## MEDIUM

Grouped by theme (these map to the plan's workstreams). All are `CONFIRMED` unless marked `PLAUSIBLE`.

### Startup / CLI crash-hardening
- **PR-M1** `__init__.py:96` — `get_default_speed()` calls `load_config()` unguarded (outside its own try/except); a malformed/half-saved `wilted.toml` raises `TOMLDecodeError` → TUI startup (`tui/__init__.py:193`) and CLI play (`cli.py:191`) crash instead of falling back to 1.0.
- **PR-M2** `cli.py:95` — `validate_project_root()` runs on *every* invocation; its write-probe `touch()`+`unlink()` share one `except OSError`. On this iCloud-synced project (HISTORY documents file-provider interference), a `touch` that succeeds but `unlink` that fails is misreported as "data/ not writable" → **every command crashes** and leaks a `.write_probe` file.
- **PR-M36** `cli.py:298` — `cmd_direct` local-file branch: `open()` with no explicit encoding and no try/except, plus a TOCTOU gap after `os.path.isfile()` → uncaught `UnicodeDecodeError`/`IsADirectoryError`/`PermissionError`/`FileNotFoundError` (raw traceback, escapes the `CLIError`-only handler).
- **PR-M37** `cli.py:410` — `_maybe_chain_discover_prepare` calls `run_discover()`/`run_prepare()` with no try/except (unlike the standalone commands) → raw traceback after `wilted feed add <url>`.
- **PR-M34** `cli.py:116` — `cmd_add` only treats `http(s)://` input as a URL; anything else (file path, pasted text, `-`) silently falls back to reading the **clipboard**, adding unrelated content with no warning.
- **PR-M35** `cli.py:206` — `--save FILE` is reused unchanged across `cmd_play`'s queue loop → every article overwrites the same path; only the last survives, yet each is reported "Saved".
- **PR-M39** `db.py:334` (`PLAUSIBLE`) — `run_migrations()` has no exception handling and its call site is outside `run_cli()`'s `CLIError` handler → raw traceback at startup on migration failure.

### Nightly script hardening (with PR-C1 / PR-H6)
- **PR-M41** `wilted-nightly.sh:57` — `report --email` failure after a successful ingest is silently swallowed (no `else`); run still exits 0 → morning report silently never arrives, monitoring sees success.
- **PR-M42** `wilted-nightly.sh:63` — failure branch logs `$?` after two intervening commands overwrote it → every failure logged as "exit code 0". (Low effort; capture `rc=$?` first.)

### Nightly pipeline resilience (discover / classify / report)
- **PR-M4** `classify.py:223` — `run_classify()` per-item loop has no per-item try/except (unlike `discover.py`) → one bad LLM response aborts the whole classify stage.
- **PR-M5** `classify.py:88/100/106` — `playlist: null` → `.lower()` crash (dict.get default doesn't apply to explicit null); `NaN` bypasses the `relevance_score` clamp (NaN compares False); `summary: null` → literal text `"None"`.
- **PR-M6** `classify.py:162` — items set to `status='error'` are never re-queried anywhere → permanently excluded from classify and report. Silent loss.
- **PR-M24** `discover.py:337` — when article text can't be fetched at all, `stats['errors']++` and return with **no Item row** → failure leaves no trace and is never retried.
- **PR-M22** `report.py:27` — `_local_date_str()` uses local wall-clock date while every other timestamp is UTC-`Z` → report scoped to the wrong day near midnight.
- **PR-M23** `report.py:221/219` — `update_source_stats()` computes `selection_rate` from mismatched cohorts (discovered-this-week vs selected-this-week regardless of discovery date) and its per-feed loop has no exception handling → wrong stats + crash.

### GPU / Metal model lifecycle (one-model invariant)
- **PR-M7** `classify.py:217` — `backend.load()` is outside the `try/finally` that guards `backend.close()` → Metal model leaked on mid-load failure. (Same shape in `run_benchmark` `:364`.)
- **PR-M8** `transcribe.py:418` — Tier-3 `transcribe_audio()` loads a second Metal model (parakeet) while `prepare.py`'s LLM backend is still resident → violates the "one model at a time" GPU invariant; OOM risk.
- **PR-M9** `transcribe.py:422` — cleanup does only `del model`, missing the `gc.collect()` + `mx.clear_cache()` that `llm.py` uses → GPU memory not reclaimed.
- **PR-M31** `llm.py:130` — `MlxBackend.close()` is a no-op when `_model is None` → can't reclaim Metal memory allocated by a `load()` that raised partway.
- **PR-M20** `prepare.py:206` — `_prepare_article()` builds a new `AudioEngine()` per article (no `close()`/`unload()` exists) → per-article model leak; also uses class-default `speed=1.0`, ignoring `get_default_speed()`.

### Download / content-acquisition integrity
- **PR-M10** `download.py:263` — `_stream_to_file()` treats a premature server-closed connection identically to normal EOF, and `download_podcast()` never checks bytes-written against the parsed `Content-Length` → truncated audio silently accepted as complete.
- **PR-M11** `download.py:192` — only catches `HTTPError`/`URLError`/`OSError`; `http.client.IncompleteRead` (an `HTTPException`, not `OSError`) escapes → uncaught crash mid-download.
- **PR-M12** `download.py:36` — `audio_file` holds a *file* path for podcasts but a *directory* for articles, and `queue.py:run_retention()` unconditionally `Path.unlink()`s it → `IsADirectoryError` / wrong cleanup.
- **PR-M33** `fetch.py:154/187` — `fetch_url_with_browser()` launches headless Chrome without the `suppress_subprocess_output()` wrapper the module documents, and `browser.new_context()`/`new_page()` run outside the `try/finally` that closes the browser → Chrome process leak on error. (Related: `fetch.py:93` `resolve_apple_news_url()` uses `print()`/stderr, reachable from the TUI where stray stdout corrupts the Textual display.)
- **PR-M32** `queue.py:142` — `add_article()` creates the DB Item row before writing the transcript file with no rollback → orphaned row if the write fails. (Mirror of `discover.py:366`, where a transcript file written inside `_db.atomic()` is not removed on rollback → orphaned file.)

### Ad detection / cutting robustness
- **PR-M25** `ads.py:256/257` — `_resolve_overlaps()` per-second vote list drops `chunk_idx`, so multiple detections from one LLM call are counted as separate votes toward the majority threshold; `int(det.start_s)`/`int(det.end_s)` unguarded against NaN/Inf.
- **PR-M26** `ads.py:442` — `cut_ads()` parses ffprobe duration with bare `float()` (can be `N/A`/empty) → undocumented `ValueError` crash.
- **PR-M27** `ads.py:427/463/499` — ffprobe/ffmpeg `subprocess.run()` calls have no `timeout=` → a stalled ffmpeg blocks the caller forever.
- **PR-M28** `ads.py:168` — `detect_ads()` per-chunk `except Exception` swallows systemic backend failure (e.g. unloaded model) identically to "no ads found".
- **PR-M29** `ads.py:499` — final ffmpeg concat writes directly to `output_path` with no temp-file + atomic rename → corrupt partial on failure.
- **PR-M30** `cache.py:21` — `check_ffmpeg()` verifies only `ffmpeg`, but `cut_ads()` also shells out to `ffprobe` with no availability check → crash if `ffprobe` missing.

### Playback engine / TUI state
- **PR-M13** `engine.py:232` — `_stop_event`/`_pause_event` are cleared at the top of every `play*()` with no wait for a prior in-flight playback thread on the same engine to exit → overlap race (the "multiple voices" family; recently churned).
- **PR-M14** `engine.py:174` — `play_audio()` (cache-hit path) never sets `_playing`/`_paused` (unlike `play_article`/`play_file`) → `is_playing`/`is_paused` stale → TUI pause/play controls report wrong state.
- **PR-M15** `engine.py:249` — `play_article()` doesn't wrap `self._model.generate()` in try/except like the sibling methods → raw TTS exceptions escape.
- **PR-M16** `engine.py:151` — `sd.OutputStream(...)` opens the PortAudio stream at construction; if the following `stream.start()` raises, the opened stream is never closed before re-raise → stream leak.
- **PR-M21** `cache.py:190/176` — `generate_article_cache()` always rebuilds a fresh empty manifest before the loop, so the `para_idx < len(manifest["paragraphs"])` "skip if cached" guard can never be true → resume-of-interrupted-TTS is dead code (regenerates everything).

### Queue / playlist correctness
- **PR-M18** `playlists.py:285` — `get_playlist_items()` includes `status='selected'` items regardless of `item_type`, whereas `load_queue()` excludes `selected` podcast episodes (they still need Phase-4 download+transcription) → unplayable items surface in TUI playback.
- **PR-M17** `playlists.py:354` (+ `queue.py:run_retention`) — only catches `ValueError` around `datetime.fromisoformat`; a timestamp missing its `Z`/offset parses to a *naive* datetime and then raises `TypeError` when subtracted from the aware `now` → crash in expiry/retention on legacy timestamps.
- **PR-M19** `prepare.py:291` — item status is committed to `'processing'` outside the per-item try/except → a crash/kill mid-item leaves it permanently stuck and invisible to future prepare runs. Silent loss.

### DB / resource lifecycle
- **PR-M38** `db.py:41` — several `@work` worker threads reach the DB via `ensure_db()`/`connect_db()` instead of the `worker_db()` context manager (`_generate_cache`, `_play_article`, `_export_wav`, `AddArticleScreen._fetch_article`) → thread-local SQLite connections opened but never closed; connections/fds accumulate across a long TUI session.
- **PR-M3** `__init__.py:23` — `DATA_DIR` is captured at import time by `download.py`/`prepare.py` (`from wilted import DATA_DIR`), so `conftest.py`'s monkeypatch of `wilted.DATA_DIR` doesn't reach them → **`make test` writes into the real `data/transcripts` & `data/audio` trees** (stray `2_transcript.json`/`4_transcript.json` already present). A future unmocked test could overwrite real production data. (Data-safety/hygiene — treat with medium-high urgency even though no destruction yet.)

### Feed CRUD (latent)
- **PR-M40** `feeds.py:112/150` — `update_feed()` validates field *names* but not the `feed_type` *value*, and skips the `IntegrityError→ValueError` translation `add_feed()` does → a raw peewee `IntegrityError` leaks for an invalid `feed_type` or duplicate `feed_url`. Latent: no current caller, but any future feed-edit UI trips it.

---

## Excluded (low severity — not planned)

Not targeted by the follow-up plan, but recorded for completeness:
- **Cleanup/dedup:** copy-pasted "fetch-by-id-or-raise" blocks (`feeds.py`, `playlists.py`, `preferences.py`); `worker_db(path)` dead param; duplicated `WPM_ESTIMATE`; `_STUB_SUBCMDS`/`_run_stub` dead code; duplicated Y/n prompt; duplicated `segments_to_arrays`; sequential (non-parallel) network-bound discover loop; per-poll `count()` where `last_checked_at is None` suffices; `prepare.py` `stats['skipped']` never incremented.
- **Conventions:** `print()` in library code (`classify.py:353`, `fetch.py:93/96`); non-UTC nightly timestamp; one-line docstrings on public APIs.
- **Documentation:** stale package/module docstrings (article-reader framing, `--debug` gate, `run_classify` return keys, `get_report` date scoping — the last is *intended* per HISTORY C2 but undocumented); README roadmap/voices out of date; `download_podcast` docstring claims a cached file skips the request.
- **Testing gaps:** `setup_logging`, `validate_project_root`, `cmd_benchmark`, `cmd_report` default branch, nightly `flock`, GGUF backend lifecycle, ad majority-vote minority path, several fetch/download/transcribe error paths — untested. (Several become regression tests *inside* the medium+ fixes above.)
- **Low correctness:** empty-string title fallback (`discover.py:268`); `startTime: null` default (`transcribe.py:212`); `total_tokens == 0` falsy (`llm.py:115`); temp-file cleanup leaks on write failure (`download.py:259`, `cache.py:68`); `report.py:93` Report-row TOCTOU; `db.py:79` `connect_db` path-ignored-after-first-call (latent); `db.py:103` `worker_db` init TOCTOU; `log.py:43` handler-close leak; deprecated `mx.metal.clear_cache()`.

**Refuted by verifiers (23):** e.g. `PROJECT_ROOT` non-editable-install assumption, `worker_db` lock (partially — see PR-M39 note), several docstring/style nits, `xml.etree` XXE on RSS transcript (mixed verdict — one verifier confirmed, two refuted; left out of medium+ pending a decision).
