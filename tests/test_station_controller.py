"""Tests for ``wilted.station_runtime.controller.StationController``.

Covers: mutation-through-the-reducer with durable persistence, rejection
handling (INV-7: stale revision), genuine concurrent submission from
multiple threads (real threads, not simulated), restore-on-start, lease
contention (``LeaseHeldError``), and submit-before-start/after-stop misuse.
"""

from __future__ import annotations

import threading

import pytest

from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    SafeInterruptionMap,
    StationEntry,
)
from wilted.station.reducer import (
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    StartPlayback,
    StationLifecycle,
    Stop,
)
from wilted.station_runtime import controller as controller_mod
from wilted.station_runtime.controller import StationController
from wilted.station_runtime.lease import ControllerLeaseManager, LeaseHeldError
from wilted.station_runtime.store import JsonStationStore

pytestmark = pytest.mark.integration


# ---------------------------------------------------------------------------
# Shared builders (mirrors tests/test_station_contracts.py's patterns)
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Accept / reject through the reducer
# ---------------------------------------------------------------------------


def test_submit_start_playback_is_accepted_and_persisted(isolated_data):
    controller = StationController(holder_id="mac-controller-1")
    controller.start()
    try:
        # start() -> ControllerLeaseManager.acquire() already bumped
        # station_revision once (0 -> 1) while claiming the lease, so the
        # baseline here is whatever start() left it at, not a hardcoded 0.
        start_revision = controller.current_state().station_revision

        entry = _entry()
        result = controller.submit_and_wait(StartPlayback(entry=entry), timeout=5)

        assert result.accepted is True
        assert result.state.active_entry is not None
        assert result.state.active_entry.entry_id == entry.entry_id
        assert result.state.station_revision == start_revision + 1

        # Durably persisted -- a fresh read of the store reflects it.
        store = JsonStationStore()
        on_disk = store.load_state()
        assert on_disk is not None
        assert on_disk.station_revision == start_revision + 1
        assert on_disk.active_entry is not None
        assert on_disk.active_entry.entry_id == entry.entry_id
    finally:
        controller.stop()


def test_submit_rejected_action_does_not_advance_revision_or_persist(isolated_data):
    controller = StationController(holder_id="mac-controller-2")
    controller.start()
    try:
        entry = _entry()
        controller.submit_and_wait(StartPlayback(entry=entry), timeout=5)
        pre_reject_state = controller.current_state()
        pre_reject_revision = pre_reject_state.station_revision

        # Stale expected_revision -> INV-7 rejection.
        result = controller.submit_and_wait(
            Checkpoint(
                mutation_id="mut-stale",
                expected_revision=pre_reject_revision + 999,
                media_offset_ms=1000,
                state_label="playing",
                writer_device="mac",
            ),
            timeout=5,
        )

        assert result.accepted is False
        assert result.revision == pre_reject_revision

        # No new persisted revision on disk.
        store = JsonStationStore()
        on_disk = store.load_state()
        assert on_disk is not None
        assert on_disk.station_revision == pre_reject_revision
    finally:
        controller.stop()


def test_submit_rejected_expired_entry_start_playback(isolated_data):
    controller = StationController(holder_id="mac-controller-2b")
    controller.start()
    try:
        start_revision = controller.current_state().station_revision

        expired_entry = _entry(entry_id="expired", expiry="2020-01-01T00:00:00Z")
        result = controller.submit_and_wait(StartPlayback(entry=expired_entry, now="2026-07-10T12:00:00Z"), timeout=5)

        assert result.accepted is False
        assert result.revision == start_revision
        assert result.state.active_entry is None

        store = JsonStationStore()
        on_disk = store.load_state()
        # Only the initial acquire()-persisted state should be on disk.
        assert on_disk is not None
        assert on_disk.station_revision == start_revision
        assert on_disk.active_entry is None
    finally:
        controller.stop()


# ---------------------------------------------------------------------------
# Concurrency: two real threads submitting concurrently
# ---------------------------------------------------------------------------


def test_concurrent_submits_serialize_with_no_lost_or_duplicated_apply(isolated_data):
    controller = StationController(holder_id="mac-controller-3")
    controller.start()
    try:
        entry = _entry()
        controller.submit_and_wait(StartPlayback(entry=entry), timeout=5)
        start_revision = controller.current_state().station_revision

        n_per_thread = 25
        all_futures: list = []
        futures_lock = threading.Lock()
        start_barrier = threading.Barrier(2)

        def submit_checkpoints(thread_tag: str) -> None:
            start_barrier.wait(timeout=5)
            local_futures = []
            for i in range(n_per_thread):
                future = controller.submit(
                    Checkpoint(
                        mutation_id=f"{thread_tag}-{i}",
                        expected_revision=-1,  # deliberately wrong -> guaranteed rejection
                        media_offset_ms=i * 1000,
                        state_label="playing",
                        writer_device=thread_tag,
                    )
                )
                local_futures.append(future)
            with futures_lock:
                all_futures.extend(local_futures)

        # One thread submits guaranteed-rejected Checkpoints (wrong
        # expected_revision) so we can assert "every future resolves,
        # nothing lost/duplicated" without racing on which checkpoints
        # happen to land on the right revision. The other thread submits
        # a real, always-accepted mutation stream (fresh idempotent
        # mutation ids) to prove accepted mutations from a concurrent
        # thread interleave safely and produce distinct increasing
        # revisions with no gaps/duplicates.
        def submit_accepted_checkpoints(thread_tag: str, expected_start: int) -> list:
            start_barrier.wait(timeout=5)
            local_futures = []
            expected = expected_start
            for i in range(n_per_thread):
                future = controller.submit(
                    Checkpoint(
                        mutation_id=f"{thread_tag}-{i}",
                        expected_revision=expected,
                        media_offset_ms=i * 1000,
                        state_label="playing",
                        writer_device=thread_tag,
                    )
                )
                local_futures.append((future, expected))
                # We don't know if it'll be accepted until resolved; this
                # loop just submits sequentially (single-thread-safe
                # revision tracking is the test's job, not the
                # controller's) -- resolve immediately to keep our own
                # expected_revision bookkeeping correct.
                result = future.result(timeout=5)
                if result.accepted:
                    expected = result.revision
            return local_futures

        rejecting_thread = threading.Thread(target=submit_checkpoints, args=("rejector",))

        accepted_results: list = []

        def run_accepted() -> None:
            accepted_results.extend(submit_accepted_checkpoints("accepter", start_revision))

        accepting_thread = threading.Thread(target=run_accepted)

        rejecting_thread.start()
        accepting_thread.start()
        rejecting_thread.join(timeout=10)
        accepting_thread.join(timeout=10)

        assert not rejecting_thread.is_alive()
        assert not accepting_thread.is_alive()

        # Every rejecting-thread future resolved (no lost/hung futures).
        assert len(all_futures) == n_per_thread
        for future in all_futures:
            result = future.result(timeout=5)
            assert result.accepted is False

        # Every accepting-thread submission was actually applied exactly
        # once: revisions strictly increased by 1 per accepted mutation,
        # sequentially, with no gaps or duplicates.
        accepted_revisions = [
            result.revision for future, _ in accepted_results for result in [future.result(timeout=5)]
        ]
        assert accepted_revisions == list(range(start_revision + 1, start_revision + 1 + n_per_thread))

        final_state = controller.current_state()
        assert final_state.station_revision == start_revision + n_per_thread

        store = JsonStationStore()
        on_disk = store.load_state()
        assert on_disk.station_revision == final_state.station_revision
    finally:
        controller.stop()


def test_concurrent_submits_from_two_threads_all_resolve_exactly_once(isolated_data):
    """Two threads submit distinct mutation_id Checkpoints concurrently;
    every future resolves, and accepted mutations serialize to a
    contiguous run of distinct revisions with the final persisted revision
    matching the in-memory one."""
    controller = StationController(holder_id="mac-controller-4")
    controller.start()
    try:
        entry = _entry()
        controller.submit_and_wait(StartPlayback(entry=entry), timeout=5)
        start_revision = controller.current_state().station_revision

        n_per_thread = 20
        results_lock = threading.Lock()
        all_results: list = []
        start_barrier = threading.Barrier(2)

        def worker(thread_tag: str) -> None:
            start_barrier.wait(timeout=5)
            local_results = []
            for i in range(n_per_thread):
                # Every submission uses a fresh, never-seen mutation_id and
                # a permissive expected_revision check is impossible to
                # predict across threads without serialization, so instead
                # we submit Checkpoints tagged with a mutation id unique
                # across both threads and let the reducer's own
                # expected_revision-vs-current check decide accept/reject;
                # we only assert on structural invariants (resolved,
                # distinct revisions, no duplicates), not on which specific
                # submissions were accepted.
                future = controller.submit(
                    Checkpoint(
                        mutation_id=f"{thread_tag}-{i}",
                        expected_revision=start_revision,
                        media_offset_ms=i * 1000,
                        state_label="playing",
                        writer_device=thread_tag,
                    )
                )
                local_results.append(future)
            with results_lock:
                all_results.extend(local_results)

        t1 = threading.Thread(target=worker, args=("thread-a",))
        t2 = threading.Thread(target=worker, args=("thread-b",))
        t1.start()
        t2.start()
        t1.join(timeout=10)
        t2.join(timeout=10)

        assert not t1.is_alive()
        assert not t2.is_alive()
        assert len(all_results) == 2 * n_per_thread

        resolved = [f.result(timeout=5) for f in all_results]
        accepted = [r for r in resolved if r.accepted]
        rejected = [r for r in resolved if not r.accepted]

        # Exactly one of the 2*n submissions could be accepted at
        # start_revision (only the first one to actually run against the
        # unchanged revision succeeds; every subsequent one -- from either
        # thread -- sees an advanced revision and is rejected). This
        # directly proves no double-apply: if the drain loop applied two
        # "expected_revision=start_revision" Checkpoints as both accepted,
        # that would mean apply() was called concurrently/out of order.
        assert len(accepted) == 1
        assert len(rejected) == 2 * n_per_thread - 1
        assert accepted[0].revision == start_revision + 1

        final_state = controller.current_state()
        assert final_state.station_revision == start_revision + 1

        store = JsonStationStore()
        on_disk = store.load_state()
        assert on_disk.station_revision == final_state.station_revision
    finally:
        controller.stop()


# ---------------------------------------------------------------------------
# Restore-on-start
# ---------------------------------------------------------------------------


def test_restore_on_start_preserves_active_entry_and_advances_epoch(isolated_data):
    first = StationController(holder_id="mac-controller-5a")
    first.start()
    entry = _entry(entry_id="entry-restore")
    first.submit_and_wait(StartPlayback(entry=entry), timeout=5)
    first_epoch = first.held_epoch
    first.stop()

    second = StationController(holder_id="mac-controller-5b")
    second.start()
    try:
        restored = second.current_state()
        assert restored.active_entry is not None
        assert restored.active_entry.entry_id == "entry-restore"
        assert restored.checkpoint is None  # StartPlayback clears checkpoint; never overwritten
        assert second.held_epoch is not None
        assert second.held_epoch > first_epoch
    finally:
        second.stop()


# ---------------------------------------------------------------------------
# Lease held elsewhere
# ---------------------------------------------------------------------------


def test_start_raises_lease_held_error_when_another_controller_is_live(isolated_data):
    store = JsonStationStore()
    holder_manager = ControllerLeaseManager("external-holder", store=store)
    holder_manager.acquire()
    try:
        second = StationController(holder_id="mac-controller-6")
        with pytest.raises(LeaseHeldError):
            second.start()
    finally:
        holder_manager.release()


# ---------------------------------------------------------------------------
# Submit before start / after stop
# ---------------------------------------------------------------------------


def test_submit_before_start_raises(isolated_data):
    controller = StationController(holder_id="mac-controller-7")
    with pytest.raises(RuntimeError):
        controller.submit(StartPlayback(entry=_entry()))


def test_submit_after_stop_raises(isolated_data):
    controller = StationController(holder_id="mac-controller-8")
    controller.start()
    controller.stop()
    with pytest.raises(RuntimeError):
        controller.submit(StartPlayback(entry=_entry()))


def test_stop_is_idempotent_and_safe_before_start(isolated_data):
    controller = StationController(holder_id="mac-controller-9")
    controller.stop()  # never started -- no-op

    controller.start()
    controller.stop()
    controller.stop()  # already stopped -- no-op


# ---------------------------------------------------------------------------
# Accepted lifecycle transitions (Stop / handoff) must persist
#
# Regression: these three reducer transitions change lifecycle without
# bumping station_revision historically, so the controller misread them as
# rejections and never persisted them -- a stopped station came back playing
# after a restart, and an acknowledged handoff was silently lost on disk.
# ---------------------------------------------------------------------------


def test_submit_stop_is_accepted_and_persisted(isolated_data):
    controller = StationController(holder_id="mac-controller-stop")
    controller.start()
    try:
        controller.submit_and_wait(StartPlayback(entry=_entry()), timeout=5)
        pre_stop_revision = controller.current_state().station_revision

        result = controller.submit_and_wait(Stop(), timeout=5)

        assert result.accepted is True
        assert result.state.lifecycle is StationLifecycle.STOPPED
        assert result.revision == pre_stop_revision + 1

        # Durably persisted: a fresh read shows the station stopped, so a
        # restart will NOT resurrect the pre-Stop playing state.
        on_disk = JsonStationStore().load_state()
        assert on_disk is not None
        assert on_disk.lifecycle is StationLifecycle.STOPPED
        assert on_disk.station_revision == pre_stop_revision + 1
    finally:
        controller.stop()


def test_submit_handoff_sequence_is_accepted_and_persisted(isolated_data):
    controller = StationController(holder_id="mac-controller-handoff")
    controller.start()
    try:
        controller.submit_and_wait(StartPlayback(entry=_entry()), timeout=5)
        mac_revision = controller.current_state().station_revision

        req = controller.submit_and_wait(
            RequestHandoff(
                phone_device_id="iphone-1",
                requested_epoch=1,
                last_known_mac_revision=mac_revision,
            ),
            timeout=5,
        )
        assert req.accepted is True
        assert req.state.lifecycle is StationLifecycle.HANDOFF_PENDING

        ack = controller.submit_and_wait(
            AcknowledgeHandoff(phone_device_id="iphone-1", epoch=1),
            timeout=5,
        )
        assert ack.accepted is True
        assert ack.state.lifecycle is StationLifecycle.OWNED_BY_IPHONE
        assert ack.state.lease is None  # Mac released the logical lease

        # The durable "iPhone now owns at epoch 1, Mac released the lease"
        # fact is on disk -- a restarted Mac must not think it still owns it.
        on_disk = JsonStationStore().load_state()
        assert on_disk is not None
        assert on_disk.lifecycle is StationLifecycle.OWNED_BY_IPHONE
        assert on_disk.phone_epoch == 1
        assert on_disk.lease is None
    finally:
        controller.stop()


# ---------------------------------------------------------------------------
# Lifecycle-edge safety (findings 2-4)
# ---------------------------------------------------------------------------


def test_submit_racing_with_stop_never_orphans_a_future(isolated_data):
    """A producer submitting concurrently with stop() must never be left
    holding a future that never resolves (which would hang a caller doing
    ``future.result()`` with no timeout). After stop() returns, every future
    the producer actually obtained is resolved."""
    for iteration in range(25):
        controller = StationController(holder_id=f"mac-race-{iteration}")
        controller.start()
        controller.submit_and_wait(StartPlayback(entry=_entry()), timeout=5)

        obtained: list = []
        obtained_lock = threading.Lock()

        def producer() -> None:
            local = []
            for i in range(40):
                try:
                    fut = controller.submit(
                        Checkpoint(
                            mutation_id=f"race-{iteration}-{i}",
                            expected_revision=-1,  # rejected either way; we only test resolution
                            media_offset_ms=i,
                            state_label="playing",
                            writer_device="racer",
                        )
                    )
                except RuntimeError:
                    # submit() after stop() raises -- no future to track. Expected.
                    break
                local.append(fut)
            with obtained_lock:
                obtained.extend(local)

        t = threading.Thread(target=producer)
        t.start()
        controller.stop()  # race the producer's submit loop
        t.join(timeout=10)

        assert not t.is_alive()
        with obtained_lock:
            for fut in obtained:
                assert fut.done(), "submit() returned a future that was never resolved (orphaned)"


def test_start_failure_after_acquire_releases_lease(isolated_data):
    """If start() fails AFTER acquiring the lease (store raises on restore),
    the lease/flock must be released so a later controller can still acquire
    -- not leaked into a permanent lockout."""
    good_store = JsonStationStore()
    lease_manager = ControllerLeaseManager("mac-startfail", store=good_store)

    class _RestoreExplodes(JsonStationStore):
        def load_state(self):
            raise RuntimeError("boom: corrupt store on restore")

    controller = StationController(
        holder_id="mac-startfail",
        store=_RestoreExplodes(),
        lease_manager=lease_manager,
    )
    with pytest.raises(RuntimeError, match="boom"):
        controller.start()

    # The lease is free again: a fresh controller can acquire and run.
    survivor = StationController(holder_id="mac-startfail-2")
    survivor.start()
    try:
        assert survivor.is_running
    finally:
        survivor.stop()


def test_stop_keeps_lease_when_drain_thread_hangs(isolated_data, monkeypatch):
    """If the drain thread can't be joined within the bound (a wedged
    persist), stop() must NOT release the lease -- releasing while the drain
    thread may still be writing would open the split-brain double-writer
    window the flock exists to prevent."""
    monkeypatch.setattr(controller_mod, "_JOIN_TIMEOUT_SECONDS", 0.15)

    in_persist = threading.Event()
    release = threading.Event()

    class _HangingPersistStore(JsonStationStore):
        def persist_state(self, state, *, expected_revision):
            in_persist.set()
            release.wait(timeout=5)
            return super().persist_state(state, expected_revision=expected_revision)

    # acquire() must use a NORMAL store (else start() would hang in the
    # lease-claim persist); only the controller's post-start writes hang.
    good_store = JsonStationStore()
    lease_manager = ControllerLeaseManager("mac-hang", store=good_store)
    controller = StationController(
        holder_id="mac-hang",
        store=_HangingPersistStore(),
        lease_manager=lease_manager,
    )
    controller.start()
    try:
        controller.submit(StartPlayback(entry=_entry()))  # its persist will block
        assert in_persist.wait(timeout=5), "drain thread never entered the hanging persist"

        controller.stop()  # join times out (drain thread stuck in persist)

        assert controller._drain_thread is not None
        assert controller._drain_thread.is_alive()  # still wedged
        # Lease was NOT released: another holder cannot acquire.
        other = ControllerLeaseManager("other-holder")
        with pytest.raises(LeaseHeldError):
            other.acquire()
    finally:
        release.set()
        if controller._drain_thread is not None:
            controller._drain_thread.join(timeout=5)
        lease_manager.release()  # explicit cleanup (stop() deliberately did not)
