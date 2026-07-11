"""Tests for wilted.station_runtime.timing_map — content-addressed timing-map store.

Covers Task 2.5's guarantees:

- round-trip: save then load preserves order, offsets, and text
- empty segments (no-transcript legitimacy): save(()), load() -> () (not an
  error, not None-because-corrupt) — this module always-persists, including
  the empty case (see normalize.py's Task 2.5 wiring)
- absent vs corrupt: a never-written sha returns None; an unknown
  schema_version or non-JSON/non-dict content raises TimingMapVersionError
  and leaves the on-disk file byte-for-byte unchanged
- atomic write: no leftover tempfiles in the shard dir; a re-save fully
  replaces the prior segments
- INV-5: save/load follow a live, monkeypatched wilted.DATA_DIR
"""

from __future__ import annotations

import json

import pytest

import wilted
from wilted.station.models import TranscriptSegment
from wilted.station_runtime.timing_map import (
    TIMING_MAP_SCHEMA_VERSION,
    TimingMapVersionError,
    load_timing_map,
    save_timing_map,
)

pytestmark = pytest.mark.unit

_FAKE_SHA = "a" * 64


def _shard_dir(sha256: str):
    return wilted.DATA_DIR / "timing_maps" / sha256[:2]


def _timing_map_path(sha256: str):
    return _shard_dir(sha256) / f"{sha256}.json"


# ---------------------------------------------------------------------------
# Round-trip
# ---------------------------------------------------------------------------


def test_round_trip_preserves_order_offsets_and_text():
    segments = (
        TranscriptSegment(start_ms=0, end_ms=1000, text="first"),
        TranscriptSegment(start_ms=1000, end_ms=2500, text="second"),
        TranscriptSegment(start_ms=2500, end_ms=4000, text="third"),
    )

    save_timing_map(_FAKE_SHA, segments)
    loaded = load_timing_map(_FAKE_SHA)

    assert loaded == segments


def test_round_trip_empty_segments_is_legitimate_not_an_error():
    """A no-transcript podcast persists an empty segments list; loading it
    back must return () — NOT None (which would mean "never written") and
    NOT an error."""
    save_timing_map(_FAKE_SHA, ())

    loaded = load_timing_map(_FAKE_SHA)

    assert loaded == ()
    assert loaded is not None


# ---------------------------------------------------------------------------
# Absent vs corrupt vs empty
# ---------------------------------------------------------------------------


def test_absent_sha_returns_none():
    never_written_sha = "b" * 64
    assert load_timing_map(never_written_sha) is None


def test_unknown_schema_version_raises_and_leaves_file_unchanged():
    sha256 = "c" * 64
    path = _timing_map_path(sha256)
    path.parent.mkdir(parents=True, exist_ok=True)
    bad_doc = {"schema_version": 999, "sha256": sha256, "segments": []}
    path.write_text(json.dumps(bad_doc))
    original_bytes = path.read_bytes()

    with pytest.raises(TimingMapVersionError):
        load_timing_map(sha256)

    assert path.read_bytes() == original_bytes


def test_non_json_content_raises():
    sha256 = "d" * 64
    path = _timing_map_path(sha256)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{ not valid json")

    with pytest.raises(TimingMapVersionError):
        load_timing_map(sha256)


def test_non_dict_json_content_raises():
    sha256 = "e" * 64
    path = _timing_map_path(sha256)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps([1, 2, 3]))

    with pytest.raises(TimingMapVersionError):
        load_timing_map(sha256)


def test_corrupt_file_is_not_overwritten_by_a_subsequent_save_attempt_check():
    """Belt-and-suspenders: confirm the corrupt-file test above didn't
    accidentally get repaired by some other call — re-checking load raises
    again (not: silently starts returning None/empty after the first
    failure)."""
    sha256 = "f" * 64
    path = _timing_map_path(sha256)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{ not valid json")

    with pytest.raises(TimingMapVersionError):
        load_timing_map(sha256)
    with pytest.raises(TimingMapVersionError):
        load_timing_map(sha256)

    assert path.read_text() == "{ not valid json"


# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------


def test_save_leaves_no_leftover_tempfiles_in_shard_dir():
    sha256 = "1" * 64
    save_timing_map(sha256, (TranscriptSegment(start_ms=0, end_ms=500, text="only"),))

    shard_dir = _shard_dir(sha256)
    entries = list(shard_dir.iterdir())

    assert entries == [_timing_map_path(sha256)]


def test_resave_with_different_segments_fully_replaces():
    sha256 = "2" * 64
    original = (TranscriptSegment(start_ms=0, end_ms=1000, text="old"),)
    replacement = (
        TranscriptSegment(start_ms=0, end_ms=500, text="new-a"),
        TranscriptSegment(start_ms=500, end_ms=900, text="new-b"),
    )

    save_timing_map(sha256, original)
    save_timing_map(sha256, replacement)

    loaded = load_timing_map(sha256)
    assert loaded == replacement


def test_on_disk_envelope_shape():
    sha256 = "3" * 64
    segments = (TranscriptSegment(start_ms=10, end_ms=20, text="hi"),)
    save_timing_map(sha256, segments)

    path = _timing_map_path(sha256)
    with path.open() as f:
        doc = json.load(f)

    assert doc == {
        "schema_version": TIMING_MAP_SCHEMA_VERSION,
        "sha256": sha256,
        "segments": [{"start_ms": 10, "end_ms": 20, "text": "hi"}],
    }


def test_path_is_sharded_by_first_two_hex_chars():
    sha256 = "abcd" + "0" * 60
    save_timing_map(sha256, ())

    expected_path = wilted.DATA_DIR / "timing_maps" / "ab" / f"{sha256}.json"
    assert expected_path.exists()


# ---------------------------------------------------------------------------
# INV-5: live wilted.DATA_DIR resolution
# ---------------------------------------------------------------------------


def test_inv5_save_and_load_follow_live_data_dir(monkeypatch, tmp_path):
    other_data_dir = tmp_path / "other_data"
    other_data_dir.mkdir()
    monkeypatch.setattr(wilted, "DATA_DIR", other_data_dir)

    sha256 = "4" * 64
    segments = (TranscriptSegment(start_ms=0, end_ms=100, text="redirected"),)
    save_timing_map(sha256, segments)

    expected_path = other_data_dir / "timing_maps" / sha256[:2] / f"{sha256}.json"
    assert expected_path.exists()

    loaded = load_timing_map(sha256)
    assert loaded == segments
