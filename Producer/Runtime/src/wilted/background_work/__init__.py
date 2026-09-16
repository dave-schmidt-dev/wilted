"""Substrate-neutral background-work contract layer.

Defines frozen value objects, pure transition functions, idempotency recipes,
and legacy cohort mappings for the durable pipeline runner described in the
Background-Work Foundation Consolidation plan (2026-07-16).

Nothing here commits to Peewee, SQLite, Textual, or filesystem layout.
It must remain importable with only the Python standard library and must
never import ``textual``, ``peewee``, ``sqlite3``, or anything from the
rest of the ``wilted`` package.

Modules:
    contracts: Orthogonal content-state enums, ReportItem, ProcessingJob
        vocabulary, artifact manifests, and submission outcomes.
    transitions: CAS transition tables for ProcessingJob and runner lifecycle,
        cancellation semantics, and report-regeneration rules.
    scheduler: Bounded scheduler tick phases, outcomes, and batch limits.
    legacy_mapping: Exhaustive legacy ``Item.status`` cohort truth table.
    idempotency: Per-kind idempotency key recipes and re-admission rules.
"""

from wilted.background_work.contracts import (
    AnalysisState,
    ArtifactManifest,
    ContentState,
    FetchState,
    JobKind,
    PlaybackState,
    PreparationState,
    ProcessingJobLease,
    ProcessingJobState,
    ReportDecision,
    ReportItem,
    RetentionFacts,
    RetentionState,
    SubmissionOutcome,
)
from wilted.background_work.idempotency import (
    IdempotencyKey,
    ReAdmissionPolicy,
    build_idempotency_key,
    re_admission_policy,
    requires_operation_version_bump,
    resolve_recurring_admission,
    should_retry_in_place,
)
from wilted.background_work.legacy_mapping import (
    ArtifactCohort,
    ItemType,
    LegacyCohort,
    LegacyStatus,
    MappingOutcome,
    all_legacy_cohorts,
    map_legacy_cohort,
)
from wilted.background_work.scheduler import (
    MAX_JOBS_PER_TICK,
    SchedulerTickOutcome,
    SchedulerTickPhase,
    bounded_batch_size,
    is_valid_scheduler_tick_phase_transition,
    resolve_scheduler_tick_outcome,
    transition_scheduler_tick_phase,
)
from wilted.background_work.transitions import (
    CancellationOutcome,
    CancelRequest,
    ProcessingJobTransitionError,
    RunnerLifecycle,
    RunnerState,
    apply_report_regeneration,
    cancel_job,
    is_valid_processing_job_transition,
    is_valid_report_decision_transition,
    is_valid_retention_transition,
    is_valid_runner_transition,
    reconcile_running_cancel,
    transition_processing_job,
    transition_report_decision,
    transition_retention,
    transition_runner,
)

__all__ = [
    "AnalysisState",
    "ArtifactCohort",
    "ArtifactManifest",
    "CancelRequest",
    "CancellationOutcome",
    "ContentState",
    "FetchState",
    "IdempotencyKey",
    "ItemType",
    "JobKind",
    "LegacyCohort",
    "LegacyStatus",
    "MappingOutcome",
    "MAX_JOBS_PER_TICK",
    "PlaybackState",
    "PreparationState",
    "ProcessingJobLease",
    "ProcessingJobState",
    "ProcessingJobTransitionError",
    "ReAdmissionPolicy",
    "ReportDecision",
    "ReportItem",
    "RetentionFacts",
    "RetentionState",
    "RunnerLifecycle",
    "RunnerState",
    "SchedulerTickOutcome",
    "SchedulerTickPhase",
    "SubmissionOutcome",
    "all_legacy_cohorts",
    "apply_report_regeneration",
    "bounded_batch_size",
    "build_idempotency_key",
    "cancel_job",
    "is_valid_processing_job_transition",
    "is_valid_report_decision_transition",
    "is_valid_retention_transition",
    "is_valid_runner_transition",
    "is_valid_scheduler_tick_phase_transition",
    "map_legacy_cohort",
    "re_admission_policy",
    "reconcile_running_cancel",
    "requires_operation_version_bump",
    "resolve_recurring_admission",
    "resolve_scheduler_tick_outcome",
    "should_retry_in_place",
    "transition_processing_job",
    "transition_report_decision",
    "transition_retention",
    "transition_runner",
    "transition_scheduler_tick_phase",
]
