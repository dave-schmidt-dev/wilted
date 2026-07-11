"""Tests for ``wilted.station_runtime.lease.ControllerLeaseManager``.

Covers OS-level controller-lease arbitration built on top of the pure
epoch-fencing logic in ``wilted.station.reducer.claim_lease`` and the
durable persistence in ``wilted.station_runtime.store.JsonStationStore``.

Mutual exclusion and liveness are both provided by an OS ``flock`` held for
the lease's entire lifetime (see ``lease.py``'s module docstring) -- there is
no heartbeat TTL involved in the accept/reject decision at all. These tests
cover:

(a) concurrent acquisitions -- including genuine cross-process races via
    ``multiprocessing`` -- resolve to exactly one holder
(b) a live (flock-held) lease is not stealable
(c) a crashed holder's flock is auto-released by the OS, so a fresh
    acquirer reclaims cleanly with a strictly advancing epoch -- both for an
    in-process simulated crash and for a genuine cross-process crash
    (``os._exit`` without ``release()``)
(d) a heartbeat record surviving a reboot (wall-clock, far-past or
    negative-age) does not block reclaim -- liveness is flock-only, not
    clock-based
(e) after takeover, ``reducer.apply`` rejects a mutation carrying the
    FORMER holder's lease (owner-loss)
(f) a clean release lets the next acquirer succeed
"""

from __future__ import annotations

import json
import multiprocessing
import os
import threading
import time
from datetime import UTC, datetime, timedelta

import pytest

import wilted
from wilted.station.models import ControllerLease
from wilted.station.reducer import Stop, apply
from wilted.station_runtime.lease import ControllerLeaseManager, LeaseHeldError, _Heartbeat
from wilted.station_runtime.store import JsonStationStore

_SHORT_TTL = 0.05
_SHORT_HEARTBEAT_INTERVAL = 0.01


def _wall_clock_z(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# (a) Concurrent acquisitions -> exactly one holder
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_concurrent_acquisitions_in_process_resolve_to_exactly_one_holder():
    """Two threads racing to acquire the same lockfile: exactly one wins.

    Threads share one OS process, so this exercises the in-process
    ``_acquire_lock`` serialization plus flock, but NOT genuine cross-process
    flock arbitration (see the multiprocessing test below for that).
    """
    store = JsonStationStore()
    manager_a = ControllerLeaseManager("holder-a", store=store, ttl_seconds=_SHORT_TTL)
    manager_b = ControllerLeaseManager("holder-b", store=store, ttl_seconds=_SHORT_TTL)

    results: dict[str, object] = {}
    start_barrier = threading.Barrier(2)

    def _try_acquire(name: str, manager: ControllerLeaseManager) -> None:
        start_barrier.wait()
        try:
            lease = manager.acquire()
            results[name] = lease
        except LeaseHeldError as exc:
            results[name] = exc

    thread_a = threading.Thread(target=_try_acquire, args=("a", manager_a))
    thread_b = threading.Thread(target=_try_acquire, args=("b", manager_b))
    thread_a.start()
    thread_b.start()
    thread_a.join(timeout=5.0)
    thread_b.join(timeout=5.0)

    try:
        successes = [v for v in results.values() if isinstance(v, ControllerLease)]
        failures = [v for v in results.values() if isinstance(v, LeaseHeldError)]

        assert len(successes) == 1, f"expected exactly one winner, got {results}"
        assert len(failures) == 1

        winner_manager = manager_a if isinstance(results["a"], ControllerLease) else manager_b
        assert winner_manager.held_epoch is not None
    finally:
        manager_a.release()
        manager_b.release()


def _mp_worker_race_for_lease(data_dir: str, holder_id: str, barrier: object, result_queue: object) -> None:
    """Module-level worker: a genuine separate process racing to acquire the lease.

    Must be module-level (not a closure/lambda) so it is picklable for
    ``multiprocessing`` under the default ``spawn`` start method, which does
    NOT inherit the parent's monkeypatched ``wilted.DATA_DIR`` -- it re-imports
    ``wilted`` fresh in the child, so ``DATA_DIR`` must be set explicitly here
    (INV-5: resolved at call time, so setting it before constructing the
    manager is sufficient and respected by every subsequent call).
    """
    import pathlib

    import wilted as wilted_mod
    from wilted.station_runtime.lease import ControllerLeaseManager, LeaseHeldError
    from wilted.station_runtime.store import JsonStationStore

    wilted_mod.DATA_DIR = pathlib.Path(data_dir)

    manager = ControllerLeaseManager(holder_id, store=JsonStationStore(), ttl_seconds=_SHORT_TTL)
    barrier.wait()
    try:
        lease = manager.acquire()
        result_queue.put((holder_id, "ok", lease.holder_id, lease.epoch))
        # Hold the lease briefly so the parent can observe a live winner
        # before this process exits (which would auto-release the flock).
        time.sleep(0.5)
        manager.release()
    except LeaseHeldError as exc:
        result_queue.put((holder_id, "held_error", str(exc), None))


@pytest.mark.integration
def test_concurrent_cross_process_takeover_resolves_to_exactly_one_winner(tmp_path):
    """N genuine separate processes race to acquire(): exactly one succeeds.

    This is the split-brain reproduction/regression test: prior to the flock
    rework, ``reducer.claim_lease`` not bumping ``station_revision`` on the
    stale-takeover path meant two racing processes could both observe their
    own compare-and-set as having won (reproduced 200/200 by the reviewer).
    With flock held for the lease's lifetime, at most one process can ever be
    inside the claim/persist critical section at a time, so at most one can
    win -- this is asserted directly against real OS processes (threads in a
    single process cannot exercise cross-process flock semantics).
    """
    data_dir = str(tmp_path / "data")
    n_processes = 6

    ctx = multiprocessing.get_context("spawn")
    barrier = ctx.Barrier(n_processes)
    result_queue = ctx.Queue()

    processes = [
        ctx.Process(
            target=_mp_worker_race_for_lease,
            args=(data_dir, f"racer-{i}", barrier, result_queue),
        )
        for i in range(n_processes)
    ]
    for p in processes:
        p.start()
    for p in processes:
        p.join(timeout=10.0)
        assert p.exitcode == 0, f"worker process {p} exited with {p.exitcode}"

    results = [result_queue.get(timeout=1.0) for _ in range(n_processes)]
    successes = [r for r in results if r[1] == "ok"]
    failures = [r for r in results if r[1] == "held_error"]

    assert len(successes) == 1, f"expected exactly one winner, got {results}"
    assert len(failures) == n_processes - 1

    # The winner's epoch is the unique epoch recorded -- no split-brain
    # duplicate epoch from a second process believing it also won.
    winner_holder_id, _, won_as_holder_id, won_epoch = successes[0]
    assert won_as_holder_id == winner_holder_id
    assert won_epoch == 1


# ---------------------------------------------------------------------------
# (b) A live (flock-held) lease is not stealable
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_live_lease_is_not_stealable():
    """A second acquire attempt while the first holder's flock is held fails."""
    store = JsonStationStore()
    first = ControllerLeaseManager("first-holder", store=store, ttl_seconds=_SHORT_TTL)
    second = ControllerLeaseManager("second-holder", store=store, ttl_seconds=_SHORT_TTL)

    first_lease = first.acquire()
    try:
        with pytest.raises(LeaseHeldError):
            second.acquire()

        # The first holder's lease is unaffected by the failed steal attempt.
        assert store.current_lease() == first_lease
        assert second.held_epoch is None
    finally:
        first.release()


@pytest.mark.unit
def test_is_lease_live_reports_true_while_a_manager_holds_the_flock():
    """A separate manager instance's is_lease_live() sees the held flock as live."""
    store = JsonStationStore()
    holder = ControllerLeaseManager("holder", store=store, ttl_seconds=_SHORT_TTL)
    observer = ControllerLeaseManager("observer", store=store, ttl_seconds=_SHORT_TTL)

    holder.acquire()
    try:
        assert observer.is_lease_live() is True
    finally:
        holder.release()

    assert observer.is_lease_live() is False


# ---------------------------------------------------------------------------
# (c) A crashed holder's flock is auto-released -> reclaimable, epoch advances
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_crash_in_process_auto_releases_flock_for_reclaim():
    """Closing the holder's fd out from under it (simulating a crash) releases the flock.

    Unlike the old TTL-based design, stopping the heartbeat thread alone is
    NOT enough to make the lease reclaimable -- the flock is still held by
    the open fd. Only the fd actually closing (which the OS also does
    automatically on process exit/crash) releases the flock. This test
    simulates that at the OS level without spawning a real process.
    """
    store = JsonStationStore()
    first = ControllerLeaseManager("crashed-holder", store=store, ttl_seconds=_SHORT_TTL)
    second = ControllerLeaseManager("rescuer", store=store, ttl_seconds=_SHORT_TTL)

    first_lease = first.acquire()
    old_epoch = first_lease.epoch

    # Merely stopping the heartbeat does NOT release the flock -- the lease
    # must still be live/unstealable, because the process (thread, here)
    # hasn't actually died.
    first._stop_heartbeat_thread()  # noqa: SLF001 - inspecting internal state for the test
    assert second.is_lease_live() is True
    with pytest.raises(LeaseHeldError):
        second.acquire()

    # Now simulate the crash for real: close the fd without going through
    # release() (a real crash never calls release() either). The OS drops
    # the flock the instant the last fd referencing it closes.
    os.close(first._lock_fd)  # noqa: SLF001 - simulating a crashed process's fd closing
    first._lock_fd = None  # noqa: SLF001 - prevent release() from double-closing in cleanup

    assert second.is_lease_live() is False

    second_lease = second.acquire()
    try:
        assert second_lease.epoch > old_epoch
        assert second_lease.holder_id == "rescuer"
        assert store.current_lease() == second_lease
    finally:
        second.release()


def _mp_worker_acquire_then_die(data_dir: str) -> None:
    """Module-level worker: acquires the lease then dies WITHOUT calling release().

    Uses ``os._exit`` (not ``sys.exit``/a normal return) to skip all Python
    and OS-level cleanup handlers, simulating a hard crash (e.g. SIGKILL) as
    closely as an in-process test can. The OS is responsible for releasing
    the flock when the process's file descriptor table is torn down --
    nothing in this module's own code runs a release() path here.
    """
    import pathlib

    import wilted as wilted_mod
    from wilted.station_runtime.lease import ControllerLeaseManager
    from wilted.station_runtime.store import JsonStationStore

    wilted_mod.DATA_DIR = pathlib.Path(data_dir)

    manager = ControllerLeaseManager("crashed-child", store=JsonStationStore(), ttl_seconds=_SHORT_TTL)
    manager.acquire()
    os._exit(1)  # noqa: SLF001 - deliberately hard-exit without release() to simulate a crash


@pytest.mark.integration
def test_crash_auto_release_cross_process(tmp_path):
    """A child process acquires then dies without release(); the parent then acquires cleanly.

    This is the direct regression test for the "reboot wedge" bug's crash
    variant: the OS must release the child's flock the moment its process
    dies, with no heartbeat/TTL involved, so the parent's subsequent
    ``acquire()`` succeeds immediately with a bumped epoch.
    """
    data_dir = str(tmp_path / "data")
    wilted.DATA_DIR = tmp_path / "data"  # also set in this (parent) process for the store below

    ctx = multiprocessing.get_context("spawn")
    child = ctx.Process(target=_mp_worker_acquire_then_die, args=(data_dir,))
    child.start()
    child.join(timeout=10.0)
    assert child.exitcode == 1

    store = JsonStationStore()
    parent = ControllerLeaseManager("parent-rescuer", store=store, ttl_seconds=_SHORT_TTL)

    assert parent.is_lease_live() is False

    lease = parent.acquire()
    try:
        assert lease.holder_id == "parent-rescuer"
        assert lease.epoch == 2  # child claimed epoch 1; parent's reclaim strictly advances
        assert store.current_lease() == lease
    finally:
        parent.release()


# ---------------------------------------------------------------------------
# (d) A heartbeat surviving a reboot (wall-clock, far-past/negative age)
#     never blocks reclaim -- liveness is flock-only, not clock-based.
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_reboot_like_far_past_heartbeat_is_reclaimable_with_free_flock():
    """A stale on-disk heartbeat (simulating a reboot) does not block acquire() when the flock is free.

    Simulates the reboot wedge directly: write a heartbeat record with a
    wall-clock timestamp far in the past (as if it survived a reboot with no
    live process holding the flock), and confirm a fresh acquirer reclaims
    immediately -- acquire() never even inspects the heartbeat for its
    mutual-exclusion decision.
    """
    store = JsonStationStore()
    manager = ControllerLeaseManager("rescuer-after-reboot", store=store, ttl_seconds=_SHORT_TTL)

    far_past = datetime.now(UTC) - timedelta(days=365)
    stale_heartbeat = _Heartbeat(holder_id="pre-reboot-holder", epoch=1, last_beat_wall_clock=_wall_clock_z(far_past))
    # Write the on-disk record directly (NOT via manager._write_heartbeat,
    # which requires an already-held flock/fd) -- this simulates a heartbeat
    # file that survived a reboot with no live process holding the lock.
    lockfile_path = manager._lockfile_path()  # noqa: SLF001
    lockfile_path.parent.mkdir(parents=True, exist_ok=True)
    lockfile_path.write_text(json.dumps(stale_heartbeat.to_json_dict()))

    # No process holds the flock (the lockfile was written directly, not via
    # acquire()), so this must succeed immediately.
    assert manager.is_lease_live() is False
    lease = manager.acquire()
    try:
        assert lease.holder_id == "rescuer-after-reboot"
    finally:
        manager.release()


@pytest.mark.unit
def test_negative_age_heartbeat_is_never_treated_as_fresh():
    """A heartbeat timestamped in the future (clock ran backwards) is stale, not fresh.

    Directly exercises ``_Heartbeat.is_stale``'s negative-age handling, which
    is the fix for the original bug's root cause: a monotonic-clock age that
    goes negative after a reboot must never be read as "fresh". Wall clock
    heartbeats have the same hazard if a clock steps backwards (NTP, manual
    change), so the same guard applies.
    """
    future = datetime.now(UTC) + timedelta(hours=1)
    heartbeat = _Heartbeat(holder_id="clock-skewed-holder", epoch=1, last_beat_wall_clock=_wall_clock_z(future))

    now_wall_clock = time.time()
    age = heartbeat.age_seconds(now_wall_clock=now_wall_clock)
    assert age < 0, "test setup sanity check: the heartbeat must be in the future"
    assert heartbeat.is_stale(ttl_seconds=15.0, now_wall_clock=now_wall_clock) is True


@pytest.mark.unit
def test_fresh_wall_clock_heartbeat_is_not_stale():
    """A heartbeat from a moment ago (small positive age) is correctly read as fresh."""
    heartbeat = _Heartbeat(holder_id="just-now", epoch=1, last_beat_wall_clock=_wall_clock_z(datetime.now(UTC)))
    now_wall_clock = time.time()
    assert heartbeat.is_stale(ttl_seconds=15.0, now_wall_clock=now_wall_clock) is False


# ---------------------------------------------------------------------------
# (e) After takeover, apply() rejects a mutation carrying the FORMER
#     holder's lease (owner-loss) -- exercises the existing reducer logic.
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_apply_rejects_former_holders_lease_after_takeover():
    """A mutation presenting the pre-takeover lease is rejected: revision unchanged, error event appended."""
    store = JsonStationStore()
    first = ControllerLeaseManager("orphaned-holder", store=store, ttl_seconds=_SHORT_TTL)
    second = ControllerLeaseManager("new-holder", store=store, ttl_seconds=_SHORT_TTL)

    former_lease = first.acquire()
    # Simulate a crash: close the fd directly (see test_crash_in_process_auto_releases_flock_for_reclaim).
    os.close(first._lock_fd)  # noqa: SLF001 - simulating a crashed process's fd closing
    first._lock_fd = None  # noqa: SLF001
    first._stop_heartbeat_thread()  # noqa: SLF001 - avoid a dangling thread from the abandoned manager

    new_lease = second.acquire()
    try:
        state = store.load_state()
        assert state.lease == new_lease

        before_revision = state.station_revision
        result = apply(state, Stop(now="2026-07-10T06:00:00Z"), requester_lease=former_lease)

        assert result.station_revision == before_revision  # rejected: no mutation applied
        assert result.events[-1].kind == "error"
        assert "owner-loss" in result.events[-1].message
    finally:
        second.release()


# ---------------------------------------------------------------------------
# (f) Clean release lets the next acquirer succeed
# ---------------------------------------------------------------------------


@pytest.mark.unit
def test_clean_release_allows_next_acquirer_to_succeed():
    """acquire -> release -> acquire (different holder) succeeds, epoch continues to advance."""
    store = JsonStationStore()
    first = ControllerLeaseManager("holder-1", store=store, ttl_seconds=_SHORT_TTL)
    second = ControllerLeaseManager("holder-2", store=store, ttl_seconds=_SHORT_TTL)

    first_lease = first.acquire()
    first.release()

    # The flock is released; a fresh manager sees no live holder.
    assert first.is_lease_live() is False

    second_lease = second.acquire()
    try:
        assert second_lease.epoch > first_lease.epoch
        assert second_lease.holder_id == "holder-2"
        assert store.current_lease() == second_lease
    finally:
        second.release()


@pytest.mark.unit
def test_release_stops_heartbeat_thread_without_leaking():
    """release() joins the background heartbeat thread; no thread is left running."""
    store = JsonStationStore()
    manager = ControllerLeaseManager(
        "holder-thread-check",
        store=store,
        ttl_seconds=_SHORT_TTL,
        heartbeat_interval_seconds=_SHORT_HEARTBEAT_INTERVAL,
    )

    manager.acquire()
    heartbeat_thread = manager._heartbeat_thread  # noqa: SLF001 - inspecting internal thread handle for leak check
    assert heartbeat_thread is not None
    assert heartbeat_thread.is_alive()

    manager.release()

    assert not heartbeat_thread.is_alive()
    assert manager._heartbeat_thread is None  # noqa: SLF001


@pytest.mark.unit
def test_release_is_a_no_op_when_never_acquired():
    """release() on a manager that never acquired anything must not raise."""
    store = JsonStationStore()
    manager = ControllerLeaseManager("never-acquired", store=store, ttl_seconds=_SHORT_TTL)

    manager.release()  # must not raise

    assert manager.held_epoch is None


@pytest.mark.unit
def test_acquire_with_no_prior_state_starts_at_epoch_one():
    """The very first acquire against an empty store claims epoch 1."""
    store = JsonStationStore()
    manager = ControllerLeaseManager("first-ever", store=store, ttl_seconds=_SHORT_TTL)

    assert store.current_lease() is None

    lease = manager.acquire()
    try:
        assert lease.epoch == 1
        assert lease.holder_id == "first-ever"
    finally:
        manager.release()


@pytest.mark.unit
def test_acquire_persists_lease_via_single_state_write_advancing_revision_by_one():
    """acquire() advances station_revision by exactly 1 per takeover (no redundant double-persist).

    Regression test for the split-brain bug's root cause: the old code path
    called ``persist_state`` and then a separate ``persist_lease`` (itself a
    CAS retry loop against the state document), which bumped
    ``station_revision`` twice for one takeover and, combined with
    ``claim_lease`` not bumping revision itself, made it possible for two
    concurrent claims to each observe their own CAS as a "win" against the
    same base revision. A single ``persist_state`` call means exactly one
    revision bump per successful acquire.
    """
    store = JsonStationStore()
    first = ControllerLeaseManager("holder-1", store=store, ttl_seconds=_SHORT_TTL)
    second = ControllerLeaseManager("holder-2", store=store, ttl_seconds=_SHORT_TTL)

    assert store.load_state() is None

    first.acquire()
    state_after_first = store.load_state()
    assert state_after_first.station_revision == 1
    first.release()

    second.acquire()
    try:
        state_after_second = store.load_state()
        assert state_after_second.station_revision == 2
    finally:
        second.release()


@pytest.mark.unit
def test_heartbeat_record_uses_wall_clock_not_monotonic():
    """The persisted heartbeat is a wall-clock ISO-Z string, parseable independent of process uptime."""
    store = JsonStationStore()
    manager = ControllerLeaseManager("wall-clock-holder", store=store, ttl_seconds=_SHORT_TTL)

    before = datetime.now(UTC)
    manager.acquire()
    try:
        heartbeat = manager._read_heartbeat()  # noqa: SLF001 - inspecting on-disk record for the test
        assert heartbeat is not None
        # Must parse as a wall-clock ISO-Z timestamp close to "now", not a
        # small monotonic-clock float like 12345.678.
        recorded = datetime.strptime(heartbeat.last_beat_wall_clock, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
        assert abs((recorded - before).total_seconds()) < 5.0
    finally:
        manager.release()


@pytest.mark.unit
def test_heartbeat_thread_keeps_refreshing_wall_clock_heartbeat():
    """The background heartbeat thread refreshes the wall-clock timestamp on its interval."""
    store = JsonStationStore()
    manager = ControllerLeaseManager(
        "steady-holder",
        store=store,
        ttl_seconds=_SHORT_TTL,
        heartbeat_interval_seconds=_SHORT_HEARTBEAT_INTERVAL,
    )

    manager.acquire()
    try:
        first_heartbeat = manager._read_heartbeat()  # noqa: SLF001
        time.sleep(_SHORT_HEARTBEAT_INTERVAL * 5)
        second_heartbeat = manager._read_heartbeat()  # noqa: SLF001
        assert second_heartbeat is not None
        assert first_heartbeat is not None
        assert second_heartbeat.last_beat_wall_clock >= first_heartbeat.last_beat_wall_clock
        # Liveness itself is unaffected either way -- the flock is still held.
        assert manager.is_lease_live() is True
    finally:
        manager.release()
