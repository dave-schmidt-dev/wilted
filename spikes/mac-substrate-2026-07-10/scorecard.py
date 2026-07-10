"""Comparison scorecard structure for the Task 0.3 substrate spike.

A small, dependency-free data structure the two candidate spikes fill in
and this module pretty-prints. Dimensions mirror the design doc's decision
framework ("The decision phase evaluates station correctness, iPhone
handoff, local-first privacy, ML lifecycle safety, native Mac/iPhone UX
velocity, migration cost, and testability. Its ADR must identify the
failure classes each option retains, eliminates, and introduces...").

Three dimensions are marked DEFERRED here because they require hardware/
tooling this shared scaffold does not have access to (a real Mac audio
route, Xcode/device build, sleep/wake testing): ``mac_ux_velocity``,
``audio_route_recovery``, ``awake_sleep_availability``. Candidates fill in
the rest from what they can actually measure against the fixture.
"""

from __future__ import annotations

from dataclasses import dataclass, field

DEFERRED_NOTE = "DEFERRED: needs Mac/Xcode/device"


@dataclass(frozen=True, slots=True)
class ScorecardDimension:
    """One measured (or deferred) dimension of a candidate's evaluation.

    Attributes:
        note: Short measured/deferred note — what was actually observed,
            or ``DEFERRED_NOTE`` verbatim if this dimension could not be
            measured in this environment.
        deferred: True if this dimension was not measured (hardware/tooling
            gap) rather than genuinely evaluated.
    """

    note: str
    deferred: bool = False


@dataclass(frozen=True, slots=True)
class Scorecard:
    """Comparison scorecard for one substrate candidate.

    Attributes:
        candidate_name: Short identifying label for the candidate (e.g.
            ``"candidate-a-python-extraction"``).
        state_correctness: Did the candidate execute the fixture's action
            sequence with the reducer's expected transitions/rejections?
        mac_ux_velocity: DEFERRED placeholder — needs a Mac UI build.
        migration_cost: Measured cost of mapping ``Item`` -> station types
            (see ``migration.py``).
        testability: How easily the candidate's boundary can be driven by
            automated tests (Pilot/snapshot/unit) without manual steps.
        audio_route_recovery: DEFERRED placeholder — needs real audio
            device route-change testing.
        awake_sleep_availability: DEFERRED placeholder — needs sleep/wake
            testing on real hardware.
        multi_process_ownership: How the candidate enforces the single-
            controller-lease invariant across process/device boundaries.
        failure_classes: Free-text summary of failure classes the
            candidate's boundary design retains, eliminates, or introduces
            (per the design doc's ADR requirement).
    """

    candidate_name: str
    state_correctness: ScorecardDimension
    mac_ux_velocity: ScorecardDimension = field(
        default_factory=lambda: ScorecardDimension(note=DEFERRED_NOTE, deferred=True)
    )
    migration_cost: ScorecardDimension = field(default_factory=lambda: ScorecardDimension(note=""))
    testability: ScorecardDimension = field(default_factory=lambda: ScorecardDimension(note=""))
    audio_route_recovery: ScorecardDimension = field(
        default_factory=lambda: ScorecardDimension(note=DEFERRED_NOTE, deferred=True)
    )
    awake_sleep_availability: ScorecardDimension = field(
        default_factory=lambda: ScorecardDimension(note=DEFERRED_NOTE, deferred=True)
    )
    multi_process_ownership: ScorecardDimension = field(default_factory=lambda: ScorecardDimension(note=""))
    failure_classes: ScorecardDimension = field(default_factory=lambda: ScorecardDimension(note=""))

    def dimensions(self) -> dict[str, ScorecardDimension]:
        """Return all scorecard dimensions keyed by field name, in report order."""
        return {
            "state_correctness": self.state_correctness,
            "mac_ux_velocity": self.mac_ux_velocity,
            "migration_cost": self.migration_cost,
            "testability": self.testability,
            "audio_route_recovery": self.audio_route_recovery,
            "awake_sleep_availability": self.awake_sleep_availability,
            "multi_process_ownership": self.multi_process_ownership,
            "failure_classes": self.failure_classes,
        }


def format_scorecard(scorecard: Scorecard) -> str:
    """Pretty-print ``scorecard`` as a readable, fixed-width text table.

    Args:
        scorecard: The scorecard to render.

    Returns:
        A multi-line string suitable for printing to stdout or embedding in
        a report.
    """
    lines = [f"Scorecard: {scorecard.candidate_name}", "-" * (12 + len(scorecard.candidate_name))]
    for dim_name, dim in scorecard.dimensions().items():
        marker = " [DEFERRED]" if dim.deferred else ""
        lines.append(f"  {dim_name:28s}{marker}")
        note = dim.note or "(no note recorded)"
        lines.append(f"      {note}")
    return "\n".join(lines)


def format_comparison(scorecards: list[Scorecard]) -> str:
    """Pretty-print multiple scorecards side by side for a quick diff read.

    Args:
        scorecards: Scorecards to compare, in display order.

    Returns:
        A multi-line string with one section per dimension, each showing
        every candidate's note for that dimension.
    """
    if not scorecards:
        return "(no scorecards to compare)"

    dim_names = list(scorecards[0].dimensions().keys())
    lines = ["Substrate spike comparison", "=" * 27]
    for dim_name in dim_names:
        lines.append(f"\n{dim_name}:")
        for card in scorecards:
            dim = card.dimensions()[dim_name]
            marker = " [DEFERRED]" if dim.deferred else ""
            note = dim.note or "(no note recorded)"
            lines.append(f"  - {card.candidate_name}{marker}: {note}")
    return "\n".join(lines)


__all__ = [
    "DEFERRED_NOTE",
    "Scorecard",
    "ScorecardDimension",
    "format_comparison",
    "format_scorecard",
]
