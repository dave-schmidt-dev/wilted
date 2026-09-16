"""ModelCoordinator — the single named lease for in-process ML work.

This module serializes Wilted-process LLM and transcription work. Speech
synthesis is resident in the separate speech daemon and does not hold this
lease. It exists to enforce two hard-won
invariants (see ``INVARIANTS.md``):

INV-1 — Remaining in-process MLX/Metal LLM work is serialized by this lease,
    and the tqdm
    multiprocessing lock is initialized on the MAIN thread before any
    Textual worker thread touches a model. The first tqdm-lock init inside
    a Textual worker thread spawns Python's ``resource_tracker`` with a bad
    fd set and crashes the process (BUG-2). :class:`RuntimeBootstrap` is the
    main-thread-only fix; :class:`ModelCoordinator` is the runtime lock that
    keeps GPU access serialized for the life of the process.

INV-2 — At most ONE ML model is resident at a time, and every load is
    paired with a close/reclaim that runs even when the load itself raised
    (try/finally). :class:`ModelCoordinator` enforces this by handing out a
    single named lease: acquiring it while it is held BLOCKS (waits for the
    slot) rather than co-loading a second model family.

Residency note (measured on M5 Max, 2026-07-10): the in-process LLM backend's
Metal allocator pool returns to baseline after ``close()``. The transcribe
family is a legacy daemon-request lease user, not a Wilted-process model
resident. The GGUF LLM backend (llama.cpp via ``llama-cpp-python``) retains
~5.4 GB of *process RSS* after ``close()`` that is not reclaimed — this is a
separate (non-Metal) allocator's residency, not a violation of "Metal
memory is reclaimed on close."

Usage:
    from wilted.station_runtime.coordinator import ModelCoordinator

    coordinator = ModelCoordinator()

    with coordinator.lease("llm") as lease:
        backend = create_backend("gguf", model="...")
        lease.load(backend.load)
        response, tokens = backend.generate(system_prompt, user_content)
        lease.close(backend.close)
"""

from __future__ import annotations

import logging
import sys
import threading
from contextlib import contextmanager
from typing import TYPE_CHECKING, TypeVar

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator

    from wilted.llm import LLMBackend

logger = logging.getLogger(__name__)

T = TypeVar("T")


def _run_close_without_masking(close_fn: Callable[[], None] | None) -> None:
    """Run ``close_fn``, logging (not raising) if it errors during unwind.

    If a primary exception is already propagating (``sys.exc_info()`` is
    non-empty) when this runs — i.e. it is being called from a ``finally``
    block after the guarded body raised — a raising ``close_fn`` must not
    replace that original exception with its own. The close/unload error is
    logged instead and swallowed, so the caller still sees the primary
    failure (e.g. the model's ``load()``/``generate()`` error), not an
    unrelated close-time error masking it.

    When there is no primary exception in flight, ``close_fn``'s error is
    allowed to propagate normally — a close failure is real information the
    caller should see when nothing else already failed.
    """
    if close_fn is None:
        return
    if sys.exc_info()[0] is not None:
        try:
            close_fn()
        except Exception:  # noqa: BLE001 - deliberately broad: never mask the primary exception
            logger.exception("close/unload raised while another exception was already propagating; suppressing it")
    else:
        close_fn()


# The two model families that ModelCoordinator arbitrates. Kept as a
# closed set (not a free-form string) so a typo in a family name fails
# loudly instead of silently bypassing the lease accounting.
_VALID_FAMILIES = frozenset({"llm", "transcribe"})


class LeaseHeldElsewhereError(RuntimeError):
    """Raised if internal bookkeeping ever finds the lease double-acquired.

    This should be unreachable in practice — the underlying ``threading.Lock``
    already prevents a second acquisition from proceeding. It exists as a
    defensive assertion so a bug in this module fails loudly (INV-2) rather
    than silently permitting two models to be resident at once.
    """


class LeaseReentrancyError(RuntimeError):
    """Raised when a thread that already holds the lease calls ``lease()`` again.

    ``ModelCoordinator``'s lock is a non-reentrant ``threading.Lock`` on
    purpose: leases must never nest. If a thread holding a lease for one
    family needs another family (or the same family again), it must release
    its current lease first — nesting would either deadlock (the same
    non-reentrant lock blocking against itself forever) or, if the lock were
    swapped for an ``RLock`` to avoid that, silently permit two families to
    be "resident" under one thread at once, defeating INV-2. This error
    makes the forbidden nesting fail immediately and loudly instead of
    hanging.
    """


class ModelLease:
    """A held slot in the single ML lease, scoped to one model family.

    Returned by :meth:`ModelCoordinator.lease` as a context-manager value.
    Callers use :meth:`load` to run a model's load callable under the lease
    and :meth:`close` to release it — both are optional convenience
    wrappers; the lease itself is already acquired by the time the caller
    gets a `ModelLease` instance, and already released once the `with`
    block exits (see :meth:`ModelCoordinator.lease`).
    """

    def __init__(self, family: str, coordinator: ModelCoordinator) -> None:
        self.family = family
        self._coordinator = coordinator

    def load(self, load_fn: Callable[[], T]) -> T:
        """Run ``load_fn`` (e.g. ``backend.load``) under the lease.

        Marks this family as resident for the duration of the call so
        concurrent-residency assertions in tests can observe it. Does NOT
        catch exceptions — a raising ``load_fn`` propagates to the caller,
        which is expected to still reach the ``finally``-guarded
        :meth:`close` (see :meth:`ModelCoordinator.lease`'s docstring and
        ``tests/test_coordinator.py::test_close_runs_on_load_exception``).
        """
        self._coordinator._mark_resident(self.family)
        try:
            return load_fn()
        finally:
            # Residency during the *load call itself* is what matters for the
            # one-at-a-time assertion; loaded-but-not-yet-closed state is
            # still tracked by lease/slot ownership, not this flag.
            self._coordinator._mark_not_resident(self.family)

    def close(self, close_fn: Callable[[], None] | None) -> None:
        """Run ``close_fn`` if provided.

        Safe to call with ``close_fn=None`` for callers that have nothing to
        close in the Wilted process (for example, daemon-backed transcription).

        If ``close_fn`` raises while another exception is already
        propagating (i.e. this is being called from a ``finally`` after the
        guarded body failed), the close error is logged and suppressed
        rather than replacing the original exception — see
        :func:`_run_close_without_masking`. With no exception in flight, a
        raising ``close_fn`` propagates normally.
        """
        _run_close_without_masking(close_fn)

    def run_call(self, call_fn: Callable[[], T]) -> T:
        """Run a bare call (e.g. ``transcribe_audio(...)``) under the lease.

        Daemon-backed families have no Wilted-process model handle. This legacy
        wrapper serializes request initiation with the LLM lease; it does not
        represent model residency in the Wilted process.
        """
        self._coordinator._mark_resident(self.family)
        try:
            return call_fn()
        finally:
            self._coordinator._mark_not_resident(self.family)


class ModelCoordinator:
    """The single named ML lease shared by the LLM and transcribe families.

    At most one family may hold the lease (and therefore be "resident") at a
    time. A second call to :meth:`lease` blocks until the first is released
    — never co-loads. Wraps two call shapes:

    - LLM: ``create_backend(...).load()`` / ``.generate()`` / ``.close()``.
    - Transcribe: ``transcribe_audio(...)`` is a flat function with no
      persistent handle, so it is serialized via :meth:`ModelLease.run_call`
      rather than load/close.
    """

    def __init__(self, bootstrap: RuntimeBootstrap | None = None) -> None:
        self._lock = threading.Lock()
        self._bootstrap = bootstrap
        # Owning thread id of the current lease holder, used to detect
        # same-thread re-entry (see LeaseReentrancyError) before the thread
        # would otherwise block forever on its own non-reentrant lock.
        self._owner_lock = threading.Lock()
        self._owner_thread_id: int | None = None
        self._resident_lock = threading.Lock()
        # Currently-resident family names, guarded by _resident_lock. Using a
        # set (rather than a depth counter) means nested same-family marks
        # from one held lease do not inflate the peak — peak_concurrent_
        # residency measures the true INV-2 quantity: distinct families
        # simultaneously resident, not mark call-depth.
        self._resident_families: set[str] = set()
        self._peak_concurrent_residency = 0

    @contextmanager
    def lease(self, family: str) -> Iterator[ModelLease]:
        """Acquire the single ML lease for ``family``, blocking until free.

        Args:
            family: One of ``"llm"`` or ``"transcribe"``.

        Yields:
            A :class:`ModelLease` bound to this family. The lease is held
            for the duration of the ``with`` block; a second thread calling
            :meth:`lease` (for any family, including the same one) blocks on
            entry until this block exits — it never runs concurrently.

        Raises:
            ValueError: If ``family`` is not a recognized model family.
            LeaseReentrancyError: If the calling thread already holds this
                lease (directly or for another family) — nesting is
                forbidden, so this raises immediately instead of the thread
                deadlocking against its own non-reentrant lock.
        """
        if family not in _VALID_FAMILIES:
            raise ValueError(f"Unknown model family: '{family}'. Use one of {sorted(_VALID_FAMILIES)}.")

        if self._bootstrap is not None:
            self._bootstrap.require_ready()

        current_thread_id = threading.get_ident()
        with self._owner_lock:
            if self._owner_thread_id == current_thread_id:
                raise LeaseReentrancyError(
                    f"Thread {current_thread_id} already holds the ML lease and attempted to "
                    f"acquire it again for family='{family}'. Leases must never nest: if one "
                    "family needs another, release the current lease (exit its `with` block) "
                    "first."
                )

        logger.debug("Acquiring ML lease for family=%s", family)
        with self._lock:
            with self._owner_lock:
                self._owner_thread_id = current_thread_id
            logger.debug("ML lease acquired for family=%s", family)
            try:
                yield ModelLease(family, self)
            finally:
                with self._owner_lock:
                    self._owner_thread_id = None
                logger.debug("ML lease released for family=%s", family)

    def _mark_resident(self, family: str) -> None:
        with self._resident_lock:
            other_families = self._resident_families - {family}
            if other_families:
                # Unreachable under correct use — the outer threading.Lock in
                # lease() already serializes callers — but assert loudly
                # rather than silently tolerate two families "resident".
                raise LeaseHeldElsewhereError(
                    f"INV-2 violation: '{family}' marked resident while {sorted(other_families)} is still resident."
                )
            self._resident_families.add(family)
            self._peak_concurrent_residency = max(self._peak_concurrent_residency, len(self._resident_families))

    def _mark_not_resident(self, family: str) -> None:
        with self._resident_lock:
            # discard() is idempotent — marking a family not-resident that
            # isn't currently in the set (e.g. nested same-family marks
            # unwinding) is a no-op, never an underflow.
            self._resident_families.discard(family)

    @property
    def peak_concurrent_residency(self) -> int:
        """Highest number of DISTINCT families simultaneously marked resident.

        Should never exceed 1 across the life of the coordinator; tests
        assert this directly to gate INV-2. Counts distinct resident family
        names, not mark call-depth — nested same-family marks from a single
        held lease do not inflate this value.
        """
        return self._peak_concurrent_residency

    def close(self) -> None:
        """Release runner-owned coordinator resources at end of a bounded run.

        Stub handlers in Task 4.1 do not load models; this hook exists so the
        pipeline runner can pair one construction with one close on every exit
        path before Task 5.1 wires real handler lifecycles.
        """
        logger.debug("ModelCoordinator closed")

    # ------------------------------------------------------------------
    # Convenience wrappers for the two concrete families. These are thin
    # sugar over `lease()` + `ModelLease` — callers may also use `lease()`
    # directly if they need finer control (e.g. multiple generate() calls
    # between load and close).
    # ------------------------------------------------------------------

    def run_llm(
        self,
        backend: LLMBackend,
        generate_fn: Callable[[LLMBackend], T],
    ) -> T:
        """Load ``backend``, run ``generate_fn(backend)``, always close.

        Mirrors ``llm.py``'s documented lifecycle (load once, generate many,
        close once) but guarantees ``close()`` runs even if ``load()``
        raises (INV-2) by using try/finally rather than relying on the
        caller.

        Args:
            backend: An object satisfying :class:`wilted.llm.LLMBackend`
                (``load``/``generate``/``close``).
            generate_fn: Callable invoked with ``backend`` after a
                successful load, e.g. ``lambda b: b.generate(sys, user)``.

        Returns:
            Whatever ``generate_fn`` returns.
        """
        with self.lease("llm") as lease:
            try:
                lease.load(backend.load)
                return generate_fn(backend)
            finally:
                lease.close(backend.close)

    def run_transcribe(self, call_fn: Callable[[], T]) -> T:
        """Serialize a transcribe call (e.g. ``transcribe_audio(...)``) under the lease.

        Transcription is daemon-backed and has no Wilted-process load/close
        handle, so there is nothing to close here. This legacy wrapper only
        serializes request initiation with the LLM lease.

        Args:
            call_fn: Zero-arg callable, e.g.
                ``lambda: transcribe_audio(audio_path)``.

        Returns:
            Whatever ``call_fn`` returns.
        """
        with self.lease("transcribe") as lease:
            return lease.run_call(call_fn)


class RuntimeBootstrap:
    """Main-thread-only process bootstrap that guards INV-1's tqdm ordering.

    Mirrors the pre-init already done in ``cli.py::main()`` (see
    ``src/wilted/cli.py`` — "Pre-initialize tqdm's multiprocessing lock on
    the main thread"): the first time ``tqdm.tqdm.get_lock()`` runs, it may
    initialize a multiprocessing lock whose setup can spawn Python's
    ``resource_tracker``. If that first init happens inside a Textual
    ``@work(thread=True)`` worker instead of the main thread, the
    resource_tracker subprocess can be spawned with a bad fd set and crash
    the process (BUG-2).

    This class gives that fix a single, named, testable entry point instead
    of a bare inline snippet in ``main()``, so any future call site (tests,
    a future non-CLI entry point) can bootstrap the same way and assert it
    ran on the main thread before any worker touches a model.

    Usage (mirrors ``cli.py::main()``'s existing ordering):
        bootstrap = RuntimeBootstrap()
        bootstrap.init_tqdm_lock()   # MUST run on the main thread
        # ... only after this point may Textual workers load models ...
        WiltedApp().run()
    """

    def __init__(self) -> None:
        self._tqdm_lock_initialized = False

    def init_tqdm_lock(self) -> None:
        """Initialize tqdm's multiprocessing lock. MUST be called from the main thread.

        Raises:
            RuntimeError: If called from any thread other than the main
                thread — calling this from a worker thread is exactly the
                BUG-2 scenario this class exists to prevent, so it fails
                loudly rather than silently risking the resource_tracker
                fds_to_keep crash.
        """
        current = threading.current_thread()
        if current is not threading.main_thread():
            raise RuntimeError(
                "RuntimeBootstrap.init_tqdm_lock() must run on the main thread "
                f"(called from {current.name!r}). Initializing tqdm's "
                "multiprocessing lock from a worker thread risks spawning "
                "resource_tracker with a bad fd set (BUG-2)."
            )

        import tqdm

        tqdm.tqdm.get_lock()
        self._tqdm_lock_initialized = True
        logger.debug("tqdm multiprocessing lock initialized on main thread (%s)", current.name)

    @property
    def is_ready(self) -> bool:
        """True once :meth:`init_tqdm_lock` has completed on the main thread."""
        return self._tqdm_lock_initialized

    def require_ready(self) -> None:
        """Raise if the bootstrap has not yet run.

        Intended for a worker's model-load path to assert ordering: call
        this before any model ``load()`` so a missing/late bootstrap call
        fails loudly instead of risking BUG-2 silently.

        Raises:
            RuntimeError: If :meth:`init_tqdm_lock` has not completed yet.
        """
        if not self._tqdm_lock_initialized:
            raise RuntimeError(
                "RuntimeBootstrap.init_tqdm_lock() has not run yet. It must "
                "complete on the main thread before any worker thread loads "
                "a model (INV-1 / BUG-2)."
            )
