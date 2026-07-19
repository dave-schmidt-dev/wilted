"""Per-kind idempotency key recipes and re-admission rules."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from enum import StrEnum

from wilted.background_work.contracts import JobKind, ProcessingJobState

_LOGICAL_IDENTITY_HELP = """
Per-kind logical identity recipes (operation_version is separate):
    discover: feed:{feed_id}:{run_date}
    classify/prepare/article_cache: item:{item_id}
    report_assembly: report:{report_date}
    compact_briefing: briefing:{window_start}:{window_end}
"""


@dataclass(frozen=True, slots=True)
class IdempotencyKey:
    """Canonical durable identity for one admitted work unit.

    Attributes:
        kind: Handler kind.
        operation_version: Integer bumped when inputs/prompt/model/handler semantics change.
        logical_identity: Stable source/item/window identity for the operation.
    """

    kind: JobKind
    operation_version: int
    logical_identity: str

    def __post_init__(self) -> None:
        if self.operation_version < 1:
            raise ValueError("IdempotencyKey.operation_version must be >= 1")
        if not self.logical_identity:
            raise ValueError("IdempotencyKey.logical_identity must be non-empty")

    @property
    def canonical(self) -> str:
        """Return the canonical string form used as the unique queue key."""
        return f"{self.kind.value}:v{self.operation_version}:{self.logical_identity}"


class ReAdmissionPolicy(StrEnum):
    """Whether a prior terminal generation retries in place or admits anew."""

    RETRY_IN_PLACE = "retry_in_place"
    NEW_GENERATION = "new_generation"


# Terminal states that may retry in place when semantics are unchanged.
_RETRY_IN_PLACE_TERMINAL = frozenset(
    {
        ProcessingJobState.FAILED,
        ProcessingJobState.CANCELLED,
    }
)

# Completed work never retries in place — a version bump or new identity is required.
_NEW_GENERATION_TERMINAL = frozenset({ProcessingJobState.COMPLETED})


def build_idempotency_key(
    kind: JobKind,
    *,
    operation_version: int,
    logical_identity: str,
) -> IdempotencyKey:
    """Build a canonical idempotency key for one job kind.

    Args:
        kind: Handler kind.
        operation_version: Handler/input/prompt/model version integer.
        logical_identity: Kind-specific stable identity (see module docstring and ``_LOGICAL_IDENTITY_HELP``).

    Returns:
        Frozen :class:`IdempotencyKey`.
    """
    return IdempotencyKey(kind=kind, operation_version=operation_version, logical_identity=logical_identity)


def _default_run_date() -> str:
    """Return today's local date as ``YYYY-MM-DD``.

    Duplicates :func:`wilted.report._local_date_str` rather than importing it:
    ``wilted.background_work`` is substrate-neutral and must not import
    anything outside the package (enforced by
    ``TestSubstrateNeutrality.test_no_forbidden_import_statements_in_source``),
    even via a lazy in-function import.
    """
    return date.today().isoformat()


def logical_identity_for_kind(
    kind: JobKind,
    *,
    feed_id: int | None = None,
    item_id: str | None = None,
    report_date: str | None = None,
    window_start: str | None = None,
    window_end: str | None = None,
    run_date: str | None = None,
) -> str:
    """Return the logical identity fragment for a job kind.

    Recipes (operation_version is separate):
        discover: ``feed:{feed_id}:{run_date}``
        classify: ``item:{item_id}``
        prepare: ``item:{item_id}``
        article_cache: ``item:{item_id}``
        report_assembly: ``report:{report_date}``
        compact_briefing: ``briefing:{window_start}:{window_end}``

    ``discover``'s identity carries a run-date component (mirroring
    ``report_assembly``'s date scoping) so ``_submit_fresh_generation``'s
    per-identity ``operation_version`` walk resets every day instead of
    climbing forever against one permanent ``feed:{feed_id}`` identity.
    ``run_date`` defaults to today's local date (see :func:`_default_run_date`,
    equivalent to :func:`wilted.report._local_date_str`) when omitted, so
    every existing ``feed_id``-only caller keeps working.

    Raises:
        ValueError: When required identity fields for ``kind`` are missing.
    """
    if kind is JobKind.DISCOVER:
        if feed_id is None:
            raise ValueError("discover requires feed_id")
        resolved_run_date = run_date if run_date is not None else _default_run_date()
        return f"feed:{feed_id}:{resolved_run_date}"
    if kind in (JobKind.CLASSIFY, JobKind.PREPARE, JobKind.ARTICLE_CACHE):
        if not item_id:
            raise ValueError(f"{kind.value} requires item_id")
        return f"item:{item_id}"
    if kind is JobKind.REPORT_ASSEMBLY:
        if not report_date:
            raise ValueError("report_assembly requires report_date")
        return f"report:{report_date}"
    if kind is JobKind.COMPACT_BRIEFING:
        if not window_start or not window_end:
            raise ValueError("compact_briefing requires window_start and window_end")
        return f"briefing:{window_start}:{window_end}"
    raise ValueError(f"Unknown job kind: {kind}")


def re_admission_policy(terminal_state: ProcessingJobState) -> ReAdmissionPolicy:
    """Return whether re-admission reuses the same idempotency key generation.

    Failed and cancelled jobs retry in place. Completed jobs require a new
    generation (operation version bump or new logical identity / window).
    """
    if terminal_state in _RETRY_IN_PLACE_TERMINAL:
        return ReAdmissionPolicy.RETRY_IN_PLACE
    if terminal_state in _NEW_GENERATION_TERMINAL:
        return ReAdmissionPolicy.NEW_GENERATION
    raise ValueError(f"re_admission_policy is only defined for terminal states, got {terminal_state.value}")


def should_retry_in_place(terminal_state: ProcessingJobState) -> bool:
    """Return whether re-admission reuses the same idempotency key generation.

    Deprecated alias for :func:`re_admission_policy`; prefer the enum return.
    """
    return re_admission_policy(terminal_state) is ReAdmissionPolicy.RETRY_IN_PLACE


def resolve_recurring_admission(
    *,
    prior_key: IdempotencyKey | None,
    proposed_key: IdempotencyKey,
    prior_terminal_state: ProcessingJobState | None,
) -> ReAdmissionPolicy:
    """Resolve recurring-generation admission for one idempotency identity.

    Rules:
        - Same canonical key + terminal ``completed`` → ``new_generation`` only
          when ``proposed_key`` differs (version bump or new window); otherwise
          dedupe by refusing a second completed generation for the same key.
        - Same canonical key + terminal ``failed``/``cancelled`` → ``retry_in_place``.
        - Same canonical key + non-terminal prior → dedupe (same window).
        - Distinct canonical keys → ``new_generation``.

    Args:
        prior_key: Previously admitted key for the same logical window, if any.
        proposed_key: Key for the proposed submission.
        prior_terminal_state: Terminal state of the prior generation, if complete.

    Returns:
        :class:`ReAdmissionPolicy` describing how admission should proceed.

    Raises:
        ValueError: When a completed duplicate shares the exact same canonical key.
    """
    if prior_key is None:
        return ReAdmissionPolicy.NEW_GENERATION
    if prior_key.canonical != proposed_key.canonical:
        return ReAdmissionPolicy.NEW_GENERATION
    if prior_terminal_state is None:
        return ReAdmissionPolicy.RETRY_IN_PLACE
    if prior_terminal_state is ProcessingJobState.COMPLETED:
        raise ValueError("same idempotency key with terminal completed requires operation_version bump or new window")
    return re_admission_policy(prior_terminal_state)


def requires_operation_version_bump(
    *,
    inputs_changed: bool = False,
    prompt_changed: bool = False,
    model_changed: bool = False,
    handler_semantics_changed: bool = False,
) -> bool:
    """Return True when any change requires bumping ``operation_version``.

    A version bump is mandatory whenever handler inputs, prompt identity,
    model identity, or handler semantics can change outputs.
    """
    return inputs_changed or prompt_changed or model_changed or handler_semantics_changed
