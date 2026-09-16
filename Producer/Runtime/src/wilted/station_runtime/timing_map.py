"""Content-addressed, versioned timing-map store keyed by media sha256.

A "timing map" is the ordered tuple of
:class:`wilted.station.models.TranscriptSegment` that
:func:`wilted.station_runtime.normalize.normalize_item` resolves for a piece
of media (podcast transcript segments, or an article's cumulative
per-paragraph segments). This module persists that tuple to disk, keyed by
the media's SHA-256, so it can be reloaded without re-deriving it (e.g.
re-transcribing or re-assembling) later.

Layout mirrors :mod:`wilted.station_runtime.media_store`'s content-addressed
sharding::

    timing_maps/<sha256[:2]>/<sha256>.json

Versioned envelope, atomic writes, and refuse-on-corrupt/unknown-version
discipline mirror :mod:`wilted.station_runtime.store`
(``JsonStationStore``): an on-disk timing-map file this module cannot
understand — an unknown/newer ``schema_version``, non-JSON content, or JSON
that doesn't parse to the expected shape — is never silently treated as
"no timing map" or overwritten. :func:`load_timing_map` raises
:class:`TimingMapVersionError` instead, so a caller can decide how to handle
an unreadable file rather than losing data. Only a genuinely *absent* file
is treated as "no timing map yet" (returns ``None``).

Empty segments are legitimate and persisted as-is: a no-transcript podcast is
explicitly ``NO_INTERRUPT`` with zero transcript segments (see
``normalize.py``'s no-transcript rule), and that "zero segments" fact is
itself worth persisting/round-tripping — it is not the same as "no timing
map was ever written for this hash". This differs from
:mod:`wilted.station_runtime.media_store`, which refuses to publish empty
*bytes* (INV-4): segment *metadata* may legitimately be an empty tuple.

INV-5: ``wilted.DATA_DIR`` is resolved by attribute access on the ``wilted``
module at *call time* in every function below, never imported as a bare
name at module scope — see ``wilted.cache`` for the full rationale. This lets
tests redirect all I/O by monkeypatching the live ``wilted.DATA_DIR``
attribute.
"""

from __future__ import annotations

import json
import os
import tempfile
from typing import TYPE_CHECKING, Any

import wilted
from wilted.station.models import TranscriptSegment

if TYPE_CHECKING:
    from pathlib import Path

__all__ = [
    "TIMING_MAP_SCHEMA_VERSION",
    "TimingMapVersionError",
    "load_timing_map",
    "save_timing_map",
]

TIMING_MAP_SCHEMA_VERSION = 1
"""Schema version of the on-disk timing-map envelope.

Bump this, and add explicit migration/refusal handling in
:func:`_decode_segments`, if the on-disk shape ever changes incompatibly. An
unknown version is always a hard refusal (see :class:`TimingMapVersionError`),
never a best-effort/partial read.
"""

_TIMING_MAPS_SUBDIR = "timing_maps"
_SHARD_PREFIX_LEN = 2


class TimingMapVersionError(Exception):
    """Raised when an on-disk timing-map file cannot be read safely.

    Covers an unknown/newer ``schema_version``, structurally corrupt JSON,
    non-UTF-8/binary content, JSON that parses but not to an object at its
    top level, and a document whose ``sha256``/``segments`` fields are
    missing or malformed. In every case the on-disk file is left completely
    untouched — this store never silently overwrites a file it cannot
    understand, and never conflates "unreadable" with "absent".
    """


def _shard_dir(sha256: str) -> Path:
    """Return the shard directory for a given hex digest (INV-5: call-time)."""
    return wilted.DATA_DIR / _TIMING_MAPS_SUBDIR / sha256[:_SHARD_PREFIX_LEN]


def _timing_map_path(sha256: str) -> Path:
    """Return the timing-map file path for ``sha256`` (INV-5: call-time)."""
    return _shard_dir(sha256) / f"{sha256}.json"


def _encode_segment(seg: TranscriptSegment) -> dict[str, Any]:
    return {"start_ms": seg.start_ms, "end_ms": seg.end_ms, "text": seg.text}


def _decode_segment(d: dict[str, Any]) -> TranscriptSegment:
    return TranscriptSegment(start_ms=d["start_ms"], end_ms=d["end_ms"], text=d["text"])


def _decode_doc(doc: Any, path: Path) -> tuple[TranscriptSegment, ...]:
    """Decode a parsed JSON document into a segment tuple, or refuse.

    Raises:
        TimingMapVersionError: If ``doc`` is not a dict, has a missing/
            unexpected ``schema_version``, or is otherwise structurally
            invalid (missing/malformed ``sha256``/``segments`` fields).
    """
    if not isinstance(doc, dict):
        raise TimingMapVersionError(
            f"timing map document at {path} is not a JSON object (got {type(doc).__name__}); "
            "refusing to read (and will not overwrite it)"
        )
    schema_version = doc.get("schema_version")
    if schema_version != TIMING_MAP_SCHEMA_VERSION:
        raise TimingMapVersionError(
            f"timing map document at {path} has schema_version={schema_version!r}, "
            f"expected {TIMING_MAP_SCHEMA_VERSION!r}; refusing to read (and will not overwrite it)"
        )
    try:
        segments_raw = doc["segments"]
        return tuple(_decode_segment(s) for s in segments_raw)
    except (KeyError, TypeError, ValueError) as exc:
        raise TimingMapVersionError(
            f"timing map document at {path} is structurally invalid and cannot be read safely: {exc!r}"
        ) from exc


def save_timing_map(sha256: str, segments: tuple[TranscriptSegment, ...]) -> None:
    """Atomically persist ``segments`` as the timing map for ``sha256``.

    Writes a versioned JSON envelope to
    ``wilted.DATA_DIR / "timing_maps" / sha256[:2] / f"{sha256}.json"`` via a
    tempfile written in the same shard directory followed by ``os.replace``
    (mirrors :mod:`wilted.station_runtime.store` /
    :mod:`wilted.station_runtime.media_store`) — a reader never observes a
    partially written file.

    Content-addressed and idempotent: calling this again for the same
    ``sha256`` fully replaces any prior timing map for that hash (last write
    wins), which is safe because ``sha256`` names immutable content — a
    re-normalization of the same item is expected to re-derive and re-write
    the same segments harmlessly.

    Empty ``segments`` (``()``) is a legitimate input (a no-transcript
    podcast is explicitly ``NO_INTERRUPT`` with zero segments) and is
    persisted as an empty list, not refused — unlike
    :func:`wilted.station_runtime.media_store.publish`, which refuses empty
    *bytes* (INV-4); segment metadata has no such restriction.

    Args:
        sha256: Content hash of the media this timing map describes.
        segments: Ordered transcript/chapter segments (possibly empty).
    """
    path = _timing_map_path(sha256)
    shard_dir = path.parent
    shard_dir.mkdir(parents=True, exist_ok=True)

    doc = {
        "schema_version": TIMING_MAP_SCHEMA_VERSION,
        "sha256": sha256,
        "segments": [_encode_segment(seg) for seg in segments],
    }

    with tempfile.NamedTemporaryFile("w", dir=shard_dir, suffix=".tmp", delete=False) as f:
        json.dump(doc, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, path)


def load_timing_map(sha256: str) -> tuple[TranscriptSegment, ...] | None:
    """Return the persisted timing map for ``sha256``, or None if never written.

    The absent-vs-unreadable distinction is based solely on
    ``path.exists()``. A file that exists but is not valid JSON, is not
    decodable as UTF-8 text, does not contain a JSON object at its top
    level, has a missing/unexpected ``schema_version``, or is otherwise
    structurally invalid is unreadable, not absent — it must never be
    treated as "no timing map yet" and silently returned as ``None``.

    Returns:
        The ordered tuple of :class:`TranscriptSegment` (possibly empty),
        or ``None`` if no timing map has ever been written for ``sha256``.

    Raises:
        TimingMapVersionError: If the file exists but cannot be safely read
            (see above). The on-disk file is left completely untouched.
    """
    path = _timing_map_path(sha256)
    if not path.exists():
        return None

    try:
        with path.open() as f:
            doc = json.load(f)
    except json.JSONDecodeError as exc:
        raise TimingMapVersionError(f"timing map document at {path} is corrupt (invalid JSON): {exc!r}") from exc
    except UnicodeDecodeError as exc:
        raise TimingMapVersionError(f"timing map document at {path} is not valid UTF-8 text: {exc!r}") from exc

    return _decode_doc(doc, path)
