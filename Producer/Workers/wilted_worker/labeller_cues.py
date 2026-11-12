"""Canonical cue-list export for the labelling model.

The response's cues are the reader's transcript, remapped onto whatever audio
the run delivered. The labelling model needs the other projection: the aligned
segments exactly as speech-to-text produced them, on the original clock, with
stable 0-based identifiers (the segment index the labelling prompt prints). This module is that projection and nothing else --
it performs no network access and changes no cut decision.

The backfill export below is the same projection over transcripts the worker
already stored: it reads the aligned speech-to-text cache and writes one cue
file per entry, so episodes prepared earlier can be labelled without
re-downloading or re-transcribing them.
"""
from __future__ import annotations

import json
import os
import tempfile
from hashlib import sha256
from pathlib import Path

from . import reporting as _worker_reporting
from .constants import ALIGNED_STT_MODEL, PROTOCOL_VERSION
from .transcript_sources import _decode_cached_aligned_segments

LABELLER_CUES_FILENAME = "labeller-cues.json"

def build_labeller_cues(segments) -> list[dict]:
    """Build the canonical cue list from aligned transcript segments.

    Args:
        segments: Time-ordered aligned segments exposing ``text``, ``start_s``
            and ``end_s``.

    Returns:
        A list of cue objects with exactly ``id`` (int, the 0-based segment index, in order),
        ``start`` and ``end`` (seconds, rounded to 3 decimals) and ``text``
        (stripped).
    """
    cues: list[dict] = []
    for index, segment in enumerate(segments):
        cues.append({
            "id": index,
            "start": round(float(segment.start_s), 3),
            "end": round(float(segment.end_s), 3),
            "text": str(segment.text).strip(),
        })
    return cues

def serialize_labeller_cues(cues) -> tuple[bytes, str]:
    """Serialize the cue list to canonical JSON bytes and their digest.

    Args:
        cues: The cue objects returned by :func:`build_labeller_cues`.

    Returns:
        A ``(payload, digest)`` pair: the canonical JSON as UTF-8 bytes (sorted
        keys, compact separators, non-ASCII kept literal) and their SHA-256
        hex digest.
    """
    payload = json.dumps(cues, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return payload, sha256(payload).hexdigest()

def write_labeller_cues(cues, work_directory) -> tuple[Path, str]:
    """Write the canonical cue list into the request's work directory.

    The bytes are the serialization, so the digest returned alongside the path
    is the digest of exactly what the file holds.

    Args:
        cues: The cue objects returned by :func:`build_labeller_cues`.
        work_directory: The worker's per-request data directory.

    Returns:
        The written file's path and the SHA-256 hex digest of its bytes.
    """
    payload, digest = serialize_labeller_cues(cues)
    directory = Path(work_directory)
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / LABELLER_CUES_FILENAME
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".labeller-cues-",
                                         suffix=".tmp", delete=False) as temporary:
            temporary.write(payload)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, destination)
    except BaseException:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        raise
    return destination, digest

def _write_bytes_atomically(payload: bytes, destination: Path) -> None:
    """Write ``payload`` to ``destination`` so a reader never sees a partial file."""
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".labeller-backfill-",
                                         suffix=".tmp", delete=False) as temporary:
            temporary.write(payload)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, destination)
    except BaseException:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        raise

def export_labeller_cues(request: dict) -> dict:
    """Export one cue file per aligned transcript stored in the request's cache.

    Episodes the worker already transcribed can be labelled without
    re-downloading or re-transcribing them: every valid cache entry recorded
    for the current model becomes the canonical cue bytes under
    ``<workDir>/wilted-pipeline/labeller-backfill/<sha256 of sourceHash>.json``.
    The cache is strictly read-only here -- unreadable or invalid entries are
    counted and left exactly as they lie, nothing is pruned or refreshed, and
    no transcript text reaches a progress record or an error message.

    Args:
        request: The worker request. Only ``workDir`` is required; a present
            ``protocolVersion`` must match the current protocol version.

    Returns:
        The ``labellerCues`` response: the export directory, one record per
        export (sorted by source hash, with the written file's SHA-256 digest)
        and the number of skipped cache entries.

    Raises:
        WorkerError: ``invalid-request`` when ``workDir`` is not a non-empty
            string, or ``protocol-version-unsupported`` when a present
            ``protocolVersion`` is not the current one.
    """
    work_dir = request.get("workDir")
    if not isinstance(work_dir, str) or not work_dir:
        # No fallback to the system temp dir: without the request's own work
        # directory there is no cache to read and nowhere to export to.
        raise _worker_reporting.WorkerError("invalid-request", "labellerCues requires a non-empty workDir")
    requested_version = request.get("protocolVersion")
    if requested_version is not None and requested_version != PROTOCOL_VERSION:
        raise _worker_reporting.WorkerError("protocol-version-unsupported", f"expected protocolVersion {PROTOCOL_VERSION}")

    cache_directory = Path(work_dir) / "wilted-pipeline" / "aligned-stt-cache"
    kept: list[tuple[str, list]] = []
    skipped = 0
    if cache_directory.is_dir():
        for path in sorted(cache_directory.glob("*.json")):
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
                segments = _decode_cached_aligned_segments(payload)
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                # Counted, never deleted: the cache belongs to preparation
                # runs, and a backfill must not destroy the evidence of what
                # it could not read.
                skipped += 1
                continue
            if payload["model"] != ALIGNED_STT_MODEL:
                continue
            if not segments:
                skipped += 1
                continue
            kept.append((payload["sourceHash"], segments))

    export_directory = Path(work_dir) / "wilted-pipeline" / "labeller-backfill"
    export_directory.mkdir(parents=True, exist_ok=True)
    for leftover in export_directory.iterdir():
        if leftover.is_file():
            leftover.unlink(missing_ok=True)
    exports = []
    for index, (source_hash, segments) in enumerate(kept, start=1):
        cues = build_labeller_cues(segments)
        cue_bytes, digest = serialize_labeller_cues(cues)
        destination = export_directory / f"{sha256(source_hash.encode('utf-8')).hexdigest()}.json"
        _write_bytes_atomically(cue_bytes, destination)
        _worker_reporting.progress("labeller.cues.export", f"{index}/{len(kept)}")
        exports.append({
            "sourceHash": source_hash,
            "cuesPath": str(destination),
            "cuesDigest": digest,
            "cueCount": len(cues),
            "lastCueEnd": max(cue["end"] for cue in cues),
        })
    return {
        "ok": True,
        "operation": "labellerCues",
        "protocolVersion": PROTOCOL_VERSION,
        "exportDirectory": str(export_directory),
        "exports": sorted(exports, key=lambda entry: entry["sourceHash"]),
        "skipped": skipped,
    }
