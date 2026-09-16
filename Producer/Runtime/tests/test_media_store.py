"""Tests for wilted.station_runtime.media_store — content-addressed store + owners index.

Covers the guarantees Task 2.1 of Plan A promises:

- publish/resolve round-trip (a descriptor's sha256 resolves to the immutable bytes)
- immutability (re-publishing identical bytes is idempotent; existing bytes are
  never rewritten; publishing different bytes yields a different hash)
- empty-input refused (INV-4)
- owners index records kind/entry_id/expiry per hash and survives a reload
- INV-5 (nothing is written under the real data/ tree; all I/O goes through the
  monkeypatched ``wilted.DATA_DIR``, exercised here via the autouse
  ``isolated_data`` fixture from ``tests/conftest.py``)
"""

from __future__ import annotations

import hashlib
import json
import threading
from datetime import UTC, datetime

import pytest

import wilted
from wilted.station_runtime import media_store

pytestmark = pytest.mark.unit


def test_publish_resolve_round_trip():
    data = b"hello station audio bytes"
    sha256 = media_store.publish(data)

    assert sha256 == hashlib.sha256(data).hexdigest()

    resolved = media_store.path_for(sha256)
    assert resolved is not None
    assert resolved.exists()
    assert resolved.read_bytes() == data
    assert media_store.exists(sha256)


def test_publish_from_file_path(tmp_path):
    src = tmp_path / "source.bin"
    src.write_bytes(b"some file-backed bytes")

    sha256 = media_store.publish(str(src))
    resolved = media_store.path_for(sha256)

    assert resolved is not None
    assert resolved.read_bytes() == b"some file-backed bytes"


def test_publish_file_convenience_wrapper(tmp_path):
    src = tmp_path / "source.bin"
    src.write_bytes(b"convenience wrapper bytes")

    sha256 = media_store.publish_file(src)
    resolved = media_store.path_for(sha256)

    assert resolved is not None
    assert resolved.read_bytes() == b"convenience wrapper bytes"


def test_path_for_missing_hash_returns_none():
    missing_hash = hashlib.sha256(b"never published").hexdigest()
    assert media_store.path_for(missing_hash) is None
    assert media_store.exists(missing_hash) is False


def test_republishing_identical_bytes_is_idempotent_noop():
    data = b"identical content"
    sha256_first = media_store.publish(data)
    path = media_store.path_for(sha256_first)
    assert path is not None

    original_mtime_ns = path.stat().st_mtime_ns
    original_inode = path.stat().st_ino

    sha256_second = media_store.publish(data)

    assert sha256_second == sha256_first
    # Existing bytes must never be rewritten: same inode, same mtime.
    assert path.stat().st_ino == original_inode
    assert path.stat().st_mtime_ns == original_mtime_ns
    assert path.read_bytes() == data


def test_different_bytes_yield_different_hash():
    sha256_a = media_store.publish(b"content A")
    sha256_b = media_store.publish(b"content B")

    assert sha256_a != sha256_b
    assert media_store.path_for(sha256_a).read_bytes() == b"content A"
    assert media_store.path_for(sha256_b).read_bytes() == b"content B"


def test_publish_empty_bytes_refused():
    with pytest.raises(media_store.EmptyMediaError):
        media_store.publish(b"")


def test_publish_empty_file_refused(tmp_path):
    src = tmp_path / "empty.bin"
    src.write_bytes(b"")

    with pytest.raises(media_store.EmptyMediaError):
        media_store.publish(str(src))


def test_empty_publish_does_not_create_a_blob():
    with pytest.raises(media_store.EmptyMediaError):
        media_store.publish(b"")

    empty_hash = hashlib.sha256(b"").hexdigest()
    assert media_store.path_for(empty_hash) is None


def test_sharded_layout_uses_first_two_hex_chars_as_subdir():
    data = b"shard layout check"
    sha256 = media_store.publish(data)

    expected_shard = wilted.DATA_DIR / "media" / sha256[:2]
    expected_path = expected_shard / sha256

    assert expected_path.exists()
    assert expected_path.read_bytes() == data


def test_owners_index_records_kind_entry_id_expiry():
    sha256 = media_store.publish(b"owned content")
    media_store.record_owner(sha256, kind="item", entry_id="item-42", expiry=None)

    owners = media_store.get_owners(sha256)
    assert owners == [{"kind": "item", "entry_id": "item-42", "expiry": None}]


def test_owners_index_survives_reload():
    sha256 = media_store.publish(b"reload check content")
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-2026-07-10T12:00Z", expiry="2026-07-10T13:00:00Z")

    owners_path = wilted.DATA_DIR / "media_owners.json"
    assert owners_path.exists()

    with owners_path.open() as f:
        on_disk = json.load(f)

    assert on_disk[sha256] == [
        {"kind": "bulletin", "entry_id": "wx-2026-07-10T12:00Z", "expiry": "2026-07-10T13:00:00Z"}
    ]

    # Simulate a fresh process re-reading the index rather than relying on
    # any in-memory cache.
    owners = media_store.get_owners(sha256)
    assert owners == [{"kind": "bulletin", "entry_id": "wx-2026-07-10T12:00Z", "expiry": "2026-07-10T13:00:00Z"}]


def test_multiple_distinct_owners_coexist():
    sha256 = media_store.publish(b"shared content, two owners")
    media_store.record_owner(sha256, kind="item", entry_id="item-1", expiry=None)
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry="2026-07-10T13:00:00Z")

    owners = media_store.get_owners(sha256)
    assert len(owners) == 2
    assert {"kind": "item", "entry_id": "item-1", "expiry": None} in owners
    assert {"kind": "bulletin", "entry_id": "wx-1", "expiry": "2026-07-10T13:00:00Z"} in owners


def test_recording_same_owner_again_updates_expiry_in_place():
    sha256 = media_store.publish(b"same owner, updated expiry")
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry="2026-07-10T13:00:00Z")
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry="2026-07-10T14:00:00Z")

    owners = media_store.get_owners(sha256)
    assert owners == [{"kind": "bulletin", "entry_id": "wx-1", "expiry": "2026-07-10T14:00:00Z"}]


def test_get_owners_for_unknown_hash_returns_empty_list():
    unknown_hash = hashlib.sha256(b"no owners here").hexdigest()
    assert media_store.get_owners(unknown_hash) == []


def test_record_owner_rejects_invalid_kind():
    sha256 = media_store.publish(b"invalid kind check")
    with pytest.raises(ValueError):
        media_store.record_owner(sha256, kind="not-a-kind", entry_id="x")  # type: ignore[arg-type]


def test_record_owner_rejects_empty_entry_id():
    sha256 = media_store.publish(b"empty entry_id check")
    with pytest.raises(ValueError):
        media_store.record_owner(sha256, kind="item", entry_id="")


def test_publish_with_owner_combines_publish_and_record():
    sha256 = media_store.publish_with_owner(b"combined call", kind="item", entry_id="item-99")

    assert media_store.path_for(sha256).read_bytes() == b"combined call"
    assert media_store.get_owners(sha256) == [{"kind": "item", "entry_id": "item-99", "expiry": None}]


def test_inv5_nothing_written_under_real_data_dir(monkeypatch, tmp_path):
    """Belt-and-suspenders INV-5 check beyond the autouse isolated_data fixture.

    Redirect wilted.DATA_DIR to a *second*, distinct temp directory partway
    through the test and confirm media_store follows the live attribute
    rather than any value captured at import time.
    """
    real_project_data_dir = wilted.PROJECT_ROOT / "data"
    before_snapshot = set(real_project_data_dir.rglob("*")) if real_project_data_dir.exists() else set()

    other_data_dir = tmp_path / "other_data"
    other_data_dir.mkdir()
    monkeypatch.setattr(wilted, "DATA_DIR", other_data_dir)

    sha256 = media_store.publish(b"inv5 redirected content")
    media_store.record_owner(sha256, kind="item", entry_id="inv5-item")

    assert (other_data_dir / "media" / sha256[:2] / sha256).exists()
    assert (other_data_dir / "media_owners.json").exists()

    after_snapshot = set(real_project_data_dir.rglob("*")) if real_project_data_dir.exists() else set()
    assert after_snapshot == before_snapshot


# ---------------------------------------------------------------------------
# Robustness: corrupt/partial on-disk state must refuse-and-report, never
# silently drop durable data that a later GC pass (Task 4.4) relies on.
# ---------------------------------------------------------------------------


def test_corrupt_owners_json_raises_on_get_owners():
    owners_path = wilted.DATA_DIR / "media_owners.json"
    owners_path.parent.mkdir(parents=True, exist_ok=True)
    owners_path.write_text("{ not json")

    with pytest.raises(media_store.MediaOwnersCorruptError):
        media_store.get_owners("deadbeef")


def test_corrupt_owners_json_raises_on_record_owner():
    owners_path = wilted.DATA_DIR / "media_owners.json"
    owners_path.parent.mkdir(parents=True, exist_ok=True)
    owners_path.write_text("{ not json")

    with pytest.raises(media_store.MediaOwnersCorruptError):
        media_store.record_owner("deadbeef", kind="item", entry_id="item-1")


def test_non_dict_owners_json_raises_on_get_owners():
    owners_path = wilted.DATA_DIR / "media_owners.json"
    owners_path.parent.mkdir(parents=True, exist_ok=True)
    owners_path.write_text(json.dumps([]))

    with pytest.raises(media_store.MediaOwnersCorruptError):
        media_store.get_owners("deadbeef")


def test_non_dict_owners_json_raises_on_record_owner():
    owners_path = wilted.DATA_DIR / "media_owners.json"
    owners_path.parent.mkdir(parents=True, exist_ok=True)
    owners_path.write_text(json.dumps([]))

    with pytest.raises(media_store.MediaOwnersCorruptError):
        media_store.record_owner("deadbeef", kind="item", entry_id="item-1")


def test_absent_owners_file_still_behaves_as_empty_start():
    owners_path = wilted.DATA_DIR / "media_owners.json"
    assert not owners_path.exists()

    assert media_store.get_owners("deadbeef") == []

    # And record_owner still works normally against a never-written index.
    media_store.record_owner("deadbeef", kind="item", entry_id="item-1")
    assert media_store.get_owners("deadbeef") == [{"kind": "item", "entry_id": "item-1", "expiry": None}]


def test_publish_repairs_zero_byte_preexisting_blob():
    data = b"content that should end up on disk"
    sha256 = hashlib.sha256(data).hexdigest()

    shard_dir = wilted.DATA_DIR / "media" / sha256[:2]
    shard_dir.mkdir(parents=True, exist_ok=True)
    broken_path = shard_dir / sha256
    broken_path.write_bytes(b"")
    assert broken_path.stat().st_size == 0

    result_sha256 = media_store.publish(data)

    assert result_sha256 == sha256
    resolved = media_store.path_for(sha256)
    assert resolved is not None
    assert resolved.read_bytes() == data
    assert resolved.stat().st_size == len(data)


def test_concurrent_record_owner_calls_lose_no_rows():
    sha256 = media_store.publish(b"concurrency target content")
    num_owners = 20
    barrier = threading.Barrier(num_owners)
    errors: list[BaseException] = []

    def record(i: int) -> None:
        try:
            barrier.wait(timeout=5)
            media_store.record_owner(sha256, kind="item", entry_id=f"item-{i}")
        except BaseException as exc:  # noqa: BLE001 - surface any thread failure to the test
            errors.append(exc)

    threads = [threading.Thread(target=record, args=(i,)) for i in range(num_owners)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert not errors, f"record_owner raised in a thread: {errors}"

    owners = media_store.get_owners(sha256)
    recorded_entry_ids = {owner["entry_id"] for owner in owners}
    expected_entry_ids = {f"item-{i}" for i in range(num_owners)}
    assert recorded_entry_ids == expected_entry_ids
    assert len(owners) == num_owners


# ---------------------------------------------------------------------------
# collect_expired_bulletins (Task 4.4): bulletin GC, and the INV-4 guarantee
# that durable Item media is never touched by it.
# ---------------------------------------------------------------------------

_NOW = datetime(2026, 7, 10, 13, 0, 0, tzinfo=UTC)
_PAST_Z = "2026-07-10T12:00:00Z"  # before _NOW: expired
_FUTURE_Z = "2026-07-10T14:00:00Z"  # after _NOW: not yet expired


def test_collect_expired_bulletins_deletes_blob_and_owners_entry():
    sha256 = media_store.publish(b"fully expired bulletin audio")
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry=_PAST_Z)

    path = media_store.path_for(sha256)
    assert path is not None
    assert path.exists()

    collected = media_store.collect_expired_bulletins(_NOW)

    assert collected == [sha256]
    assert not path.exists()
    assert media_store.get_owners(sha256) == []

    owners_path = wilted.DATA_DIR / "media_owners.json"
    with owners_path.open() as f:
        on_disk = json.load(f)
    assert sha256 not in on_disk


def test_collect_expired_bulletins_never_deletes_hash_with_item_owner():
    """INV-4: an item owner protects a hash even if it also carries an
    already-expired bulletin owner -- the durable-media safety property."""
    sha256 = media_store.publish(b"durable item audio, plus an expired bulletin owner")
    media_store.record_owner(sha256, kind="item", entry_id="item-1", expiry=None)
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry=_PAST_Z)

    path = media_store.path_for(sha256)
    assert path is not None

    collected = media_store.collect_expired_bulletins(_NOW)

    assert collected == []
    assert path.exists()
    owners = media_store.get_owners(sha256)
    assert {"kind": "item", "entry_id": "item-1", "expiry": None} in owners
    assert {"kind": "bulletin", "entry_id": "wx-1", "expiry": _PAST_Z} in owners


def test_collect_expired_bulletins_retains_not_yet_expired_bulletin_owner():
    sha256 = media_store.publish(b"bulletin audio that has not expired yet")
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry=_FUTURE_Z)

    collected = media_store.collect_expired_bulletins(_NOW)

    assert collected == []
    assert media_store.exists(sha256)
    assert media_store.get_owners(sha256) == [{"kind": "bulletin", "entry_id": "wx-1", "expiry": _FUTURE_Z}]


def test_collect_expired_bulletins_never_collects_expiry_none_bulletin_owner():
    sha256 = media_store.publish(b"bulletin audio that never expires")
    media_store.record_owner(sha256, kind="bulletin", entry_id="wx-1", expiry=None)

    collected = media_store.collect_expired_bulletins(_NOW)

    assert collected == []
    assert media_store.exists(sha256)
    assert media_store.get_owners(sha256) == [{"kind": "bulletin", "entry_id": "wx-1", "expiry": None}]


def test_collect_expired_bulletins_multiple_hashes_only_fully_expired_collected():
    """A mixed owners index: only the hash with nothing but expired bulletin
    owners is collected. Item-owned, unexpired, and never-expiring hashes
    all survive, and the return value names exactly the collected hash."""
    expired_only = media_store.publish(b"hash A: nothing but a fully expired bulletin owner")
    media_store.record_owner(expired_only, kind="bulletin", entry_id="wx-a", expiry=_PAST_Z)

    item_and_expired_bulletin = media_store.publish(b"hash B: item owner plus an expired bulletin owner")
    media_store.record_owner(item_and_expired_bulletin, kind="item", entry_id="item-b", expiry=None)
    media_store.record_owner(item_and_expired_bulletin, kind="bulletin", entry_id="wx-b", expiry=_PAST_Z)

    unexpired = media_store.publish(b"hash C: bulletin owner not yet expired")
    media_store.record_owner(unexpired, kind="bulletin", entry_id="wx-c", expiry=_FUTURE_Z)

    partially_expired = media_store.publish(b"hash D: one expired and one not-yet-expired bulletin owner")
    media_store.record_owner(partially_expired, kind="bulletin", entry_id="wx-d1", expiry=_PAST_Z)
    media_store.record_owner(partially_expired, kind="bulletin", entry_id="wx-d2", expiry=_FUTURE_Z)

    collected = media_store.collect_expired_bulletins(_NOW)

    assert collected == [expired_only]
    assert media_store.path_for(expired_only) is None
    assert media_store.get_owners(expired_only) == []

    assert media_store.exists(item_and_expired_bulletin)
    assert len(media_store.get_owners(item_and_expired_bulletin)) == 2

    assert media_store.exists(unexpired)
    assert media_store.get_owners(unexpired) == [{"kind": "bulletin", "entry_id": "wx-c", "expiry": _FUTURE_Z}]

    assert media_store.exists(partially_expired)
    assert len(media_store.get_owners(partially_expired)) == 2


def test_collect_expired_bulletins_raises_on_corrupt_owners_doc_and_deletes_nothing():
    sha256 = media_store.publish(b"content sitting under a soon-to-be-corrupted owners doc")
    path = media_store.path_for(sha256)
    assert path is not None

    owners_path = wilted.DATA_DIR / "media_owners.json"
    owners_path.write_text("{ not json")

    with pytest.raises(media_store.MediaOwnersCorruptError):
        media_store.collect_expired_bulletins(_NOW)

    # Refusal must be total: the blob that was sitting on disk before the
    # corrupt read is completely untouched.
    assert path.exists()
