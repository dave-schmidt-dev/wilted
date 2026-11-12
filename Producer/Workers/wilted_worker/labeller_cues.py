"""Canonical cue-list export for the labelling model.

The response's cues are the reader's transcript, remapped onto whatever audio
the run delivered. The labelling model needs the other projection: the aligned
segments exactly as speech-to-text produced them, on the original clock, with
stable 0-based identifiers (the segment index the labelling prompt prints). This module is that projection and nothing else --
it performs no network access and changes no cut decision.
"""
from __future__ import annotations

import json
import os
import tempfile
from hashlib import sha256
from pathlib import Path

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
