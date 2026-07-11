"""Tests for ``wilted.station_runtime.store.JsonStationStore``.

Covers full-state round-trip (incl. nested dataclasses/enums/tuples/
frozenset), crash-safety (a leftover ``.tmp`` file is never read as state),
compare-and-set rejection on a stale ``expected_revision``, refuse-and-report
on an unreadable/unknown-schema-version document, and INV-5 (``wilted.DATA_DIR``
resolved at call time, so monkeypatching it redirects all I/O).
"""

from __future__ import annotations

import json

import pytest

import wilted
from wilted.station.models import (
    ControllerLease,
    FinalizationState,
    InterruptionMode,
    MediaDescriptor,
    PlaybackCheckpoint,
    SafeInterruptionMap,
    StationEntry,
    StationEvent,
    TranscriptSegment,
)
from wilted.station.reducer import StationLifecycle, StationState
from wilted.station_runtime.store import (
    STATION_SCHEMA_VERSION,
    JsonStationStore,
    StationStoreVersionError,
)

pytestmark = pytest.mark.unit


def _full_media_descriptor() -> MediaDescriptor:
    """A populated MediaDescriptor exercising every nested value object."""
    return MediaDescriptor(
        sha256="a" * 64,
        byte_size=123456,
        mime_type="audio/mpeg",
        duration_ms=600_000,
        transcript_segments=(
            TranscriptSegment(start_ms=0, end_ms=1000, text="Hello there."),
            TranscriptSegment(start_ms=1000, end_ms=2500, text="Second segment."),
        ),
        safe_interruption=SafeInterruptionMap(
            mode=InterruptionMode.WINDOWED,
            windows=((0, 1000), (5000, 6000)),
            source="transcript",
        ),
        byte_range_available=True,
        finalization=FinalizationState.complete(),
    )


def _full_entry(entry_id: str = "entry-1") -> StationEntry:
    return StationEntry(
        entry_id=entry_id,
        kind="item",
        item_id="item-42",
        source="feed:npr-news",
        policy_id="policy-1",
        priority=0,
        expiry=None,
        duration_ms=600_000,
        media=_full_media_descriptor(),
    )


def _full_state() -> StationState:
    """A StationState populated across all 9 fields for round-trip coverage."""
    active_entry = _full_entry("entry-active")
    interrupted_entry = _full_entry("entry-interrupted")
    checkpoint = PlaybackCheckpoint(
        station_revision=3,
        entry_id="entry-active",
        media_offset_ms=42_000,
        state="playing",
        interrupted_entry_stack=("entry-interrupted",),
        writer_device="mac",
        mutation_id="mut-abc",
        timestamp="2026-07-10T06:00:00Z",
    )
    lease = ControllerLease(holder_id="mac-controller-1", epoch=7)
    events = (
        StationEvent(kind="start", timestamp="2026-07-10T05:00:00Z", entry_id="entry-active", message=""),
        StationEvent(kind="error", timestamp="2026-07-10T05:30:00Z", entry_id=None, message="rejected: something"),
    )
    return StationState(
        lifecycle=StationLifecycle.PLAYING,
        station_revision=3,
        active_entry=active_entry,
        checkpoint=checkpoint,
        interruption_stack=(interrupted_entry,),
        lease=lease,
        phone_epoch=2,
        seen_mutation_ids=frozenset({"mut-abc", "mut-xyz"}),
        events=events,
    )


# ---------------------------------------------------------------------------
# (a) full-state round-trip
# ---------------------------------------------------------------------------


def test_persist_and_load_state_round_trips_full_envelope():
    """A fully populated StationState round-trips exactly through persist/load."""
    store = JsonStationStore()
    state = _full_state()

    applied = store.persist_state(state, expected_revision=0)
    assert applied is True

    loaded = store.load_state()
    assert loaded == state


def test_round_trip_preserves_frozenset_type_for_seen_mutation_ids():
    """seen_mutation_ids decodes back to a frozenset, not a list/set."""
    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)

    loaded = store.load_state()
    assert isinstance(loaded.seen_mutation_ids, frozenset)
    assert loaded.seen_mutation_ids == state.seen_mutation_ids


def test_round_trip_preserves_tuple_types():
    """interruption_stack, events, and interrupted_entry_stack decode back to tuples."""
    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)

    loaded = store.load_state()
    assert isinstance(loaded.interruption_stack, tuple)
    assert isinstance(loaded.events, tuple)
    assert isinstance(loaded.checkpoint.interrupted_entry_stack, tuple)
    assert isinstance(loaded.active_entry.media.transcript_segments, tuple)
    assert isinstance(loaded.active_entry.media.safe_interruption.windows, tuple)


def test_round_trip_preserves_enum_types():
    """lifecycle and safe_interruption.mode decode back to their Enum types, not raw strings."""
    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)

    loaded = store.load_state()
    assert loaded.lifecycle is StationLifecycle.PLAYING
    assert loaded.active_entry.media.safe_interruption.mode is InterruptionMode.WINDOWED


def test_load_state_returns_none_when_no_document_exists():
    store = JsonStationStore()
    assert store.load_state() is None


def test_on_disk_document_includes_schema_version():
    store = JsonStationStore()
    store.persist_state(_full_state(), expected_revision=0)

    state_path = wilted.DATA_DIR / "station" / "state.json"
    with state_path.open() as f:
        doc = json.load(f)
    assert doc["schema_version"] == STATION_SCHEMA_VERSION


# ---------------------------------------------------------------------------
# (b) crash-safety: a leftover .tmp file must never be read as state
# ---------------------------------------------------------------------------


def test_leftover_tmp_file_is_never_read_as_state():
    """A crash between tempfile-write and os.replace must not corrupt reads."""
    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)

    station_dir = wilted.DATA_DIR / "station"
    leftover_tmp = station_dir / "leftover123.tmp"
    leftover_tmp.write_text("not valid json at all {{{")

    # The real state.json must still load cleanly; the .tmp is ignored.
    loaded = store.load_state()
    assert loaded == state
    assert leftover_tmp.exists()  # store does not clean up or touch stray tmp files


def test_leftover_tmp_file_does_not_appear_where_state_is_expected():
    """The store only ever reads from the fixed state.json filename."""
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    (station_dir / "stray.tmp").write_text(json.dumps({"schema_version": 999}))

    # No state.json exists yet, so load_state must report None, not raise
    # on account of the unrelated stray .tmp file.
    assert store.load_state() is None


# ---------------------------------------------------------------------------
# (c) stale persist_state leaves disk unchanged
# ---------------------------------------------------------------------------


def test_persist_state_rejects_stale_expected_revision_and_leaves_disk_unchanged():
    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)

    state_path = wilted.DATA_DIR / "station" / "state.json"
    on_disk_before = state_path.read_text()

    stale_update = StationState(station_revision=99)
    applied = store.persist_state(stale_update, expected_revision=0)  # disk is now at revision 3, not 0

    assert applied is False
    assert state_path.read_text() == on_disk_before
    assert store.load_state() == state


def test_persist_state_accepts_matching_expected_revision():
    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)

    next_state = StationState(station_revision=state.station_revision + 1)
    applied = store.persist_state(next_state, expected_revision=state.station_revision)

    assert applied is True
    assert store.load_state() == next_state


def test_persist_state_first_write_requires_expected_revision_zero():
    store = JsonStationStore()
    state = _full_state()  # station_revision=3

    rejected = store.persist_state(state, expected_revision=1)
    assert rejected is False
    assert store.load_state() is None

    applied = store.persist_state(state, expected_revision=0)
    assert applied is True


# ---------------------------------------------------------------------------
# (d) unreadable/unknown schema_version -> raises, never overwrites
# ---------------------------------------------------------------------------


def test_load_state_raises_on_unknown_schema_version():
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    state_path.write_text(json.dumps({"schema_version": STATION_SCHEMA_VERSION + 1, "bogus": True}))

    with pytest.raises(StationStoreVersionError):
        store.load_state()

    # Must not have been overwritten/truncated.
    with state_path.open() as f:
        doc = json.load(f)
    assert doc["schema_version"] == STATION_SCHEMA_VERSION + 1
    assert doc["bogus"] is True


def test_load_state_raises_on_corrupt_json():
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    state_path.write_text("{ this is not valid json ]")

    with pytest.raises(StationStoreVersionError):
        store.load_state()

    # Must not have been overwritten/truncated.
    assert state_path.read_text() == "{ this is not valid json ]"


def test_persist_state_does_not_overwrite_unreadable_document():
    """A CAS write must not clobber a document it cannot safely read the revision of."""
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    original_corrupt_contents = json.dumps({"schema_version": STATION_SCHEMA_VERSION + 5})
    state_path.write_text(original_corrupt_contents)

    with pytest.raises(StationStoreVersionError):
        store.persist_state(_full_state(), expected_revision=0)

    assert state_path.read_text() == original_corrupt_contents


def test_current_checkpoint_facade_raises_on_unreadable_document():
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    (station_dir / "state.json").write_text(json.dumps({"schema_version": STATION_SCHEMA_VERSION + 1}))

    with pytest.raises(StationStoreVersionError):
        store.current_checkpoint()


# ---------------------------------------------------------------------------
# (d.1) file exists but top-level parsed content is not a dict -> unreadable,
# never treated as "absent" (regression coverage: null must not be silently
# overwritten by a revision-0 first write).
# ---------------------------------------------------------------------------

_NON_DICT_TEXT_CASES = {
    "null": "null",
    "list": json.dumps([1, 2, 3]),
    "string": json.dumps("x"),
    "number": json.dumps(5),
}


@pytest.mark.parametrize("case_name", sorted(_NON_DICT_TEXT_CASES))
def test_load_state_raises_on_non_dict_top_level_content(case_name):
    """A file that exists but doesn't parse to a dict is unreadable, not absent."""
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    state_path.write_text(_NON_DICT_TEXT_CASES[case_name])

    with pytest.raises(StationStoreVersionError):
        store.load_state()


@pytest.mark.parametrize("case_name", sorted(_NON_DICT_TEXT_CASES))
def test_persist_state_refuses_non_dict_top_level_content_and_leaves_disk_unchanged(case_name):
    """persist_state must not mistake `null`/list/string/number content for an absent file.

    Regression coverage for the bug where a `null`-content file computed
    current_revision = 0 (treating unreadable as absent) and was silently
    overwritten by a revision-0 first write.
    """
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    original_contents = _NON_DICT_TEXT_CASES[case_name]
    state_path.write_text(original_contents)

    with pytest.raises(StationStoreVersionError):
        store.persist_state(StationState(), expected_revision=0)

    assert state_path.read_text() == original_contents


def test_load_state_raises_on_non_utf8_binary_content():
    """Binary/non-UTF-8 bytes must surface as StationStoreVersionError, not UnicodeDecodeError."""
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    state_path.write_bytes(b"\xff\xfe\x00\x01")

    with pytest.raises(StationStoreVersionError):
        store.load_state()


def test_persist_state_refuses_non_utf8_binary_content_and_leaves_disk_unchanged():
    store = JsonStationStore()
    station_dir = wilted.DATA_DIR / "station"
    station_dir.mkdir(parents=True)
    state_path = station_dir / "state.json"
    original_bytes = b"\xff\xfe\x00\x01"
    state_path.write_bytes(original_bytes)

    with pytest.raises(StationStoreVersionError):
        store.persist_state(StationState(), expected_revision=0)

    assert state_path.read_bytes() == original_bytes


def test_persist_state_succeeds_at_revision_zero_when_file_genuinely_absent():
    """The genuinely-absent-file case (no station/ dir, no state.json at all) still first-writes."""
    store = JsonStationStore()
    state_path = wilted.DATA_DIR / "station" / "state.json"
    assert not state_path.exists()

    applied = store.persist_state(_full_state(), expected_revision=0)

    assert applied is True
    assert state_path.exists()
    assert store.load_state() == _full_state()


# ---------------------------------------------------------------------------
# (e) INV-5: wilted.DATA_DIR resolved at call time
# ---------------------------------------------------------------------------


def _snapshot_tree(root):
    """Set of (relative-path, size) for every file under ``root``.

    Returns an empty set when ``root`` is absent. Used to assert a block of
    code caused no change to a directory that may legitimately already exist.
    """
    if not root.exists():
        return frozenset()
    return frozenset((str(p.relative_to(root)), p.stat().st_size) for p in root.rglob("*") if p.is_file())


def test_store_writes_under_monkeypatched_data_dir_not_real_tree(tmp_path, monkeypatch):
    """Exercising the store must never write under the real project data/ tree."""
    real_station_dir = wilted.PROJECT_ROOT / "data" / "station"
    isolated_dir = tmp_path / "isolated-data"
    monkeypatch.setattr(wilted, "DATA_DIR", isolated_dir)

    # Snapshot the real station/ tree first. It may already exist from real app
    # runs on this machine (fresh CI checkouts have none); the invariant under
    # test is that THIS test does not create or modify it, not that it is absent.
    before = _snapshot_tree(real_station_dir)

    store = JsonStationStore()
    state = _full_state()
    store.persist_state(state, expected_revision=0)
    store.append_event(StationEvent(kind="start", timestamp="2026-07-10T06:00:00Z", entry_id=None, message=""))

    expected_path = isolated_dir / "station" / "state.json"
    assert expected_path.exists()
    assert store.load_state() is not None

    # The monkeypatched writes landed in isolated_dir (asserted above) and left
    # the real data/station tree byte-for-byte unchanged (INV-5).
    assert _snapshot_tree(real_station_dir) == before


def test_store_resolves_data_dir_at_call_time_not_construction_time(tmp_path, monkeypatch):
    """Constructing JsonStationStore before monkeypatching DATA_DIR must still redirect."""
    store = JsonStationStore()  # constructed before DATA_DIR is patched

    isolated_dir = tmp_path / "isolated-data-2"
    monkeypatch.setattr(wilted, "DATA_DIR", isolated_dir)

    store.persist_state(_full_state(), expected_revision=0)

    assert (isolated_dir / "station" / "state.json").exists()


# ---------------------------------------------------------------------------
# Facade methods over the full-state document
# ---------------------------------------------------------------------------


def test_current_checkpoint_facade_returns_none_when_no_state():
    store = JsonStationStore()
    assert store.current_checkpoint() is None


def test_persist_checkpoint_facade_sets_checkpoint_and_bumps_revision():
    store = JsonStationStore()
    checkpoint = PlaybackCheckpoint(
        station_revision=0,
        entry_id="entry-1",
        media_offset_ms=1000,
        state="playing",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="mut-1",
        timestamp="2026-07-10T06:00:00Z",
    )

    applied = store.persist_checkpoint(checkpoint, expected_revision=0)
    assert applied is True
    assert store.current_checkpoint() == checkpoint

    state = store.load_state()
    assert state.station_revision == 1


def test_persist_checkpoint_facade_rejects_stale_revision():
    store = JsonStationStore()
    checkpoint = PlaybackCheckpoint(
        station_revision=0,
        entry_id="entry-1",
        media_offset_ms=1000,
        state="playing",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="mut-1",
        timestamp="2026-07-10T06:00:00Z",
    )
    store.persist_checkpoint(checkpoint, expected_revision=0)

    stale_checkpoint = PlaybackCheckpoint(
        station_revision=0,
        entry_id="entry-1",
        media_offset_ms=2000,
        state="playing",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="mut-2",
        timestamp="2026-07-10T06:05:00Z",
    )
    applied = store.persist_checkpoint(stale_checkpoint, expected_revision=0)  # disk is now at revision 1

    assert applied is False
    assert store.current_checkpoint() == checkpoint


def test_append_event_facade_appends_to_events_log():
    store = JsonStationStore()
    event1 = StationEvent(kind="start", timestamp="2026-07-10T06:00:00Z", entry_id="entry-1", message="")
    event2 = StationEvent(kind="checkpoint", timestamp="2026-07-10T06:01:00Z", entry_id="entry-1", message="")

    store.append_event(event1)
    store.append_event(event2)

    state = store.load_state()
    assert state.events == (event1, event2)


def test_current_lease_facade_returns_none_when_no_state():
    store = JsonStationStore()
    assert store.current_lease() is None


def test_persist_lease_facade_round_trips():
    store = JsonStationStore()
    lease = ControllerLease(holder_id="mac-1", epoch=1)

    store.persist_lease(lease)

    assert store.current_lease() == lease


def test_persist_lease_facade_replaces_existing_lease():
    store = JsonStationStore()
    store.persist_lease(ControllerLease(holder_id="mac-1", epoch=1))
    store.persist_lease(ControllerLease(holder_id="mac-1", epoch=2))

    assert store.current_lease() == ControllerLease(holder_id="mac-1", epoch=2)
