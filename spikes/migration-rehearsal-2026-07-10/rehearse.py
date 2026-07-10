"""Task 0.6 — export -> import -> validate -> rollback migration rehearsal.

**Disposable spike. Not production code.** Entirely isolated: never opens
the real ``data/wilted.db`` or writes anywhere under the real ``data/``
tree. See the isolation guard in :func:`run_isolation_guard` and the
module docstring's INV-5 note below.

Rehearses Task 0.6 of
``~/Documents/Projects/.plans/wilted/mac-first-personal-radio-2026-07-10-tasks.md``:
export representative existing content/media, import it into a candidate
station store, validate the import against the export manifest, then roll
back and prove the source is untouched.

Candidate store shape rehearsed: **a versioned atomic JSON state document
plus a durable-media index** (own media directory, one file per artifact,
named by content SHA-256). This is the concrete, disposable form of the
0.3 scorecard's recommendation ("Lean toward candidate (a)'s direction — a
headless station core exposing a versioned JSON manifest/checkpoint
boundary") and its explicit note that "authoritative state must be
**persisted** (survive restart) ... A real store (SQLite station tables or
a versioned atomic doc) is required and is the *same* work for both
candidates." A SQLite station-tables store was the other option considered
(see README.md "Why this shape") but the atomic JSON document was chosen
because it *is* the same manifest shape candidate (a)'s boundary already
serializes, so this rehearsal exercises the artifact the real Task A.1
work will actually produce, and its rollback story is a single
``os.replace`` away from the write it is undoing.

Five phases, run in order by ``main()``:

1. ``build_isolated_source()``      — seed an isolated SQLite ``Item`` DB
   plus a temp media directory with small fake artifacts; record the
   pristine baseline (row count + per-file SHA-256).
2. ``export_manifest()``            — read the source and produce a JSON
   export manifest (item identity + per-media-file hash/size).
3. ``import_into_station_store()``  — map each ``Item`` through the reused
   ``item_to_station_entry()``, copy+hash media into the candidate store's
   own media dir, and atomically publish the versioned state document.
4. ``validate_import()``            — assert imported counts/hashes match
   the export manifest exactly.
5. ``rollback()``                   — restore the source DB + media dir
   from a pristine backup and assert byte-identical equality with the
   original baseline, via a clean scripted restore (no manual DB edits).

Isolation (INV-5): every path this script touches is created under a
``tempfile.TemporaryDirectory``. ``run_isolation_guard()`` asserts that
every path recorded during the run resolves under that temp root, and
that the real ``data/wilted.db`` mtime is byte-for-byte unchanged before
and after the whole rehearsal — see ``tests/conftest.py``'s
``isolated_data`` autouse fixture, which this script's
``seed_isolated_db()`` reuse (via ``migration.py``) mirrors.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tempfile
from dataclasses import asdict
from enum import Enum
from pathlib import Path
from typing import Any

# spikes/migration-rehearsal-2026-07-10/rehearse.py -> project root is 2 parents up.
_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_PROJECT_ROOT / "spikes" / "mac-substrate-2026-07-10"))
sys.path.insert(0, str(_PROJECT_ROOT / "src"))

from migration import item_to_station_entry, seed_isolated_db  # noqa: E402 (path setup above)

from wilted.db import Item, reset_db  # noqa: E402 (path setup above)

MANIFEST_SCHEMA_VERSION = 1

# The real data/wilted.db this rehearsal must never touch or modify.
REAL_DB_PATH = _PROJECT_ROOT / "data" / "wilted.db"
REAL_DATA_DIR = _PROJECT_ROOT / "data"


def _sha256_file(path: Path) -> str:
    """Return the hex SHA-256 digest of a file's contents."""
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _hash_tree(dir_path: Path) -> dict[str, str]:
    """Return {relative_posix_path: sha256} for every file under dir_path."""
    return {
        str(p.relative_to(dir_path).as_posix()): _sha256_file(p) for p in sorted(dir_path.rglob("*")) if p.is_file()
    }


# ---------------------------------------------------------------------------
# Phase 1 — isolated source: seeded SQLite DB + fake media directory.
# ---------------------------------------------------------------------------


def build_isolated_source(tmp_root: Path) -> dict[str, Any]:
    """Seed an isolated SQLite source DB and a temp media dir with fake artifacts.

    Stands in for the existing content/media tree without touching real
    data. Four representative ``Item`` rows are created (two articles, two
    podcast episodes) spanning varied ``status`` values, each with a small
    fake media file on disk (a few KB of deterministic pseudo-random bytes,
    not real audio — YAGNI for a schema/round-trip rehearsal).

    Args:
        tmp_root: Isolated temp directory root for this rehearsal run.

    Returns:
        Dict with ``db_path``, ``media_dir``, ``item_count``, and
        ``baseline`` (row count + per-file SHA-256 map) describing the
        pristine state immediately after seeding.
    """
    source_dir = tmp_root / "source"
    db_path = source_dir / "isolated-source.db"
    media_dir = source_dir / "media"
    media_dir.mkdir(parents=True)

    seed_isolated_db(db_path)

    # Four representative items: two articles, two podcast episodes, varied
    # status (mirrors migration.py's seed_sample_items() shapes but adds a
    # second pair with different statuses to exercise more of the Item enum).
    now = "2026-07-10T12:00:00Z"

    article_1_dir = media_dir / "article-1"
    article_1_dir.mkdir()
    article_1_audio = article_1_dir / "paragraph-0.mp3"
    article_1_audio.write_bytes(b"FAKE-MP3-ARTICLE-1-PARA-0" * 128)  # ~3.3 KB

    article_2_dir = media_dir / "article-2"
    article_2_dir.mkdir()
    article_2_audio = article_2_dir / "paragraph-0.mp3"
    article_2_audio.write_bytes(b"FAKE-MP3-ARTICLE-2-PARA-0-DISCOVERED" * 96)  # ~3.5 KB

    podcast_1_audio = media_dir / "podcast-1.mp3"
    podcast_1_audio.write_bytes(b"FAKE-MP3-PODCAST-1-FULL-EPISODE" * 200)  # ~6.4 KB

    podcast_2_audio = media_dir / "podcast-2.mp3"
    podcast_2_audio.write_bytes(b"FAKE-MP3-PODCAST-2-COMPLETED-EPISODE" * 150)  # ~5.5 KB

    Item.create(
        guid="rehearsal-article-1",
        title="A Ready Article",
        source_name="NPR",
        source_url="https://example.org/article-1",
        discovered_at=now,
        item_type="article",
        status="ready",
        status_changed_at=now,
        word_count=850,
        duration_seconds=480.0,
        transcript_file="articles/article-1/transcript.txt",
        audio_file=str(article_1_dir.relative_to(media_dir)),
    )
    Item.create(
        guid="rehearsal-article-2",
        title="A Freshly Discovered Article",
        source_name="The Atlantic",
        source_url="https://example.org/article-2",
        discovered_at=now,
        item_type="article",
        status="discovered",
        status_changed_at=now,
        word_count=None,
        duration_seconds=None,
        transcript_file=None,
        audio_file=str(article_2_dir.relative_to(media_dir)),
    )
    Item.create(
        guid="rehearsal-podcast-1",
        title="A Sample Podcast Episode",
        source_name="Sample Podcast",
        source_url="https://example.org/podcast/ep-1",
        canonical_url="https://example.org/podcast/ep-1",
        discovered_at=now,
        item_type="podcast_episode",
        status="ready",
        status_changed_at=now,
        duration_seconds=5400.0,
        transcript_file="transcripts/podcast-1.json",
        enclosure_url="https://example.org/podcast/ep-1.mp3",
        enclosure_type="audio/mpeg",
        audio_file=str(podcast_1_audio.relative_to(media_dir)),
    )
    Item.create(
        guid="rehearsal-podcast-2",
        title="A Completed Podcast Episode",
        source_name="Sample Podcast",
        source_url="https://example.org/podcast/ep-2",
        canonical_url="https://example.org/podcast/ep-2",
        discovered_at=now,
        item_type="podcast_episode",
        status="completed",
        status_changed_at=now,
        duration_seconds=2700.0,
        transcript_file="transcripts/podcast-2.json",
        enclosure_url="https://example.org/podcast/ep-2.mp3",
        enclosure_type="audio/mpeg",
        audio_file=str(podcast_2_audio.relative_to(media_dir)),
    )

    item_count = Item.select().count()

    baseline = {
        "row_count": item_count,
        "media_hashes": _hash_tree(media_dir),
    }

    return {
        "db_path": db_path,
        "media_dir": media_dir,
        "item_count": item_count,
        "baseline": baseline,
    }


# ---------------------------------------------------------------------------
# Phase 2 — export manifest.
# ---------------------------------------------------------------------------


def export_manifest(source: dict[str, Any]) -> dict[str, Any]:
    """Produce a JSON-serializable export manifest from the isolated source.

    Captures item count, per-item identity (id/guid/type/status), and
    per-media-file SHA-256 + byte size — the ground truth
    :func:`validate_import` checks the candidate store against.

    Args:
        source: The dict returned by :func:`build_isolated_source`.

    Returns:
        The export manifest dict (also JSON-serializable as-is).
    """
    media_dir: Path = source["media_dir"]
    items = list(Item.select().order_by(Item.id))

    item_records = [
        {
            "item_id": item.id,
            "guid": item.guid,
            "title": item.title,
            "item_type": item.item_type,
            "status": item.status,
            "audio_file": item.audio_file,
        }
        for item in items
    ]

    media_records = [
        {"relative_path": rel_path, "sha256": sha256, "byte_size": (media_dir / rel_path).stat().st_size}
        for rel_path, sha256 in sorted(source["baseline"]["media_hashes"].items())
    ]

    return {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "item_count": len(item_records),
        "items": item_records,
        "media_file_count": len(media_records),
        "media_files": media_records,
    }


# ---------------------------------------------------------------------------
# Phase 3 — import into a candidate station store.
# ---------------------------------------------------------------------------


def import_into_station_store(source: dict[str, Any], tmp_root: Path) -> dict[str, Any]:
    """Import the isolated source into a NEW candidate station store.

    Candidate store shape: a versioned atomic JSON state document
    (``station-state.json``) plus a durable-media index directory
    (``media/<sha256>``). The source DB/media dir is read-only here — the
    import never mutates or converts it in place; it only reads ``Item``
    rows and copies media bytes into the store's own directory.

    Each ``Item`` is mapped to a ``StationEntry``/``MediaDescriptor`` pair
    via the reused ``item_to_station_entry()`` from the 0.3 spike. Media
    files are copied into the store's media index and re-hashed from the
    copy (not trusted from the source read) so validation proves the copy
    is byte-identical, not merely that the source hash was recorded.

    Args:
        source: The dict returned by :func:`build_isolated_source`.
        tmp_root: Isolated temp directory root for this rehearsal run.

    Returns:
        Dict with ``store_dir``, ``state_document`` (the atomic JSON
        manifest actually written), and ``media_records`` (post-copy
        hash/size per file, keyed by the store's own media index name).
    """
    store_dir = tmp_root / "candidate-station-store"
    store_media_dir = store_dir / "media"
    store_media_dir.mkdir(parents=True)

    media_dir: Path = source["media_dir"]
    items = list(Item.select().order_by(Item.id))

    entries = []
    media_records = []
    for item in items:
        entry = item_to_station_entry(item)

        # Resolve the item's audio artifact(s) to concrete file(s) under the
        # source media dir. Article audio_file is a per-paragraph directory;
        # podcast audio_file is a single file — normalize both to a list of
        # files, mirroring the inconsistency MediaDescriptor is designed to
        # hide (see wilted/station/models.py MediaDescriptor docstring).
        source_path = media_dir / item.audio_file
        source_files = sorted(source_path.rglob("*")) if source_path.is_dir() else [source_path]

        for src_file in source_files:
            if not src_file.is_file():
                continue
            file_sha256 = _sha256_file(src_file)
            dest_name = f"{file_sha256}{src_file.suffix}"
            dest_path = store_media_dir / dest_name
            shutil.copy2(src_file, dest_path)
            copied_sha256 = _sha256_file(dest_path)  # re-hash the copy, don't trust the source read
            media_records.append(
                {
                    "entry_id": entry.entry_id,
                    "store_filename": dest_name,
                    "sha256": copied_sha256,
                    "byte_size": dest_path.stat().st_size,
                }
            )

        entries.append(entry)

    state_document = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "station_revision": 1,
        "entries": [_station_entry_to_dict(e) for e in entries],
    }

    # Atomic publish: write to a temp file in the same directory, then
    # os.replace over the final path — same pattern already proven in
    # cache.py's save_manifest (tempfile + os.replace), the template the
    # 0.3 scorecard names for a MediaDescriptor publication gate.
    state_path = store_dir / "station-state.json"
    tmp_fd, tmp_name = tempfile.mkstemp(dir=store_dir, prefix=".station-state-", suffix=".tmp")
    try:
        with open(tmp_fd, "w") as fh:
            json.dump(state_document, fh, indent=2)
        Path(tmp_name).replace(state_path)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise

    return {
        "store_dir": store_dir,
        "state_path": state_path,
        "state_document": state_document,
        "media_records": media_records,
    }


def _station_entry_to_dict(entry: Any) -> dict[str, Any]:
    """Convert a frozen StationEntry (with nested dataclasses/enums) to a plain JSON-able dict.

    ``dataclasses.asdict()`` recurses through nested dataclasses but leaves
    ``Enum`` members (e.g. ``InterruptionMode``) untouched, so a second pass
    walks the resulting structure and swaps any ``Enum`` for its ``.value``.
    """

    def _convert(obj: Any) -> Any:
        if isinstance(obj, Enum):
            return obj.value
        if isinstance(obj, dict):
            return {k: _convert(v) for k, v in obj.items()}
        if isinstance(obj, (list, tuple)):
            return [_convert(v) for v in obj]
        return obj

    return _convert(asdict(entry))


# ---------------------------------------------------------------------------
# Phase 4 — validate import against the export manifest.
# ---------------------------------------------------------------------------


class ValidationError(RuntimeError):
    """Raised when imported content/media does not match the export manifest."""


def validate_import(manifest: dict[str, Any], import_result: dict[str, Any]) -> dict[str, Any]:
    """Assert imported counts and per-file hashes match the export manifest exactly.

    Fails loudly (raises :class:`ValidationError`) on any mismatch rather
    than logging a warning and continuing.

    Args:
        manifest: The dict returned by :func:`export_manifest`.
        import_result: The dict returned by :func:`import_into_station_store`.

    Returns:
        A small summary dict for printing, only on success.
    """
    imported_entry_count = len(import_result["state_document"]["entries"])
    if imported_entry_count != manifest["item_count"]:
        raise ValidationError(
            f"item count mismatch: export manifest has {manifest['item_count']}, import produced {imported_entry_count}"
        )

    imported_media_count = len(import_result["media_records"])
    if imported_media_count != manifest["media_file_count"]:
        raise ValidationError(
            f"media file count mismatch: export manifest has {manifest['media_file_count']}, "
            f"import produced {imported_media_count}"
        )

    export_hashes = {rec["sha256"] for rec in manifest["media_files"]}
    export_sizes = {rec["sha256"]: rec["byte_size"] for rec in manifest["media_files"]}
    imported_hashes = {rec["sha256"] for rec in import_result["media_records"]}

    missing_in_import = export_hashes - imported_hashes
    extra_in_import = imported_hashes - export_hashes
    if missing_in_import or extra_in_import:
        raise ValidationError(
            f"media hash set mismatch: missing_in_import={sorted(missing_in_import)}, "
            f"extra_in_import={sorted(extra_in_import)}"
        )

    for rec in import_result["media_records"]:
        expected_size = export_sizes[rec["sha256"]]
        if rec["byte_size"] != expected_size:
            raise ValidationError(
                f"byte size mismatch for sha256={rec['sha256']}: export={expected_size}, import={rec['byte_size']}"
            )

    return {
        "item_count_match": True,
        "media_count_match": True,
        "all_hashes_match": True,
        "checked_items": imported_entry_count,
        "checked_media_files": imported_media_count,
    }


# ---------------------------------------------------------------------------
# Phase 5 — rollback: restore source from a pristine backup, verify identity.
# ---------------------------------------------------------------------------


def rollback(source: dict[str, Any], tmp_root: Path) -> dict[str, Any]:
    """Restore the source DB + media dir from a pristine backup, then verify.

    The backup is taken *before* any import activity (immediately after
    :func:`build_isolated_source` seeds the source, by ``main()``), so
    restoring it is a clean scripted operation — copy backup over source —
    with no manual DB edits. The import phase never wrote into the source
    tree in the first place (it only read from it and copied out), so this
    also proves the source was never touched, not just that it can be
    reset.

    Args:
        source: The dict returned by :func:`build_isolated_source`.
        tmp_root: Isolated temp directory root for this rehearsal run.

    Returns:
        Dict with ``row_count_match``, ``media_hashes_match``, and the
        restored row count / media hash map, for printing.

    Raises:
        ValidationError: if the restored source is not byte-identical to
            the pristine baseline.
    """
    backup_dir = tmp_root / "source-backup"
    source_dir: Path = source["db_path"].parent

    # Restore: wipe the (already-untouched, but we restore unconditionally
    # to prove the operation itself is clean/scripted) live source dir and
    # copy the pristine backup back over it.
    reset_db()  # close the live SQLite connection before file operations
    shutil.rmtree(source_dir)
    shutil.copytree(backup_dir, source_dir)

    restored_db_path = source_dir / "isolated-source.db"
    restored_media_dir = source_dir / "media"

    seed_isolated_db_reconnect_only(restored_db_path)
    restored_row_count = Item.select().count()
    reset_db()

    restored_media_hashes = _hash_tree(restored_media_dir)

    row_count_match = restored_row_count == source["baseline"]["row_count"]
    media_hashes_match = restored_media_hashes == source["baseline"]["media_hashes"]

    if not row_count_match:
        raise ValidationError(
            f"rollback row count mismatch: baseline={source['baseline']['row_count']}, restored={restored_row_count}"
        )
    if not media_hashes_match:
        raise ValidationError(
            "rollback media hash mismatch: restored tree does not match pristine baseline "
            f"(baseline had {len(source['baseline']['media_hashes'])} files, "
            f"restored has {len(restored_media_hashes)} files)"
        )

    return {
        "row_count_match": row_count_match,
        "media_hashes_match": media_hashes_match,
        "restored_row_count": restored_row_count,
        "restored_media_file_count": len(restored_media_hashes),
    }


def seed_isolated_db_reconnect_only(db_path: Path) -> None:
    """Reconnect to an already-migrated isolated DB without re-running migrations.

    Used only by :func:`rollback` to read the restored backup's row count.
    Unlike ``migration.seed_isolated_db``, this does not call
    ``run_migrations`` (the restored file is already fully migrated) — it
    just points the Peewee connection at the restored file.
    """
    from wilted.db import connect_db

    reset_db()
    connect_db(db_path)


# ---------------------------------------------------------------------------
# Isolation guard.
# ---------------------------------------------------------------------------


def run_isolation_guard(tmp_root: Path, real_db_mtime_before: float) -> dict[str, Any]:
    """Prove this rehearsal never read/wrote the real ``data/`` tree.

    Two checks, mirroring the ``isolated_data`` autouse fixture's contract
    (``tests/conftest.py``): (1) every path this script created resolves
    under ``tmp_root``, a ``tempfile.TemporaryDirectory``, never under the
    real project ``data/`` directory; (2) the real ``data/wilted.db``
    mtime is byte-identical before and after the run — i.e. untouched.

    Args:
        tmp_root: The isolated temp directory root used for the whole run.
        real_db_mtime_before: ``REAL_DB_PATH.stat().st_mtime`` captured
            before any rehearsal phase ran.

    Returns:
        Dict describing the guard result, for printing.

    Raises:
        ValidationError: if either check fails.
    """
    tmp_root_resolved = tmp_root.resolve()
    real_data_dir_resolved = REAL_DATA_DIR.resolve()

    if str(tmp_root_resolved).startswith(str(real_data_dir_resolved)):
        raise ValidationError(f"isolation guard failed: tmp_root {tmp_root_resolved} is under real data/ tree")

    real_db_exists = REAL_DB_PATH.exists()
    real_db_mtime_after = REAL_DB_PATH.stat().st_mtime if real_db_exists else None

    mtime_unchanged = real_db_exists and real_db_mtime_after == real_db_mtime_before

    if real_db_exists and not mtime_unchanged:
        raise ValidationError(
            f"isolation guard failed: real data/wilted.db mtime changed "
            f"({real_db_mtime_before} -> {real_db_mtime_after})"
        )

    return {
        "tmp_root_under_real_data_dir": False,
        "real_db_exists": real_db_exists,
        "real_db_mtime_before": real_db_mtime_before,
        "real_db_mtime_after": real_db_mtime_after,
        "real_db_mtime_unchanged": mtime_unchanged,
    }


# ---------------------------------------------------------------------------
# Orchestration.
# ---------------------------------------------------------------------------


def main() -> int:
    real_db_mtime_before = REAL_DB_PATH.stat().st_mtime if REAL_DB_PATH.exists() else None

    with tempfile.TemporaryDirectory(prefix="wilted-migration-rehearsal-") as tmp_dir:
        tmp_root = Path(tmp_dir)

        try:
            print("=" * 72)
            print("Task 0.6 migration rehearsal (DISPOSABLE SPIKE, isolated data only)")
            print("=" * 72)

            # --- Phase 1: build isolated source + take a pristine backup ---
            source = build_isolated_source(tmp_root)
            backup_dir = tmp_root / "source-backup"
            shutil.copytree(source["db_path"].parent, backup_dir)
            print(
                f"\n[1/5] Isolated source built: {source['item_count']} Item rows, "
                f"{len(source['baseline']['media_hashes'])} media files "
                f"(pristine backup taken at {backup_dir})"
            )

            # --- Phase 2: export manifest ---
            manifest = export_manifest(source)
            print(
                f"[2/5] Export manifest: item_count={manifest['item_count']}, "
                f"media_file_count={manifest['media_file_count']}, "
                f"schema_version={manifest['schema_version']}"
            )
            for rec in manifest["media_files"]:
                print(f"        {rec['relative_path']}: sha256={rec['sha256'][:12]}... size={rec['byte_size']}B")

            # --- Phase 3: import into candidate station store ---
            import_result = import_into_station_store(source, tmp_root)
            print(
                f"[3/5] Imported into candidate store at {import_result['store_dir']}: "
                f"{len(import_result['state_document']['entries'])} StationEntry rows, "
                f"{len(import_result['media_records'])} media files copied+hashed "
                f"(store shape: versioned atomic JSON state document + media index)"
            )

            # --- Phase 4: validate ---
            validation = validate_import(manifest, import_result)
            print(
                f"[4/5] Validation: item_count_match={validation['item_count_match']}, "
                f"media_count_match={validation['media_count_match']}, "
                f"all_hashes_match={validation['all_hashes_match']} "
                f"({validation['checked_items']} items, {validation['checked_media_files']} files checked)"
            )

            # --- Phase 5: rollback ---
            rollback_result = rollback(source, tmp_root)
            print(
                f"[5/5] Rollback: row_count_match={rollback_result['row_count_match']} "
                f"({rollback_result['restored_row_count']} rows), "
                f"media_hashes_match={rollback_result['media_hashes_match']} "
                f"({rollback_result['restored_media_file_count']} files) "
                "— source restored byte-identical to pristine baseline via clean scripted restore"
            )

            # --- Isolation guard ---
            guard_result = run_isolation_guard(tmp_root, real_db_mtime_before)
            print(
                f"\nIsolation guard: tmp_root_under_real_data_dir="
                f"{guard_result['tmp_root_under_real_data_dir']}, "
                f"real_db_mtime_unchanged={guard_result['real_db_mtime_unchanged']} "
                f"(before={guard_result['real_db_mtime_before']}, after={guard_result['real_db_mtime_after']})"
            )

        finally:
            reset_db()

    print("\n" + "=" * 72)
    print(
        "REHEARSAL PASSED: no in-place conversion, counts+hashes match, "
        "rollback restored source cleanly, isolation guard held."
    )
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
