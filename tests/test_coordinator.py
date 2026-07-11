"""Tests for wilted.station_runtime.coordinator — ModelCoordinator and RuntimeBootstrap.

Covers the two hard-won invariants from INVARIANTS.md:

INV-1: the tqdm multiprocessing lock is initialized on the main thread
before any worker thread loads a model (guards BUG-2 — resource_tracker
spawned with a bad fd set when the first tqdm-lock init happens inside a
Textual worker).

INV-2: at most one ML model family is resident at a time, and every load is
paired with a close/reclaim that runs even when load() itself raised.

All backends here are FAKES. No real MLX/Metal model is loaded — that would
violate the "keep this suite fast and off the real GPU" constraint and is
unnecessary to prove the coordinator's locking/lifecycle behavior.
"""

from __future__ import annotations

import threading
import time

import pytest

from wilted.station_runtime.coordinator import (
    LeaseHeldElsewhereError,
    LeaseReentrancyError,
    ModelCoordinator,
    RuntimeBootstrap,
)

# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


class FakeLLMBackend:
    """Fake satisfying the LLMBackend Protocol shape (load/generate/close).

    Records call order and can be told to raise on load() to exercise the
    close-runs-on-exception path.
    """

    def __init__(self, *, raise_on_load: bool = False):
        self.raise_on_load = raise_on_load
        self.loaded = False
        self.closed = False
        self.calls: list[str] = []

    def load(self) -> None:
        self.calls.append("load")
        if self.raise_on_load:
            raise RuntimeError("simulated load failure")
        self.loaded = True

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        self.calls.append("generate")
        return ("fake response", 3)

    def close(self) -> None:
        self.calls.append("close")
        self.closed = True
        self.loaded = False


class FakeAudioEngine:
    """Fake satisfying AudioEngine's load_model()/generate_audio() shape."""

    def __init__(self, *, raise_on_load: bool = False):
        self.raise_on_load = raise_on_load
        self.loaded = False
        self.calls: list[str] = []

    def load_model(self) -> None:
        self.calls.append("load_model")
        if self.raise_on_load:
            raise RuntimeError("simulated TTS load failure")
        self.loaded = True

    def generate_audio(self, text: str, **kwargs) -> list[float]:
        self.calls.append("generate_audio")
        return [0.0, 0.0]


class ResidencyRecorder:
    """Records concurrent-residency count across threads under a coordinator.

    Used to assert INV-2 holds even when multiple threads race to acquire
    the lease for different families: the recorded peak must never exceed 1.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._current = 0
        self.peak = 0
        self.timeline: list[tuple[str, str]] = []

    def enter(self, label: str) -> None:
        with self._lock:
            self._current += 1
            self.peak = max(self.peak, self._current)
            self.timeline.append((label, "enter"))

    def exit(self, label: str) -> None:
        with self._lock:
            self.timeline.append((label, "exit"))
            self._current -= 1


# ---------------------------------------------------------------------------
# INV-2 (a): only one family resident at a time
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestOneModelAtATime:
    def test_run_llm_reports_peak_residency_of_one(self):
        """A single run_llm call never registers concurrent residency > 1."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend()

        result = coordinator.run_llm(backend, lambda b: b.generate("sys", "user"))

        assert result == ("fake response", 3)
        assert coordinator.peak_concurrent_residency == 1
        assert backend.calls == ["load", "generate", "close"]

    def test_two_families_never_resident_concurrently(self):
        """Two threads racing on llm and tts leases never overlap residency.

        Both threads are released to race for the coordinator's single lease
        at the same instant (via a start gate), and each fake's load() sleeps
        briefly to widen the window in which a bug would show overlap. The
        recorder's peak concurrent-residency count (spanning both threads)
        must never exceed 1 — proving the coordinator serializes (the second
        racer waits for the lease) rather than co-loading.
        """
        coordinator = ModelCoordinator()
        recorder = ResidencyRecorder()
        start_gate = threading.Event()

        results = {}
        errors = []

        def run_llm_thread():
            try:
                start_gate.wait(timeout=5.0)
                backend = FakeLLMBackend()

                def _load():
                    recorder.enter("llm")
                    time.sleep(0.05)
                    backend.load()
                    recorder.exit("llm")

                with coordinator.lease("llm") as lease:
                    lease.load(_load)
                    results["llm"] = backend.calls
                    lease.close(backend.close)
            except Exception as e:  # noqa: BLE001 - surfaced via errors list
                errors.append(e)

        def run_tts_thread():
            try:
                start_gate.wait(timeout=5.0)
                engine = FakeAudioEngine()

                def _load():
                    recorder.enter("tts")
                    time.sleep(0.05)
                    engine.load_model()
                    recorder.exit("tts")

                with coordinator.lease("tts") as lease:
                    lease.load(_load)
                    results["tts"] = engine.calls
            except Exception as e:  # noqa: BLE001
                errors.append(e)

        t1 = threading.Thread(target=run_llm_thread)
        t2 = threading.Thread(target=run_tts_thread)
        t1.start()
        t2.start()
        start_gate.set()  # release both threads to race for the lease together
        t1.join(timeout=5.0)
        t2.join(timeout=5.0)

        assert not errors, f"unexpected errors in worker threads: {errors}"
        assert recorder.peak == 1, (
            f"concurrent residency exceeded 1 (peak={recorder.peak}); timeline={recorder.timeline}"
        )
        assert coordinator.peak_concurrent_residency == 1

    def test_second_acquisition_blocks_until_first_releases(self):
        """Acquiring the lease while held waits for the slot instead of proceeding.

        The second thread's lease() call must not return until the first
        thread's `with` block exits, proven by an order-of-events list.
        """
        coordinator = ModelCoordinator()
        order: list[str] = []
        first_holds = threading.Event()
        release_first = threading.Event()

        def hold_first():
            with coordinator.lease("llm"):
                order.append("first-acquired")
                first_holds.set()
                release_first.wait(timeout=5.0)
                order.append("first-releasing")

        def acquire_second():
            first_holds.wait(timeout=5.0)
            order.append("second-waiting")
            with coordinator.lease("tts"):
                order.append("second-acquired")

        t1 = threading.Thread(target=hold_first)
        t2 = threading.Thread(target=acquire_second)
        t1.start()
        t2.start()
        time.sleep(0.1)  # let second thread reach "waiting" and block on lease()
        assert order[-1] == "second-waiting", "second thread should be blocked, not acquired"
        release_first.set()
        t1.join(timeout=5.0)
        t2.join(timeout=5.0)

        assert order == [
            "first-acquired",
            "second-waiting",
            "first-releasing",
            "second-acquired",
        ]

    def test_unknown_family_rejected(self):
        coordinator = ModelCoordinator()
        with pytest.raises(ValueError, match="Unknown model family"):
            with coordinator.lease("ranking-model"):
                pass


# ---------------------------------------------------------------------------
# INV-2 (b): close runs even when load() raises
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestCloseRunsOnException:
    def test_llm_close_runs_when_load_raises(self):
        """run_llm's finally must call close() even though load() raised."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend(raise_on_load=True)

        with pytest.raises(RuntimeError, match="simulated load failure"):
            coordinator.run_llm(backend, lambda b: b.generate("sys", "user"))

        assert backend.calls == ["load", "close"]
        assert backend.closed is True
        assert backend.loaded is False

    def test_tts_unload_runs_when_load_raises(self):
        """run_tts's finally must call unload_fn even though load_model() raised."""
        coordinator = ModelCoordinator()
        engine = FakeAudioEngine(raise_on_load=True)
        unload_calls = []

        with pytest.raises(RuntimeError, match="simulated TTS load failure"):
            coordinator.run_tts(
                engine,
                lambda e: e.generate_audio("text"),
                unload_fn=lambda: unload_calls.append("unloaded"),
            )

        assert engine.calls == ["load_model"]
        assert unload_calls == ["unloaded"]

    def test_manual_lease_close_runs_on_load_exception(self):
        """Direct lease() usage: close() still fires in a finally around load()."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend(raise_on_load=True)

        with pytest.raises(RuntimeError, match="simulated load failure"):
            with coordinator.lease("llm") as lease:
                try:
                    lease.load(backend.load)
                finally:
                    lease.close(backend.close)

        assert backend.calls == ["load", "close"]
        assert backend.closed is True

    def test_lease_released_after_exception_so_next_acquisition_proceeds(self):
        """A raised load() must not leave the lease permanently held.

        Regression guard: if the lock were acquired outside the try/finally
        that releases it, an exception during load() could deadlock all
        subsequent acquisitions.
        """
        coordinator = ModelCoordinator()
        failing_backend = FakeLLMBackend(raise_on_load=True)

        with pytest.raises(RuntimeError):
            coordinator.run_llm(failing_backend, lambda b: b.generate("sys", "user"))

        # Lease must be free again — this must not hang.
        healthy_backend = FakeLLMBackend()
        result = coordinator.run_llm(healthy_backend, lambda b: b.generate("sys", "user"))
        assert result == ("fake response", 3)
        assert healthy_backend.calls == ["load", "generate", "close"]

    def test_transcribe_call_serialized_and_exception_propagates(self):
        """run_transcribe propagates a raising call and still releases the lease."""
        coordinator = ModelCoordinator()

        def failing_call():
            raise RuntimeError("simulated transcribe failure")

        with pytest.raises(RuntimeError, match="simulated transcribe failure"):
            coordinator.run_transcribe(failing_call)

        # Lease released — a subsequent acquisition must proceed, not hang.
        result = coordinator.run_transcribe(lambda: "ok")
        assert result == "ok"

    def test_lease_held_elsewhere_error_is_a_runtime_error_subclass(self):
        """Defensive-assertion error type is importable and a RuntimeError."""
        assert issubclass(LeaseHeldElsewhereError, RuntimeError)


# ---------------------------------------------------------------------------
# Nested-lease self-deadlock must raise immediately, not hang
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestNestedLeaseRaisesInsteadOfHanging:
    def test_nested_lease_different_family_raises_quickly(self):
        """A thread holding 'llm' that calls lease('tts') must raise, not block.

        Proven with a background-thread + join(timeout=...) harness: if this
        ever regressed to a hang, the join would time out and the assertion
        on `raised` would fail instead of the test itself hanging forever.
        """
        coordinator = ModelCoordinator()
        raised: list[BaseException] = []
        done = threading.Event()

        def attempt_nested_lease():
            try:
                with coordinator.lease("llm"):
                    try:
                        with coordinator.lease("tts"):
                            pass
                    except BaseException as e:  # noqa: BLE001 - captured for assertion
                        raised.append(e)
            finally:
                done.set()

        t = threading.Thread(target=attempt_nested_lease)
        start = time.monotonic()
        t.start()
        finished = done.wait(timeout=2.0)
        t.join(timeout=2.0)
        elapsed = time.monotonic() - start

        assert finished, "nested lease() call hung instead of raising"
        assert elapsed < 2.0, f"nested lease() took too long ({elapsed:.2f}s) — looks like a hang"
        assert len(raised) == 1
        assert isinstance(raised[0], LeaseReentrancyError)
        assert "must never nest" in str(raised[0])

    def test_nested_lease_same_family_raises_quickly(self):
        """A thread holding 'llm' that calls lease('llm') again must also raise, not block."""
        coordinator = ModelCoordinator()
        raised: list[BaseException] = []
        done = threading.Event()

        def attempt_nested_lease():
            try:
                with coordinator.lease("llm"):
                    try:
                        with coordinator.lease("llm"):
                            pass
                    except BaseException as e:  # noqa: BLE001 - captured for assertion
                        raised.append(e)
            finally:
                done.set()

        t = threading.Thread(target=attempt_nested_lease)
        start = time.monotonic()
        t.start()
        finished = done.wait(timeout=2.0)
        t.join(timeout=2.0)
        elapsed = time.monotonic() - start

        assert finished, "same-family nested lease() call hung instead of raising"
        assert elapsed < 2.0, f"nested lease() took too long ({elapsed:.2f}s) — looks like a hang"
        assert len(raised) == 1
        assert isinstance(raised[0], LeaseReentrancyError)

    def test_outer_lease_still_releases_after_reentrancy_error_and_next_acquire_works(self):
        """A LeaseReentrancyError in a nested call must not corrupt the outer lease's release.

        After the outer `with` block exits (having caught the inner
        LeaseReentrancyError), a fresh acquisition from a new thread must
        succeed promptly — proving the lock and owner-tracking were left in
        a clean state.
        """
        coordinator = ModelCoordinator()
        inner_errors: list[BaseException] = []

        def holder_thread():
            with coordinator.lease("llm"):
                try:
                    with coordinator.lease("llm"):
                        pass
                except LeaseReentrancyError as e:
                    inner_errors.append(e)

        t = threading.Thread(target=holder_thread)
        t.start()
        t.join(timeout=2.0)
        assert not t.is_alive(), "holder thread did not finish — outer lease may not have released"
        assert len(inner_errors) == 1

        # A fresh acquisition (different thread) must proceed without hanging.
        acquired = threading.Event()

        def fresh_acquire():
            with coordinator.lease("tts"):
                acquired.set()

        t2 = threading.Thread(target=fresh_acquire)
        t2.start()
        t2.join(timeout=2.0)
        assert acquired.is_set(), "subsequent fresh lease acquisition did not succeed"


# ---------------------------------------------------------------------------
# peak_concurrent_residency counts DISTINCT families, not mark call-depth
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestPeakResidencyCountsDistinctFamilies:
    def test_nested_same_family_marks_do_not_inflate_peak(self):
        """Nested same-family _mark_resident calls within one lease must not push peak to 2.

        Simulates a single held lease whose body calls something that marks
        the same family resident twice before either mark is cleared (e.g. a
        load() followed by a nested run_call()-style helper on the same
        family) — this must still report a peak of 1, since only one
        DISTINCT family was ever resident.
        """
        coordinator = ModelCoordinator()

        with coordinator.lease("llm") as lease:
            coordinator._mark_resident(lease.family)
            try:
                coordinator._mark_resident(lease.family)
                try:
                    pass
                finally:
                    coordinator._mark_not_resident(lease.family)
            finally:
                coordinator._mark_not_resident(lease.family)

        assert coordinator.peak_concurrent_residency == 1

    def test_normal_run_llm_still_reports_peak_of_one(self):
        """Sanity check the distinct-family accounting didn't break the existing happy path."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend()

        coordinator.run_llm(backend, lambda b: b.generate("sys", "user"))

        assert coordinator.peak_concurrent_residency == 1


# ---------------------------------------------------------------------------
# A raising close_fn/unload_fn must not mask the primary exception
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestCloseErrorDoesNotMaskPrimaryException:
    def test_run_llm_close_error_does_not_mask_generate_error(self):
        """If generate_fn raises AND close() also raises, the ORIGINAL (generate) error propagates."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend()

        def failing_close():
            backend.calls.append("close")
            raise RuntimeError("simulated close failure")

        backend.close = failing_close

        def failing_generate(b):
            raise ValueError("simulated generate failure")

        with pytest.raises(ValueError, match="simulated generate failure"):
            coordinator.run_llm(backend, failing_generate)

    def test_run_llm_close_error_does_not_mask_load_error(self):
        """If load() raises AND close() also raises, the ORIGINAL (load) error propagates."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend(raise_on_load=True)

        def failing_close():
            raise RuntimeError("simulated close failure")

        backend.close = failing_close

        with pytest.raises(RuntimeError, match="simulated load failure"):
            coordinator.run_llm(backend, lambda b: b.generate("sys", "user"))

    def test_close_error_propagates_normally_when_no_primary_exception(self):
        """With nothing else failing, a raising close_fn's error IS the one that propagates."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend()

        def failing_close():
            raise RuntimeError("simulated close failure, nothing else failed")

        backend.close = failing_close

        with pytest.raises(RuntimeError, match="simulated close failure, nothing else failed"):
            coordinator.run_llm(backend, lambda b: b.generate("sys", "user"))

    def test_lease_released_after_masked_close_error_so_next_acquisition_works(self):
        """A suppressed close-time error must still release the lease cleanly."""
        coordinator = ModelCoordinator()
        backend = FakeLLMBackend()

        def failing_close():
            raise RuntimeError("simulated close failure")

        backend.close = failing_close

        with pytest.raises(ValueError, match="simulated generate failure"):
            coordinator.run_llm(backend, lambda b: (_ for _ in ()).throw(ValueError("simulated generate failure")))

        # Lease must be free again.
        healthy_backend = FakeLLMBackend()
        result = coordinator.run_llm(healthy_backend, lambda b: b.generate("sys", "user"))
        assert result == ("fake response", 3)


# ---------------------------------------------------------------------------
# Optional RuntimeBootstrap wiring on ModelCoordinator
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestCoordinatorBootstrapWiring:
    def test_lease_raises_require_ready_error_before_bootstrap(self):
        """With a bootstrap attached, lease() enforces require_ready() before acquiring the slot."""
        bootstrap = RuntimeBootstrap()
        coordinator = ModelCoordinator(bootstrap=bootstrap)

        with pytest.raises(RuntimeError, match="has not run yet"):
            with coordinator.lease("llm"):
                pass

    def test_lease_succeeds_after_bootstrap_ready(self):
        """Once the bootstrap has run, lease() proceeds normally."""
        bootstrap = RuntimeBootstrap()
        bootstrap.init_tqdm_lock()
        coordinator = ModelCoordinator(bootstrap=bootstrap)

        with coordinator.lease("llm") as lease:
            assert lease.family == "llm"

    def test_no_bootstrap_attached_behaves_as_before(self):
        """With no bootstrap passed to __init__, lease() works exactly as before (backward compatible)."""
        coordinator = ModelCoordinator()

        with coordinator.lease("llm") as lease:
            assert lease.family == "llm"


# ---------------------------------------------------------------------------
# INV-1: RuntimeBootstrap main-thread tqdm-lock ordering
# ---------------------------------------------------------------------------


@pytest.mark.unit
class TestRuntimeBootstrap:
    def test_init_tqdm_lock_succeeds_on_main_thread(self):
        bootstrap = RuntimeBootstrap()
        assert bootstrap.is_ready is False

        bootstrap.init_tqdm_lock()

        assert bootstrap.is_ready is True

    def test_init_tqdm_lock_rejects_worker_thread(self):
        """Calling init_tqdm_lock() from a worker thread must raise, not silently proceed.

        This is the direct guard against BUG-2: the fix is to never let the
        first tqdm-lock init happen off the main thread.
        """
        bootstrap = RuntimeBootstrap()
        errors: list[Exception] = []

        def worker():
            try:
                bootstrap.init_tqdm_lock()
            except Exception as e:  # noqa: BLE001 - captured for the assertion below
                errors.append(e)

        t = threading.Thread(target=worker, name="test-worker-thread")
        t.start()
        t.join(timeout=5.0)

        assert len(errors) == 1
        assert isinstance(errors[0], RuntimeError)
        assert "main thread" in str(errors[0])
        assert bootstrap.is_ready is False

    def test_require_ready_raises_before_bootstrap(self):
        bootstrap = RuntimeBootstrap()
        with pytest.raises(RuntimeError, match="has not run yet"):
            bootstrap.require_ready()

    def test_require_ready_passes_after_bootstrap(self):
        bootstrap = RuntimeBootstrap()
        bootstrap.init_tqdm_lock()
        bootstrap.require_ready()  # must not raise

    @pytest.mark.integration
    def test_bootstrap_before_worker_ordering_with_fake_model_load(self):
        """End-to-end ordering check: bootstrap on main thread, then a worker
        thread loads a fake model via ModelCoordinator — never re-triggering
        the worker-thread tqdm-init path.

        This exercises the full intended call sequence from cli.py::main()
        (bootstrap → ... → TUI worker loads a model) using a fake backend so
        no real MLX/Metal model is touched, while still proving:
          1. RuntimeBootstrap.init_tqdm_lock() completes on the main thread
             before any worker starts.
          2. A worker thread that calls require_ready() first (mirroring how
             a real model-load path should assert ordering) sees is_ready
             True and never itself calls init_tqdm_lock().
          3. The model load still runs successfully under ModelCoordinator
             from the worker thread, proving worker-thread model loads work
             fine *after* the main-thread bootstrap — the BUG-2 trigger was
             specifically the lock's first-ever init happening off-thread.
        """
        bootstrap = RuntimeBootstrap()
        coordinator = ModelCoordinator()
        events: list[str] = []

        # Step 1: main-thread bootstrap, exactly like cli.py::main() does
        # before starting the Textual app.
        bootstrap.init_tqdm_lock()
        events.append("bootstrap-done")
        assert bootstrap.is_ready is True

        worker_errors: list[Exception] = []

        def worker_loads_model():
            try:
                # A real worker's model-load path should assert readiness
                # before touching a model — this call raises loudly if
                # bootstrap hasn't happened yet (see test above).
                bootstrap.require_ready()
                events.append("worker-checked-ready")

                backend = FakeLLMBackend()
                result = coordinator.run_llm(backend, lambda b: b.generate("sys", "user"))
                events.append("worker-model-loaded")
                assert result == ("fake response", 3)
                assert backend.calls == ["load", "generate", "close"]
            except Exception as e:  # noqa: BLE001 - surfaced via worker_errors
                worker_errors.append(e)

        worker = threading.Thread(target=worker_loads_model, name="fake-textual-worker")
        worker.start()
        worker.join(timeout=5.0)

        assert not worker_errors, f"worker thread raised: {worker_errors}"
        assert events == ["bootstrap-done", "worker-checked-ready", "worker-model-loaded"]
