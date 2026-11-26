"""Queue completed ad-feedback tuning actions for Wilted to apply.

This command reads the app-owned inbox and tuning evidence. It never edits the
inbox. Wilted consumes an owner-private request queue and writes handled state
and replay receipts through its own durable store.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import ad_feedback_export
from ad_corpus_recorded import revision_matches_source

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FEEDBACK = ad_feedback_export.DEFAULT_FEEDBACK
DEFAULT_MANIFEST = REPO_ROOT / "Producer" / "Workers" / "adcorpus" / "manifest.json"
DEFAULT_SPOOL = (Path.home() / "Library" / "Application Support" / "Wilted" /
                 "ad-feedback-actions" / "pending")
WAKE_URL = "wilted://ad-feedback/process"
APPLICATION_ID = "com.zerodelta.wilted.mac"
MAX_HANDLED_REPORTS = 200
IDENTITY_FIELDS = (
    "id", "kind", "itemID", "revisionID", "playedSeconds", "originalSeconds", "mapping",
    "nearestCut", "engineVersion", "pipelineFingerprint", "createdAt", "deviceID", "source",
    "showTitle", "episodeTitle", "review", "label", "reviewedAt",
)


class ActionError(RuntimeError):
    """A tuning proof or private action queue failed validation."""


def _json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _read_json(path: Path, description: str) -> tuple[object, bytes]:
    try:
        raw = path.read_bytes()
        return json.loads(raw), raw
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActionError(f"could not read {description}: {path}") from error


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _digest(value: object, field: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ActionError(f"{field} must be a lowercase SHA-256 digest")
    return value


def _git(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ActionError("could not verify the tuning branch") from error
    return result.stdout.strip()


def _candidate(repo: Path, proof: dict) -> tuple[str, str]:
    commit = _git(repo, "rev-parse", "HEAD")
    branch = _git(repo, "branch", "--show-current")
    if proof.get("candidateCommit") != commit:
        raise ActionError("proof candidate does not match the current commit")
    if branch != "main" and not (
        branch.startswith("ad-tuning/") and len(branch) > len("ad-tuning/")
    ):
        raise ActionError("mark handled requires an ad-tuning branch or accepted main candidate")
    if _git(repo, "status", "--porcelain", "--untracked-files=all"):
        raise ActionError("mark handled requires a clean tuning branch")
    return commit, branch


def _feedback_map(path: Path) -> tuple[dict[str, dict], bytes]:
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ActionError(f"could not read the ad-feedback file: {path}") from error
    if not isinstance(payload, dict) or payload.get("version") not in (1, 2):
        raise ActionError(f"ad-feedback file has an unsupported version: {path}")
    if not isinstance(entries := payload.get("entries"), list):
        raise ActionError(f"ad-feedback file has no entries list: {path}")
    if payload["version"] == 2 and not isinstance(payload.get("handledActions"), list):
        raise ActionError(f"ad-feedback file has no action receipt list: {path}")
    by_id: dict[str, dict] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id or entry_id in by_id:
            raise ActionError("feedback snapshot has a missing or repeated report ID")
        by_id[entry_id] = entry
    return by_id, raw


def _active(entry: dict) -> bool:
    return ad_feedback_export._counts(entry) and entry.get("handledAt") is None


def _identity(entry: dict) -> dict:
    return {field: entry.get(field) for field in IDENTITY_FIELDS}


def _finite(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _covers_interval(spans: list[dict], start: float, end: float, label: str) -> bool:
    cursor = start
    for span in sorted(
        (row for row in spans if row.get("label") == label and row.get("passed") is True
         and _finite(row.get("start")) and _finite(row.get("end"))),
        key=lambda row: row["start"],
    ):
        if span["end"] <= cursor:
            continue
        if span["start"] > cursor + 1e-6:
            break
        cursor = max(cursor, span["end"])
        if cursor >= end - 1e-6:
            return True
    return False


def _cuts_cover(cuts: list, start: float, end: float) -> bool:
    cursor = start
    for cut in sorted(cuts, key=lambda item: item[0]):
        if not isinstance(cut, list) or len(cut) != 2 or not all(_finite(value) for value in cut):
            continue
        if cut[1] <= cursor:
            continue
        if cut[0] > cursor + 1e-6:
            break
        cursor = max(cursor, cut[1])
        if cursor >= end - 1e-6:
            return True
    return False


def _cut_contains(cuts: list, point: float) -> bool:
    return any(
        isinstance(cut, list) and len(cut) == 2 and all(_finite(value) for value in cut)
        and cut[0] <= point < cut[1]
        for cut in cuts
    )


def _cut_overlaps(cuts: list, start: float, end: float) -> bool:
    return any(
        isinstance(cut, list) and len(cut) == 2 and all(_finite(value) for value in cut)
        and max(start, cut[0]) < min(end, cut[1])
        for cut in cuts
    )


def _local_evidence(entry: dict, result: dict) -> dict:
    """Require the actual reported point or cut to pass, not just its whole case."""
    position = entry.get("originalSeconds")
    spans, cuts = result.get("spanVerdicts"), result.get("producedCuts")
    if not _finite(position) or not isinstance(spans, list) or not isinstance(cuts, list):
        raise ActionError(f"feedback {entry.get('id')} has no exact local replay evidence")

    nearest = entry.get("nearestCut")
    interval: tuple[float, float] | None = None
    label: str
    if entry.get("kind") == "adHere":
        label = "must-cut"
        local = next((span for span in spans if isinstance(span, dict)
                      and span.get("label") == label and span.get("passed") is True
                      and _finite(span.get("start")) and _finite(span.get("end"))
                      and span["start"] <= position < span["end"]), None)
        if local is None or not _cut_contains(cuts, float(position)):
            raise ActionError(f"Ad here report {entry.get('id')} is not cut at its exact reported position")
        interval = (float(local["start"]), float(local["end"]))
        nearest_fully_cut = None
        position_cut = True
    elif entry.get("kind") in ("goodCut", "notAnAd"):
        if (not isinstance(nearest, dict) or not _finite(nearest.get("originalStartSeconds"))
                or not _finite(nearest.get("originalEndSeconds"))
                or nearest["originalStartSeconds"] >= nearest["originalEndSeconds"]):
            raise ActionError(f"feedback {entry.get('id')} has no exact reviewed cut interval")
        start, end = float(nearest["originalStartSeconds"]), float(nearest["originalEndSeconds"])
        label = "must-cut" if entry["kind"] == "goodCut" else "must-keep"
        local = next((span for span in spans if isinstance(span, dict)
                      and span.get("label") == label and span.get("passed") is True
                      and _finite(span.get("start")) and _finite(span.get("end"))
                      and (entry["kind"] == "goodCut" or span["start"] <= position < span["end"])
                      and span["start"] <= start and end <= span["end"]), None)
        if local is None or not _covers_interval(spans, start, end, label):
            raise ActionError(f"feedback {entry.get('id')} has no passing local label for its cut")
        interval = (float(local["start"]), float(local["end"]))
        nearest_fully_cut = _cuts_cover(cuts, start, end)
        nearest_any_cut = _cut_overlaps(cuts, start, end)
        position_cut = _cut_contains(cuts, float(position))
        if entry["kind"] == "goodCut" and not nearest_fully_cut:
            raise ActionError(f"Good cut report {entry.get('id')} is not fully cut in the replay")
        if entry["kind"] == "notAnAd" and (nearest_any_cut or position_cut):
            raise ActionError(f"Not an ad report {entry.get('id')} is still cut at its reported material")
    else:
        raise ActionError(f"feedback {entry.get('id')} has an unsupported report kind")

    assert interval is not None
    return {
        "label": label,
        "startSeconds": interval[0],
        "endSeconds": interval[1],
        "reportedPositionSeconds": float(position),
        "localVerdictPassed": True,
        "reportedPositionWasCut": position_cut,
        "nearestCutFullyCut": nearest_fully_cut,
        "nearestCutAnyCut": nearest_any_cut if entry.get("kind") != "adHere" else None,
    }


def build_action_payload(
    *, proof_path: Path, snapshot_path: Path, replay_path: Path, feedback_path: Path,
    manifest_path: Path, library_path: Path, repo: Path,
) -> dict:
    """Validate a completed case replay against the intake snapshot and current branch."""
    proof_value, _ = _read_json(proof_path, "tuning proof")
    if not isinstance(proof_value, dict) or proof_value.get("schemaVersion") != 1:
        raise ActionError("tuning proof schema is unsupported")
    proof = proof_value
    candidate_commit, branch = _candidate(repo, proof)

    snapshot, snapshot_bytes = _feedback_map(snapshot_path)
    current, _ = _feedback_map(feedback_path)
    snapshot_digest = _digest(proof.get("intakeSnapshotSHA256"), "intakeSnapshotSHA256")
    if _sha256(snapshot_bytes) != snapshot_digest:
        raise ActionError("intake snapshot digest does not match the tuning proof")

    replay_value, replay_bytes = _read_json(replay_path, "candidate replay report")
    report_digest = _digest(proof.get("replayReportSHA256"), "replayReportSHA256")
    if _sha256(replay_bytes) != report_digest:
        raise ActionError("replay report digest does not match the tuning proof")
    if not isinstance(replay_value, dict) or replay_value.get("schemaVersion") != 1:
        raise ActionError("candidate replay report schema is unsupported")
    if (replay_value.get("candidateCommit") != candidate_commit
            or replay_value.get("workingTreeClean") is not True):
        raise ActionError("replay report was not produced for the current candidate")
    fixture_id = replay_value.get("fixtureID")
    replay_command_parts = replay_value.get("replayCommand")
    if (not isinstance(fixture_id, str) or not fixture_id
            or not isinstance(replay_command_parts, list)
            or not replay_command_parts
            or not all(isinstance(part, str) and part for part in replay_command_parts)):
        raise ActionError("replay report is missing its fixture and command identity")
    replay_command = json.dumps(replay_command_parts, ensure_ascii=False, separators=(",", ":"))
    if len(replay_command) > 4096:
        raise ActionError("replay command identity is too long")
    replay_rows = replay_value.get("rows")
    if not isinstance(replay_rows, list):
        raise ActionError("candidate replay report has no rows list")
    replay_by_case: dict[str, dict] = {}
    for result in replay_rows:
        case_id = result.get("caseID", result.get("id")) if isinstance(result, dict) else None
        if not isinstance(result, dict) or not isinstance(case_id, str) or not case_id:
            raise ActionError("candidate replay report contains a malformed case result")
        if case_id in replay_by_case:
            raise ActionError("candidate replay report repeats a case ID")
        replay_by_case[case_id] = result

    manifest_value, _ = _read_json(manifest_path, "ad corpus manifest")
    cases = manifest_value.get("cases") if isinstance(manifest_value, dict) else None
    if not isinstance(cases, list):
        raise ActionError("ad corpus manifest has no cases list")
    case_by_id: dict[str, dict] = {}
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str):
            raise ActionError("ad corpus manifest contains a malformed case")
        if case["id"] in case_by_id:
            raise ActionError("ad corpus manifest repeats a case ID")
        case_by_id[case["id"]] = case

    selected = proof.get("readyFeedback")
    if not isinstance(selected, list) or not selected:
        raise ActionError("tuning proof has no reports ready to mark handled")
    if len(selected) > MAX_HANDLED_REPORTS:
        raise ActionError(f"a handled batch may contain at most {MAX_HANDLED_REPORTS} reports")
    ready: list[dict] = []
    seen_ids: set[str] = set()
    for item in selected:
        if not isinstance(item, dict):
            raise ActionError("tuning proof has a malformed feedback link")
        feedback_id, case_id = item.get("feedbackID"), item.get("caseID")
        if not isinstance(feedback_id, str) or not feedback_id or not isinstance(case_id, str) or not case_id:
            raise ActionError("tuning proof must link each feedback ID to a corpus case")
        if feedback_id in seen_ids:
            raise ActionError("tuning proof repeats a feedback ID")
        seen_ids.add(feedback_id)
        captured = snapshot.get(feedback_id)
        live = current.get(feedback_id)
        if captured is None or live is None or not _active(captured) or not _active(live):
            raise ActionError(f"feedback {feedback_id} is missing, dismissed, or already handled")
        if _identity(captured) != _identity(live):
            raise ActionError(f"feedback {feedback_id} changed after the intake snapshot")
        if captured.get("review") != "accepted" or live.get("review") != "accepted":
            raise ActionError(f"feedback {feedback_id} must be accepted in the app inbox")

        case = case_by_id.get(case_id)
        result = replay_by_case.get(case_id)
        source_hash = case.get("sourceHash") if isinstance(case, dict) else None
        if (case is None or case.get("itemID") != captured.get("itemID")
                or not isinstance(source_hash, str) or not source_hash.startswith("sha256:")
                or len(source_hash) != len("sha256:") + 64
                or any(character not in "0123456789abcdef" for character in source_hash[7:])
                or result is None or result.get("sourceHash") != source_hash):
            raise ActionError(f"corpus case {case_id} does not match feedback {feedback_id}")
        case_revision = case.get("revisionID")
        if case_revision is not None and case_revision != captured.get("revisionID"):
            raise ActionError(f"corpus case {case_id} is pinned to a different revision")
        if not revision_matches_source(
            captured.get("itemID", ""), captured.get("revisionID", ""), source_hash,
            library=library_path,
        ):
            raise ActionError(f"feedback {feedback_id} has no authoritative source match for its revision")

        result_feedback_ids = result.get("feedbackIDs")
        if (result.get("itemID") != captured.get("itemID")
                or result.get("revisionID") != captured.get("revisionID")
                or not isinstance(result_feedback_ids, list) or feedback_id not in result_feedback_ids
                or result.get("passed") is not True or result.get("skipped") is not False
                or result.get("coverageComplete") is not True or result.get("clean") is not True):
            raise ActionError(f"feedback {feedback_id} has no clean exact-revision replay result")
        local_evidence = _local_evidence(captured, result)

        ready.append({
            "identity": _identity(captured),
            "caseID": case_id,
            "sourceHash": source_hash,
            "replay": {
                "candidateCommit": candidate_commit,
                "reportSHA256": report_digest,
                "fixtureID": fixture_id,
                "replayCommand": replay_command,
                "passed": True,
                "clean": True,
                "skipped": False,
                "coverageComplete": True,
                "localEvidence": local_evidence,
            },
        })

    return {
        "schemaVersion": 1,
        "candidateCommit": candidate_commit,
        "candidateBranch": branch,
        "intakeSnapshotSHA256": snapshot_digest,
        "replayReportSHA256": report_digest,
        "entries": ready,
    }


def _private_directory(path: Path) -> None:
    try:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = path.lstat()
    except OSError as error:
        raise ActionError(f"could not prepare the private action queue: {path}") from error
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise ActionError("action queue must be an owner-only directory owned by this user")


def enqueue_action(payload: dict, spool: Path) -> tuple[str, Path, bool]:
    """Atomically add one owner-private, content-addressed request without overwriting."""
    payload_bytes = _json_bytes(payload)
    action_id = _sha256(payload_bytes)
    envelope = {
        "actionID": action_id,
        "payloadSHA256": action_id,
        "payload": base64.b64encode(payload_bytes).decode("ascii"),
    }
    request_bytes = _json_bytes(envelope)
    _private_directory(spool.parent)
    _private_directory(spool)
    target = spool / f"{action_id}.json"
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{action_id}.", dir=spool)
    except OSError as error:
        raise ActionError(f"could not create the private action request: {target}") from error
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(request_bytes)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, target, follow_symlinks=False)
            created = True
        except FileExistsError:
            info = target.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) & 0o077 or target.read_bytes() != request_bytes):
                raise ActionError("action ID already exists with different or unsafe contents")
            created = False
        directory_fd = os.open(spool, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as error:
        raise ActionError(f"could not enqueue the private action: {target}") from error
    finally:
        temporary.unlink(missing_ok=True)
    return action_id, target, created


def wake_app() -> None:
    """Wake Wilted with a fixed URL that carries no action data or file path."""
    try:
        subprocess.run(["open", "-b", APPLICATION_ID, WAKE_URL], check=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        raise ActionError("the request is queued, but Wilted could not be woken") from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--proof", type=Path, required=True,
                        help="final tuning proof with ready feedback IDs and corpus case links")
    parser.add_argument("--snapshot", type=Path, required=True,
                        help="read-only ad-feedback intake snapshot")
    parser.add_argument("--replay-report", type=Path, required=True,
                        help="machine-readable exact-candidate replay results")
    parser.add_argument("--feedback", type=Path, default=DEFAULT_FEEDBACK,
                        help="current app-owned feedback file, read-only")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--library", type=Path, default=ad_feedback_export.ad_corpus.DEFAULT_LIBRARY,
                        help="read-only Wilted library used to verify the revision source hash")
    parser.add_argument("--repo", type=Path, default=REPO_ROOT)
    parser.add_argument("--spool", type=Path, default=DEFAULT_SPOOL,
                        help=argparse.SUPPRESS)
    parser.add_argument("--queue-only", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        payload = build_action_payload(
            proof_path=args.proof, snapshot_path=args.snapshot, replay_path=args.replay_report,
            feedback_path=args.feedback, manifest_path=args.manifest, library_path=args.library,
            repo=args.repo,
        )
        action_id, _path, created = enqueue_action(payload, args.spool)
        if not args.queue_only:
            wake_app()
    except ActionError as error:
        print(f"ad-feedback.handle: {error}", file=sys.stderr)
        return 2
    print(f"ad-feedback.handle queued action={action_id} new={'yes' if created else 'no'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
