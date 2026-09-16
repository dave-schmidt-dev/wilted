"""Exhaustive unit tests for the pure deferral policy (INV-12 gate test).

Covers each of the five starvation rules at its fire/no-fire boundary, the
expensive-only guard, fail-open on an unavailable sensor, priority bypass, the
age-ceiling backstop, the daytime-window boundaries, the machine-idle truth
table, and the ``select_claimable`` global-``None`` candidate-set property.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from wilted.background_work.contracts import JobKind
from wilted.scheduling_policy import (
    DeferralReason,
    DeferralSummary,
    JobCandidate,
    PolicyContext,
    PolicyThresholds,
    format_deferral_summary,
    select_claimable,
    should_defer,
    summarize_claimable,
    thresholds_from_settings,
)
from wilted.station_runtime.machine_availability import MachineAvailability

# A fixed instant inside the default busy window (hour 10 in [8, 20)).
NOW = datetime(2026, 7, 25, 10, 0, tzinfo=UTC)
THRESHOLDS = PolicyThresholds()


def _avail(
    *,
    ok: bool = True,
    load_per_core: float = 2.0,
    on_ac_power: bool = True,
    user_idle_seconds: float | None = 10.0,
) -> MachineAvailability:
    """Build a MachineAvailability. Defaults describe a BUSY machine (not idle)."""
    return MachineAvailability(
        load_per_core=load_per_core,
        on_ac_power=on_ac_power,
        user_idle_seconds=user_idle_seconds,
        sampled_at="2026-07-25T10:00:00Z",
        ok=ok,
    )


def _ctx(
    *,
    now: datetime = NOW,
    availability: MachineAvailability | None = None,
    listenable_count: int = 5,
) -> PolicyContext:
    return PolicyContext(
        now=now,
        availability=availability if availability is not None else _avail(),
        listenable_count=listenable_count,
    )


def _cand(
    *,
    kind: str = JobKind.COMPACT_BRIEFING.value,
    priority: int = 0,
    created_at: datetime | None = None,
    item_type: str | None = None,
    checkpoint_json: str | None = None,
    job_id: int = 1,
) -> JobCandidate:
    """Build a candidate. Defaults describe an EXPENSIVE, low-priority, young job."""
    return JobCandidate(
        priority=priority,
        kind=kind,
        created_at=created_at if created_at is not None else NOW - timedelta(hours=1),
        item_type=item_type,
        checkpoint_json=checkpoint_json,
        job_id=job_id,
    )


# ---------------------------------------------------------------------------
# Baseline: the one scenario that actually defers
# ---------------------------------------------------------------------------
class TestBaselineDefers:
    def test_expensive_low_priority_busy_daytime_with_inventory_defers(self):
        decision = should_defer(_cand(), _ctx(), THRESHOLDS)
        assert decision.deferred is True
        assert decision.reason is DeferralReason.DAYTIME_BUSY

    def test_daytime_busy_is_the_only_deferred_reason(self):
        # Every other reason corresponds to running.
        assert should_defer(_cand(), _ctx(), THRESHOLDS).reason is DeferralReason.DAYTIME_BUSY


# ---------------------------------------------------------------------------
# Rule 0: expensive-only (CHEAP/MEDIUM never defer)
# ---------------------------------------------------------------------------
class TestExpensiveOnly:
    @pytest.mark.parametrize(
        "kind",
        [JobKind.DISCOVER.value, JobKind.REPORT_ASSEMBLY.value, JobKind.CLASSIFY.value],
    )
    def test_non_expensive_kinds_always_run(self, kind):
        # Even in the exact busy-daytime-with-inventory scenario that defers an
        # expensive job, cheap/medium work is always eligible.
        decision = should_defer(_cand(kind=kind), _ctx(), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.NOT_EXPENSIVE

    @pytest.mark.parametrize(
        "kind",
        [JobKind.ARTICLE_CACHE.value, JobKind.COMPACT_BRIEFING.value],
    )
    def test_always_expensive_kinds_reach_deferral(self, kind):
        decision = should_defer(_cand(kind=kind), _ctx(), THRESHOLDS)
        assert decision.deferred is True

    def test_prepare_with_speech_is_expensive_and_defers(self):
        # PREPARE for a podcast episode requires speech -> expensive.
        decision = should_defer(_cand(kind=JobKind.PREPARE.value, item_type="podcast_episode"), _ctx(), THRESHOLDS)
        assert decision.deferred is True
        assert decision.reason is DeferralReason.DAYTIME_BUSY

    def test_prepare_skip_tts_article_is_cheap_and_runs(self):
        decision = should_defer(
            _cand(kind=JobKind.PREPARE.value, item_type="article", checkpoint_json='{"skip_tts": true}'),
            _ctx(),
            THRESHOLDS,
        )
        assert decision.deferred is False
        assert decision.reason is DeferralReason.NOT_EXPENSIVE


# ---------------------------------------------------------------------------
# Rule 1: priority bypass (interactive floor)
# ---------------------------------------------------------------------------
class TestPriorityBypass:
    def test_priority_at_floor_bypasses(self):
        decision = should_defer(_cand(priority=THRESHOLDS.interactive_priority_floor), _ctx(), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.PRIORITY_BYPASS

    def test_priority_above_floor_bypasses(self):
        decision = should_defer(_cand(priority=10), _ctx(), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.PRIORITY_BYPASS

    def test_priority_below_floor_still_defers(self):
        # floor default is 1; background priority 0 is below it.
        assert THRESHOLDS.interactive_priority_floor == 1
        decision = should_defer(_cand(priority=0), _ctx(), THRESHOLDS)
        assert decision.deferred is True

    def test_priority_bypass_wins_even_with_broken_sensor(self):
        # Priority is evaluated before the fail-open branch: the reason is the
        # bypass, not SENSOR_UNAVAILABLE.
        decision = should_defer(_cand(priority=5), _ctx(availability=_avail(ok=False)), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.PRIORITY_BYPASS


# ---------------------------------------------------------------------------
# Rule 2: inventory gate (short inventory -> run)
# ---------------------------------------------------------------------------
class TestInventoryGate:
    def test_short_inventory_runs(self):
        decision = should_defer(_cand(), _ctx(listenable_count=2), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.INVENTORY_LOW

    def test_inventory_exactly_enough_defers(self):
        # enough_inventory == 3: a count of exactly 3 is "enough" -> keep deferring.
        assert THRESHOLDS.enough_inventory == 3
        decision = should_defer(_cand(), _ctx(listenable_count=3), THRESHOLDS)
        assert decision.deferred is True

    def test_inventory_one_below_enough_runs(self):
        decision = should_defer(_cand(), _ctx(listenable_count=2), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.INVENTORY_LOW

    def test_zero_inventory_runs(self):
        decision = should_defer(_cand(), _ctx(listenable_count=0), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.INVENTORY_LOW


# ---------------------------------------------------------------------------
# Rule 3: age ceiling backstop
# ---------------------------------------------------------------------------
class TestAgeCeiling:
    def test_age_exactly_at_ceiling_runs(self):
        created = NOW - timedelta(hours=THRESHOLDS.max_defer_hours)
        decision = should_defer(_cand(created_at=created), _ctx(), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.AGE_CEILING

    def test_age_just_under_ceiling_defers(self):
        created = NOW - timedelta(hours=THRESHOLDS.max_defer_hours) + timedelta(minutes=1)
        decision = should_defer(_cand(created_at=created), _ctx(), THRESHOLDS)
        assert decision.deferred is True

    def test_age_ceiling_backstops_busy_daytime(self):
        # A very old job runs even in the busy window with full inventory and a
        # busy machine -> no starvation.
        created = NOW - timedelta(hours=48)
        decision = should_defer(_cand(created_at=created), _ctx(), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.AGE_CEILING

    def test_age_ceiling_precedes_fail_open(self):
        # Aged + broken sensor -> AGE_CEILING (age is checked before fail-open).
        created = NOW - timedelta(hours=48)
        decision = should_defer(_cand(created_at=created), _ctx(availability=_avail(ok=False)), THRESHOLDS)
        assert decision.reason is DeferralReason.AGE_CEILING


# ---------------------------------------------------------------------------
# Rule 4: daytime window boundaries [08:00, 20:00)
# ---------------------------------------------------------------------------
class TestDaytimeWindow:
    @pytest.mark.parametrize(
        ("hour", "minute", "deferred", "reason"),
        [
            (7, 59, False, DeferralReason.OUTSIDE_WINDOW),  # just before open -> run
            (8, 0, True, DeferralReason.DAYTIME_BUSY),  # window opens -> defer
            (19, 59, True, DeferralReason.DAYTIME_BUSY),  # last busy minute -> defer
            (20, 0, False, DeferralReason.OUTSIDE_WINDOW),  # window closes -> run
            (23, 30, False, DeferralReason.OUTSIDE_WINDOW),  # overnight -> run
            (3, 0, False, DeferralReason.OUTSIDE_WINDOW),  # small hours -> run
        ],
    )
    def test_window_boundaries(self, hour, minute, deferred, reason):
        now = datetime(2026, 7, 25, hour, minute, tzinfo=UTC)
        # created_at just before `now` so the age ceiling never interferes.
        cand = _cand(created_at=now - timedelta(hours=1))
        decision = should_defer(cand, _ctx(now=now), THRESHOLDS)
        assert decision.deferred is deferred
        assert decision.reason is reason


# ---------------------------------------------------------------------------
# Rule 5: machine-idle override truth table
# ---------------------------------------------------------------------------
class TestMachineIdleOverride:
    def test_fully_idle_machine_runs(self):
        avail = _avail(load_per_core=0.5, on_ac_power=True, user_idle_seconds=301.0)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.MACHINE_IDLE

    def test_load_at_threshold_is_not_idle(self):
        # load_per_core must be strictly below idle_load_per_core (0.6).
        avail = _avail(load_per_core=0.6, on_ac_power=True, user_idle_seconds=301.0)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is True

    def test_on_battery_is_not_idle(self):
        avail = _avail(load_per_core=0.5, on_ac_power=False, user_idle_seconds=301.0)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is True

    def test_user_idle_at_threshold_is_not_idle(self):
        # user_idle_seconds must be strictly greater than idle_min_seconds (300).
        avail = _avail(load_per_core=0.5, on_ac_power=True, user_idle_seconds=300.0)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is True

    def test_user_idle_none_is_not_idle(self):
        avail = _avail(load_per_core=0.5, on_ac_power=True, user_idle_seconds=None)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is True

    def test_user_idle_just_above_threshold_runs(self):
        avail = _avail(load_per_core=0.59, on_ac_power=True, user_idle_seconds=300.01)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.MACHINE_IDLE


# ---------------------------------------------------------------------------
# Fail-open: unknown availability never defers
# ---------------------------------------------------------------------------
class TestFailOpen:
    def test_sensor_unavailable_runs(self):
        decision = should_defer(_cand(), _ctx(availability=_avail(ok=False)), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.SENSOR_UNAVAILABLE

    def test_sensor_unavailable_with_idle_looking_values_still_reports_sensor(self):
        # ok=False short-circuits before the idle check even if the numbers look idle.
        avail = _avail(ok=False, load_per_core=0.1, on_ac_power=True, user_idle_seconds=9999.0)
        decision = should_defer(_cand(), _ctx(availability=avail), THRESHOLDS)
        assert decision.deferred is False
        assert decision.reason is DeferralReason.SENSOR_UNAVAILABLE

    def test_outside_window_precedes_fail_open(self):
        # A night job with a broken sensor runs for the window reason, not the
        # sensor reason (so it triggers no fail-open warning at the seam).
        night = datetime(2026, 7, 25, 22, 0, tzinfo=UTC)
        cand = _cand(created_at=night - timedelta(hours=1))
        decision = should_defer(cand, _ctx(now=night, availability=_avail(ok=False)), THRESHOLDS)
        assert decision.reason is DeferralReason.OUTSIDE_WINDOW

    def test_low_inventory_precedes_fail_open(self):
        decision = should_defer(_cand(), _ctx(listenable_count=0, availability=_avail(ok=False)), THRESHOLDS)
        assert decision.reason is DeferralReason.INVENTORY_LOW


# ---------------------------------------------------------------------------
# select_claimable: candidate-set global-None contract
# ---------------------------------------------------------------------------
class TestSelectClaimable:
    def test_empty_candidates_returns_none(self):
        assert select_claimable([], _ctx(), THRESHOLDS) is None

    def test_all_deferred_returns_none(self):
        # Three expensive-deferrable jobs, none claimable -> None means "nothing
        # claimable globally".
        cands = [_cand(job_id=i) for i in range(1, 4)]
        assert select_claimable(cands, _ctx(), THRESHOLDS) is None

    def test_first_n_deferrable_then_cheap_returns_cheap_not_none(self):
        # THE candidate-set property: N deferrable expensive jobs followed by a
        # claimable cheap job must return the cheap job, never None. A bounded
        # limit(N) window would wrongly stall here.
        cands = [
            _cand(job_id=1),
            _cand(job_id=2),
            _cand(job_id=3),
            _cand(kind=JobKind.CLASSIFY.value, job_id=4),  # non-expensive, runnable
        ]
        chosen = select_claimable(cands, _ctx(), THRESHOLDS)
        assert chosen is not None
        assert chosen.job_id == 4

    def test_returns_first_runnable_in_order(self):
        # Deferred expensive first, then a runnable expensive (priority bypass):
        # the runnable one is chosen, order preserved.
        cands = [
            _cand(job_id=1),  # deferred
            _cand(priority=10, job_id=2),  # runnable via priority bypass
            _cand(kind=JobKind.CLASSIFY.value, job_id=3),  # also runnable, but later
        ]
        chosen = select_claimable(cands, _ctx(), THRESHOLDS)
        assert chosen is not None
        assert chosen.job_id == 2

    def test_single_runnable_returned(self):
        cand = _cand(kind=JobKind.CLASSIFY.value, job_id=7)
        chosen = select_claimable([cand], _ctx(), THRESHOLDS)
        assert chosen is not None
        assert chosen.job_id == 7


# ---------------------------------------------------------------------------
# thresholds_from_settings factory (impure boundary, get_setting overrides)
# ---------------------------------------------------------------------------
class TestThresholdsFromSettings:
    def test_defaults_when_unset(self, monkeypatch):
        monkeypatch.setattr("wilted.db.get_setting", lambda key, default=None: None)
        assert thresholds_from_settings() == PolicyThresholds()

    def test_overrides_applied(self, monkeypatch):
        overrides = {
            "scheduling_interactive_priority_floor": "2",
            "scheduling_enough_inventory": "10",
            "scheduling_daytime_start_hour": "6",
            "scheduling_daytime_end_hour": "22",
            "scheduling_max_defer_hours": "24",
            "scheduling_idle_load_per_core": "0.4",
            "scheduling_idle_min_seconds": "600",
        }
        monkeypatch.setattr("wilted.db.get_setting", lambda key, default=None: overrides.get(key))
        result = thresholds_from_settings()
        assert result == PolicyThresholds(
            interactive_priority_floor=2,
            enough_inventory=10,
            daytime_start_hour=6,
            daytime_end_hour=22,
            max_defer_hours=24,
            idle_load_per_core=0.4,
            idle_min_seconds=600.0,
        )

    def test_malformed_setting_falls_back_to_default(self, monkeypatch):
        monkeypatch.setattr(
            "wilted.db.get_setting",
            lambda key, default=None: "not-a-number" if key == "scheduling_enough_inventory" else None,
        )
        result = thresholds_from_settings()
        assert result.enough_inventory == PolicyThresholds().enough_inventory


# ---------------------------------------------------------------------------
# summarize_claimable: pure fold over should_defer (M5 gate)
# ---------------------------------------------------------------------------
class TestSummarizeClaimable:
    def test_empty_candidates_returns_zeros(self):
        summary = summarize_claimable([], _ctx(), THRESHOLDS)
        assert summary.deferred_count == 0
        assert summary.claimable_now_count == 0
        assert dict(summary.by_reason) == {}
        # NOW (10:00) is inside the default [8, 20) window.
        assert summary.next_window_open_hour == THRESHOLDS.daytime_end_hour

    def test_mixed_queue_counts_each_reason_once(self):
        cands = [
            _cand(job_id=1),  # deferred: DAYTIME_BUSY
            _cand(job_id=2),  # deferred: DAYTIME_BUSY
            _cand(priority=5, job_id=3),  # PRIORITY_BYPASS
            _cand(kind=JobKind.CLASSIFY.value, job_id=4),  # NOT_EXPENSIVE
        ]
        summary = summarize_claimable(cands, _ctx(), THRESHOLDS)

        assert summary.deferred_count == 2
        assert summary.claimable_now_count == 2
        assert dict(summary.by_reason) == {
            DeferralReason.DAYTIME_BUSY: 2,
            DeferralReason.PRIORITY_BYPASS: 1,
            DeferralReason.NOT_EXPENSIVE: 1,
        }

    def test_by_reason_covers_every_candidate_exactly_once(self):
        cands = [_cand(job_id=i) for i in range(1, 6)]
        summary = summarize_claimable(cands, _ctx(), THRESHOLDS)
        assert sum(summary.by_reason.values()) == len(cands)

    def test_next_window_open_hour_none_outside_window(self):
        night = datetime(2026, 7, 25, 22, 0, tzinfo=UTC)
        summary = summarize_claimable([_cand(created_at=night - timedelta(hours=1))], _ctx(now=night), THRESHOLDS)
        assert summary.next_window_open_hour is None

    def test_next_window_open_hour_set_inside_window_even_with_no_candidates(self):
        # Purely clock-derived: no candidates at all, but still inside the window.
        summary = summarize_claimable([], _ctx(now=NOW), THRESHOLDS)
        assert summary.next_window_open_hour == THRESHOLDS.daytime_end_hour

    def test_all_deferred_matches_select_claimable_none(self):
        cands = [_cand(job_id=i) for i in range(1, 4)]
        summary = summarize_claimable(cands, _ctx(), THRESHOLDS)
        assert select_claimable(cands, _ctx(), THRESHOLDS) is None
        assert summary.deferred_count == 3
        assert summary.claimable_now_count == 0


# ---------------------------------------------------------------------------
# format_deferral_summary: pure text projection (M5)
# ---------------------------------------------------------------------------
class TestFormatDeferralSummary:
    def test_nothing_held_message(self):
        summary = DeferralSummary(deferred_count=0, claimable_now_count=4, by_reason={}, next_window_open_hour=None)
        assert format_deferral_summary(summary) == "no expensive jobs held"

    def test_held_with_window_hour_is_zero_padded(self):
        summary = DeferralSummary(
            deferred_count=3,
            claimable_now_count=1,
            by_reason={DeferralReason.DAYTIME_BUSY: 3},
            next_window_open_hour=20,
        )
        assert format_deferral_summary(summary) == "3 expensive jobs held until 20:00"

    def test_singular_job_noun(self):
        summary = DeferralSummary(
            deferred_count=1,
            claimable_now_count=0,
            by_reason={DeferralReason.DAYTIME_BUSY: 1},
            next_window_open_hour=8,
        )
        assert format_deferral_summary(summary) == "1 expensive job held until 08:00"

    def test_bypassed_reasons_appended(self):
        summary = DeferralSummary(
            deferred_count=2,
            claimable_now_count=3,
            by_reason={
                DeferralReason.DAYTIME_BUSY: 2,
                DeferralReason.PRIORITY_BYPASS: 1,
                DeferralReason.AGE_CEILING: 1,
                DeferralReason.MACHINE_IDLE: 1,
                DeferralReason.NOT_EXPENSIVE: 1,
            },
            next_window_open_hour=20,
        )
        text = format_deferral_summary(summary)
        assert (
            text
            == "2 expensive jobs held until 20:00; 1 bypassed (priority); 1 bypassed (age); 1 bypassed (idle machine)"
        )

    def test_held_with_no_window_hour_omits_until_clause(self):
        summary = DeferralSummary(
            deferred_count=1,
            claimable_now_count=0,
            by_reason={DeferralReason.DAYTIME_BUSY: 1},
            next_window_open_hour=None,
        )
        assert format_deferral_summary(summary) == "1 expensive job held"
