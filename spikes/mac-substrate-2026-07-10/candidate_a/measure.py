#!/usr/bin/env python3
"""Runnable measurement for substrate-spike candidate (a).

Candidate (a): "extracted headless core with a native-client boundary."
``StationCore`` (see ``core.py``) owns the authoritative
``wilted.station.reducer.StationState`` and exposes only a versioned,
JSON-serializable manifest/checkpoint boundary plus idempotent mutation
commands — no client, present or future (Textual today, a native macOS/iOS
client later), ever touches ``StationState``, the reducer, or any station
value object directly.

This script measures four things for the comparative scorecard:

1. STATE-CORRECTNESS PARITY — runs the shared fixture's canonical action
   sequence through the core and asserts the same final state the shared
   scaffold's reducer-only ``measure.py`` observed: lifecycle
   ``owned_by_iphone``, ``station_revision == 6``, ``phone_epoch == 1``,
   zero ``error``/``skip`` events on the happy path.
2. MULTI-PROCESS OWNERSHIP — candidate (a)'s expected strength. Two client
   identities against one core: the lease holder can mutate; a second,
   non-owner client's mutation is rejected (owner-loss); a monotonic lease
   handoff lets the second client take over, after which the first is
   fenced out.
3. JSON BOUNDARY — confirms the manifest and checkpoint survive a
   ``json.dumps``/``json.loads`` round-trip unchanged.
4. MIGRATION COST — runs the shared scaffold's ``migration.py`` measurement
   (a real hash/size pass, same tool both candidates use) and reports it.

Usage:
    python spikes/mac-substrate-2026-07-10/candidate_a/measure.py

Exits 0 on success (all parity/ownership/round-trip checks pass), 1 with a
diagnostic otherwise. This is a spike CLI entry point, not an importable
library module, so it prints rather than logs.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

_CANDIDATE_DIR = Path(__file__).resolve().parent
_SCAFFOLD_DIR = _CANDIDATE_DIR.parent
_SRC_DIR = _SCAFFOLD_DIR.parents[1] / "src"
for _path in (_CANDIDATE_DIR, _SCAFFOLD_DIR, _SRC_DIR):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from core import CommandRejected, InProcessClient, StationCore  # noqa: E402
from fixture import (  # noqa: E402
    MAC_HOLDER_ID,
    MAC_LEASE_EPOCH,
    build_action_sequence,
)
from migration import run_migration_measurement  # noqa: E402
from scorecard import Scorecard, ScorecardDimension, format_scorecard  # noqa: E402

from wilted.station.reducer import (  # noqa: E402
    AcceptInterruption,
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    ResumeFromInterruption,
    StartPlayback,
)

EXPECTED_FINAL_REVISION = 6
EXPECTED_PHONE_EPOCH = 1


# ---------------------------------------------------------------------------
# 1. State-correctness parity: drive the core through the shared fixture.
# ---------------------------------------------------------------------------


def run_parity_check() -> tuple[bool, list[str], StationCore]:
    """Run the fixture's canonical action sequence through ``StationCore``.

    Returns:
        ``(ok, problems, core)`` — ``ok`` is True iff the sequence completed
        with the same final state the scaffold's reducer-only ``measure.py``
        observed (lifecycle ``owned_by_iphone``, revision 6, phone_epoch 1,
        no error/skip events). ``core`` is returned so the caller can reuse
        its final manifest for the JSON round-trip check.
    """
    problems: list[str] = []
    core = StationCore()

    manifest = core.claim_lease(MAC_HOLDER_ID, MAC_LEASE_EPOCH)
    if manifest["lease"] is None:
        problems.append("claim_lease() did not grant the initial lease")
        return False, problems, core

    events_before = manifest["event_count"]

    # Translate the fixture's (action, lease) pairs into StationCore command
    # calls. This mirrors exactly what a real client boundary would do:
    # unpack a known action shape into a command call, never touching the
    # reducer/StationState directly.
    for step_index, (action, (holder_id, epoch)) in enumerate(build_action_sequence(), start=1):
        if isinstance(action, StartPlayback):
            manifest = core.start_playback(action.entry, holder_id, epoch)
        elif isinstance(action, Checkpoint):
            manifest = core.submit_checkpoint(
                mutation_id=action.mutation_id,
                expected_revision=action.expected_revision,
                media_offset_ms=action.media_offset_ms,
                state_label=action.state_label,
                writer_device=action.writer_device,
                holder_id=holder_id,
                epoch=epoch,
            )
        elif isinstance(action, AcceptInterruption):
            manifest = core.accept_interruption(
                bulletin=action.bulletin,
                interrupt_offset_ms=action.interrupt_offset_ms,
                policy_current=action.policy_current,
                holder_id=holder_id,
                epoch=epoch,
            )
        elif isinstance(action, ResumeFromInterruption):
            manifest = core.resume(holder_id, epoch)
        elif isinstance(action, RequestHandoff):
            manifest = core.request_handoff(
                phone_device_id=action.phone_device_id,
                requested_epoch=action.requested_epoch,
                last_known_mac_revision=action.last_known_mac_revision,
                holder_id=holder_id,
                epoch=epoch,
            )
        elif isinstance(action, AcknowledgeHandoff):
            manifest = core.acknowledge_handoff(
                phone_device_id=action.phone_device_id,
                epoch=action.epoch,
                holder_id=holder_id,
                requester_epoch=epoch,
            )
        else:
            problems.append(f"step {step_index}: unrecognized action type {type(action).__name__}")
            continue

        new_events = core.recent_events(limit=manifest["event_count"] - events_before)
        for event in new_events:
            if event["kind"] in ("error", "skip"):
                problems.append(
                    f"step {step_index} ({type(action).__name__}): unexpected {event['kind']!r} event -- "
                    f"{event['message']}"
                )
        events_before = manifest["event_count"]

    if manifest["lifecycle"] != "owned_by_iphone":
        problems.append(f"final lifecycle was {manifest['lifecycle']!r}, expected 'owned_by_iphone'")
    if manifest["station_revision"] != EXPECTED_FINAL_REVISION:
        problems.append(
            f"final station_revision was {manifest['station_revision']}, expected {EXPECTED_FINAL_REVISION}"
        )
    if manifest["phone_epoch"] != EXPECTED_PHONE_EPOCH:
        problems.append(f"final phone_epoch was {manifest['phone_epoch']!r}, expected {EXPECTED_PHONE_EPOCH}")

    print(f"[parity] final lifecycle: {manifest['lifecycle']}")
    print(f"[parity] final station_revision: {manifest['station_revision']}")
    print(f"[parity] phone_epoch acknowledged: {manifest['phone_epoch']}")
    print(f"[parity] total diagnostic events appended: {manifest['event_count'] - 0}")

    return (len(problems) == 0), problems, core


# ---------------------------------------------------------------------------
# 2. Multi-process ownership: two client identities, one core.
# ---------------------------------------------------------------------------


def run_multi_process_ownership_demo() -> tuple[bool, list[str], dict[str, object]]:
    """Demonstrate owner-mutates / non-owner-rejected / handoff-then-fence.

    Builds one fresh ``StationCore`` and two ``InProcessClient`` identities
    against it (simulating two separate processes/devices that each only
    ever see JSON manifest bytes and submit command dicts). Walks through:

    1. Client A claims the lease (epoch 1) and starts playback -- accepted.
    2. Client B (non-owner, no lease) attempts a checkpoint -- REJECTED
       (owner-loss error event, station_revision unchanged).
    3. Client B claims the lease at a strictly higher epoch (2) -- accepted
       per the reducer's fencing-token rule.
    4. Client A (now fenced out, presenting the stale epoch-1 lease)
       attempts a checkpoint -- REJECTED (owner-loss, same as step 2).
    5. Client B, now the legitimate holder, writes a checkpoint --
       accepted.

    Returns:
        ``(ok, problems, observations)`` — ``observations`` is a plain dict
        of what was actually observed at each step, printed by ``main()``
        and folded into the scorecard's ``multi_process_ownership`` note.
    """
    problems: list[str] = []
    observations: dict[str, object] = {}

    core = StationCore()
    client_a = InProcessClient(core, holder_id="process-a")
    client_b = InProcessClient(core, holder_id="process-b")

    # Step 1: A claims the lease and starts playback.
    manifest = client_a.submit_command("claim_lease", epoch=1)
    if manifest["lease"] != {"holder_id": "process-a", "epoch": 1}:
        problems.append(f"step1: client A did not obtain the lease, got {manifest['lease']!r}")

    from fixture import ARTICLE_ENTRY  # local import: keep fixture entries out of the top-level namespace

    manifest = client_a.submit_command("start_playback", entry=ARTICLE_ENTRY, epoch=1)
    revision_after_a_start = manifest["station_revision"]
    observations["step1_owner_start_playback"] = {
        "actor": "process-a",
        "accepted": manifest["lifecycle"] == "playing",
        "lifecycle": manifest["lifecycle"],
        "station_revision": revision_after_a_start,
    }
    if manifest["lifecycle"] != "playing":
        problems.append(f"step1: client A's start_playback did not reach 'playing', got {manifest['lifecycle']!r}")

    # Step 2: B (non-owner, never claimed a lease) attempts to mutate.
    manifest_before = core.get_manifest()
    try:
        manifest = client_b.submit_command(
            "submit_checkpoint",
            mutation_id="rogue-ckpt-1",
            expected_revision=revision_after_a_start,
            media_offset_ms=1000,
            state_label="playing",
            writer_device="process-b",
            epoch=1,
        )
    except CommandRejected as exc:  # pragma: no cover -- not expected on a well-formed command
        problems.append(f"step2: client B's command dict was rejected as malformed, unexpectedly: {exc}")
        manifest = manifest_before

    non_owner_rejected = manifest["station_revision"] == manifest_before["station_revision"]
    rejection_event = manifest["last_event"]
    observations["step2_non_owner_mutation_rejected"] = {
        "actor": "process-b",
        "revision_unchanged": non_owner_rejected,
        "last_event_kind": rejection_event["kind"] if rejection_event else None,
        "last_event_message": rejection_event["message"] if rejection_event else None,
    }
    if not non_owner_rejected:
        problems.append(
            f"step2: client B (non-owner) mutation was NOT rejected -- revision moved from "
            f"{manifest_before['station_revision']} to {manifest['station_revision']}"
        )
    if rejection_event is None or rejection_event["kind"] != "error" or "owner-loss" not in rejection_event["message"]:
        problems.append(f"step2: expected an owner-loss error event, got {rejection_event!r}")

    # Step 3: B claims the lease at a strictly higher epoch -- monotonic handoff.
    manifest = client_b.submit_command("claim_lease", epoch=2)
    handoff_accepted = manifest["lease"] == {"holder_id": "process-b", "epoch": 2}
    observations["step3_monotonic_handoff"] = {
        "actor": "process-b",
        "accepted": handoff_accepted,
        "new_lease": manifest["lease"],
    }
    if not handoff_accepted:
        problems.append(f"step3: client B's lease claim at epoch 2 did not take effect, got {manifest['lease']!r}")

    # Step 4: A, now fenced out (presents the stale epoch-1 lease), attempts to mutate.
    manifest_before = core.get_manifest()
    manifest = client_a.submit_command(
        "submit_checkpoint",
        mutation_id="stale-ckpt-1",
        expected_revision=manifest_before["station_revision"],
        media_offset_ms=2000,
        state_label="playing",
        writer_device="process-a",
        epoch=1,  # A's original epoch -- now stale.
    )
    a_fenced_out = manifest["station_revision"] == manifest_before["station_revision"]
    fence_event = manifest["last_event"]
    observations["step4_former_owner_fenced_out"] = {
        "actor": "process-a",
        "revision_unchanged": a_fenced_out,
        "last_event_kind": fence_event["kind"] if fence_event else None,
        "last_event_message": fence_event["message"] if fence_event else None,
    }
    if not a_fenced_out:
        problems.append("step4: client A (fenced-out former owner) was able to mutate after B's takeover")
    if fence_event is None or fence_event["kind"] != "error" or "owner-loss" not in fence_event["message"]:
        problems.append(f"step4: expected an owner-loss error event fencing out A, got {fence_event!r}")

    # Step 5: B, the legitimate new holder, writes a checkpoint successfully.
    manifest = client_b.submit_command(
        "submit_checkpoint",
        mutation_id="legit-ckpt-1",
        expected_revision=manifest["station_revision"],
        media_offset_ms=3000,
        state_label="playing",
        writer_device="process-b",
        epoch=2,
    )
    new_owner_can_mutate = manifest["checkpoint"] is not None and manifest["checkpoint"]["media_offset_ms"] == 3000
    observations["step5_new_owner_mutates_successfully"] = {
        "actor": "process-b",
        "accepted": new_owner_can_mutate,
        "checkpoint": manifest["checkpoint"],
    }
    if not new_owner_can_mutate:
        problems.append(f"step5: client B's post-handoff checkpoint did not apply, got {manifest['checkpoint']!r}")

    return (len(problems) == 0), problems, observations


# ---------------------------------------------------------------------------
# 3. JSON boundary round-trip.
# ---------------------------------------------------------------------------


def run_json_roundtrip_check(core: StationCore) -> tuple[bool, list[str]]:
    """Confirm the manifest and checkpoint survive ``json.dumps``/``json.loads``.

    Args:
        core: A ``StationCore`` with state already advanced (reused from the
            parity check so the checkpoint is non-None).

    Returns:
        ``(ok, problems)``.
    """
    problems: list[str] = []

    manifest = core.get_manifest()
    try:
        manifest_json = json.dumps(manifest)
    except TypeError as exc:
        problems.append(f"manifest is not JSON-serializable: {exc}")
        return False, problems
    manifest_roundtripped = json.loads(manifest_json)
    if manifest_roundtripped != manifest:
        problems.append("manifest changed shape across a json.dumps/json.loads round-trip")

    checkpoint = core.get_checkpoint()
    try:
        checkpoint_json = json.dumps(checkpoint)
    except TypeError as exc:
        problems.append(f"checkpoint is not JSON-serializable: {exc}")
        return False, problems
    checkpoint_roundtripped = json.loads(checkpoint_json)
    if checkpoint_roundtripped != checkpoint:
        problems.append("checkpoint changed shape across a json.dumps/json.loads round-trip")

    print(f"[json] manifest round-trip bytes: {len(manifest_json)}")
    print(f"[json] checkpoint round-trip bytes: {len(checkpoint_json) if checkpoint is not None else 0}")

    return (len(problems) == 0), problems


# ---------------------------------------------------------------------------
# 4. Migration cost (shared tool, same measurement both candidates use).
# ---------------------------------------------------------------------------


def run_migration_cost_measurement() -> dict[str, object]:
    """Run the shared scaffold's ``migration.py`` measurement and time it.

    Returns:
        Dict with ``item_count``, ``unmapped_field_count``, and
        ``elapsed_seconds`` for the scorecard note.
    """
    start = time.monotonic()
    result = run_migration_measurement()
    elapsed = time.monotonic() - start
    return {
        "item_count": result["item_count"],
        "unmapped_field_count": len(result["unmapped_fields"]),
        "unmapped_fields": result["unmapped_fields"],
        "elapsed_seconds": elapsed,
    }


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def main() -> int:  # noqa: C901 -- orchestration entry point, not library logic
    """Entry point. Returns a process exit code."""
    all_problems: list[str] = []

    print("=== 1. State-correctness parity ===")
    parity_ok, parity_problems, core = run_parity_check()
    all_problems.extend(parity_problems)
    print("OK" if parity_ok else "FAILED", "\n")

    print("=== 2. Multi-process ownership demonstration ===")
    ownership_ok, ownership_problems, observations = run_multi_process_ownership_demo()
    all_problems.extend(ownership_problems)
    for step_name, detail in observations.items():
        print(f"  {step_name}: {detail}")
    print("OK" if ownership_ok else "FAILED", "\n")

    print("=== 3. JSON boundary round-trip ===")
    json_ok, json_problems = run_json_roundtrip_check(core)
    all_problems.extend(json_problems)
    print("OK" if json_ok else "FAILED", "\n")

    print("=== 4. Migration cost (shared migration.py) ===")
    migration_stats = run_migration_cost_measurement()
    print(f"  item_count: {migration_stats['item_count']}")
    print(f"  unmapped_field_count: {migration_stats['unmapped_field_count']}")
    print(f"  elapsed_seconds: {migration_stats['elapsed_seconds']:.4f}")
    print()

    # -- Build and print the scorecard ---------------------------------------

    scorecard = Scorecard(
        candidate_name="candidate_a",
        state_correctness=ScorecardDimension(
            note=(
                f"Parity with reducer-only baseline: lifecycle=owned_by_iphone, revision=6, "
                f"phone_epoch=1, 0 error/skip events, driven entirely through StationCore command "
                f"methods (never touched StationState directly). "
                f"{'PASS' if parity_ok else 'FAIL: ' + '; '.join(parity_problems)}"
            )
        ),
        migration_cost=ScorecardDimension(
            note=(
                f"Ran shared migration.py's real Item->StationEntry mapping unmodified: "
                f"{migration_stats['item_count']} items mapped, "
                f"{migration_stats['unmapped_field_count']} fields with no clean Item equivalent "
                f"(sha256, byte_size, transcript_segments, safe_interruption, byte_range_available, "
                f"finalization, priority), {migration_stats['elapsed_seconds']:.4f}s. Identical cost to "
                f"candidate b since both call the same unmodified migration.py -- the boundary choice "
                f"does not change migration cost, only how the mapped StationEntry then enters state."
            )
        ),
        testability=ScorecardDimension(
            note=(
                "StationCore is driven entirely through plain-JSON-in/JSON-out command methods with "
                "no UI, no Textual Pilot, no event loop -- every assertion in this measure.py is a "
                "synchronous dict comparison. InProcessClient proves the same commands are drivable "
                "through a pure bytes-in/bytes-out boundary, which is what a native-client contract "
                "test or a Swift-side integration test would exercise without any Python runtime "
                "present. Friction: none encountered -- the committed reducer's rejection-vs-exception "
                "convention (return state unchanged + event, don't raise) mapped directly onto "
                "command-methods returning a manifest dict either way, so no exception-based control "
                "flow had to be invented for the boundary."
            )
        ),
        multi_process_ownership=ScorecardDimension(
            note=(
                "Two independent client identities (InProcessClient instances, each with its own "
                "holder_id) against one StationCore: owner mutates successfully (station_revision "
                "advances); non-owner's submit_checkpoint is rejected outright (revision unchanged, "
                "owner-loss error event) without the core needing any extra ownership logic beyond "
                "what the committed reducer already enforces; a monotonic lease claim at a higher "
                "epoch hands ownership to the second client; the original holder, now presenting a "
                "stale epoch, is fenced out identically to the never-owned case. This is the candidate's "
                "expected strength: the lease/fencing invariant lives once in the reducer and the core "
                "adds zero new ownership rules -- multi-client correctness falls out of the boundary "
                "for free." + (" ALL STEPS PASSED." if ownership_ok else " FAILED: " + "; ".join(ownership_problems))
            )
        ),
        failure_classes=ScorecardDimension(
            note=(
                "RETAINED: every failure class the committed reducer already defines (owner-loss, "
                "stale revision, stale/repeated mutation id, expired entry, incomplete bulletin media, "
                "missing safe checkpoint, stale phone/Mac epoch) is unchanged -- the core adds a "
                "pass-through, not a reinterpretation. ELIMINATED vs. today's in-process Textual worker: "
                "UI-thread-couples-to-playback-state class of bug (a screen widget cannot accidentally "
                "read/write StationState fields directly, since only JSON dicts cross the boundary); "
                "'forgot to route podcast through the right adapter' class of bug is structurally harder "
                "to reintroduce because the client only ever sees an opaque entry_id + media summary, "
                "not a workflow-specific code path per content type. INTRODUCED: a new serialization-drift "
                "failure class -- if get_manifest()'s dict shape changes without bumping "
                "MANIFEST_SCHEMA_VERSION, an older native client silently misreads a newer manifest (this "
                "spike defends against it with a version field but does not yet enforce/reject on mismatch); "
                "also a new synchronization-latency failure class once a client boundary is remote/async "
                "instead of in-process (a manifest a client is acting on can be staler than what "
                "InProcessClient sees, though the mutation_id/expected_revision fields exist precisely "
                "to make that safe rather than silently wrong)."
            )
        ),
    )

    print(format_scorecard(scorecard))
    print()

    if all_problems:
        print("FAILED: candidate_a measurement found problems:", file=sys.stderr)
        for problem in all_problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print("OK: candidate_a (extracted headless core + native-client boundary) measurement passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
