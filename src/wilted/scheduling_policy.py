"""Pure anti-starvation deferral policy for the local-processing claim seam.

Milestone 3 of the "resource-aware smart processing queue" feature. Given a
job, a machine-availability snapshot, the current listenable inventory count
and the wall clock, this module decides whether an *expensive* local-model
job should be **deferred** — i.e. left ``QUEUED`` and not claimed right now so
the machine stays responsive during the day — or run immediately.

Pure by construction
---------------------
:func:`should_defer` and :func:`select_claimable` perform **no I/O, no DB
access, no clock reads and no logging**. Everything time-, machine- and
inventory-dependent is captured up front in a :class:`PolicyContext` that the
impure claim seam assembles (it samples availability once, counts inventory
once and reads the clock once per claim attempt). This keeps the five
starvation rules exhaustively unit-testable with plain frozen dataclasses and
no mocking. The one impure helper here is :func:`thresholds_from_settings`,
a factory that reads ``get_setting`` overrides — it is deliberately *not* a
pure decision function and is never called from inside ``should_defer``.

The five starvation rules (each is a reason **not** to defer)
-------------------------------------------------------------
An expensive job is deferred only when *none* of these escape valves fire:

1. **Priority bypass** — priority ``>=`` ``interactive_priority_floor`` is
   treated as interactive and is never deferred.
2. **Inventory gate** — deferral only makes sense when there is already
   enough listenable content to play; if inventory is short (``<
   enough_inventory``) the job runs so the queue keeps producing.
3. **Daytime window** — deferral only applies inside the local busy window
   ``[daytime_start_hour, daytime_end_hour)``; outside it (evening/overnight)
   the job runs.
4. **Machine-idle override** — even inside the window, if the sample shows a
   quiet machine (low load, on AC, user idle past the threshold) the job runs
   because there is real slack to use.
5. **Age ceiling** — a job older than ``max_defer_hours`` runs regardless;
   this is the hard backstop that guarantees no job is deferred forever.

Fail-open on unknown availability
---------------------------------
If the availability sample is not ``ok`` (sensor unavailable / non-darwin /
probe failed) the policy **runs** the job (never defers). A broken sensor must
never be able to starve the queue. The seam logs a single WARNING when this
fail-open path actually causes an expensive job to run; the pure module only
reports the machine-readable :class:`DeferralReason` so callers can act on it.

Known imprecision (documented, accepted)
----------------------------------------
The machine-idle override reads ``availability.load_per_core``, which the
sensor derives from ``os.getloadavg()[0]`` — the **1-minute** load average, an
exponentially-weighted moving average. At a work<->idle transition the EWMA
lags reality, so the override can misfire by up to ~1 minute (running a job a
minute too eagerly as load decays, or holding one back a minute too long as
load ramps). This is acceptable: the age-ceiling rule backstops any job the
override wrongly holds, and one job's worth of eager start is harmless. It is
called out here so a future reader does not mistake it for a bug.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from typing import TYPE_CHECKING

from wilted.scheduling_cost import JobCostClass, estimate_cost_class

if TYPE_CHECKING:
    from collections.abc import Iterable

    from wilted.station_runtime.machine_availability import MachineAvailability

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
@dataclass(frozen=True, slots=True)
class PolicyThresholds:
    """Tunable thresholds for the deferral policy.

    Defaults are David's locked recommendations (2026-07-25). Every field is
    overridable at runtime via :func:`thresholds_from_settings`, which reads
    the corresponding ``scheduling_*`` setting keys.

    Attributes:
        interactive_priority_floor: A job whose ``priority`` is at or above
            this value is treated as interactive and is never deferred.
            ``ProcessingJob.priority`` defaults to ``0`` and is ordered
            ``DESC`` (higher == claimed sooner), so ``1`` is the smallest
            elevation above background work — anything explicitly prioritized
            bypasses deferral.
        enough_inventory: Deferral only applies when at least this many
            listenable items are already ready to play.
        daytime_start_hour: Inclusive local hour the busy window opens.
        daytime_end_hour: Exclusive local hour the busy window closes.
        max_defer_hours: A job at least this old (by absolute age) always
            runs — the hard anti-starvation backstop.
        idle_load_per_core: Machine-idle override fires only when
            ``load_per_core`` is strictly below this.
        idle_min_seconds: Machine-idle override fires only when the user has
            been idle for strictly more than this many seconds.
    """

    interactive_priority_floor: int = 1
    enough_inventory: int = 3
    daytime_start_hour: int = 8
    daytime_end_hour: int = 20
    max_defer_hours: int = 18
    idle_load_per_core: float = 0.6
    idle_min_seconds: float = 300.0


# Setting keys read by ``thresholds_from_settings`` (flat, ``scheduling_``
# prefix — mirrors the existing flat setting-key convention, e.g. "speed").
_SETTING_KEYS: dict[str, str] = {
    "interactive_priority_floor": "scheduling_interactive_priority_floor",
    "enough_inventory": "scheduling_enough_inventory",
    "daytime_start_hour": "scheduling_daytime_start_hour",
    "daytime_end_hour": "scheduling_daytime_end_hour",
    "max_defer_hours": "scheduling_max_defer_hours",
    "idle_load_per_core": "scheduling_idle_load_per_core",
    "idle_min_seconds": "scheduling_idle_min_seconds",
}


def thresholds_from_settings() -> PolicyThresholds:
    """Build :class:`PolicyThresholds`, applying ``get_setting`` overrides.

    Impure: reads the settings table via :func:`wilted.db.get_setting`. This
    is a factory, deliberately separated from the pure decision functions —
    resolve it once at the impure seam (never as an import-time default) so
    the DB read happens at call time under the caller's :data:`wilted.DATA_DIR`
    (INV-5), not at module import.

    Any missing or malformed setting falls back to the coded default (with a
    WARNING for malformed values); the policy is never left un-thresholded.

    Returns:
        A :class:`PolicyThresholds` with per-field overrides applied.
    """
    from wilted.db import get_setting  # local import: keep pure decisions DB-free

    defaults = PolicyThresholds()
    return PolicyThresholds(
        interactive_priority_floor=_int_override(
            get_setting, "interactive_priority_floor", defaults.interactive_priority_floor
        ),
        enough_inventory=_int_override(get_setting, "enough_inventory", defaults.enough_inventory),
        daytime_start_hour=_int_override(get_setting, "daytime_start_hour", defaults.daytime_start_hour),
        daytime_end_hour=_int_override(get_setting, "daytime_end_hour", defaults.daytime_end_hour),
        max_defer_hours=_int_override(get_setting, "max_defer_hours", defaults.max_defer_hours),
        idle_load_per_core=_float_override(get_setting, "idle_load_per_core", defaults.idle_load_per_core),
        idle_min_seconds=_float_override(get_setting, "idle_min_seconds", defaults.idle_min_seconds),
    )


def _int_override(getter, field: str, default: int) -> int:
    raw = getter(_SETTING_KEYS[field])
    if raw is None:
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        logger.warning("Ignoring malformed setting %s=%r; using default %d", _SETTING_KEYS[field], raw, default)
        return default


def _float_override(getter, field: str, default: float) -> float:
    raw = getter(_SETTING_KEYS[field])
    if raw is None:
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        logger.warning("Ignoring malformed setting %s=%r; using default %s", _SETTING_KEYS[field], raw, default)
        return default


# ---------------------------------------------------------------------------
# Machine-readable decision
# ---------------------------------------------------------------------------
class DeferralReason(StrEnum):
    """Why the policy reached its defer/run decision (machine-readable).

    Exactly one value is attached to every :class:`DeferralDecision`. Only
    :data:`DAYTIME_BUSY` corresponds to ``deferred=True``; all others are the
    specific escape valve that caused the job to run.
    """

    # deferred=True
    DAYTIME_BUSY = "daytime_busy"
    # deferred=False (a rule fired -> run)
    NOT_EXPENSIVE = "not_expensive"
    PRIORITY_BYPASS = "priority_bypass"
    INVENTORY_LOW = "inventory_low"
    AGE_CEILING = "age_ceiling"
    OUTSIDE_WINDOW = "outside_window"
    SENSOR_UNAVAILABLE = "sensor_unavailable"
    MACHINE_IDLE = "machine_idle"


@dataclass(frozen=True, slots=True)
class DeferralDecision:
    """The policy's verdict for one job.

    Attributes:
        deferred: ``True`` == "skip: leave the job QUEUED, do not claim it now".
            ``False`` == "run: this job is eligible to be claimed".
        reason: The machine-readable :class:`DeferralReason` for the verdict.
    """

    deferred: bool
    reason: DeferralReason


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
@dataclass(frozen=True, slots=True)
class JobCandidate:
    """A claimable job reduced to exactly what the policy needs.

    The seam builds one of these per fetched claimable row so the pure policy
    never touches the ORM. ``created_at`` is a timezone-aware datetime (the
    seam parses the stored ``Z`` timestamp) so age math is instant-correct.

    Attributes:
        priority: The job's ``priority`` column (higher == more urgent).
        kind: The job's ``kind`` value (drives the cost estimate).
        created_at: Timezone-aware creation instant (for the age ceiling).
        item_type: Optional item type (``article``/``podcast_episode``),
            forwarded to the cost estimate for the ``PREPARE`` branch.
        checkpoint_json: Optional serialized checkpoint, forwarded to the
            cost estimate for the ``PREPARE`` branch.
        job_id: Optional identifier, carried for the seam's convenience/logs.
    """

    priority: int
    kind: str
    created_at: datetime
    item_type: str | None = None
    checkpoint_json: str | None = None
    job_id: int | None = None


@dataclass(frozen=True, slots=True)
class PolicyContext:
    """Everything time-, machine- and inventory-dependent, sampled once.

    Attributes:
        now: Timezone-aware "current" instant. Its local wall-clock ``.hour``
            drives the daytime-window check; its absolute value drives the age
            ceiling. The seam passes a *local-aware* datetime so ``.hour`` is
            machine-local in production and deterministic in tests.
        availability: The machine-availability snapshot for this attempt.
        listenable_count: How many listenable items are ready right now.
    """

    now: datetime
    availability: MachineAvailability
    listenable_count: int


# ---------------------------------------------------------------------------
# Pure decision functions
# ---------------------------------------------------------------------------
def should_defer(
    candidate: JobCandidate,
    ctx: PolicyContext,
    thresholds: PolicyThresholds,
) -> DeferralDecision:
    """Decide whether one job should be deferred (skipped) right now.

    Pure: no I/O, no DB, no clock read, no logging. All external state arrives
    via ``ctx`` and ``thresholds``.

    Deferral is **expensive-only**: ``CHEAP`` and ``MEDIUM`` jobs are always
    eligible to run. For an expensive job the five starvation rules are each a
    reason to run; the job is deferred only if none fire. Evaluation order is
    chosen so the returned :class:`DeferralReason` names the most informative
    cause and so the fail-open branch is reached only when a broken sensor is
    the operative reason a job runs:

    1. non-expensive -> :data:`~DeferralReason.NOT_EXPENSIVE` (run)
    2. priority ``>=`` floor -> :data:`~DeferralReason.PRIORITY_BYPASS` (run)
    3. inventory ``<`` enough -> :data:`~DeferralReason.INVENTORY_LOW` (run)
    4. age ``>=`` ceiling -> :data:`~DeferralReason.AGE_CEILING` (run)
    5. outside the local window -> :data:`~DeferralReason.OUTSIDE_WINDOW` (run)
    6. availability not ``ok`` -> :data:`~DeferralReason.SENSOR_UNAVAILABLE`
       (run, fail-open)
    7. machine idle -> :data:`~DeferralReason.MACHINE_IDLE` (run)
    8. otherwise -> :data:`~DeferralReason.DAYTIME_BUSY` (**defer**)

    The machine-idle override (rule 7) reads the 1-minute-EWMA load average and
    can therefore misfire by ~1 minute at a load transition — see the module
    docstring; the age ceiling backstops any job it wrongly holds.

    Args:
        candidate: The job under consideration.
        ctx: The once-sampled time/machine/inventory context.
        thresholds: The active tunables.

    Returns:
        A :class:`DeferralDecision` (``deferred`` plus its machine-readable
        :class:`DeferralReason`).
    """
    cost = estimate_cost_class(candidate.kind, item_type=candidate.item_type, checkpoint_json=candidate.checkpoint_json)
    if cost is not JobCostClass.EXPENSIVE:
        return DeferralDecision(deferred=False, reason=DeferralReason.NOT_EXPENSIVE)

    if candidate.priority >= thresholds.interactive_priority_floor:
        return DeferralDecision(deferred=False, reason=DeferralReason.PRIORITY_BYPASS)

    if ctx.listenable_count < thresholds.enough_inventory:
        return DeferralDecision(deferred=False, reason=DeferralReason.INVENTORY_LOW)

    age = ctx.now - candidate.created_at
    if age >= timedelta(hours=thresholds.max_defer_hours):
        return DeferralDecision(deferred=False, reason=DeferralReason.AGE_CEILING)

    hour = ctx.now.hour
    if not (thresholds.daytime_start_hour <= hour < thresholds.daytime_end_hour):
        return DeferralDecision(deferred=False, reason=DeferralReason.OUTSIDE_WINDOW)

    # Fail-open: a broken/unknown sensor must never defer (starve) a job.
    if not ctx.availability.ok:
        return DeferralDecision(deferred=False, reason=DeferralReason.SENSOR_UNAVAILABLE)

    if (
        ctx.availability.ok
        and ctx.availability.load_per_core < thresholds.idle_load_per_core
        and ctx.availability.on_ac_power
        and ctx.availability.user_idle_seconds is not None
        and ctx.availability.user_idle_seconds > thresholds.idle_min_seconds
    ):
        return DeferralDecision(deferred=False, reason=DeferralReason.MACHINE_IDLE)

    return DeferralDecision(deferred=True, reason=DeferralReason.DAYTIME_BUSY)


def select_claimable(
    candidates: Iterable[JobCandidate],
    ctx: PolicyContext,
    thresholds: PolicyThresholds,
) -> JobCandidate | None:
    """Return the first claimable candidate, or ``None`` if none are claimable.

    Pure: no I/O, no DB, no clock read, no logging.

    **Candidate-set contract (non-negotiable):** ``None`` means "nothing is
    claimable *globally* right now", never "nothing in the first N". The caller
    MUST pass **all** currently-claimable rows in the base query order
    (priority ``DESC``, ``created_at`` ``ASC``); this function scans that full
    order and returns the first non-deferred job. It must never be fed a
    bounded ``.limit(N)`` window — a window full of deferrable expensive jobs
    would hide a claimable cheap job at position N+1 and stall real throughput.

    Args:
        candidates: All claimable jobs, in base query order.
        ctx: The once-sampled time/machine/inventory context.
        thresholds: The active tunables.

    Returns:
        The first :class:`JobCandidate` the policy would run, or ``None`` if
        every candidate is deferred.
    """
    for candidate in candidates:
        if not should_defer(candidate, ctx, thresholds).deferred:
            return candidate
    return None


__all__ = [
    "DeferralDecision",
    "DeferralReason",
    "JobCandidate",
    "PolicyContext",
    "PolicyThresholds",
    "select_claimable",
    "should_defer",
    "thresholds_from_settings",
]
