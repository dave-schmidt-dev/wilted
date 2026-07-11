"""Concrete station runtime implementations.

The ``wilted.station`` package is the substrate-neutral contract layer
(value objects, reducer, Protocol seams) and by contract imports nothing
outside itself (enforced by ``tests/test_station_contracts.py``'s
substrate-neutrality check). This sibling package holds the CONCRETE
implementations of those contracts — the pieces that necessarily depend on
the rest of ``wilted`` (``DATA_DIR``, the audio engine, the LLM/transcribe
backends), and therefore must live outside ``wilted.station``:

    store: ``JsonStationStore`` — the concrete ``StationStore`` on a
        versioned atomic JSON envelope under the live ``wilted.DATA_DIR``.
    coordinator: ``ModelCoordinator`` + ``RuntimeBootstrap`` — the single
        named ML lease enforcing INV-1/INV-2 (at most one model resident;
        main-thread tqdm bootstrap before any worker model load).
    lease: ``ControllerLeaseManager`` — OS-level (``flock``) mutual exclusion
        so exactly one live ``StationController`` process holds the writer
        lease, with a crashed/rebooted holder's lease immediately reclaimable.
    media_store: content-addressed immutable media store + owners index
        (module-level functions ``publish``/``publish_with_owner``/
        ``get_owners``/``path_for``; import as ``from wilted.station_runtime
        import media_store``). Its exceptions are re-exported here for
        convenient ``except`` sites.
"""

from wilted.station_runtime.coordinator import (
    LeaseHeldElsewhereError,
    LeaseReentrancyError,
    ModelCoordinator,
    ModelLease,
    RuntimeBootstrap,
)
from wilted.station_runtime.lease import (
    ControllerLeaseManager,
    LeaseHeldError,
)
from wilted.station_runtime.media_store import (
    EmptyMediaError,
    MediaOwnersCorruptError,
)
from wilted.station_runtime.store import (
    STATION_SCHEMA_VERSION,
    JsonStationStore,
    StationStoreVersionError,
)

__all__ = [
    "STATION_SCHEMA_VERSION",
    "ControllerLeaseManager",
    "EmptyMediaError",
    "JsonStationStore",
    "LeaseHeldElsewhereError",
    "LeaseHeldError",
    "LeaseReentrancyError",
    "MediaOwnersCorruptError",
    "ModelCoordinator",
    "ModelLease",
    "RuntimeBootstrap",
    "StationStoreVersionError",
]
