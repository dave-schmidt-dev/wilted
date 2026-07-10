#!/usr/bin/env python3
"""Runnable smoke check for the Task 0.3 substrate spike's shared fixture.

Runs ``fixture.build_action_sequence()`` through the committed reducer
(``wilted.station.reducer.apply`` / ``claim_lease``) directly — no
candidate substrate involved yet. This proves the fixture itself is valid
(the safe-interruption offset really is safe, the handoff sequence really
reaches ``OWNED_BY_IPHONE``, nothing in the happy path is rejected) before
either candidate spike consumes it.

Usage:
    python spikes/mac-substrate-2026-07-10/measure.py

Exits 0 and prints the final lifecycle plus a rejection-free confirmation
on success. Exits 1 with a diagnostic on any unexpected rejection or wrong
final state. This script is a CLI entry point, not an importable library
module, so it prints rather than logs (matches project convention: "CLI
commands can print").
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))

from fixture import MAC_HOLDER_ID, MAC_LEASE_EPOCH, build_action_sequence  # noqa: E402

from wilted.station.models import ControllerLease  # noqa: E402
from wilted.station.reducer import StationLifecycle, StationState, apply, claim_lease  # noqa: E402


def run_fixture_smoke_check() -> tuple[bool, list[str]]:
    """Apply the fixture's canonical action sequence through the reducer.

    Returns:
        ``(ok, problems)`` — ``ok`` is True iff the sequence completed with
        lifecycle ``OWNED_BY_IPHONE`` and no ``error``/rejection-kind events
        were appended along the way. ``problems`` lists human-readable
        descriptions of anything unexpected, empty when ``ok`` is True.
    """
    problems: list[str] = []

    state = StationState()
    state = claim_lease(state, MAC_HOLDER_ID, MAC_LEASE_EPOCH)
    if state.lease is None:
        problems.append("claim_lease() did not grant the initial lease")
        return False, problems

    events_before_actions = len(state.events)

    for step_index, (action, (holder_id, epoch)) in enumerate(build_action_sequence(), start=1):
        requester_lease = ControllerLease(holder_id=holder_id, epoch=epoch)
        new_state = apply(state, action, requester_lease)

        new_events = new_state.events[len(state.events) :]
        for event in new_events:
            if event.kind in ("error", "skip"):
                problems.append(
                    f"step {step_index} ({type(action).__name__}): unexpected {event.kind!r} event -- {event.message}"
                )
        state = new_state

    if state.lifecycle is not StationLifecycle.OWNED_BY_IPHONE:
        problems.append(f"final lifecycle was {state.lifecycle.value!r}, expected 'owned_by_iphone'")

    total_new_events = len(state.events) - events_before_actions
    print(f"Final lifecycle: {state.lifecycle.value}")
    print(f"Final station_revision: {state.station_revision}")
    print(f"Phone epoch acknowledged: {state.phone_epoch}")
    print(f"Total diagnostic events appended: {total_new_events}")

    return (len(problems) == 0), problems


def main() -> int:
    """Entry point. Returns a process exit code."""
    ok, problems = run_fixture_smoke_check()

    if ok:
        print("\nOK: fixture action sequence completed with no happy-path rejections.")
        return 0

    print("\nFAILED: fixture smoke check found problems:", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
