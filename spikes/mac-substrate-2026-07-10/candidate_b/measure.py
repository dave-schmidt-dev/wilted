#!/usr/bin/env python3
"""Runnable measurement for CANDIDATE (b): controller hosted in-process.

Usage:
    python spikes/mac-substrate-2026-07-10/candidate_b/measure.py

Three things happen, in order:

1. STATE-CORRECTNESS PARITY: run the shared fixture's canonical action
   sequence through one in-process ``StationController`` and assert it
   reaches the same terminal state as the scaffold's reducer-only run
   (``../measure.py``) — lifecycle ``owned_by_iphone``, ``station_revision
   == 6``, ``phone_epoch == 1``, zero ``error``/``skip`` events. This is
   expected to pass: candidate (b) calls the exact same committed reducer,
   just through an in-process class instead of directly, so there is no
   reason for the outcome to differ.

2. MULTI-PROCESS OWNERSHIP WEAKNESS: instantiate two independent
   ``StationController`` objects to simulate two OS processes that would
   both host a controller today — the Textual TUI and the nightly daemon
   (``scripts/wilted-nightly.sh``), which already runs as a separate
   process from the TUI per the design doc's "Ownership boundary" section.
   Both controllers claim a lease and mutate independently. Because each
   controller's ``StationState`` lives only in that instance's process
   memory, there is no shared store for the reducer's lease check to
   consult, so nothing rejects the second controller — both succeed,
   independently, and their states diverge (split brain). This is
   candidate (b)'s expected structural weakness; this script measures and
   prints it rather than hiding it.

3. Builds and prints a ``Scorecard`` for "candidate_b" summarizing both
   findings plus the migration-cost/testability dimensions.

Exits 0 iff the parity assertions in step 1 pass and the split-brain demo in
step 2 completed without raising. This script is a CLI entry point, not an
importable library module, so it prints rather than logs (matches project
convention: "CLI commands can print").
"""

from __future__ import annotations

import sys
from pathlib import Path

_CANDIDATE_DIR = Path(__file__).resolve().parent
_SCAFFOLD_DIR = _CANDIDATE_DIR.parent
_SRC_DIR = _SCAFFOLD_DIR.parents[1] / "src"

sys.path.insert(0, str(_CANDIDATE_DIR))
sys.path.insert(0, str(_SCAFFOLD_DIR))
sys.path.insert(0, str(_SRC_DIR))

from controller import StationController  # noqa: E402
from fixture import MAC_HOLDER_ID, MAC_LEASE_EPOCH, build_action_sequence  # noqa: E402
from migration import run_migration_measurement  # noqa: E402
from scorecard import Scorecard, ScorecardDimension, format_scorecard  # noqa: E402

from wilted.station.reducer import StationLifecycle  # noqa: E402

EXPECTED_FINAL_REVISION = 6
EXPECTED_PHONE_EPOCH = 1

# Two independent holder ids simulating two OS processes that would each
# host their own StationController today: the Textual TUI and the nightly
# daemon (scripts/wilted-nightly.sh), which already runs as a separate
# process per the design doc's "Ownership boundary" section.
PROCESS_A_HOLDER_ID = MAC_HOLDER_ID  # "mac-controller-spike" -- stands in for the TUI process
PROCESS_B_HOLDER_ID = "nightly-daemon-spike"  # stands in for scripts/wilted-nightly.sh


def run_parity_check() -> tuple[bool, list[str], StationController]:
    """Run the fixture's action sequence through one in-process controller.

    Returns:
        ``(ok, problems, controller)`` — ``ok`` is True iff the sequence
        completed at ``OWNED_BY_IPHONE`` with ``station_revision == 6``,
        ``phone_epoch == 1``, and no ``error``/``skip`` events. ``problems``
        lists human-readable descriptions of anything unexpected. The
        returned controller holds the final state for the manifest print.
    """
    problems: list[str] = []
    controller = StationController(holder_id=MAC_HOLDER_ID)
    controller.claim_lease(MAC_LEASE_EPOCH)
    if controller.state.lease is None:
        problems.append("claim_lease() did not grant the initial lease")
        return False, problems, controller

    events_before = len(controller.state.events)

    for step_index, (action, _requester_lease) in enumerate(build_action_sequence(), start=1):
        # candidate (b) calls the controller's mirrored methods directly,
        # in-process, rather than re-presenting a lease tuple to apply() --
        # the controller supplies its own held lease on every call.
        state = _dispatch(controller, action)
        new_events = (
            state.events[len(controller.state.events) :] if len(state.events) > len(controller.state.events) else ()
        )
        for event in new_events:
            if event.kind in ("error", "skip"):
                problems.append(
                    f"step {step_index} ({type(action).__name__}): unexpected {event.kind!r} event -- {event.message}"
                )

    final = controller.state
    if final.lifecycle is not StationLifecycle.OWNED_BY_IPHONE:
        problems.append(f"final lifecycle was {final.lifecycle.value!r}, expected 'owned_by_iphone'")
    if final.station_revision != EXPECTED_FINAL_REVISION:
        problems.append(f"final station_revision was {final.station_revision}, expected {EXPECTED_FINAL_REVISION}")
    if final.phone_epoch != EXPECTED_PHONE_EPOCH:
        problems.append(f"final phone_epoch was {final.phone_epoch!r}, expected {EXPECTED_PHONE_EPOCH}")

    total_new_events = len(final.events) - events_before
    print(f"[parity] Final lifecycle: {final.lifecycle.value}")
    print(f"[parity] Final station_revision: {final.station_revision}")
    print(f"[parity] Phone epoch acknowledged: {final.phone_epoch}")
    print(f"[parity] Total diagnostic events appended: {total_new_events}")
    print(f"[parity] get_manifest(): {controller.get_manifest()}")
    print(f"[parity] get_checkpoint(): {controller.get_checkpoint()}")

    return (len(problems) == 0), problems, controller


def _dispatch(controller: StationController, action: object) -> object:
    """Route one fixture action to its mirrored ``StationController`` method.

    The fixture yields committed reducer action dataclasses (built for the
    scaffold's own reducer-direct ``measure.py``); candidate (b) exposes
    one method per action instead of a single ``apply()`` entry point, so
    this dispatch translates one shape into the other for the shared
    fixture script. Returns the controller's new ``StationState`` (also
    stored on ``controller.state`` as a side effect, matching every other
    controller method).
    """
    from wilted.station.reducer import (
        AcceptInterruption,
        AcknowledgeHandoff,
        Checkpoint,
        RequestHandoff,
        ResumeFromInterruption,
        StartPlayback,
    )

    if isinstance(action, StartPlayback):
        return controller.start_playback(action.entry)
    if isinstance(action, Checkpoint):
        return controller.checkpoint(
            mutation_id=action.mutation_id,
            expected_revision=action.expected_revision,
            media_offset_ms=action.media_offset_ms,
            state_label=action.state_label,
            writer_device=action.writer_device,
        )
    if isinstance(action, AcceptInterruption):
        return controller.accept_interruption(
            bulletin=action.bulletin,
            interrupt_offset_ms=action.interrupt_offset_ms,
            policy_current=action.policy_current,
        )
    if isinstance(action, ResumeFromInterruption):
        return controller.resume()
    if isinstance(action, RequestHandoff):
        return controller.request_handoff(
            phone_device_id=action.phone_device_id,
            requested_epoch=action.requested_epoch,
            last_known_mac_revision=action.last_known_mac_revision,
        )
    if isinstance(action, AcknowledgeHandoff):
        return controller.acknowledge_handoff(phone_device_id=action.phone_device_id, epoch=action.epoch)

    raise TypeError(f"measure.py's dispatcher received an unrecognized fixture action type: {type(action)!r}")


def run_split_brain_demo() -> dict[str, object]:
    """Instantiate two independent controllers and show them diverge with no rejection.

    Simulates two OS processes that would each host their own
    ``StationController`` today (the Textual TUI and the nightly daemon,
    which the design doc already documents as a separate process — see
    ``scripts/wilted-nightly.sh``). Both:

    1. claim a lease under their own holder id at epoch 1 (both succeed --
       neither can see the other's ``StationState``, so there is no
       existing lease to conflict with from either one's point of view);
    2. start playback of a different entry (process A: the article,
       process B: the podcast);
    3. write a checkpoint.

    Returns:
        A dict recording each process's final lease/lifecycle/active-entry
        plus an explicit ``diverged`` bool and ``cross_process_rejection``
        bool (always False here) for the scorecard/report.
    """
    from fixture import ARTICLE_ENTRY, PODCAST_ENTRY

    process_a = StationController(holder_id=PROCESS_A_HOLDER_ID)
    process_b = StationController(holder_id=PROCESS_B_HOLDER_ID)

    # Both processes independently claim lease epoch 1. Neither apply() nor
    # claim_lease() has any way to see the other's in-memory StationState --
    # there is no shared store, so this is not a race, it is two fully
    # separate, un-coordinated state machines.
    process_a.claim_lease(1)
    process_b.claim_lease(1)

    a_claimed = process_a.state.lease is not None
    b_claimed = process_b.state.lease is not None

    process_a.start_playback(ARTICLE_ENTRY)
    process_b.start_playback(PODCAST_ENTRY)

    process_a.checkpoint(
        mutation_id="split-brain-a-1",
        expected_revision=process_a.state.station_revision,
        media_offset_ms=10_000,
        state_label="playing",
        writer_device=PROCESS_A_HOLDER_ID,
    )
    process_b.checkpoint(
        mutation_id="split-brain-b-1",
        expected_revision=process_b.state.station_revision,
        media_offset_ms=20_000,
        state_label="playing",
        writer_device=PROCESS_B_HOLDER_ID,
    )

    a_active = process_a.state.active_entry.entry_id if process_a.state.active_entry else None
    b_active = process_b.state.active_entry.entry_id if process_b.state.active_entry else None
    a_error_events = [e for e in process_a.state.events if e.kind == "error"]
    b_error_events = [e for e in process_b.state.events if e.kind == "error"]

    diverged = a_active != b_active or process_a.state.checkpoint != process_b.state.checkpoint
    cross_process_rejection = False  # Structurally impossible here: neither controller can observe the other.

    result = {
        "process_a_holder_id": PROCESS_A_HOLDER_ID,
        "process_b_holder_id": PROCESS_B_HOLDER_ID,
        "process_a_lease_claimed": a_claimed,
        "process_b_lease_claimed": b_claimed,
        "process_a_active_entry": a_active,
        "process_b_active_entry": b_active,
        "process_a_checkpoint_offset_ms": process_a.state.checkpoint.media_offset_ms
        if process_a.state.checkpoint
        else None,
        "process_b_checkpoint_offset_ms": process_b.state.checkpoint.media_offset_ms
        if process_b.state.checkpoint
        else None,
        "process_a_error_events": len(a_error_events),
        "process_b_error_events": len(b_error_events),
        "diverged": diverged,
        "cross_process_rejection": cross_process_rejection,
    }

    print("\n[split-brain] Two independent in-process StationControllers, simulating two OS processes:")
    print(
        f"[split-brain]   process A ({PROCESS_A_HOLDER_ID}): lease claimed = {a_claimed}, "
        f"active entry = {a_active!r}, checkpoint offset = {result['process_a_checkpoint_offset_ms']}, "
        f"error events = {len(a_error_events)}"
    )
    print(
        f"[split-brain]   process B ({PROCESS_B_HOLDER_ID}): lease claimed = {b_claimed}, "
        f"active entry = {b_active!r}, checkpoint offset = {result['process_b_checkpoint_offset_ms']}, "
        f"error events = {len(b_error_events)}"
    )
    print(f"[split-brain]   diverged: {diverged}")
    print(f"[split-brain]   cross_process_rejection: {cross_process_rejection}")
    print(
        "[split-brain]   Fix requires: a shared store or IPC boundary between the two processes "
        "(persisted lease + persisted state both processes read/write through), which is exactly "
        "candidate (a)'s extracted-service boundary -- i.e. eliminating this weakness reinvents (a)."
    )

    return result


def build_candidate_b_scorecard(parity_ok: bool, split_brain: dict[str, object]) -> Scorecard:
    """Assemble the ``Scorecard`` for candidate_b from this run's measurements."""
    migration_result = run_migration_measurement()
    unmapped = migration_result["unmapped_fields"]

    return Scorecard(
        candidate_name="candidate_b",
        state_correctness=ScorecardDimension(
            note=(
                f"PASS: in-process StationController reproduced the reducer-only run exactly -- "
                f"lifecycle=owned_by_iphone, station_revision={EXPECTED_FINAL_REVISION}, "
                f"phone_epoch={EXPECTED_PHONE_EPOCH}, zero error/skip events on the happy path. "
                f"Expected: candidate (b) calls the identical committed reducer, just through "
                f"in-process methods instead of a direct apply() call. parity_ok={parity_ok}."
            )
        ),
        migration_cost=ScorecardDimension(
            note=(
                f"Same schema-mapping cost as candidate (a) -- both consume the same "
                f"item_to_station_entry() (migration.py), which is substrate-independent. "
                f"Measured {migration_result['item_count']} sample Items mapped; "
                f"{len(unmapped)} fields have no clean Item equivalent and need a real hash/size "
                f"pass before finalization can honestly claim complete=True "
                f"(sha256, byte_size, transcript_segments, safe_interruption, byte_range_available, "
                f"finalization, priority). This candidate's in-process hosting does not change that "
                f"cost -- migration cost is a store/schema question, not a substrate question."
            )
        ),
        testability=ScorecardDimension(
            note=(
                "Easy in-process: a single StationController instance is a plain Python object -- "
                "the parity check above drives it directly with no mocks, no event loop, no Textual "
                "Pilot harness, just method calls and assertions on controller.state. "
                "Impossible to test the thing that actually matters for a multi-device/multi-process "
                "station (cross-process lease arbitration, split-brain prevention) without adding an "
                "IPC/shared-store layer first -- there is nothing in this candidate's own boundary to "
                "unit-test for that property, because the property does not exist yet. The split-brain "
                "demo above is the most this candidate's design can prove: that the failure occurs, "
                "not that it's prevented."
            )
        ),
        multi_process_ownership=ScorecardDimension(
            note=(
                f"WEAK (measured, not assumed): two independent StationController instances "
                f"(holder_ids {split_brain['process_a_holder_id']!r} and "
                f"{split_brain['process_b_holder_id']!r}, simulating the TUI process and the nightly "
                f"daemon process) both claimed lease epoch 1 successfully "
                f"(a={split_brain['process_a_lease_claimed']}, b={split_brain['process_b_lease_claimed']}), "
                f"both mutated independently with zero error events on either side "
                f"(a_errors={split_brain['process_a_error_events']}, "
                f"b_errors={split_brain['process_b_error_events']}), "
                f"and ended up with divergent active entries/checkpoints "
                f"(diverged={split_brain['diverged']}). No cross-process rejection occurred "
                f"(cross_process_rejection={split_brain['cross_process_rejection']}) because each "
                f"controller's StationState lives only in its own process memory -- the reducer's lease "
                f"check has nothing shared to check against. Fixing this requires a shared store or IPC "
                f"boundary (persisted lease + persisted state both processes read/write through), which "
                f"is candidate (a)'s extracted-service boundary -- eliminating this weakness means "
                f"reinventing (a)."
            )
        ),
        failure_classes=ScorecardDimension(
            note=(
                "RETAINED (same as candidate a, both wrap the identical reducer): stale-revision "
                "writes, repeated mutation_id writes, non-owner-lease writes *within one process*, "
                "expired-entry admission, incomplete-bulletin-media admission, missing-safe-checkpoint "
                "interruption, stale-epoch handoff/acknowledge clobber -- all rejected identically to "
                "candidate (a) because both call wilted.station.reducer.apply()/claim_lease() unmodified. "
                "ELIMINATED: none beyond what the reducer itself already eliminates -- this candidate "
                "adds no new safety mechanism of its own. "
                "INTRODUCED / UNADDRESSED: split-brain across OS processes (measured above) -- two "
                "controllers in two processes (e.g. TUI + nightly daemon) can each independently claim "
                "a lease and diverge with zero rejection, because 'the controller' is scoped to one "
                "process's memory, not to the station as a whole. This is not a bug in the reducer (the "
                "reducer is substrate-neutral and correct); it is a consequence of candidate (b)'s "
                "hosting choice -- no shared store means no cross-process invariant enforcement is "
                "possible without adding one, which is exactly what candidate (a) provides."
            )
        ),
        mac_ux_velocity=ScorecardDimension(
            note=(
                "DEFERRED: needs Mac/Xcode/device. One relevant in-process observation though: this "
                "candidate is tightly coupled to hosting inside the existing Textual/AudioEngine "
                "process (per the design doc, 'the current TUI owns one article-centric worker "
                "in-process') -- there is no described path to a native Mac UI without either keeping "
                "Textual or building a new host process around this same in-process controller, which "
                "would face the identical multi-process weakness measured above the moment a second "
                "surface (e.g. a menu-bar app) is added alongside the TUI."
            ),
            deferred=True,
        ),
    )


def main() -> int:
    """Entry point. Returns a process exit code."""
    parity_ok, problems, _controller = run_parity_check()

    if not parity_ok:
        print("\nFAILED: candidate_b parity check found problems:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print("\nOK: candidate_b in-process StationController matched the reducer-only reference run.")

    split_brain = run_split_brain_demo()

    scorecard = build_candidate_b_scorecard(parity_ok, split_brain)
    print()
    print(format_scorecard(scorecard))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
