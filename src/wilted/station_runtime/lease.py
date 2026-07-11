"""``ControllerLeaseManager`` — OS-level mutual exclusion for the station controller.

The reducer (``wilted.station.reducer.claim_lease``) and the store
(``wilted.station_runtime.store.JsonStationStore``) already implement the
*pure* fencing-token logic and durable persistence for a
:class:`~wilted.station.models.ControllerLease`: given a candidate epoch,
``claim_lease`` decides whether the claim strictly advances ownership, and
the store durably records the winning lease. Neither of those pieces knows
anything about *processes* — they are pure/CAS-retried data operations, not
OS-level arbitration.

This module is the glue above both: it adds the OS-level primitive needed so
that exactly one *live* ``StationController`` process can hold the writer
lease at a time, and a crashed (or rebooted-away) holder's lease becomes
reclaimable immediately, with no clock involved.

Mechanism:

- **Mutual exclusion + liveness, in one primitive**: ``acquire()`` opens (or
  creates) ``wilted.DATA_DIR / "station" / "controller.lock"`` and attempts
  ``fcntl.flock(fd, LOCK_EX | LOCK_NB)``. The OS guarantees at most one
  process can hold that exclusive lock at a time, and — critically —
  guarantees the lock is released automatically the instant the holding
  process dies for *any* reason: a clean exit, a crash, ``SIGKILL``, or the
  machine rebooting out from under it. There is no heartbeat TTL, no stored
  clock reading, and therefore no clock-domain mismatch to reason about: a
  successful ``flock`` acquire is *itself* the proof that any prior holder
  is dead, because a live holder's flock cannot have been released any other
  way. This closes the "reboot wedge" failure mode where a monotonic-clock
  heartbeat persisted across a reboot could read as arbitrarily fresh (or
  even land at a large negative age) and never expire.
- **Held for the lease's lifetime**: unlike a create-once lockfile, the fd
  and its flock are kept open on the manager for as long as the lease is
  held, and released (``LOCK_UN`` + close) only in :meth:`release`. This is
  what makes "flock succeeded" equivalent to "I am the sole owner" for the
  entire lease lifetime, not just at acquire time.
- **Heartbeat is wall-clock, observability-only**: the holder still writes a
  small JSON heartbeat record (holder_id, epoch, wall-clock ISO-Z timestamp)
  on an interval, refreshed by a background daemon thread, for
  humans/monitoring to see who holds the lease and how recently it checked
  in. Liveness/mutual-exclusion no longer depends on this record's
  freshness — it is not consulted by ``acquire()`` at all. A negative age
  (clock ran backwards) is always treated as stale/untrustworthy, never as
  "fresh", in any code path that still inspects heartbeat age.
- **Epoch fencing**: delegates entirely to ``wilted.station.reducer.claim_lease``
  for the accept/reject decision — this module never re-implements or
  second-guesses that logic. Once flock is held, exactly one process can be
  attempting a claim at a time, so the epoch handed to ``claim_lease`` is
  computed and persisted without a concurrent-writer race. The claimed state
  (lease included) is written with a *single* ``persist_state`` call — there
  is no separate ``persist_lease`` call, which would otherwise let two racing
  writers each observe their own CAS as having "succeeded" against a base
  revision that only one of them should have been allowed to advance from.

INV-5: ``wilted.DATA_DIR`` is resolved by attribute access on the ``wilted``
module at *call time*, in every method that needs a path — never imported as
a bare name at module scope — so a test (or caller) that monkeypatches
``wilted.DATA_DIR`` is respected for every operation, including ones from a
manager instance constructed before the monkeypatch.
"""

from __future__ import annotations

import dataclasses
import errno
import fcntl
import json
import logging
import os
import threading
from datetime import UTC, datetime
from typing import TYPE_CHECKING

import wilted
from wilted.station.models import now_utc_z
from wilted.station.reducer import StationState, claim_lease
from wilted.station_runtime.store import JsonStationStore

if TYPE_CHECKING:
    from pathlib import Path

    from wilted.station.models import ControllerLease

_WALL_CLOCK_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
"""Matches ``wilted.station.models.now_utc_z``'s format exactly."""

logger = logging.getLogger(__name__)

_LOCKFILE_NAME = "controller.lock"


def _resolve_lockfile_path(data_dir: Path | None = None) -> Path:
    """Resolve the controller lockfile path under ``data_dir``.

    This is the SINGLE place the lockfile path is computed from a data
    directory root; :meth:`ControllerLeaseManager._lockfile_path` and
    :func:`is_station_active` both delegate to this so there is never a
    second, divergent path computation to keep in sync.

    INV-5: when ``data_dir`` is omitted, ``wilted.DATA_DIR`` is read here, at
    call time -- never cached -- so a caller/test that monkeypatches
    ``wilted.DATA_DIR`` between calls (e.g. the ``isolated_data`` fixture) is
    respected on every call, including ones made before the monkeypatch was
    applied.
    """
    base = data_dir if data_dir is not None else wilted.DATA_DIR
    return base / "station" / _LOCKFILE_NAME


def _probe_flock_would_block(path: Path) -> bool:
    """Return True iff a non-blocking exclusive flock on ``path`` would block.

    This is the single shared flock-contention probe used by both
    :meth:`ControllerLeaseManager.is_lease_live` and :func:`is_station_active`:
    it opens ``path``, attempts
    ``fcntl.flock(fd, LOCK_EX | LOCK_NB)`` purely to test contention, then
    immediately releases and closes its OWN probe fd before returning -- it
    never holds the lock itself, never touches any caller's fd, and never
    mutates the file's contents. If ``path`` does not exist yet, returns
    False without creating anything (no holder has ever acquired the lease).
    """
    if not path.exists():
        return False
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
            return True
        raise
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


DEFAULT_HEARTBEAT_INTERVAL_SECONDS = 3.0
"""Default interval between heartbeat refreshes while a lease is held.

The heartbeat record is observability-only (see module docstring) — nothing
in ``acquire()``/``release()`` reads it to decide liveness. It exists so a
human or monitoring tool can see who holds the lease and how recently it
last checked in.
"""

DEFAULT_TTL_SECONDS = 15.0
"""Default heartbeat-staleness threshold used only by observability/diagnostic
call sites (e.g. :meth:`_Heartbeat.is_stale`) -- it plays no role in
``acquire()``'s mutual-exclusion decision, which is flock-only and has no
TTL at all (see module docstring)."""


class LeaseHeldError(RuntimeError):
    """Raised by :meth:`ControllerLeaseManager.acquire` when a LIVE holder exists.

    ``flock(LOCK_EX | LOCK_NB)`` failing with ``EWOULDBLOCK``/``EAGAIN``
    means another process currently holds the exclusive lock on the
    lockfile — and since the OS only releases a held flock when its owning
    process dies (cleanly or otherwise) or explicitly unlocks it, a held
    flock is proof of a genuinely live holder right now. This manager never
    steals a live lease. The caller should back off and retry later, or
    exit, rather than attempt to force acquisition.
    """


@dataclasses.dataclass(frozen=True, slots=True)
class _Heartbeat:
    """On-disk heartbeat record for the current lockfile holder (observability only)."""

    holder_id: str
    epoch: int
    last_beat_wall_clock: str
    """A wall-clock ISO-8601 ``Z``-suffixed timestamp (see ``now_utc_z()``)
    captured by the writer.

    This is informational only: mutual exclusion and liveness are entirely
    provided by the ``flock`` held for the lease's lifetime (see module
    docstring), never by comparing this timestamp against a TTL. Wall clock
    is used instead of ``time.monotonic()`` because monotonic's reference
    point is undefined across process restarts and resets across a reboot,
    which previously made a persisted monotonic reading meaningless (and
    even nonsensically "fresh") once read back by a different process epoch
    or after a reboot.
    """

    def age_seconds(self, *, now_wall_clock: float) -> float:
        """Seconds between this heartbeat and ``now_wall_clock`` (a ``time.time()`` reading).

        A negative result means the recorded timestamp is in the future
        relative to ``now_wall_clock`` — e.g. the clock stepped backwards,
        or a stale/foreign record was read. Callers must never treat a
        negative age as "fresh"; see :meth:`is_stale`.
        """
        recorded = datetime.strptime(self.last_beat_wall_clock, _WALL_CLOCK_FORMAT).replace(tzinfo=UTC).timestamp()
        return now_wall_clock - recorded

    def is_stale(self, *, ttl_seconds: float, now_wall_clock: float) -> bool:
        """True if this heartbeat is older than ``ttl_seconds``, OR its age is negative.

        A negative age (clock ran backwards, e.g. NTP step or a persisted
        record read back across a reboot) is never "fresh" — it is always
        treated as stale/untrustworthy here, even though this manager's
        ``acquire()``/``release()`` no longer consult staleness for
        mutual-exclusion purposes (see module docstring; this method is kept
        for observability/diagnostics call sites such as :meth:`is_lease_live`).
        """
        age = self.age_seconds(now_wall_clock=now_wall_clock)
        return age < 0 or age > ttl_seconds

    def to_json_dict(self) -> dict:
        return {
            "holder_id": self.holder_id,
            "epoch": self.epoch,
            "last_beat_wall_clock": self.last_beat_wall_clock,
        }

    @classmethod
    def from_json_dict(cls, d: dict) -> _Heartbeat:
        return cls(
            holder_id=d["holder_id"],
            epoch=d["epoch"],
            last_beat_wall_clock=d["last_beat_wall_clock"],
        )


class ControllerLeaseManager:
    """OS-level mutual exclusion + liveness on top of the reducer/store.

    One instance is meant to be owned by one ``StationController`` process.
    It does not itself run the controller — it only answers "am I allowed
    to be the writer right now" and keeps an observability heartbeat alive
    for as long as it holds that answer.

    Mutual exclusion and liveness are both provided by an OS ``flock`` held
    for the entire lifetime of the lease (see module docstring for why this
    is the authoritative mechanism, not a heartbeat TTL):

    Usage::

        manager = ControllerLeaseManager(holder_id="mac-controller-pid123")
        lease = manager.acquire()  # raises LeaseHeldError if another is live
        try:
            ...  # run the controller, using `lease` as apply()'s requester_lease
        finally:
            manager.release()
    """

    def __init__(
        self,
        holder_id: str,
        *,
        store: JsonStationStore | None = None,
        ttl_seconds: float = DEFAULT_TTL_SECONDS,
        heartbeat_interval_seconds: float = DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
    ) -> None:
        if not holder_id:
            raise ValueError("ControllerLeaseManager.holder_id must be non-empty")
        if ttl_seconds <= 0:
            raise ValueError(f"ttl_seconds must be > 0, got {ttl_seconds}")
        if heartbeat_interval_seconds <= 0:
            raise ValueError(f"heartbeat_interval_seconds must be > 0, got {heartbeat_interval_seconds}")

        self.holder_id = holder_id
        self._store = store if store is not None else JsonStationStore()
        # ttl_seconds is retained only for `is_lease_live`'s observability
        # judgment (see its docstring) -- it plays no role in acquire()'s
        # mutual-exclusion decision, which is flock-only.
        self._ttl_seconds = ttl_seconds
        self._heartbeat_interval_seconds = heartbeat_interval_seconds

        # Serializes acquire/release attempts made through *this* manager
        # instance. The flock is the cross-process primitive; this lock
        # additionally makes multi-threaded use of a single manager instance
        # well-defined (not part of the spec, but cheap correctness
        # insurance).
        self._acquire_lock = threading.Lock()

        self._held_epoch: int | None = None
        self._lock_fd: int | None = None
        self._heartbeat_stop: threading.Event | None = None
        self._heartbeat_thread: threading.Thread | None = None

    # ------------------------------------------------------------------
    # Path helpers (INV-5: resolve wilted.DATA_DIR at call time)
    # ------------------------------------------------------------------

    def _lockfile_path(self) -> Path:
        return _resolve_lockfile_path()

    # ------------------------------------------------------------------
    # Heartbeat file I/O (observability only -- see module docstring)
    # ------------------------------------------------------------------

    def _write_heartbeat(self, heartbeat: _Heartbeat) -> None:
        """Write ``heartbeat`` IN PLACE to the already-locked lockfile fd.

        Deliberately does NOT use the tempfile-plus-``os.replace`` atomic
        write pattern used elsewhere in this codebase (e.g.
        ``JsonStationStore._write_doc``): ``os.replace`` swaps in a *new
        inode* at the path, which would silently detach the ``flock`` held
        by :attr:`_lock_fd` from the file that future ``open()`` calls on
        that path would see -- any new opener (a competing ``acquire()``, or
        ``is_lease_live()``) would then acquire a lock on the fresh inode
        and see no contention at all, defeating mutual exclusion the moment
        the first heartbeat was written. Writing in place (truncate + seek +
        write on the *same* fd/inode the lock is held on) keeps the lock and
        the file identity intact for the entire time the lease is held.

        A torn/partial write here (process dies mid-write) is not a
        correctness hazard: the flock itself is still held (or, if the
        process really died, released) independent of the heartbeat
        content, and the heartbeat is observability-only (see module
        docstring) -- :meth:`_read_heartbeat` treats unparseable content as
        "no heartbeat" rather than trying to recover it.
        """
        payload = json.dumps(heartbeat.to_json_dict()).encode("utf-8")
        os.lseek(self._lock_fd, 0, os.SEEK_SET)
        os.ftruncate(self._lock_fd, 0)
        os.write(self._lock_fd, payload)
        os.fsync(self._lock_fd)

    def _read_heartbeat(self) -> _Heartbeat | None:
        """Read the current on-disk heartbeat, or None if no lockfile exists.

        A lockfile that exists but is unreadable/corrupt (e.g. a torn write
        from a process that crashed mid-write, which ``os.replace`` should
        prevent, but defense in depth costs little) is treated the same as
        absent -- for observability purposes only, since a missing/corrupt
        heartbeat record no longer affects acquire()'s mutual-exclusion
        decision.
        """
        path = self._lockfile_path()
        if not path.exists():
            return None
        try:
            with path.open() as f:
                doc = json.load(f)
            return _Heartbeat.from_json_dict(doc)
        except (json.JSONDecodeError, KeyError, TypeError, OSError):
            logger.warning("Lockfile at %s is unreadable/corrupt; treating as no heartbeat.", path)
            return None

    # ------------------------------------------------------------------
    # Acquire / release
    # ------------------------------------------------------------------

    def acquire(self) -> ControllerLease:
        """Attempt to become the live writer, reusing the reducer/store for fencing.

        Opens (creating if absent) the lockfile and attempts
        ``fcntl.flock(fd, LOCK_EX | LOCK_NB)``:

        - If the flock succeeds, this process is the sole live holder --
          any prior holder is necessarily dead (crashed, killed, or the
          machine rebooted), because the OS only releases a held flock when
          its owning process goes away. This claims the next epoch
          (``store.current_lease().epoch + 1``, or ``1`` if there is no
          current lease), advances the reducer state via ``claim_lease``,
          persists the *entire* new state (lease included) via a single
          ``persist_state`` call, writes an observability heartbeat, starts
          the background heartbeat thread, and returns the new lease. The
          flock is held on this manager for the lease's entire lifetime --
          it is only released in :meth:`release`.
        - If the flock fails with ``EWOULDBLOCK``/``EAGAIN`` (raised by
          Python as ``BlockingIOError``, a subclass of ``OSError``), a live
          holder already exists: raises :class:`LeaseHeldError`.

        Raises:
            LeaseHeldError: A live holder already exists (flock is held by
                another process), or the epoch-fencing / CAS persistence
                step lost a race to a concurrent writer that is not going
                through this same flock (which should not happen in normal
                operation, but is surfaced rather than silently ignored).
        """
        with self._acquire_lock:
            path = self._lockfile_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            # 0o600: the lockfile is a private per-user control file (holds
            # only an observability heartbeat). Pin its mode rather than
            # inheriting whatever the process umask happens to be.
            fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                os.close(fd)
                if exc.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                    raise LeaseHeldError(
                        f"Controller lease lockfile at {path} is held by a live process; "
                        "refusing to steal a live lease."
                    ) from exc
                raise

            # From here on, this process holds the exclusive flock. Any
            # prior holder is dead. Set _lock_fd now (rather than only on
            # success) so _write_heartbeat below -- which writes in place to
            # this fd, see its docstring for why -- has it available; roll
            # both back on any failure so a failed acquire() never leaves a
            # dangling held flock or a stale _lock_fd.
            self._lock_fd = fd
            try:
                # Single read: derive the next epoch from the SAME state
                # snapshot used for the claim and the CAS below. Because we
                # hold the flock we are the sole writer, so a second read
                # could not observe a different lease — but reading once makes
                # that self-evident rather than something a reader has to
                # reason about, and eliminates the read-current / read-base
                # window entirely.
                state = self._store.load_state()
                base_state = state if state is not None else StationState()
                current_lease = base_state.lease
                new_epoch = 1 if current_lease is None else current_lease.epoch + 1
                new_state = claim_lease(base_state, holder_id=self.holder_id, epoch=new_epoch)

                # claim_lease only rejects when epoch <= current lease epoch,
                # which cannot happen here since new_epoch is derived as
                # current_lease.epoch + 1 while we are the sole flock
                # holder -- a mismatch would indicate a genuine concurrent
                # writer bypassing this manager entirely, which is outside
                # this module's scope.
                new_lease = new_state.lease
                if new_lease is None or not new_lease.matches(self.holder_id, new_epoch):
                    raise LeaseHeldError(
                        f"claim_lease rejected epoch {new_epoch} for holder {self.holder_id!r}; "
                        "the on-disk lease was advanced by another writer concurrently."
                    )

                # claim_lease() (in reducer.py, which this module must not
                # modify) only replaces `.lease` -- it deliberately never
                # touches `station_revision`, since epoch fencing and
                # logical station revisions are separate concerns owned by
                # separate call sites. A lease takeover is still a real,
                # monotonic state transition, so this manager bumps
                # station_revision itself, once, right here -- this is the
                # ONLY place a takeover advances it, replacing the old
                # design's separate `persist_lease` call (itself a CAS
                # retry loop) that used to double-bump revision per
                # takeover and helped mask the split-brain race.
                new_state = dataclasses.replace(new_state, station_revision=base_state.station_revision + 1)

                # Single consistent write: persist_state writes the FULL
                # state, including the lease and the bumped revision, so
                # both advance together in one CAS instead of two separate
                # writes (which previously let two racing claims each
                # believe they'd won).
                if not self._store.persist_state(new_state, expected_revision=base_state.station_revision):
                    raise LeaseHeldError("Lost a concurrent compare-and-set race while persisting the claimed lease.")

                heartbeat = _Heartbeat(holder_id=self.holder_id, epoch=new_epoch, last_beat_wall_clock=now_utc_z())
                self._write_heartbeat(heartbeat)
            except BaseException:
                self._lock_fd = None
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)
                raise

            self._held_epoch = new_epoch
            self._start_heartbeat_thread()

            logger.info("Controller lease acquired by %r at epoch %d", self.holder_id, new_epoch)
            return new_lease

    def release(self) -> None:
        """Cleanly release a held lease: stop the heartbeat thread, unlock and close the fd.

        Safe to call even if this manager never successfully acquired the
        lease (a no-op in that case). After this returns, the flock is
        released and the next acquirer sees no live holder.
        """
        self._stop_heartbeat_thread()
        if self._lock_fd is not None:
            fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            os.close(self._lock_fd)
            logger.info("Controller lease released by %r (epoch %s)", self.holder_id, self._held_epoch)
        self._lock_fd = None
        self._held_epoch = None

    # ------------------------------------------------------------------
    # Background heartbeat thread (observability only)
    # ------------------------------------------------------------------

    def _start_heartbeat_thread(self) -> None:
        self._stop_heartbeat_thread()  # defensive: never leak a prior thread
        stop_event = threading.Event()
        self._heartbeat_stop = stop_event

        def _run() -> None:
            while not stop_event.wait(self._heartbeat_interval_seconds):
                epoch = self._held_epoch
                if epoch is None:
                    return
                heartbeat = _Heartbeat(holder_id=self.holder_id, epoch=epoch, last_beat_wall_clock=now_utc_z())
                try:
                    self._write_heartbeat(heartbeat)
                except OSError:
                    logger.exception("Failed to refresh controller lease heartbeat for %r", self.holder_id)

        thread = threading.Thread(target=_run, name=f"controller-lease-heartbeat-{self.holder_id}", daemon=True)
        self._heartbeat_thread = thread
        thread.start()

    def _stop_heartbeat_thread(self) -> None:
        if self._heartbeat_stop is not None:
            self._heartbeat_stop.set()
        if self._heartbeat_thread is not None:
            self._heartbeat_thread.join(timeout=5.0)
        self._heartbeat_stop = None
        self._heartbeat_thread = None

    # ------------------------------------------------------------------
    # Introspection helpers (used by tests / diagnostics)
    # ------------------------------------------------------------------

    @property
    def held_epoch(self) -> int | None:
        """The epoch this manager currently believes it holds, or None."""
        return self._held_epoch

    def is_lease_live(self) -> bool:
        """Return True iff another process currently holds the lockfile's flock.

        This is the authoritative liveness check (mirrors what ``acquire()``
        itself relies on): it attempts a non-blocking ``flock`` on its own
        *separate* fd for the lockfile. If that attempt would block, some
        other process holds the lock right now. If it succeeds, no one
        holds it -- this method immediately releases and closes its probe
        fd without disturbing anything (it never holds the lock itself, and
        never touches ``self._lock_fd``).

        Deliberately does not consult heartbeat freshness/TTL -- a stale
        heartbeat record proves nothing about liveness now that mutual
        exclusion is flock-based (see module docstring).
        """
        return _probe_flock_would_block(self._lockfile_path())


def is_station_active(*, data_dir: Path | None = None) -> bool:
    """Read-only flock probe: does a LIVE controller currently hold the writer lease?

    Unlike :meth:`ControllerLeaseManager.is_lease_live`, this is a free
    function that needs no ``holder_id`` and no
    :class:`~wilted.station_runtime.store.JsonStationStore` -- callers (e.g.
    the CLI) that just want a yes/no answer before deciding whether to
    proceed do not need to construct a manager to get one. It shares the
    exact same lockfile-path resolution (:func:`_resolve_lockfile_path`) and
    the exact same flock-contention probe (:func:`_probe_flock_would_block`)
    that :meth:`ControllerLeaseManager.acquire`/``is_lease_live`` use, so
    there is only one path computation and one flock-probe implementation in
    this module, not a second, potentially divergent, copy.

    ``fcntl.flock`` is the SOLE source of truth here -- the on-disk
    heartbeat JSON is observability-only and is NEVER consulted by this
    function. This call is entirely read-only with respect to station
    state: it never calls :meth:`ControllerLeaseManager.acquire`, never
    calls ``persist_state``, and never bumps a lease epoch or
    ``station_revision``. It never leaves a flock held on return -- if it
    opens the lockfile at all, it always unlocks and closes its own probe
    fd before returning, in every branch. If the lockfile does not exist
    yet, it returns False without creating anything.

    Args:
        data_dir: Override for the data directory root. If omitted,
            resolves ``wilted.DATA_DIR`` at call time (INV-5), i.e. the
            same default location a real ``ControllerLeaseManager``
            constructed in this process would use.

    Returns:
        True if a live process holds the writer lease right now, False
        otherwise.
    """
    return _probe_flock_would_block(_resolve_lockfile_path(data_dir))


__all__ = [
    "DEFAULT_HEARTBEAT_INTERVAL_SECONDS",
    "DEFAULT_TTL_SECONDS",
    "ControllerLeaseManager",
    "LeaseHeldError",
    "is_station_active",
]
