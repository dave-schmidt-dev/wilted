# Migration rehearsal spike — 2026-07-10 (Task 0.6)

**This is a disposable architecture spike. It is not production code.**

## Purpose

Rehearses Task 0.6 of
`~/Documents/Projects/.plans/wilted/mac-first-personal-radio-2026-07-10-tasks.md`:
export representative existing content/media, import it into a candidate
station store, validate the import against the export manifest, then roll
back and prove the source is untouched — **entirely on isolated data**.
This is a rehearsal of the mechanics, not a production migration; it does
not authorize any in-place conversion of the real `data/wilted.db` (see the
design doc's ownership-boundary note, lines 70-80).

## How to run

From the project root:

```bash
python spikes/migration-rehearsal-2026-07-10/rehearse.py
```

(or `uv run python spikes/migration-rehearsal-2026-07-10/rehearse.py` if
`python` isn't on `PATH`)

Expected: exits 0, printing the export manifest summary, import validation
(counts + hashes match), rollback verification (source byte-identical to
the pristine baseline), and the isolation-guard result (real
`data/wilted.db` mtime unchanged before/after).

To lint just this spike (intentionally outside `make validate`'s scope,
same convention as `spikes/mac-substrate-2026-07-10/`):

```bash
ruff check spikes/migration-rehearsal-2026-07-10
```

## Candidate store shape rehearsed

**A versioned atomic JSON state document (`station-state.json`) plus a
durable-media index directory (`media/<sha256>.<ext>`).**

Task 0.6 offered a choice: (1) a versioned atomic state document + durable
media index, or (2) a separate SQLite station-tables DB. This rehearsal
picked (1) because it is the concrete, persisted form of the direction the
Task 0.3 substrate scorecard already recommended (see
`~/Documents/Projects/.plans/wilted/phase0-3-substrate-scorecard-2026-07-10.md`,
outside this repo): candidate (a), a headless station core exposing a
versioned JSON manifest/checkpoint boundary. The scorecard explicitly notes
"authoritative state must be **persisted** (survive restart) ... A real
store (SQLite station tables or a versioned atomic doc) is required and is
the *same* work for both candidates" — so rehearsing the atomic-JSON-doc
shape here exercises the artifact Task A.1's real station-store work will
actually produce, not a throwaway alternative. Its rollback story is also
simpler to make airtight for a disposable spike: one `os.replace` publishes
the whole state document atomically (same tempfile+`os.replace` pattern
already proven in `cache.py`'s `save_manifest`), so there is never a
partially-written state document to reason about.

A separate SQLite station-tables DB was the other option and remains
viable for Task A.1 — nothing here rules it out. It just doesn't map as
directly onto the boundary shape the 0.3 scorecard already measured.

## Reuse

`rehearse.py` imports `item_to_station_entry()` and `seed_isolated_db()`
directly from `spikes/mac-substrate-2026-07-10/migration.py` (Task 0.3's
spike) rather than reimplementing the `Item -> StationEntry` mapping. See
that module's docstring for the full field-by-field mapping and which
fields have no clean `Item` equivalent (unchanged by this rehearsal).

## Measured result (last run)

All five phases and the isolation guard passed in a single run:

| Phase | Result |
|---|---|
| 1. Isolated source built | 4 `Item` rows (2 articles, 2 podcast episodes, varied `status`: `discovered`/`ready`/`completed`), 4 fake media files (a few KB each), pristine baseline recorded (row count + per-file SHA-256) |
| 2. Export manifest | `item_count=4`, `media_file_count=4`, schema_version=1, per-file SHA-256 + byte size captured |
| 3. Import into candidate store | 4 `Item` rows mapped to `StationEntry`/`MediaDescriptor` via the reused `item_to_station_entry()`; 4 media files copied into the store's own `media/` dir, re-hashed **from the copy** (not trusted from the source read); atomic JSON state document published via tempfile + `os.replace` |
| 4. Validation | `item_count_match=True`, `media_count_match=True`, `all_hashes_match=True` — 4 items / 4 files checked, byte-for-byte |
| 5. Rollback | Source DB + media dir restored from the pristine pre-import backup via a clean scripted copy (no manual DB edits); `row_count_match=True` (4 rows), `media_hashes_match=True` (4 files) — byte-identical to the original baseline |
| Isolation guard | `tmp_root_under_real_data_dir=False`; real `data/wilted.db` mtime **unchanged** before/after the run |

Run with `python spikes/migration-rehearsal-2026-07-10/rehearse.py`, exit
code 0. `ruff check spikes/migration-rehearsal-2026-07-10` is clean.

## Task 0.6 "done when" — mapped to this rehearsal

1. **No production database is converted in place.** The import phase
   (`import_into_station_store()`) only *reads* `Item` rows and *copies*
   media bytes out to a brand-new store directory; it never writes into
   the source DB or source media dir. The source is a temp SQLite file
   this script creates itself — the real `data/wilted.db` is never opened.
2. **Imported content/media counts and hashes match the export
   manifest.** `validate_import()` asserts exact equality of item count,
   media file count, the full set of SHA-256 hashes, and per-hash byte
   size, raising `ValidationError` (failing loudly, not a warning) on any
   mismatch.
3. **Rollback restores the original state without manual database
   edits.** `rollback()` is a scripted `shutil.rmtree` + `shutil.copytree`
   restore from a pristine pre-import backup, verified by re-reading the
   restored DB's row count and re-hashing the restored media tree —
   both compared for exact equality against the baseline recorded in
   Phase 1.
4. **The chosen store has an `isolated_data`-equivalent fixture/guard.**
   `run_isolation_guard()` asserts every path used resolves under the
   `tempfile.TemporaryDirectory` root (never under the real `data/` tree)
   and that `data/wilted.db`'s mtime is identical before and after the
   entire run. This mirrors `tests/conftest.py`'s `isolated_data` autouse
   fixture pattern (temp `DATA_DIR` + `reset_db()`/`run_migrations()`
   against a temp path) rather than reinventing it.

## Migration friction / fields with no clean round-trip

Same gaps `migration.py`'s docstring already documents for the `Item ->
StationEntry` mapping (unchanged here — this rehearsal exercises the
export/import/rollback mechanics around that mapping, not the mapping
itself):

- **`priority`** — `Item` has no priority column; the mapper defaults to
  `5` for every migrated entry. A real migration needs an explicit
  priority-assignment policy.
- **`media.sha256` / `media.byte_size`** — `Item` never stores a content
  hash or verified byte size for `audio_file`/`transcript_file`. This
  rehearsal *does* compute real hashes during import (that's the whole
  point of the validation step), but that's new work the rehearsal adds,
  not something `item_to_station_entry()` reads from the `Item` row itself.
- **`media.transcript_segments` / `media.safe_interruption`** — `Item`
  only stores a *path* to a transcript file; the segments themselves live
  in a separate JSON file the reused mapper deliberately does not open.
  A real migration would need to parse that file per item to populate a
  non-empty `SafeInterruptionMap`.
- **`media.finalization`** — cannot honestly be derived from `Item.status`
  alone. `MediaDescriptor.__post_init__` (INV-4) rejects `published=True`
  when `sha256` is empty or `byte_size` is 0, so a real migration must
  hash and stat the actual artifact bytes before it can claim any
  finalization state beyond the all-`False` default — `status="ready"` or
  `"completed"` alone is not sufficient proof.
- **Article vs. podcast `audio_file` shape inconsistency** — confirmed
  again here: article `audio_file` is a per-paragraph directory (multiple
  files import into multiple media-index entries), podcast `audio_file`
  is a single file. `import_into_station_store()` normalizes both by
  checking `.is_dir()` and iterating, but this is exactly the
  inconsistency `MediaDescriptor` is documented to hide — a real
  migration will need the same normalization logic, not a shortcut.

None of these are blockers for the rehearsal (they're pre-existing,
already-documented mapping gaps), but they are exactly the gaps a real
Task A.1 migration must close before treating a migrated `StationEntry`
as playable/checkpointable.

## Rules for anything built on top of this scaffold

- **Nothing under `src/wilted/` may import anything from `spikes/`.**
  This directory is removable at any time without touching production
  code or data.
- Only ever opens SQLite paths it creates itself under a
  `tempfile.TemporaryDirectory` — never `wilted.DATA_DIR` or the real
  `data/wilted.db` (INV-5).
- Substrate-neutral: no `textual` import, no real-audio playback, no UI,
  no networking.
- Cleans up its own temp directories on every run (context-managed
  `tempfile.TemporaryDirectory`); nothing persists after the process exits.
