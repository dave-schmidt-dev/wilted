"""Contract tests for wilted.station — the substrate-neutral station layer.

This file is the executable "frozen contract" for Task 0.2 of the
Mac-first personal radio plan: value objects, safe interruption maps, the
pure reducer, controller-lease/ownership handling, and Mac/phone handoff.

The in-memory reference fakes (``InMemoryStationStore``,
``InMemoryPlaybackAdapter``) implementing ``wilted.station.protocols`` live
inline in this module rather than in a separate ``tests/station_fakes.py``
file: they are small (a few methods each), used only by this file, and
keeping them next to the tests that exercise them avoids an extra
almost-empty module. If a second test file needed the same fakes, they
should move to a shared helper module at that point.
"""

from __future__ import annotations

import dataclasses
import importlib
import pkgutil
import sys
from typing import TYPE_CHECKING

import pytest

import wilted.station as station_pkg
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
from wilted.station.reducer import (
    AcceptInterruption,
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    ResumeFromInterruption,
    StartPlayback,
    StationLifecycle,
    StationState,
    Stop,
    _acknowledge_handoff,
    _checkpoint,
    _request_handoff,
    apply,
    claim_lease,
)

if TYPE_CHECKING:
    from wilted.station.protocols import PlaybackAdapter, StationStore

# ---------------------------------------------------------------------------
# In-memory reference fakes (test-scope only, NOT real storage)
# ---------------------------------------------------------------------------


class InMemoryStationStore:
    """Minimal in-memory ``StationStore`` implementation, for tests only."""

    def __init__(self) -> None:
        self._checkpoint: PlaybackCheckpoint | None = None
        self._lease: ControllerLease | None = None
        self._events: list[StationEvent] = []

    def current_checkpoint(self) -> PlaybackCheckpoint | None:
        return self._checkpoint

    def persist_checkpoint(self, checkpoint: PlaybackCheckpoint, *, expected_revision: int) -> bool:
        if self._checkpoint is not None and self._checkpoint.station_revision > expected_revision:
            return False
        self._checkpoint = checkpoint
        return True

    def append_event(self, event: StationEvent) -> None:
        self._events.append(event)

    def current_lease(self) -> ControllerLease | None:
        return self._lease

    def persist_lease(self, lease: ControllerLease) -> None:
        self._lease = lease


class InMemoryPlaybackAdapter:
    """Minimal in-memory ``PlaybackAdapter`` implementation, for tests only."""

    def __init__(self) -> None:
        self._offset_ms = 0
        self._playing = False

    def play(self, media: MediaDescriptor, *, offset_ms: int) -> None:
        self._offset_ms = offset_ms
        self._playing = True

    def pause(self) -> None:
        self._playing = False

    def stop(self) -> None:
        self._playing = False
        self._offset_ms = 0

    def seek(self, offset_ms: int) -> None:
        self._offset_ms = offset_ms

    def current_offset_ms(self) -> int:
        return self._offset_ms


def test_fakes_satisfy_protocols():
    """The in-memory fakes structurally satisfy the Protocol seams."""
    store: StationStore = InMemoryStationStore()
    adapter: PlaybackAdapter = InMemoryPlaybackAdapter()
    assert store.current_checkpoint() is None
    assert adapter.current_offset_ms() == 0


def test_store_persist_checkpoint_rejects_stale_revision_behaviorally():
    """Behavioral (not just structural) coverage of ``StationStore.persist_checkpoint``.

    FIX 2 makes an accepted ``Checkpoint`` bump ``station_revision``, which
    is what makes this guard reachable/meaningful: before that fix, two
    checkpoints for the same entry always shared the same
    ``station_revision``, so ``checkpoint.station_revision > expected_revision``
    could never be true and this branch was dead in practice. Exercises the
    fake's actual persistence and rejection behavior end-to-end, not merely
    that the methods exist.
    """
    store: StationStore = InMemoryStationStore()
    entry = _entry()
    state = _state_with_active_entry(entry)

    first = apply(
        state,
        Checkpoint(
            mutation_id="mut-1",
            expected_revision=state.station_revision,
            media_offset_ms=1000,
            state_label="playing",
            writer_device="mac",
        ),
        MAC,
    )
    assert first.checkpoint.station_revision == state.station_revision + 1

    # A writer persists the first (newer) checkpoint successfully.
    assert store.persist_checkpoint(first.checkpoint, expected_revision=state.station_revision) is True
    assert store.current_checkpoint() == first.checkpoint

    # A second, stale writer — still holding the old, pre-bump revision —
    # attempts to persist an older checkpoint after a newer one is already
    # stored. The store's own guard rejects it independently of the reducer.
    stale_checkpoint = dataclasses.replace(first.checkpoint, station_revision=state.station_revision, media_offset_ms=1)
    assert store.persist_checkpoint(stale_checkpoint, expected_revision=state.station_revision) is False
    # The newer checkpoint already persisted is not clobbered.
    assert store.current_checkpoint() == first.checkpoint
    assert store.current_checkpoint().media_offset_ms == 1000


def test_playback_adapter_play_pause_seek_behaviorally():
    """Behavioral coverage of ``PlaybackAdapter``: play/pause/seek actually
    mutate the fake's observable offset/playing state, not just exist."""
    adapter: PlaybackAdapter = InMemoryPlaybackAdapter()
    media = _finalized_media()

    adapter.play(media, offset_ms=5000)
    assert adapter.current_offset_ms() == 5000

    adapter.seek(9000)
    assert adapter.current_offset_ms() == 9000

    adapter.pause()
    assert adapter.current_offset_ms() == 9000  # pause preserves offset

    adapter.stop()
    assert adapter.current_offset_ms() == 0  # stop resets offset


# ---------------------------------------------------------------------------
# Shared builders
# ---------------------------------------------------------------------------

MAC = ControllerLease(holder_id="mac-controller", epoch=1)


def _finalized_media(**overrides) -> MediaDescriptor:
    defaults = dict(
        sha256="a" * 64,
        byte_size=1024,
        mime_type="audio/mpeg",
        duration_ms=60_000,
        transcript_segments=(),
        safe_interruption=SafeInterruptionMap.empty(),
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
    defaults.update(overrides)
    return MediaDescriptor(**defaults)


def _entry(entry_id="entry-1", kind="item", priority=5, expiry=None, media=None, **overrides) -> StationEntry:
    defaults = dict(
        entry_id=entry_id,
        kind=kind,
        item_id="item-1" if kind == "item" else None,
        source="feed:test",
        policy_id=None,
        priority=priority,
        expiry=expiry,
        duration_ms=60_000,
        media=media if media is not None else _finalized_media(),
    )
    defaults.update(overrides)
    return StationEntry(**defaults)


def _state_with_active_entry(entry: StationEntry, lease: ControllerLease = MAC) -> StationState:
    state = claim_lease(StationState(), lease.holder_id, lease.epoch)
    return apply(state, StartPlayback(entry=entry), lease)


# ---------------------------------------------------------------------------
# 1. MediaDescriptor finalization gating
# ---------------------------------------------------------------------------


class TestMediaDescriptorFinalization:
    """A media artifact cannot be played or checkpointed before ad cutting,
    timing-map creation, hashing, and atomic publication all complete."""

    def test_fully_finalized_is_playable_and_checkpointable(self):
        """All four preconditions present => both properties True."""
        media = _finalized_media()
        assert media.is_playable is True
        assert media.is_checkpointable is True

    def test_missing_ads_cut_blocks_playability(self):
        """ads_cut=False alone (everything else True) => not playable."""
        finalization = FinalizationState(ads_cut=False, timing_map_created=False, hashed=False, published=False)
        media = _finalized_media(finalization=finalization)
        assert media.is_playable is False
        assert media.is_checkpointable is False

    def test_missing_timing_map_blocks_playability(self):
        """timing_map_created=False (only ads_cut True) => not playable."""
        finalization = FinalizationState(ads_cut=True, timing_map_created=False, hashed=False, published=False)
        media = _finalized_media(finalization=finalization)
        assert media.is_playable is False
        assert media.is_checkpointable is False

    def test_missing_hash_blocks_playability(self):
        """Everything done except hash => still not playable."""
        finalization = FinalizationState(ads_cut=True, timing_map_created=True, hashed=False, published=False)
        media = _finalized_media(finalization=finalization)
        assert media.is_playable is False
        assert media.is_checkpointable is False

    def test_missing_publication_blocks_playability(self):
        """Everything done except atomic publication => still not playable."""
        finalization = FinalizationState(ads_cut=True, timing_map_created=True, hashed=True, published=False)
        media = _finalized_media(finalization=finalization)
        assert media.is_playable is False
        assert media.is_checkpointable is False

    def test_contradictory_finalization_state_rejected_at_construction(self):
        """published=True while hashed=False is internally contradictory and raises."""
        with pytest.raises(ValueError, match="contradictory"):
            FinalizationState(ads_cut=True, timing_map_created=True, hashed=False, published=True)

    def test_published_with_zero_byte_size_rejected(self):
        """INV-4: a descriptor cannot claim published=True with zero byte_size."""
        with pytest.raises(ValueError, match="empty"):
            MediaDescriptor(
                sha256="",
                byte_size=0,
                mime_type="audio/mpeg",
                duration_ms=1000,
                transcript_segments=(),
                safe_interruption=SafeInterruptionMap.empty(),
                byte_range_available=False,
                finalization=FinalizationState.complete(),
            )


# ---------------------------------------------------------------------------
# 2. Safe interruption boundaries
# ---------------------------------------------------------------------------


class TestSafeInterruptionMap:
    """Transcript/chapter/window safe boundaries and the explicit no-interrupt mode."""

    def test_from_transcript_segments_marks_segment_starts_safe(self):
        """Default band_ms=0: a point at a segment's start offset is safe;
        a point mid-segment is not (exact-boundary match only)."""
        segments = (
            TranscriptSegment(start_ms=0, end_ms=5000, text="intro"),
            TranscriptSegment(start_ms=5000, end_ms=10000, text="body"),
        )
        safe_map = SafeInterruptionMap.from_transcript_segments(segments)
        assert safe_map.mode is InterruptionMode.WINDOWED
        assert safe_map.safe_point_at(5000) is True
        assert safe_map.safe_point_at(7000) is False

    def test_from_transcript_segments_with_band_widens_match_around_boundary(self):
        """An explicit band_ms is a matching tolerance around a boundary: a
        point within the band of a boundary is safe, one well outside is not."""
        segments = (
            TranscriptSegment(start_ms=0, end_ms=5000, text="intro"),
            TranscriptSegment(start_ms=5000, end_ms=10000, text="body"),
        )
        safe_map = SafeInterruptionMap.from_transcript_segments(segments, band_ms=250)
        assert safe_map.mode is InterruptionMode.WINDOWED
        assert safe_map.safe_point_at(5200) is True
        assert safe_map.safe_point_at(4800) is True
        assert safe_map.safe_point_at(7000) is False

    def test_from_transcript_segments_clamps_low_edge_at_zero(self):
        """A segment starting at 0 with a band must not produce a negative
        low edge (which __post_init__ would reject) — it clamps to 0."""
        segments = (TranscriptSegment(start_ms=0, end_ms=5000, text="intro"),)
        safe_map = SafeInterruptionMap.from_transcript_segments(segments, band_ms=250)
        assert safe_map.windows == ((0, 250),)
        assert safe_map.safe_point_at(0) is True
        assert safe_map.safe_point_at(100) is True

    def test_from_transcript_segments_rejects_negative_band(self):
        """band_ms < 0 is rejected outright rather than silently misbehaving."""
        segments = (TranscriptSegment(start_ms=0, end_ms=5000, text="intro"),)
        with pytest.raises(ValueError, match="band_ms"):
            SafeInterruptionMap.from_transcript_segments(segments, band_ms=-1)

    def test_from_rss_chapters_marks_whole_chapter_safe(self):
        """A point anywhere inside a chapter's [start, end) range is safe."""
        chapters = (TranscriptSegment(start_ms=0, end_ms=30_000, text="Chapter 1"),)
        safe_map = SafeInterruptionMap.from_rss_chapters(chapters)
        assert safe_map.mode is InterruptionMode.WINDOWED
        assert safe_map.safe_point_at(15_000) is True
        assert safe_map.safe_point_at(30_001) is False

    def test_from_verified_windows_marks_conservative_ranges_safe(self):
        """A point inside a verified silence window is safe; outside is not."""
        safe_map = SafeInterruptionMap.from_verified_windows(((1000, 1200), (9000, 9300)))
        assert safe_map.mode is InterruptionMode.WINDOWED
        assert safe_map.safe_point_at(1100) is True
        assert safe_map.safe_point_at(9250) is True
        assert safe_map.safe_point_at(5000) is False

    def test_empty_map_is_explicit_no_interrupt_mode(self):
        """SafeInterruptionMap.empty() is a distinct, queryable state — not an
        implicit 'always safe' or 'never safe' inferred from an empty list."""
        safe_map = SafeInterruptionMap.empty()
        assert safe_map.mode is InterruptionMode.NO_INTERRUPT
        assert safe_map.is_no_interrupt is True
        assert safe_map.windows == ()
        # Explicitly false everywhere, not "safe everywhere":
        assert safe_map.safe_point_at(0) is False
        assert safe_map.safe_point_at(999_999) is False

    def test_from_transcript_segments_with_no_segments_yields_empty(self):
        """Building from an empty segment tuple yields the explicit empty/no-interrupt map."""
        safe_map = SafeInterruptionMap.from_transcript_segments(())
        assert safe_map.is_no_interrupt is True

    def test_construction_rejects_windowed_mode_with_no_windows(self):
        """Cannot directly construct a WINDOWED map with an empty windows tuple —
        that would recreate the ambiguity the mode field exists to prevent."""
        with pytest.raises(ValueError, match="WINDOWED"):
            SafeInterruptionMap(mode=InterruptionMode.WINDOWED, windows=(), source="transcript")

    def test_nearest_safe_point_returns_none_for_no_interrupt(self):
        """nearest_safe_point on a no-interrupt map returns None, not a guess."""
        assert SafeInterruptionMap.empty().nearest_safe_point(5000) is None

    def test_reducer_rejects_interruption_of_no_interrupt_entry_explicitly(self):
        """An entry with a no-interrupt map does not silently defer/block an alert
        forever — AcceptInterruption is explicitly rejected with a visible,
        attributable event, and the active entry does not change."""
        no_interrupt_entry = _entry(entry_id="no-interrupt-entry", media=_finalized_media())
        state = _state_with_active_entry(no_interrupt_entry)
        assert state.active_entry.media.safe_interruption.is_no_interrupt is True

        bulletin = _entry(entry_id="bulletin-1", kind="bulletin", priority=0)
        action = AcceptInterruption(bulletin=bulletin, interrupt_offset_ms=1000, policy_current=True)
        new_state = apply(state, action, MAC)

        # Rejected: active entry unchanged, station revision unchanged.
        assert new_state.active_entry.entry_id == "no-interrupt-entry"
        assert new_state.station_revision == state.station_revision
        # Rejection is visible/attributable, not silent — a "skip" event was logged.
        assert new_state.events[-1].kind == "skip"
        assert "no safe resume checkpoint" in new_state.events[-1].message
        assert "no-interrupt" in new_state.events[-1].message


# ---------------------------------------------------------------------------
# 3. Entry/bulletin expiry
# ---------------------------------------------------------------------------


class TestExpiry:
    """Expired entries are discarded by the reducer, not admitted/played."""

    def test_expired_entry_is_discarded_not_started(self):
        """StartPlayback with an entry whose expiry is in the past is rejected."""
        state = claim_lease(StationState(), MAC.holder_id, MAC.epoch)
        expired_entry = _entry(entry_id="stale-bulletin", expiry="2020-01-01T00:00:00Z")

        new_state = apply(state, StartPlayback(entry=expired_entry, now="2026-07-10T12:00:00Z"), MAC)

        assert new_state.active_entry is None
        assert new_state.lifecycle is StationLifecycle.IDLE
        assert new_state.events[-1].kind == "skip"
        assert "expired" in new_state.events[-1].message

    def test_non_expired_entry_is_admitted(self):
        """An entry with a future expiry starts playback normally."""
        state = claim_lease(StationState(), MAC.holder_id, MAC.epoch)
        entry = _entry(entry_id="fresh", expiry="2099-01-01T00:00:00Z")

        new_state = apply(state, StartPlayback(entry=entry, now="2026-07-10T12:00:00Z"), MAC)

        assert new_state.active_entry is not None
        assert new_state.active_entry.entry_id == "fresh"

    def test_expired_bulletin_is_discarded_on_interruption_attempt(self):
        """An AcceptInterruption referencing an expired bulletin is rejected;
        active entry is unchanged."""
        active_entry = _entry(
            entry_id="active",
            media=_finalized_media(safe_interruption=SafeInterruptionMap.from_verified_windows(((0, 60_000),))),
        )
        state = _state_with_active_entry(active_entry)
        expired_bulletin = _entry(
            entry_id="expired-bulletin", kind="bulletin", priority=0, expiry="2020-01-01T00:00:00Z"
        )

        action = AcceptInterruption(
            bulletin=expired_bulletin, interrupt_offset_ms=1000, policy_current=True, now="2026-07-10T12:00:00Z"
        )
        new_state = apply(state, action, MAC)

        assert new_state.active_entry.entry_id == "active"
        assert new_state.events[-1].kind == "skip"
        assert "expired" in new_state.events[-1].message


# ---------------------------------------------------------------------------
# 4. Stale-writer rejection
# ---------------------------------------------------------------------------


class TestStaleWriterRejection:
    """A Checkpoint action with a wrong revision or repeated mutation_id is rejected."""

    def test_stale_revision_is_rejected(self):
        """expected_revision that doesn't match current station_revision is rejected."""
        entry = _entry()
        state = _state_with_active_entry(entry)
        assert state.station_revision == 1

        action = Checkpoint(
            mutation_id="mut-1",
            expected_revision=999,  # stale/wrong
            media_offset_ms=5000,
            state_label="playing",
            writer_device="mac",
        )
        new_state = apply(state, action, MAC)

        assert new_state.checkpoint is state.checkpoint  # unchanged (None)
        assert new_state.events[-1].kind == "error"
        assert "stale writer" in new_state.events[-1].message

    def test_repeated_mutation_id_is_rejected(self):
        """A second Checkpoint action reusing an already-applied mutation_id is
        rejected and does not overwrite the newer checkpoint already in state."""
        entry = _entry()
        state = _state_with_active_entry(entry)

        first = Checkpoint(
            mutation_id="mut-dup",
            expected_revision=1,
            media_offset_ms=5000,
            state_label="playing",
            writer_device="mac",
        )
        state_after_first = apply(state, first, MAC)
        assert state_after_first.checkpoint.media_offset_ms == 5000

        # Replay the same mutation_id with a different (bogus) offset.
        replay = Checkpoint(
            mutation_id="mut-dup",
            expected_revision=1,
            media_offset_ms=99_999,
            state_label="playing",
            writer_device="mac",
        )
        state_after_replay = apply(state_after_first, replay, MAC)

        assert state_after_replay.checkpoint == state_after_first.checkpoint
        assert state_after_replay.checkpoint.media_offset_ms == 5000
        assert state_after_replay.events[-1].kind == "error"
        assert "already applied" in state_after_replay.events[-1].message

    def test_valid_checkpoint_is_accepted(self):
        """A checkpoint with a matching revision and fresh mutation_id is applied.

        FIX 2: an accepted checkpoint bumps ``station_revision`` (mirroring
        the other accepted-write transitions), and the new checkpoint's own
        ``station_revision`` records the post-bump value, not the pre-write
        one.
        """
        entry = _entry()
        state = _state_with_active_entry(entry)
        assert state.station_revision == 1

        action = Checkpoint(
            mutation_id="mut-ok",
            expected_revision=1,
            media_offset_ms=12_345,
            state_label="playing",
            writer_device="mac",
        )
        new_state = apply(state, action, MAC)

        assert new_state.checkpoint is not None
        assert new_state.checkpoint.media_offset_ms == 12_345
        assert new_state.checkpoint.mutation_id == "mut-ok"
        assert new_state.station_revision == 2  # bumped from 1
        assert new_state.checkpoint.station_revision == 2  # records the NEW post-bump revision

    def test_concurrent_writers_same_revision_second_rejected_first_preserved(self):
        """F2 regression: two distinct writers both read station_revision N and
        submit Checkpoint actions with expected_revision=N and different
        mutation_ids. Before FIX 2, station_revision never advanced on an
        accepted checkpoint, so both writes would be accepted
        (last-writer-wins, silently clobbering the first). After FIX 2, the
        first accepted checkpoint bumps the revision, so the second writer's
        now-stale expected_revision is correctly rejected and the first
        checkpoint's offset is preserved untouched.
        """
        entry = _entry()
        state = _state_with_active_entry(entry)
        assert state.station_revision == 1

        writer_a = Checkpoint(
            mutation_id="writer-a",
            expected_revision=1,
            media_offset_ms=10_000,
            state_label="playing",
            writer_device="mac",
        )
        writer_b = Checkpoint(
            mutation_id="writer-b",
            expected_revision=1,  # both writers read the same revision=1
            media_offset_ms=20_000,
            state_label="playing",
            writer_device="iphone",
        )

        state_after_a = apply(state, writer_a, MAC)
        assert state_after_a.checkpoint.media_offset_ms == 10_000
        assert state_after_a.station_revision == 2

        # Writer B submits against the same expected_revision=1, which is
        # now stale (current is 2) — must be rejected, not last-writer-wins.
        state_after_b = apply(state_after_a, writer_b, MAC)

        assert state_after_b.checkpoint == state_after_a.checkpoint  # unchanged, not clobbered
        assert state_after_b.checkpoint.media_offset_ms == 10_000  # writer A's offset preserved
        assert state_after_b.events[-1].kind == "error"
        assert "stale writer" in state_after_b.events[-1].message

    def test_stop_retains_durable_checkpoint_from_any_state(self):
        """Stop transitions any state to stopped while retaining the last checkpoint."""
        entry = _entry()
        state = _state_with_active_entry(entry)
        state = apply(
            state,
            Checkpoint(
                mutation_id="mut-before-stop",
                expected_revision=1,
                media_offset_ms=42_000,
                state_label="playing",
                writer_device="mac",
            ),
            MAC,
        )

        new_state = apply(state, Stop(), MAC)

        assert new_state.lifecycle is StationLifecycle.STOPPED
        assert new_state.checkpoint is not None
        assert new_state.checkpoint.media_offset_ms == 42_000  # durable checkpoint retained

    def test_checkpoint_after_stop_is_rejected(self):
        """F3 regression: a Checkpoint issued after Stop is rejected — the
        station is no longer playing, so a stale writer cannot silently
        resurrect/overwrite the durable stopped checkpoint."""
        entry = _entry()
        state = _state_with_active_entry(entry)
        state = apply(state, Stop(), MAC)
        assert state.lifecycle is StationLifecycle.STOPPED

        late_checkpoint = Checkpoint(
            mutation_id="mut-after-stop",
            expected_revision=state.station_revision,
            media_offset_ms=77_000,
            state_label="playing",
            writer_device="mac",
        )
        new_state = apply(state, late_checkpoint, MAC)

        assert new_state.checkpoint is state.checkpoint  # unchanged
        assert new_state.events[-1].kind == "error"
        assert "playing station" in new_state.events[-1].message

    def test_checkpoint_by_mac_after_handoff_acknowledged_is_rejected(self):
        """F3 regression: once the phone owns the station (AcknowledgeHandoff
        completed), a Checkpoint issued by the Mac is rejected for two
        independent, compounding reasons — the Mac's lease was released
        (FIX 3b), so apply()'s central lease gate rejects it as owner-loss
        before the lifecycle guard is even reached."""
        entry = _entry()
        state = _state_with_active_entry(entry)
        state = apply(
            state,
            RequestHandoff(phone_device_id="iphone-1", requested_epoch=2, last_known_mac_revision=1),
            MAC,
        )
        state = apply(state, AcknowledgeHandoff(phone_device_id="iphone-1", epoch=2), MAC)
        assert state.lifecycle is StationLifecycle.OWNED_BY_IPHONE
        assert state.lease is None

        stale_mac_checkpoint = Checkpoint(
            mutation_id="mut-stale-mac",
            expected_revision=state.station_revision,
            media_offset_ms=5000,
            state_label="playing",
            writer_device="mac",
        )
        new_state = apply(state, stale_mac_checkpoint, MAC)

        assert new_state.checkpoint == state.checkpoint  # unchanged
        assert new_state.events[-1].kind == "error"
        assert "owner-loss" in new_state.events[-1].message

        # Even if the Mac somehow still held a matching lease (e.g. a
        # dispatch-layer bug bypassing apply()'s gate), the lifecycle guard
        # inside _checkpoint independently blocks it — belt and suspenders.
        directly_rejected = _checkpoint(state, stale_mac_checkpoint)
        assert directly_rejected.checkpoint == state.checkpoint
        assert directly_rejected.events[-1].kind == "error"
        assert "playing station" in directly_rejected.events[-1].message


# ---------------------------------------------------------------------------
# 5. Controller owner-loss
# ---------------------------------------------------------------------------


class TestControllerOwnerLoss:
    """A mutating action from a requester whose lease doesn't match the
    current holder is rejected; playback state does not change."""

    def test_action_from_non_owner_lease_is_rejected(self):
        """A requester who never held the lease cannot mutate state."""
        state = StationState()  # no lease claimed at all
        stranger = ControllerLease(holder_id="rogue-process", epoch=1)
        entry = _entry()

        new_state = apply(state, StartPlayback(entry=entry), stranger)

        assert new_state.active_entry is None
        assert new_state.lifecycle is StationLifecycle.IDLE
        assert new_state.events[-1].kind == "error"
        assert "owner-loss" in new_state.events[-1].message

    def test_action_from_lost_lease_is_rejected(self):
        """A requester who held the lease but was superseded by a new epoch is rejected."""
        state = claim_lease(StationState(), "mac-controller", epoch=1)
        # A new controller instance takes over with a bumped epoch.
        state = claim_lease(state, "mac-controller", epoch=2)

        stale_requester = ControllerLease(holder_id="mac-controller", epoch=1)  # old epoch
        entry = _entry()

        new_state = apply(state, StartPlayback(entry=entry), stale_requester)

        assert new_state.active_entry is None
        assert new_state.events[-1].kind == "error"
        assert "owner-loss" in new_state.events[-1].message

    def test_action_from_current_lease_holder_succeeds(self):
        """The current lease holder's actions are applied normally."""
        state = claim_lease(StationState(), "mac-controller", epoch=1)
        current = ControllerLease(holder_id="mac-controller", epoch=1)
        entry = _entry()

        new_state = apply(state, StartPlayback(entry=entry), current)

        assert new_state.active_entry is not None
        assert new_state.active_entry.entry_id == entry.entry_id

    def test_claim_lease_first_acquire_still_works(self):
        """F1: claiming a lease when none exists yet (lease is None) is always
        accepted — the fencing-token guard only applies to reclaims."""
        state = claim_lease(StationState(), "mac-controller", epoch=0)
        assert state.lease == ControllerLease(holder_id="mac-controller", epoch=0)

    def test_claim_lease_rejects_stale_or_equal_epoch(self):
        """F1 regression: claim_lease must enforce a strictly-advancing
        fencing token. A claim at an epoch <= the current lease's epoch is
        rejected (lease unchanged); a claim with epoch > current is
        accepted. Before this fix, claim_lease overwrote the lease with ANY
        epoch, enabling a stale process to steal ownership back."""
        state = claim_lease(StationState(), "mac-controller", epoch=2)
        original_lease = state.lease

        # Equal epoch: rejected.
        same_epoch = claim_lease(state, "rogue-process", epoch=2)
        assert same_epoch.lease == original_lease
        assert same_epoch.events[-1].kind == "error"
        assert "stale lease claim" in same_epoch.events[-1].message

        # Lower epoch: rejected.
        lower_epoch = claim_lease(state, "rogue-process", epoch=1)
        assert lower_epoch.lease == original_lease
        assert lower_epoch.events[-1].kind == "error"
        assert "stale lease claim" in lower_epoch.events[-1].message

        # Strictly higher epoch: accepted, ownership transfers.
        higher_epoch = claim_lease(state, "new-controller", epoch=3)
        assert higher_epoch.lease == ControllerLease(holder_id="new-controller", epoch=3)

    def test_claim_lease_probe_stale_mac_cannot_reclaim_after_phone_takeover(self):
        """F1 probe scenario: Mac@1 playing -> phone claims@2 -> stale Mac
        claim@1 is REJECTED -> the stale Mac's StartPlayback is still
        rejected by apply()'s central lease gate.

        This is the adversarial-review scenario the fencing-token guard
        exists to close: without FIX 1, a stale/orphaned Mac controller
        process could reclaim the lease at its old epoch after a new
        controller (the phone) already took over at a higher epoch,
        resurrecting a state where two controllers both believe they own
        the station.
        """
        mac_epoch_1 = ControllerLease(holder_id="mac-controller", epoch=1)
        state = claim_lease(StationState(), mac_epoch_1.holder_id, mac_epoch_1.epoch)
        entry = _entry()
        state = apply(state, StartPlayback(entry=entry), mac_epoch_1)
        assert state.lifecycle is StationLifecycle.PLAYING
        assert state.lease == mac_epoch_1

        # The phone (a new controller) claims ownership at a higher epoch.
        phone_epoch_2 = ControllerLease(holder_id="iphone-controller", epoch=2)
        state = claim_lease(state, phone_epoch_2.holder_id, phone_epoch_2.epoch)
        assert state.lease == phone_epoch_2

        # The stale Mac process attempts to reclaim at its old epoch=1.
        reclaim_attempt = claim_lease(state, mac_epoch_1.holder_id, mac_epoch_1.epoch)
        assert reclaim_attempt.lease == phone_epoch_2  # unchanged — phone still owns
        assert reclaim_attempt.events[-1].kind == "error"
        assert "stale lease claim" in reclaim_attempt.events[-1].message

        # The stale Mac, still presenting its old lease, cannot mutate state
        # either — apply()'s central lease gate rejects it as owner-loss.
        another_entry = _entry(entry_id="entry-2")
        rejected = apply(reclaim_attempt, StartPlayback(entry=another_entry), mac_epoch_1)
        assert rejected.active_entry is not None
        assert rejected.active_entry.entry_id == entry.entry_id  # unchanged, still the original entry
        assert rejected.events[-1].kind == "error"
        assert "owner-loss" in rejected.events[-1].message


# ---------------------------------------------------------------------------
# 6. Mac/phone ownership transfer
# ---------------------------------------------------------------------------


class TestMacPhoneHandoff:
    """Full takeover sequence: request records phone epoch, Mac stops only
    after acknowledgement, no concurrent dual ownership, stale Mac cannot
    clobber a newer phone checkpoint."""

    def test_full_handoff_sequence_transfers_ownership_cleanly(self):
        """RequestHandoff -> AcknowledgeHandoff transitions to owned_by_iphone
        with no state where both Mac and phone are simultaneously active owners."""
        entry = _entry()
        state = _state_with_active_entry(entry)
        assert state.lifecycle is StationLifecycle.PLAYING

        request = RequestHandoff(
            phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=state.station_revision
        )
        state = apply(state, request, MAC)
        assert state.lifecycle is StationLifecycle.HANDOFF_PENDING

        ack = AcknowledgeHandoff(phone_device_id="iphone-1", epoch=1)
        state = apply(state, ack, MAC)

        assert state.lifecycle is StationLifecycle.OWNED_BY_IPHONE
        assert state.phone_epoch == 1
        # No dual ownership: lifecycle is exactly one value, and it is the
        # phone-owned state, not any Mac-active-playing variant.
        assert state.lifecycle is not StationLifecycle.PLAYING
        # Durable checkpoint is retained (state stopped, not discarded).
        assert state.checkpoint is not None
        assert state.checkpoint.state == "stopped"

    def test_handoff_request_rejected_on_stale_mac_revision(self):
        """A phone request citing a stale last_known_mac_revision is rejected."""
        entry = _entry()
        state = _state_with_active_entry(entry)

        request = RequestHandoff(phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=999)
        new_state = apply(state, request, MAC)

        assert new_state.lifecycle is StationLifecycle.PLAYING  # unchanged
        assert new_state.events[-1].kind == "error"
        assert "stale handoff request" in new_state.events[-1].message

    def test_stale_mac_acknowledgement_cannot_clobber_newer_phone_checkpoint(self):
        """A second, older-epoch AcknowledgeHandoff cannot overwrite state
        already recording a newer phone_epoch.

        Exercises the ``_acknowledge_handoff`` transition function directly
        (rather than through ``apply()``) because — after FIX 3(b) — the Mac
        legitimately loses its controller lease the moment ownership
        transfers to the phone, so a real end-to-end replay through
        ``apply()`` is now (correctly) intercepted earlier by the central
        owner-loss lease gate. This test targets the transition function's
        own epoch/clobber guard specifically, which remains load-bearing as
        defense in depth (e.g. against a caller that bypasses ``apply()``).
        """
        entry = _entry()
        state = _state_with_active_entry(entry)

        state = apply(
            state,
            RequestHandoff(phone_device_id="iphone-1", requested_epoch=5, last_known_mac_revision=1),
            MAC,
        )
        state = apply(state, AcknowledgeHandoff(phone_device_id="iphone-1", epoch=5), MAC)
        assert state.phone_epoch == 5
        assert state.lifecycle is StationLifecycle.OWNED_BY_IPHONE
        assert state.lease is None  # Mac released the lease on handoff (FIX 3b)

        # A stale Mac process replays an acknowledgement with an old epoch,
        # calling the transition function directly to isolate its guard.
        stale_ack = AcknowledgeHandoff(phone_device_id="iphone-1", epoch=2)
        new_state = _acknowledge_handoff(state, stale_ack)

        assert new_state.phone_epoch == 5  # unchanged, not clobbered
        assert new_state is not None
        assert new_state.events[-1].kind == "error"
        assert "clobber" in new_state.events[-1].message

        # And the realistic end-to-end path (through apply(), with the Mac's
        # stale/absent lease) is rejected too, just earlier and for the more
        # fundamental owner-loss reason.
        rejected_via_apply = apply(state, stale_ack, MAC)
        assert rejected_via_apply.phone_epoch == 5
        assert rejected_via_apply.events[-1].kind == "error"
        assert "owner-loss" in rejected_via_apply.events[-1].message

    def test_stale_handoff_request_epoch_rejected(self):
        """A RequestHandoff whose epoch is not newer than the already-recorded
        phone_epoch is rejected outright (covers repeated/duplicate requests).

        Exercises ``_request_handoff`` directly for the same reason as
        ``test_stale_mac_acknowledgement_cannot_clobber_newer_phone_checkpoint``
        above: after a real handoff, the Mac's lease is released (FIX 3b) and
        the station is no longer ``playing`` (FIX 4 also independently
        rejects this replay via the lifecycle guard), so a realistic
        end-to-end replay through ``apply()`` is intercepted earlier. This
        test isolates the epoch-ordering guard inside the transition
        function on a synthetic state that is still ``playing`` with
        ``phone_epoch`` already set, to keep that guard load-bearing.
        """
        entry = _entry()
        state = _state_with_active_entry(entry)
        state = apply(
            state,
            RequestHandoff(phone_device_id="iphone-1", requested_epoch=5, last_known_mac_revision=1),
            MAC,
        )
        state = apply(state, AcknowledgeHandoff(phone_device_id="iphone-1", epoch=5), MAC)
        assert state.phone_epoch == 5

        # Synthesize a still-playing state (as if a new Mac session resumed
        # ownership and started playback again) that retains the
        # already-acknowledged phone_epoch, to isolate the epoch-ordering
        # guard from the (separately-tested) lifecycle/lease guards.
        resumed = dataclasses.replace(state, lifecycle=StationLifecycle.PLAYING, active_entry=entry, lease=MAC)
        replay_request = RequestHandoff(
            phone_device_id="iphone-1", requested_epoch=5, last_known_mac_revision=resumed.station_revision
        )
        new_state = _request_handoff(resumed, replay_request)
        assert new_state.events[-1].kind == "error"
        assert "not newer than" in new_state.events[-1].message

        # And the realistic end-to-end replay (unmodified post-handoff state,
        # through apply()) is rejected too, for the more fundamental
        # owner-loss reason (Mac lease was released on handoff).
        rejected_via_apply = apply(state, replay_request, MAC)
        assert rejected_via_apply.events[-1].kind == "error"
        assert "owner-loss" in rejected_via_apply.events[-1].message

    def test_request_handoff_rejected_from_idle(self):
        """F4 regression: RequestHandoff against an idle station (no active
        entry) is rejected — "handoff of nothing" must not be admitted."""
        state = claim_lease(StationState(), MAC.holder_id, MAC.epoch)
        assert state.lifecycle is StationLifecycle.IDLE
        assert state.active_entry is None

        request = RequestHandoff(phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=0)
        new_state = apply(state, request, MAC)

        assert new_state.lifecycle is StationLifecycle.IDLE  # unchanged
        assert new_state.events[-1].kind == "error"
        assert "playing station" in new_state.events[-1].message

    def test_request_handoff_rejected_from_stopped(self):
        """F4 regression: RequestHandoff against a stopped station (no active
        entry, per Stop's lifecycle transition) is rejected."""
        entry = _entry()
        state = _state_with_active_entry(entry)
        state = apply(state, Stop(), MAC)
        assert state.lifecycle is StationLifecycle.STOPPED

        request = RequestHandoff(
            phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=state.station_revision
        )
        new_state = apply(state, request, MAC)

        assert new_state.lifecycle is StationLifecycle.STOPPED  # unchanged
        assert new_state.events[-1].kind == "error"
        assert "playing station" in new_state.events[-1].message

    def test_second_request_handoff_while_already_pending_is_rejected(self):
        """F4 regression: a second RequestHandoff while the station is already
        handoff_pending is rejected — the lifecycle guard blocks duplicate
        requests, not just the epoch-ordering guard (which only fires once
        a phone_epoch has actually been acknowledged)."""
        entry = _entry()
        state = _state_with_active_entry(entry)

        first_request = RequestHandoff(
            phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=state.station_revision
        )
        state = apply(state, first_request, MAC)
        assert state.lifecycle is StationLifecycle.HANDOFF_PENDING

        duplicate_request = RequestHandoff(
            phone_device_id="iphone-2", requested_epoch=2, last_known_mac_revision=state.station_revision
        )
        new_state = apply(state, duplicate_request, MAC)

        assert new_state.lifecycle is StationLifecycle.HANDOFF_PENDING  # unchanged
        assert new_state.events[-1].kind == "error"
        assert "playing station" in new_state.events[-1].message


class TestAcceptedLifecycleTransitionsBumpRevision:
    """Every *accepted* mutating write advances ``station_revision`` — the
    contract ``StationState.station_revision`` documents ("bumped on every
    accepted mutating write") and that ``StationController`` relies on to
    distinguish an accepted mutation (persist it) from a rejection (do not).

    Regression for the bug where ``Stop``/``RequestHandoff``/
    ``AcknowledgeHandoff`` changed lifecycle without bumping the revision, so
    the controller misread them as rejections, never persisted them, and a
    restart reloaded the pre-transition state (a stopped station came back
    playing; an acknowledged handoff was lost so the Mac still thought it
    owned the lease). Rejections must still leave the revision unchanged.
    """

    def test_stop_bumps_revision(self):
        entry = _entry()
        state = _state_with_active_entry(entry)
        before = state.station_revision

        stopped = apply(state, Stop(), MAC)

        assert stopped.lifecycle is StationLifecycle.STOPPED
        assert stopped.station_revision == before + 1

    def test_request_handoff_bumps_revision(self):
        entry = _entry()
        state = _state_with_active_entry(entry)
        before = state.station_revision

        pending = apply(
            state,
            RequestHandoff(phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=before),
            MAC,
        )

        assert pending.lifecycle is StationLifecycle.HANDOFF_PENDING
        assert pending.station_revision == before + 1

    def test_acknowledge_handoff_bumps_revision(self):
        entry = _entry()
        state = _state_with_active_entry(entry)
        state = apply(
            state,
            RequestHandoff(
                phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=state.station_revision
            ),
            MAC,
        )
        before = state.station_revision

        owned = apply(state, AcknowledgeHandoff(phone_device_id="iphone-1", epoch=1), MAC)

        assert owned.lifecycle is StationLifecycle.OWNED_BY_IPHONE
        assert owned.station_revision == before + 1
        assert owned.lease is None  # Mac released the lease on handoff

    def test_full_lifecycle_revision_advances_monotonically(self):
        """Start -> Checkpoint -> RequestHandoff -> AcknowledgeHandoff:
        revision strictly increases by exactly 1 at each accepted step, and a
        rejected write in the middle does not perturb the sequence."""
        entry = _entry()
        state = _state_with_active_entry(entry)  # StartPlayback -> rev 1
        assert state.station_revision == 1

        state = apply(
            state,
            Checkpoint(
                mutation_id="mut-1",
                expected_revision=1,
                media_offset_ms=1000,
                state_label="playing",
                writer_device="mac",
            ),
            MAC,
        )
        assert state.station_revision == 2

        # A rejected Checkpoint (stale expected_revision) must NOT advance it.
        rejected = apply(
            state,
            Checkpoint(
                mutation_id="mut-stale",
                expected_revision=999,
                media_offset_ms=2000,
                state_label="playing",
                writer_device="mac",
            ),
            MAC,
        )
        assert rejected.station_revision == 2  # unchanged on rejection

        state = apply(
            state,
            RequestHandoff(phone_device_id="iphone-1", requested_epoch=1, last_known_mac_revision=2),
            MAC,
        )
        assert state.station_revision == 3

        state = apply(state, AcknowledgeHandoff(phone_device_id="iphone-1", epoch=1), MAC)
        assert state.station_revision == 4


# ---------------------------------------------------------------------------
# 7. Failed bulletin generation
# ---------------------------------------------------------------------------


class TestFailedBulletinGeneration:
    """An AcceptInterruption referencing a not-playable bulletin is logged
    and skipped without changing the active entry."""

    def test_incomplete_bulletin_media_is_skipped_without_changing_active_entry(self):
        """bulletin.media.is_playable is False (e.g. hash never computed) => rejected."""
        safe_map = SafeInterruptionMap.from_verified_windows(((0, 60_000),))
        active_entry = _entry(entry_id="active", media=_finalized_media(safe_interruption=safe_map))
        state = _state_with_active_entry(active_entry)

        broken_finalization = FinalizationState(ads_cut=True, timing_map_created=True, hashed=False, published=False)
        failed_bulletin = _entry(
            entry_id="failed-bulletin",
            kind="bulletin",
            priority=0,
            media=_finalized_media(finalization=broken_finalization),
        )

        action = AcceptInterruption(bulletin=failed_bulletin, interrupt_offset_ms=1000, policy_current=True)
        new_state = apply(state, action, MAC)

        assert new_state.active_entry.entry_id == "active"
        assert new_state.station_revision == state.station_revision
        assert new_state.events[-1].kind == "error"
        assert "failed/incomplete" in new_state.events[-1].message

    def test_successful_interruption_then_resume_round_trip(self):
        """Sanity check the accept path works when all preconditions are met,
        and ResumeFromInterruption pops back to the original entry."""
        safe_map = SafeInterruptionMap.from_verified_windows(((0, 60_000),))
        active_entry = _entry(entry_id="active", media=_finalized_media(safe_interruption=safe_map))
        state = _state_with_active_entry(active_entry)

        bulletin = _entry(entry_id="bulletin-1", kind="bulletin", priority=0)
        state = apply(state, AcceptInterruption(bulletin=bulletin, interrupt_offset_ms=1000, policy_current=True), MAC)
        assert state.active_entry.entry_id == "bulletin-1"
        assert len(state.interruption_stack) == 1
        assert state.interruption_stack[0].entry_id == "active"

        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "active"
        assert state.interruption_stack == ()

    def test_nested_interruptions_queued_by_priority(self):
        """Two nested bulletins are ordered so the higher-priority (lower value)
        one is resumed to first.

        Both the originally-playing entry and the first bulletin need their
        own safe interruption maps here: the second, higher-priority
        bulletin interrupts whatever is *currently* active (the first
        bulletin), so the first bulletin's media must itself expose a safe
        resume point for the nested interruption to be accepted.
        """
        safe_map = SafeInterruptionMap.from_verified_windows(((0, 60_000),))
        active_entry = _entry(entry_id="active", media=_finalized_media(safe_interruption=safe_map))
        state = _state_with_active_entry(active_entry)

        low_priority_bulletin = _entry(
            entry_id="weather",
            kind="bulletin",
            priority=5,
            media=_finalized_media(safe_interruption=safe_map),
        )
        high_priority_bulletin = _entry(
            entry_id="breaking-news",
            kind="bulletin",
            priority=0,
            media=_finalized_media(safe_interruption=safe_map),
        )

        state = apply(
            state,
            AcceptInterruption(bulletin=low_priority_bulletin, interrupt_offset_ms=1000, policy_current=True),
            MAC,
        )
        assert state.active_entry.entry_id == "weather"
        assert [e.entry_id for e in state.interruption_stack] == ["active"]

        # A second, higher-priority bulletin interrupts the first bulletin.
        state = apply(
            state,
            AcceptInterruption(bulletin=high_priority_bulletin, interrupt_offset_ms=2000, policy_current=True),
            MAC,
        )
        assert state.active_entry.entry_id == "breaking-news"
        # The interruption stack now holds both prior entries, ordered by
        # ascending priority value (weather=5 is queued behind active's
        # default priority=5 by insertion order — both share priority 5,
        # so the sort is stable and preserves push order: active pushed
        # first, weather pushed second).
        stack_ids = [e.entry_id for e in state.interruption_stack]
        assert stack_ids == ["active", "weather"]

        # Popping resumes the front of the stack (lowest priority value,
        # ties broken by original push order) first.
        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "active"
        assert [e.entry_id for e in state.interruption_stack] == ["weather"]

        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "weather"
        assert state.interruption_stack == ()


# ---------------------------------------------------------------------------
# 8. OQ-1: interruption resume order (priority-order, locked 2026-07-10)
# ---------------------------------------------------------------------------


class TestOq1InterruptionResumeOrder:
    """OQ-1 resolved 2026-07-10 (David): interruption resume is PRIORITY-ORDERED,
    not LIFO. These tests lock that choice — a change to strict most-recently-
    interrupted (LIFO) resume must fail here."""

    def test_resume_order_is_priority_not_lifo(self):
        """Interrupt with a LESS urgent bulletin first, then a MORE urgent one.

        Under LIFO ("resume whatever you most recently interrupted"), the
        first ResumeFromInterruption would return to ``traffic`` (priority=9,
        interrupted second/most recently). Under priority-order (the
        reducer's actual, locked behavior), it instead returns to ``active``
        (priority=5, more urgent than traffic's 9) even though ``active`` was
        interrupted first/least recently. These two predictions genuinely
        differ, so this assertion fails if the reducer is ever flipped to
        pop the last-inserted stack entry instead of sorting by priority.
        """
        safe_map = SafeInterruptionMap.from_verified_windows(((0, 60_000),))
        active_entry = _entry(entry_id="active", priority=5, media=_finalized_media(safe_interruption=safe_map))
        state = _state_with_active_entry(active_entry)

        # Interrupted 1st (least recently), but MORE urgent (priority=5 < 9).
        traffic = _entry(
            entry_id="traffic",
            kind="bulletin",
            priority=9,
            media=_finalized_media(safe_interruption=safe_map),
        )
        state = apply(
            state,
            AcceptInterruption(bulletin=traffic, interrupt_offset_ms=1000, policy_current=True),
            MAC,
        )
        assert state.active_entry.entry_id == "traffic"
        assert [e.entry_id for e in state.interruption_stack] == ["active"]

        # Interrupted 2nd (most recently), but LESS urgent than active
        # (priority=1 is more urgent than active's 5) — irrelevant to LIFO,
        # which only cares about recency, but relevant to priority-order.
        breaking = _entry(
            entry_id="breaking",
            kind="bulletin",
            priority=1,
            media=_finalized_media(safe_interruption=safe_map),
        )
        state = apply(
            state,
            AcceptInterruption(bulletin=breaking, interrupt_offset_ms=2000, policy_current=True),
            MAC,
        )
        assert state.active_entry.entry_id == "breaking"
        # Stack sorted ascending by priority: active(5) before traffic(9).
        assert [e.entry_id for e in state.interruption_stack] == ["active", "traffic"]

        # First resume: priority-order must return to "active" (priority=5,
        # the most urgent pending entry). LIFO would (incorrectly, for this
        # locked product decision) return to "traffic" (priority=9), since
        # traffic was interrupted more recently than active.
        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "active"  # LIFO would give "traffic" here.
        assert [e.entry_id for e in state.interruption_stack] == ["traffic"]

        # Second resume: only "traffic" remains either way, but assert it
        # for a complete, self-consistent round trip.
        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "traffic"
        assert state.interruption_stack == ()

    def test_resume_order_diverges_from_lifo_across_three_nested_interruptions(self):
        """Three-deep interruption chain where priority-order and LIFO
        predict DIFFERENT resume sequences at BOTH the first and second
        resume step (a stronger, independent check than the two-entry case
        above).

        Interrupted chronologically (oldest to most recent): active(5),
        low(8), mid(6). Stack, sorted ascending by priority: [active(5),
        mid(6), low(8)].

          - LIFO (most-recently-interrupted-first) predicts: mid, low, active.
          - Priority-order (most-urgent-first) predicts: active, mid, low.

        The two predictions disagree at both the first and second pop, so
        this test fails immediately if the reducer is ever changed to pop
        the last-inserted stack entry instead of sorting by priority.
        """
        safe_map = SafeInterruptionMap.from_verified_windows(((0, 60_000),))
        active_entry = _entry(entry_id="active", priority=5, media=_finalized_media(safe_interruption=safe_map))
        state = _state_with_active_entry(active_entry)

        # Interrupted 1st (oldest), mid urgency (priority=5).
        low = _entry(entry_id="low", kind="bulletin", priority=8, media=_finalized_media(safe_interruption=safe_map))
        state = apply(state, AcceptInterruption(bulletin=low, interrupt_offset_ms=1000, policy_current=True), MAC)
        assert state.active_entry.entry_id == "low"

        # Interrupted 2nd, LEAST urgent (priority=8).
        mid = _entry(entry_id="mid", kind="bulletin", priority=6, media=_finalized_media(safe_interruption=safe_map))
        state = apply(state, AcceptInterruption(bulletin=mid, interrupt_offset_ms=2000, policy_current=True), MAC)
        assert state.active_entry.entry_id == "mid"

        # Interrupted 3rd (most recent), moderately urgent (priority=6).
        urgent = _entry(
            entry_id="urgent",
            kind="bulletin",
            priority=1,
            media=_finalized_media(safe_interruption=safe_map),
        )
        state = apply(state, AcceptInterruption(bulletin=urgent, interrupt_offset_ms=3000, policy_current=True), MAC)
        assert state.active_entry.entry_id == "urgent"
        # Sorted ascending by priority: active(5), mid(6), low(8).
        assert [e.entry_id for e in state.interruption_stack] == ["active", "mid", "low"]

        # First resume: priority-order picks "active" (priority=5, most
        # urgent pending). LIFO would instead pick "mid" (interrupted most
        # recently, priority=6).
        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "active"  # LIFO would give "mid" here.
        assert [e.entry_id for e in state.interruption_stack] == ["mid", "low"]

        # Second resume: priority-order picks "mid" (priority=6, more
        # urgent than "low"'s 8). LIFO would instead pick "low" (interrupted
        # more recently than "active", which LIFO already consumed above).
        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "mid"  # LIFO would give "low" here.
        assert [e.entry_id for e in state.interruption_stack] == ["low"]

        state = apply(state, ResumeFromInterruption(), MAC)
        assert state.active_entry.entry_id == "low"
        assert state.interruption_stack == ()


# ---------------------------------------------------------------------------
# 9. Substrate-neutrality
# ---------------------------------------------------------------------------


class TestSubstrateNeutrality:
    """The station package makes no direct Textual, Peewee, sqlite3, or
    wilted-package assumption.

    We verify this via static source inspection (reading every .py file
    under src/wilted/station/ and checking for forbidden import statements)
    rather than solely checking sys.modules after import. Source inspection
    is chosen as the primary, authoritative check because it catches
    forbidden imports even if they are conditionally executed (e.g. behind
    an `if TYPE_CHECKING:` guard or inside a function body that isn't
    called during a plain import) — sys.modules only reflects what actually
    got imported on this particular run, which could miss a forbidden
    import hidden behind a code path this test doesn't happen to trigger.
    We additionally check sys.modules as a second, complementary signal:
    it catches the case where a forbidden module is pulled in indirectly
    (e.g. via a transitive import) that source-grepping wilted.station
    alone wouldn't reveal.
    """

    FORBIDDEN_MODULE_PREFIXES = ("textual", "peewee", "sqlite3", "wilted.db")

    def _station_package_files(self):
        """Yield the source path of every .py file under wilted.station."""
        station_dir = list(station_pkg.__path__)[0]
        import pathlib

        return sorted(pathlib.Path(station_dir).rglob("*.py"))

    def test_no_forbidden_import_statements_in_source(self):
        """Static source scan: no file under wilted/station/ imports textual,
        peewee, sqlite3, wilted.db, or any other wilted.* submodule."""
        files = self._station_package_files()
        assert files, "expected at least one .py file under wilted/station/"

        for path in files:
            source = path.read_text()
            tree = __import__("ast").parse(source, filename=str(path))
            for node in __import__("ast").walk(tree):
                if isinstance(node, __import__("ast").Import):
                    for alias in node.names:
                        self._assert_module_allowed(alias.name, path)
                elif isinstance(node, __import__("ast").ImportFrom):
                    if node.module:
                        self._assert_module_allowed(node.module, path)

    def _assert_module_allowed(self, module_name: str, path) -> None:
        for forbidden in self.FORBIDDEN_MODULE_PREFIXES:
            assert not (module_name == forbidden or module_name.startswith(forbidden + ".")), (
                f"{path} imports forbidden module {module_name!r}"
            )
        # No dependency on the rest of wilted at all — only wilted.station.*
        # submodules (relative-style absolute imports) are allowed.
        if module_name == "wilted" or module_name.startswith("wilted."):
            assert module_name == "wilted.station" or module_name.startswith("wilted.station."), (
                f"{path} imports {module_name!r}, which is outside wilted.station"
            )

    def test_importing_station_package_does_not_pull_in_forbidden_modules(self):
        """Complementary dynamic check: importing wilted.station fresh does not
        add textual/peewee/sqlite3/wilted.db to sys.modules as a side effect."""
        # Drop wilted.station and its submodules (but not the forbidden
        # modules themselves — we want to detect if importing wilted.station
        # is what causes them to appear) so re-import is not a no-op.
        for name in list(sys.modules):
            if name == "wilted.station" or name.startswith("wilted.station."):
                del sys.modules[name]

        pre_existing_forbidden = {
            name
            for name in sys.modules
            if any(name == f or name.startswith(f + ".") for f in self.FORBIDDEN_MODULE_PREFIXES)
        }

        importlib.import_module("wilted.station")
        for _finder, name, _ispkg in pkgutil.walk_packages(station_pkg.__path__, prefix="wilted.station."):
            importlib.import_module(name)

        post_import_forbidden = {
            name
            for name in sys.modules
            if any(name == f or name.startswith(f + ".") for f in self.FORBIDDEN_MODULE_PREFIXES)
        }

        newly_added = post_import_forbidden - pre_existing_forbidden
        assert not newly_added, f"Importing wilted.station added forbidden modules to sys.modules: {newly_added}"
