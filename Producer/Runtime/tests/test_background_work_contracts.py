"""Contract tests for wilted.background_work — frozen background-work contracts.

Executable contract for Task 1.1 of the Background-Work Foundation
Consolidation plan: orthogonal content states, ReportItem decisions,
ProcessingJob CAS transitions, legacy cohort mapping, idempotency keys,
cancellation semantics, artifact manifests, submission vocabulary, and
runner lifecycle transitions.
"""

from __future__ import annotations

import dataclasses
import importlib
import pkgutil
import sys

import pytest

import wilted.background_work as background_work_pkg
from wilted.background_work.contracts import (
    ArtifactManifest,
    JobKind,
    PreparationState,
    ProcessingJobState,
    ReportDecision,
    ReportItem,
    RetentionFacts,
    RetentionState,
    SubmissionOutcome,
)
from wilted.background_work.idempotency import (
    ReAdmissionPolicy,
    build_idempotency_key,
    logical_identity_for_kind,
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
    ProcessingJobTransitionError,
    RunnerLifecycle,
    RunnerState,
    all_processing_job_transition_pairs,
    all_runner_transition_pairs,
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

# ---------------------------------------------------------------------------
# Shared builders
# ---------------------------------------------------------------------------


def _report_item(
    *,
    report_id: int = 1,
    item_id: str = "item-1",
    rank: int = 0,
    decision: ReportDecision = ReportDecision.PENDING,
    defer_until: str | None = None,
) -> ReportItem:
    return ReportItem(
        report_id=report_id,
        item_id=item_id,
        rank=rank,
        decision=decision,
        defer_until=defer_until,
    )


def _manifest(**overrides) -> ArtifactManifest:
    defaults = dict(
        item_id="42",
        input_digest="a" * 64,
        operation_version=1,
        output_digests=("b" * 64,),
        completeness_checks=("non_empty",),
    )
    defaults.update(overrides)
    return ArtifactManifest(**defaults)


# ---------------------------------------------------------------------------
# 1. Content state enums and value objects
# ---------------------------------------------------------------------------


class TestContentStateContracts:
    def test_report_item_rejects_defer_until_without_deferred_decision(self):
        with pytest.raises(ValueError, match="defer_until"):
            _report_item(decision=ReportDecision.ACCEPTED, defer_until="2026-07-16T12:00:00Z")

    def test_retention_facts_rejects_expired_with_keep_override(self):
        with pytest.raises(ValueError, match="keep_override"):
            RetentionFacts(state=RetentionState.EXPIRED, keep_override=True)

    def test_artifact_manifest_rejects_empty_outputs(self):
        with pytest.raises(ValueError, match="output_digests"):
            ArtifactManifest(
                item_id="1",
                input_digest="a" * 64,
                output_digests=(),
                completeness_checks=("non_empty",),
            )

    def test_artifact_manifest_is_complete_requires_digests_and_checks(self):
        manifest = _manifest()
        assert manifest.is_complete is True
        object.__setattr__(manifest, "output_digests", ())
        assert manifest.is_complete is False

    def test_submission_outcome_vocabulary(self):
        assert {o.value for o in SubmissionOutcome} == {
            "submitted",
            "completed",
            "partial",
            "failed",
            "busy",
        }


# ---------------------------------------------------------------------------
# 2. Legacy cohort mapping — exhaustive table
# ---------------------------------------------------------------------------


class TestLegacyMapping:
    def test_every_legacy_cohort_has_exactly_one_mapping_or_quarantine(self):
        cohorts = all_legacy_cohorts()
        assert len(cohorts) == 66  # 9*2*3 + expired(2*3*2)
        outcomes = {cohort: map_legacy_cohort(cohort) for cohort in cohorts}
        assert len(outcomes) == len(cohorts)
        for cohort, outcome in outcomes.items():
            if outcome.quarantine:
                assert outcome.content is None
                assert outcome.quarantine_reason
            else:
                assert outcome.content is not None

    def test_auto_selected_podcast_is_pending_not_accepted(self):
        cohort = LegacyCohort(
            status=LegacyStatus.SELECTED,
            item_type=ItemType.PODCAST_EPISODE,
            artifacts=ArtifactCohort.NONE,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.report_decision is ReportDecision.PENDING
        assert outcome.report_decision is not ReportDecision.ACCEPTED

    def test_selected_article_is_accepted(self):
        cohort = LegacyCohort(
            status=LegacyStatus.SELECTED,
            item_type=ItemType.ARTICLE,
            artifacts=ArtifactCohort.PARTIAL,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.report_decision is ReportDecision.ACCEPTED

    def test_processing_complete_reconciles_to_preparation_ready(self):
        cohort = LegacyCohort(
            status=LegacyStatus.PROCESSING,
            item_type=ItemType.ARTICLE,
            artifacts=ArtifactCohort.COMPLETE,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.content is not None
        assert outcome.content.preparation is PreparationState.READY

    def test_processing_without_artifacts_returns_to_queued_preparation(self):
        cohort = LegacyCohort(
            status=LegacyStatus.PROCESSING,
            item_type=ItemType.PODCAST_EPISODE,
            artifacts=ArtifactCohort.NONE,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.content is not None
        assert outcome.content.preparation is PreparationState.QUEUED

    def test_ready_without_complete_artifacts_is_quarantine(self):
        cohort = LegacyCohort(
            status=LegacyStatus.READY,
            item_type=ItemType.ARTICLE,
            artifacts=ArtifactCohort.PARTIAL,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.quarantine is True

    def test_expired_keep_override_maps_to_active_retention(self):
        cohort = LegacyCohort(
            status=LegacyStatus.EXPIRED,
            item_type=ItemType.ARTICLE,
            artifacts=ArtifactCohort.COMPLETE,
            keep_override=True,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.content is not None
        assert outcome.content.retention.keep_override is True
        assert outcome.content.retention.state is RetentionState.ACTIVE

    def test_skipped_maps_to_dismissed_report_decision(self):
        cohort = LegacyCohort(
            status=LegacyStatus.SKIPPED,
            item_type=ItemType.ARTICLE,
            artifacts=ArtifactCohort.COMPLETE,
        )
        outcome = map_legacy_cohort(cohort)
        assert outcome.report_decision is ReportDecision.DISMISSED


# ---------------------------------------------------------------------------
# 3. ProcessingJob CAS transitions
# ---------------------------------------------------------------------------


class TestProcessingJobTransitions:
    @pytest.mark.parametrize(
        ("current", "target", "valid"),
        all_processing_job_transition_pairs(),
    )
    def test_transition_table(self, current, target, valid):
        assert is_valid_processing_job_transition(current, target) is valid
        if valid:
            assert transition_processing_job(current, target) is target
        else:
            with pytest.raises(ProcessingJobTransitionError):
                transition_processing_job(current, target)

    def test_exhaustive_pair_count(self):
        pairs = all_processing_job_transition_pairs()
        assert len(pairs) == 42
        assert sum(1 for _, _, valid in pairs if valid) == 15
        assert sum(1 for _, _, valid in pairs if not valid) == 27


# ---------------------------------------------------------------------------
# 4. Cancellation semantics
# ---------------------------------------------------------------------------


class TestCancellation:
    def test_unclaimed_job_cancels_immediately(self):
        for state in (ProcessingJobState.QUEUED, ProcessingJobState.RETRY, ProcessingJobState.DEFERRED):
            assert cancel_job(state) is ProcessingJobState.CANCELLED

    def test_running_job_cancel_is_cooperative(self):
        assert cancel_job(ProcessingJobState.RUNNING) is ProcessingJobState.RUNNING

    def test_terminal_job_cancel_raises(self):
        for state in (ProcessingJobState.COMPLETED, ProcessingJobState.FAILED):
            with pytest.raises(ProcessingJobTransitionError):
                cancel_job(state)

    def test_reconcile_running_cancel_requires_cancel_requested(self):
        with pytest.raises(ValueError, match="cancel_requested"):
            reconcile_running_cancel(
                cancel_requested=False,
                artifact_published=True,
                artifact_valid=True,
            )

    def test_running_cancel_with_valid_artifact_completes(self):
        outcome = reconcile_running_cancel(
            cancel_requested=True,
            artifact_published=True,
            artifact_valid=True,
        )
        assert outcome is CancellationOutcome.COMPLETED

    def test_running_cancel_without_valid_artifact_cancels(self):
        outcome = reconcile_running_cancel(
            cancel_requested=True,
            artifact_published=False,
            artifact_valid=False,
        )
        assert outcome is CancellationOutcome.CANCELLED

    def test_running_cancel_published_but_invalid_cancels(self):
        outcome = reconcile_running_cancel(
            cancel_requested=True,
            artifact_published=True,
            artifact_valid=False,
        )
        assert outcome is CancellationOutcome.CANCELLED


# ---------------------------------------------------------------------------
# 5. Report regeneration
# ---------------------------------------------------------------------------


class TestReportRegeneration:
    def test_same_day_regeneration_replaces_only_pending_rows(self):
        existing = (
            _report_item(item_id="pending-1", rank=0, decision=ReportDecision.PENDING),
            _report_item(item_id="accepted-1", rank=1, decision=ReportDecision.ACCEPTED),
            _report_item(
                item_id="deferred-1", rank=2, decision=ReportDecision.DEFERRED, defer_until="2099-01-01T00:00:00Z"
            ),
            _report_item(report_id=2, item_id="historical-1", rank=0, decision=ReportDecision.PENDING),
        )
        proposed = (
            _report_item(item_id="new-pending-1", rank=0),
            _report_item(item_id="new-pending-2", rank=1),
        )

        result = apply_report_regeneration(existing, proposed, report_id=1)
        by_id = {row.item_id: row for row in result}

        assert "pending-1" not in by_id
        assert by_id["new-pending-1"].decision is ReportDecision.PENDING
        assert by_id["new-pending-2"].decision is ReportDecision.PENDING
        assert by_id["accepted-1"].decision is ReportDecision.ACCEPTED
        assert by_id["deferred-1"].decision is ReportDecision.DEFERRED
        assert by_id["historical-1"].report_id == 2

    def test_proposed_non_pending_rows_rejected(self):
        existing = (_report_item(),)
        proposed = (_report_item(decision=ReportDecision.ACCEPTED),)
        with pytest.raises(ValueError, match="pending"):
            apply_report_regeneration(existing, proposed, report_id=1)

    def test_proposed_pending_duplicate_of_decided_item_rejected(self):
        existing = (_report_item(item_id="dup", decision=ReportDecision.ACCEPTED),)
        proposed = (_report_item(item_id="dup"),)
        with pytest.raises(ValueError, match="decided row"):
            apply_report_regeneration(existing, proposed, report_id=1)


# ---------------------------------------------------------------------------
# 5b. Report decision transitions
# ---------------------------------------------------------------------------


class TestReportDecisionTransitions:
    @pytest.mark.parametrize(
        ("current", "target", "valid"),
        [
            (ReportDecision.PENDING, ReportDecision.ACCEPTED, True),
            (ReportDecision.PENDING, ReportDecision.DEFERRED, True),
            (ReportDecision.PENDING, ReportDecision.DISMISSED, True),
            (ReportDecision.DEFERRED, ReportDecision.ACCEPTED, True),
            (ReportDecision.DEFERRED, ReportDecision.DISMISSED, True),
            (ReportDecision.ACCEPTED, ReportDecision.DISMISSED, False),
            (ReportDecision.DISMISSED, ReportDecision.ACCEPTED, False),
            (ReportDecision.PENDING, ReportDecision.PENDING, False),
            (ReportDecision.DEFERRED, ReportDecision.DEFERRED, False),
        ],
    )
    def test_transition_table(self, current, target, valid):
        assert is_valid_report_decision_transition(current, target) is valid
        defer_until = "2099-01-01T00:00:00Z" if target is ReportDecision.DEFERRED else None
        if valid:
            assert transition_report_decision(current, target, defer_until=defer_until) is target
        else:
            with pytest.raises(ProcessingJobTransitionError):
                transition_report_decision(current, target, defer_until=defer_until)

    def test_deferred_requires_defer_until(self):
        with pytest.raises(ValueError, match="defer_until"):
            transition_report_decision(ReportDecision.PENDING, ReportDecision.DEFERRED)

    def test_non_deferred_rejects_defer_until(self):
        with pytest.raises(ValueError, match="defer_until"):
            transition_report_decision(
                ReportDecision.PENDING,
                ReportDecision.ACCEPTED,
                defer_until="2099-01-01T00:00:00Z",
            )


# ---------------------------------------------------------------------------
# 5c. Retention transitions
# ---------------------------------------------------------------------------


class TestRetentionTransitions:
    def test_active_to_expired(self):
        facts = RetentionFacts(state=RetentionState.ACTIVE)
        updated = transition_retention(
            facts,
            RetentionState.EXPIRED,
            expires_at="2026-07-16T00:00:00Z",
            now="2026-07-17T00:00:00Z",
        )
        assert updated.state is RetentionState.EXPIRED
        assert updated.expired_at == "2026-07-16T00:00:00Z"

    def test_keep_override_prevents_expiry(self):
        facts = RetentionFacts(state=RetentionState.ACTIVE, keep_override=True)
        updated = transition_retention(
            facts,
            RetentionState.EXPIRED,
            expires_at="2026-07-16T00:00:00Z",
            now="2026-07-17T00:00:00Z",
        )
        assert updated.state is RetentionState.ACTIVE
        assert updated.keep_override is True
        assert updated.expired_at is None

    def test_cannot_expire_before_expires_at(self):
        facts = RetentionFacts(state=RetentionState.ACTIVE)
        with pytest.raises(ValueError, match="expires_at"):
            transition_retention(
                facts,
                RetentionState.EXPIRED,
                expires_at="2026-07-17T00:00:00Z",
                now="2026-07-16T00:00:00Z",
            )

    def test_expired_is_terminal(self):
        facts = RetentionFacts(state=RetentionState.EXPIRED, expired_at="2026-07-16T00:00:00Z")
        assert is_valid_retention_transition(RetentionState.EXPIRED, RetentionState.ACTIVE) is False
        with pytest.raises(ProcessingJobTransitionError):
            transition_retention(
                facts,
                RetentionState.ACTIVE,
                expires_at="2026-07-16T00:00:00Z",
                now="2026-07-17T00:00:00Z",
            )


# ---------------------------------------------------------------------------
# 6. Idempotency keys
# ---------------------------------------------------------------------------


class TestIdempotency:
    def test_key_stability_for_same_inputs(self):
        key_a = build_idempotency_key(
            JobKind.CLASSIFY,
            operation_version=3,
            logical_identity=logical_identity_for_kind(JobKind.CLASSIFY, item_id="item-99"),
        )
        key_b = build_idempotency_key(
            JobKind.CLASSIFY,
            operation_version=3,
            logical_identity="item:item-99",
        )
        assert key_a.canonical == key_b.canonical == "classify:v3:item:item-99"

    def test_discover_identity_defaults_run_date_when_omitted(self):
        """Discover's run_date param defaults to today so existing feed_id-only callers keep working."""
        from wilted.report import _local_date_str

        identity = logical_identity_for_kind(JobKind.DISCOVER, feed_id=7)
        assert identity == f"feed:7:{_local_date_str()}"

    def test_discover_identity_accepts_explicit_run_date(self):
        identity = logical_identity_for_kind(JobKind.DISCOVER, feed_id=7, run_date="2026-01-01")
        assert identity == "feed:7:2026-01-01"

    def test_discover_identity_differs_across_run_dates(self):
        """Distinct run_date values must yield distinct identities and canonical keys.

        This is the mechanism that resets the operation_version walk daily
        instead of letting it climb forever against one permanent identity.
        """
        identity_a = logical_identity_for_kind(JobKind.DISCOVER, feed_id=7, run_date="2026-01-01")
        identity_b = logical_identity_for_kind(JobKind.DISCOVER, feed_id=7, run_date="2026-01-02")
        assert identity_a != identity_b

        key_a = build_idempotency_key(JobKind.DISCOVER, operation_version=1, logical_identity=identity_a)
        key_b = build_idempotency_key(JobKind.DISCOVER, operation_version=1, logical_identity=identity_b)
        assert key_a.canonical != key_b.canonical

    def test_version_bump_changes_canonical_key(self):
        identity = logical_identity_for_kind(JobKind.PREPARE, item_id="7")
        key_v1 = build_idempotency_key(JobKind.PREPARE, operation_version=1, logical_identity=identity)
        key_v2 = build_idempotency_key(JobKind.PREPARE, operation_version=2, logical_identity=identity)
        assert key_v1.canonical != key_v2.canonical

    def test_requires_operation_version_bump_when_semantics_change(self):
        assert requires_operation_version_bump(handler_semantics_changed=True) is True
        assert requires_operation_version_bump() is False

    def test_re_admission_policy_terminal_states(self):
        assert re_admission_policy(ProcessingJobState.FAILED) is ReAdmissionPolicy.RETRY_IN_PLACE
        assert re_admission_policy(ProcessingJobState.CANCELLED) is ReAdmissionPolicy.RETRY_IN_PLACE
        assert re_admission_policy(ProcessingJobState.COMPLETED) is ReAdmissionPolicy.NEW_GENERATION

    def test_failed_and_cancelled_retry_in_place(self):
        assert should_retry_in_place(ProcessingJobState.FAILED) is True
        assert should_retry_in_place(ProcessingJobState.CANCELLED) is True

    def test_completed_requires_new_generation(self):
        assert should_retry_in_place(ProcessingJobState.COMPLETED) is False

    def test_should_retry_in_place_non_terminal_raises(self):
        with pytest.raises(ValueError, match="terminal states"):
            should_retry_in_place(ProcessingJobState.QUEUED)

    def test_same_window_recurring_dedupes_non_terminal(self):
        key = build_idempotency_key(
            JobKind.COMPACT_BRIEFING,
            operation_version=1,
            logical_identity=logical_identity_for_kind(
                JobKind.COMPACT_BRIEFING,
                window_start="2026-07-16T05:00:00Z",
                window_end="2026-07-16T06:00:00Z",
            ),
        )
        assert (
            resolve_recurring_admission(
                prior_key=key,
                proposed_key=key,
                prior_terminal_state=None,
            )
            is ReAdmissionPolicy.RETRY_IN_PLACE
        )

    def test_completed_same_key_requires_version_bump_or_new_window(self):
        key = build_idempotency_key(
            JobKind.REPORT_ASSEMBLY,
            operation_version=1,
            logical_identity=logical_identity_for_kind(JobKind.REPORT_ASSEMBLY, report_date="2026-07-16"),
        )
        with pytest.raises(ValueError, match="version bump or new window"):
            resolve_recurring_admission(
                prior_key=key,
                proposed_key=key,
                prior_terminal_state=ProcessingJobState.COMPLETED,
            )

    def test_version_bump_admits_new_generation(self):
        identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id="42")
        prior = build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)
        proposed = build_idempotency_key(JobKind.CLASSIFY, operation_version=2, logical_identity=identity)
        assert (
            resolve_recurring_admission(
                prior_key=prior,
                proposed_key=proposed,
                prior_terminal_state=ProcessingJobState.COMPLETED,
            )
            is ReAdmissionPolicy.NEW_GENERATION
        )

    @pytest.mark.parametrize(
        "kind",
        list(JobKind),
    )
    def test_every_job_kind_has_identity_recipe(self, kind: JobKind):
        if kind is JobKind.DISCOVER:
            identity = logical_identity_for_kind(kind, feed_id=1)
        elif kind in (JobKind.CLASSIFY, JobKind.PREPARE, JobKind.ARTICLE_CACHE):
            identity = logical_identity_for_kind(kind, item_id="1")
        elif kind is JobKind.REPORT_ASSEMBLY:
            identity = logical_identity_for_kind(kind, report_date="2026-07-16")
        else:
            identity = logical_identity_for_kind(
                kind,
                window_start="2026-07-16T05:00:00Z",
                window_end="2026-07-16T06:00:00Z",
            )
        key = build_idempotency_key(kind, operation_version=1, logical_identity=identity)
        assert key.canonical.startswith(f"{kind.value}:v1:")


# ---------------------------------------------------------------------------
# 7. Runner lifecycle
# ---------------------------------------------------------------------------


class TestRunnerLifecycle:
    @pytest.mark.parametrize(
        ("current", "target", "valid"),
        all_runner_transition_pairs(),
    )
    def test_transition_table(self, current, target, valid):
        assert is_valid_runner_transition(current, target) is valid
        if valid:
            assert transition_runner(current, target) is target
        else:
            with pytest.raises(ProcessingJobTransitionError):
                transition_runner(current, target)

    def test_exhaustive_pair_count(self):
        pairs = all_runner_transition_pairs()
        assert len(pairs) == 90
        assert sum(1 for _, _, valid in pairs if valid) == 22
        assert sum(1 for _, _, valid in pairs if not valid) == 68

    def test_happy_path_transitions(self):
        state = RunnerState()
        lifecycle = transition_runner(state.lifecycle, RunnerLifecycle.ACQUIRING_FLOCK)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.BOOTSTRAPPING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.CLAIMING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.HANDLING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.PUBLISHING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.ACKNOWLEDGING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.RELEASING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.IDLE)
        assert lifecycle is RunnerLifecycle.IDLE

    def test_station_active_yield_path(self):
        lifecycle = RunnerLifecycle.CLAIMING
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.YIELDING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.RELEASING)
        assert lifecycle is RunnerLifecycle.RELEASING

    def test_invalid_runner_transition_rejected(self):
        with pytest.raises(ProcessingJobTransitionError):
            transition_runner(RunnerLifecycle.IDLE, RunnerLifecycle.HANDLING)

    def test_sigterm_stop_at_item_boundary(self):
        state = dataclasses.replace(
            RunnerState(lifecycle=RunnerLifecycle.HANDLING),
            stop_requested=True,
        )
        lifecycle = transition_runner(state.lifecycle, RunnerLifecycle.STOPPING)
        lifecycle = transition_runner(lifecycle, RunnerLifecycle.IDLE)
        assert lifecycle is RunnerLifecycle.IDLE


# ---------------------------------------------------------------------------
# 8. Scheduler tick contract
# ---------------------------------------------------------------------------


class TestSchedulerTick:
    def test_bounded_batch_limit(self):
        assert bounded_batch_size(0) == 0
        assert bounded_batch_size(MAX_JOBS_PER_TICK) == MAX_JOBS_PER_TICK
        assert bounded_batch_size(MAX_JOBS_PER_TICK + 5) == MAX_JOBS_PER_TICK

    @pytest.mark.parametrize(
        ("current", "target", "valid"),
        [
            (SchedulerTickPhase.ACQUIRE_LOCK, SchedulerTickPhase.CHECK_DUE, True),
            (SchedulerTickPhase.ACQUIRE_LOCK, SchedulerTickPhase.RELEASE, True),
            (SchedulerTickPhase.CHECK_DUE, SchedulerTickPhase.DRAIN_BATCH, True),
            (SchedulerTickPhase.CHECK_DUE, SchedulerTickPhase.RELEASE, True),
            (SchedulerTickPhase.DRAIN_BATCH, SchedulerTickPhase.RELEASE, True),
            (SchedulerTickPhase.RELEASE, SchedulerTickPhase.ACQUIRE_LOCK, False),
            (SchedulerTickPhase.ACQUIRE_LOCK, SchedulerTickPhase.DRAIN_BATCH, False),
        ],
    )
    def test_phase_transitions(self, current, target, valid):
        assert is_valid_scheduler_tick_phase_transition(current, target) is valid
        if valid:
            assert transition_scheduler_tick_phase(current, target) is target
        else:
            with pytest.raises(ProcessingJobTransitionError):
                transition_scheduler_tick_phase(current, target)

    def test_resolve_outcomes(self):
        assert (
            resolve_scheduler_tick_outcome(
                lock_acquired=True,
                dns_available=True,
                jobs_due=0,
                jobs_ran=0,
            )
            is SchedulerTickOutcome.NOTHING_DUE
        )
        assert (
            resolve_scheduler_tick_outcome(
                lock_acquired=False,
                dns_available=True,
                jobs_due=3,
                jobs_ran=0,
            )
            is SchedulerTickOutcome.LOCK_BUSY
        )
        assert (
            resolve_scheduler_tick_outcome(
                lock_acquired=True,
                dns_available=False,
                jobs_due=3,
                jobs_ran=0,
            )
            is SchedulerTickOutcome.DNS_UNAVAILABLE
        )
        assert (
            resolve_scheduler_tick_outcome(
                lock_acquired=True,
                dns_available=True,
                jobs_due=3,
                jobs_ran=2,
                child_failed=True,
            )
            is SchedulerTickOutcome.CHILD_FAILED
        )
        assert (
            resolve_scheduler_tick_outcome(
                lock_acquired=True,
                dns_available=True,
                jobs_due=3,
                jobs_ran=2,
            )
            is SchedulerTickOutcome.RAN_BATCH
        )
        assert (
            resolve_scheduler_tick_outcome(
                lock_acquired=True,
                dns_available=True,
                jobs_due=3,
                jobs_ran=0,
                stop_requested=True,
            )
            is SchedulerTickOutcome.STOPPED
        )


# ---------------------------------------------------------------------------
# 9. Substrate neutrality
# ---------------------------------------------------------------------------


class TestSubstrateNeutrality:
    FORBIDDEN_MODULE_PREFIXES = ("textual", "peewee", "sqlite3", "wilted.db")

    def _background_work_package_files(self):
        import pathlib

        package_dir = list(background_work_pkg.__path__)[0]
        return sorted(pathlib.Path(package_dir).rglob("*.py"))

    def test_no_forbidden_import_statements_in_source(self):
        files = self._background_work_package_files()
        assert files, "expected at least one .py file under wilted/background_work/"

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
        if module_name == "wilted" or module_name.startswith("wilted."):
            assert module_name == "wilted.background_work" or module_name.startswith("wilted.background_work."), (
                f"{path} imports {module_name!r}, which is outside wilted.background_work"
            )

    def test_importing_package_does_not_pull_in_forbidden_modules(self):
        for name in list(sys.modules):
            if name == "wilted.background_work" or name.startswith("wilted.background_work."):
                del sys.modules[name]

        pre_existing = {
            name
            for name in sys.modules
            if any(name == f or name.startswith(f + ".") for f in self.FORBIDDEN_MODULE_PREFIXES)
        }

        importlib.import_module("wilted.background_work")
        for _finder, name, _ispkg in pkgutil.walk_packages(
            background_work_pkg.__path__,
            prefix="wilted.background_work.",
        ):
            importlib.import_module(name)

        post_import = {
            name
            for name in sys.modules
            if any(name == f or name.startswith(f + ".") for f in self.FORBIDDEN_MODULE_PREFIXES)
        }
        newly_added = post_import - pre_existing
        assert not newly_added, f"Importing background_work added forbidden modules: {newly_added}"
