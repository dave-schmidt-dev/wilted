"""Score a saved online-labeller replay without sending provider requests.

The fixture directory contains ``cases/<id>/case.json`` and ``breaks.json``.
The report stores timings and source identities only; it never copies reply or
transcript text. ``ad_corpus.score_case`` remains the source of truth for
must-cut and must-keep scoring.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

from ad_corpus import Span, score_case, union_spans
from wilted_worker.cue_timing import build_effective_cut_map
from wilted_worker.labelled_outcome import decide_labelled_outcome
from wilted_worker.reporting import WorkerError

AD_FREE_CASES = frozenset({"in030", "in027"})
REJECT_REASON = {"outside the episode": "out-of-range"}


def _sha256(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def _fixture_identity(rows: list[dict]) -> tuple[str, list[dict]]:
    """Fingerprint the exact metadata, labels and break bytes each row read."""
    inputs = [
        {
            "caseID": row["caseID"],
            "caseSha256": row["caseSha256"],
            "breaksSha256": row["breaksSha256"],
            "identitySha256": row["identitySha256"],
        }
        for row in rows
    ]
    serialized = json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(serialized).hexdigest(), inputs


def _identity(case: dict, folder: Path) -> dict:
    """Pass through explicit row identity without inferring it from show names."""
    identity = {
        key: case.get(key)
        for key in ("itemID", "revisionID", "sourceHash", "feedbackIDs")
    }
    sidecar = folder / "identity.json"
    sidecar_bytes = sidecar.read_bytes() if sidecar.is_file() else None
    sidecar_digest = hashlib.sha256(sidecar_bytes).hexdigest() if sidecar_bytes is not None else None
    if sidecar_bytes is not None:
        supplied = json.loads(sidecar_bytes)
        if supplied.get("caseID") not in (None, case.get("id")):
            raise ValueError(f"{folder.name}: identity.json caseID does not match")
        if supplied.get("sourceHash") not in (None, case.get("sourceHash")):
            raise ValueError(f"{folder.name}: identity.json sourceHash does not match")
        identity.update({key: supplied[key] for key in identity if key in supplied})
    if not isinstance(identity.get("feedbackIDs"), list):
        identity["feedbackIDs"] = []
    return {**identity, "identitySha256": sidecar_digest}


def _removed_spans(decision, duration: float) -> tuple[list[Span], str | None]:
    """Return the product's exact cut complement or the reason it refused."""
    if decision.keep_whole_reason is not None:
        return [], decision.keep_whole_reason
    if not decision.detections:
        return [], None
    try:
        _, keeps = build_effective_cut_map(decision.detections, duration)
    except WorkerError as error:
        if error.code == "cut-unsafe":
            return [], f"cut-unsafe: {error}"
        raise
    if not keeps:
        return [], "every span classified as an advertisement"
    removed, cursor = [], 0.0
    for keep in sorted(keeps, key=lambda item: item.start_s):
        if keep.start_s > cursor:
            removed.append(Span(cursor, keep.start_s))
        cursor = max(cursor, keep.end_s)
    if cursor < duration:
        removed.append(Span(cursor, duration))
    return [span for span in removed if span.seconds > 1e-9], None


def _score_one(folder: Path) -> tuple[dict, dict | None]:
    case_path = folder / "case.json"
    case_bytes = case_path.read_bytes()
    case = json.loads(case_bytes)
    case_id = case.get("id", folder.name)
    row = {
        "id": case_id,
        "caseID": case_id,
        "show": str(case.get("show", ""))[:22],
        **_identity(case, folder),
        "caseSha256": hashlib.sha256(case_bytes).hexdigest(),
    }
    breaks_path = folder / "breaks.json"
    breaks_bytes = breaks_path.read_bytes() if breaks_path.is_file() else None
    row["breaksSha256"] = hashlib.sha256(breaks_bytes).hexdigest() if breaks_bytes is not None else None
    document = json.loads(breaks_bytes) if breaks_bytes is not None else None
    if document is None or "labelledBreaks" not in document:
        row.update(
            measured=False, passed=False, clean=False, skipped=False,
            coverageComplete=False, leftIn=0.0, keepLoss=0.0, outside=0.0,
            cut=0.0, labelledAdSeconds=0.0, originalLabelledAdSeconds=0.0,
            adLabelOverhangSeconds=0.0, labelOverhangSeconds=0.0, labelOverhangs=[],
            spanVerdicts=[], producedCuts=[],
            why="no reply" if document is None else f"unusable: {document.get('unusable')}",
        )
        return row, None

    duration = float(case["durationSeconds"])
    effective_case = {
        **case,
        "audioDurationSeconds": duration,
        "expected": [{"why": "", **item} for item in case["expected"]],
    }
    decision = decide_labelled_outcome(
        document["labelledBreaks"], duration,
        remove_self_promotion=case.get("removeSelfPromotion") is True,
    )
    cuts, refusal = _removed_spans(decision, duration)
    verdict = score_case(effective_case, cuts)
    must_cut = [span for span in verdict.spans if span.label == "must-cut"]
    raw_ad_seconds = sum(span.span.seconds for span in must_cut)
    scored_ad_seconds = sum(span.scored_span.seconds for span in must_cut)
    ad_overhang_seconds = raw_ad_seconds - scored_ad_seconds
    overhangs = []
    for span in verdict.spans:
        overhang = max(0.0, span.span.seconds - span.scored_span.seconds)
        if overhang <= 1e-9:
            continue
        overhangs.append({
            "label": span.label,
            "start": span.span.start,
            "end": span.span.end,
            "scoredStart": span.scored_span.start if span.scored_span.seconds else None,
            "scoredEnd": span.scored_span.end if span.scored_span.seconds else None,
            "originalSeconds": round(span.span.seconds, 3),
            "scoredSeconds": round(span.scored_span.seconds, 3),
            "outsideSourceSeconds": round(overhang, 3),
        })

    left_in = sum(max(0.0, span.scored_span.seconds - span.overlap_seconds) for span in must_cut)
    total_label_overhang = sum(
        max(0.0, span.span.seconds - span.scored_span.seconds)
        for span in verdict.spans
    )
    left_reasons = {}
    for item in decision.left_in:
        left_reasons[item.reason] = left_reasons.get(item.reason, 0) + 1
    for reason, count in document.get("rejectedByReason", {}).items():
        category = REJECT_REASON.get(reason, "malformed")
        left_reasons[f"rejected:{category}"] = left_reasons.get(f"rejected:{category}", 0) + count

    clean = verdict.passed and verdict.coverage_complete and refusal is None
    row.update(
        measured=True,
        passed=verdict.passed and refusal is None,
        clean=clean,
        skipped=False,
        coverageComplete=verdict.coverage_complete,
        reason=verdict.reason,
        labelledAdSeconds=round(scored_ad_seconds, 1),
        originalLabelledAdSeconds=round(raw_ad_seconds, 1),
        adLabelOverhangSeconds=round(ad_overhang_seconds, 3),
        labelOverhangSeconds=round(total_label_overhang, 3),
        labelOverhangs=overhangs,
        leftIn=round(left_in, 1),
        keepLoss=round(verdict.keep_loss_seconds, 1),
        outside=round(verdict.outside_ad_label_cut_seconds, 1),
        cut=round(sum(span.seconds for span in union_spans(verdict.produced)), 1),
        breaksProposed=decision.breaks_proposed,
        breaksCut=len(decision.detections) if refusal is None else 0,
        leftInByReason=dict(sorted(left_reasons.items())),
        keepWholeReason=decision.keep_whole_reason or refusal,
        labelledCoverage=round(verdict.labelled_coverage, 4),
        spanVerdicts=[
            {
                "label": span.label,
                "start": span.span.start,
                "end": span.span.end,
                "scoredStart": span.scored_span.start if span.scored_span.seconds else None,
                "scoredEnd": span.scored_span.end if span.scored_span.seconds else None,
                "passed": span.passed,
                "overlapSeconds": round(span.overlap_seconds, 3),
            }
            for span in verdict.spans
        ],
        producedCuts=[[span.start, span.end] for span in union_spans(verdict.produced)],
    )
    return row, verdict


def _git_value(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], check=True,
        capture_output=True, text=True,
    )
    return result.stdout.strip()


def score_fixture(fixture_dir: Path, *, output: Path, repo: Path) -> dict:
    """Score every saved case and write an identity-bound, text-free JSON report."""
    fixture_dir = fixture_dir.resolve()
    output = output.resolve()
    repo = repo.resolve()
    cases_dir = fixture_dir / "cases"
    if not cases_dir.is_dir():
        raise ValueError(f"fixture directory has no cases/: {fixture_dir}")
    if output.is_relative_to(fixture_dir):
        raise ValueError("output must be outside the fixture directory")

    rows, verdicts = [], []
    for folder in sorted(cases_dir.iterdir()):
        if folder.is_dir() and (folder / "case.json").is_file():
            row, verdict = _score_one(folder)
            rows.append(row)
            if verdict is not None:
                verdicts.append(verdict)

    measured = [row for row in rows if row["measured"]]
    total_ad = sum(sum(span.scored_span.seconds for span in verdict.spans if span.label == "must-cut")
                   for verdict in verdicts)
    total_raw_ad = sum(sum(span.span.seconds for span in verdict.spans if span.label == "must-cut")
                       for verdict in verdicts)
    total_left = sum(row["leftIn"] for row in measured)
    total_overhang = sum(row["labelOverhangSeconds"] for row in measured)
    left_percent = 100.0 * total_left / total_ad if total_ad else 0.0
    worst_outside = max(measured, key=lambda row: row["outside"], default=None)
    ad_free = [row for row in measured if row["caseID"] in AD_FREE_CASES]
    complete = len(measured) == len(rows)

    def target(failed: bool, target_complete: bool = True) -> str:
        if failed:
            return "FAIL"
        return "PASS" if target_complete else f"NOT PROVEN ({len(rows) - len(measured)} not measured)"

    targets = {
        "leftInUnder2Percent": {
            "limitPercent": 2.0, "valuePercent": round(left_percent, 2),
            "result": target(left_percent > 2.0, complete),
        },
        "outsideLabelsUnder120SecondsPerCase": {
            "limitSeconds": 120.0,
            "worstCase": [worst_outside["caseID"], worst_outside["outside"]] if worst_outside else None,
            "result": target(any(row["outside"] > 120.0 for row in measured), complete),
        },
        "adFreeCasesRemainUncut": {
            "cutSeconds": {row["caseID"]: row["cut"] for row in ad_free},
            "result": target(any(row["cut"] > 0 for row in ad_free), len(ad_free) == len(AD_FREE_CASES)),
        },
    }
    fixture_id, inputs = _fixture_identity(rows)
    command = [
        sys.executable, str(Path(__file__).resolve()),
        "--fixture-dir", str(fixture_dir), "--output", str(output), "--repo", str(repo),
    ]
    report = {
        "schemaVersion": 1,
        "runID": str(uuid.uuid4()),
        "fixtureID": fixture_id,
        "fixtureDirectory": str(fixture_dir),
        "fixtureInputs": inputs,
        "candidateCommit": _git_value(repo, "rev-parse", "HEAD"),
        "workingTreeClean": not bool(_git_value(repo, "status", "--porcelain")),
        "replayCommand": command,
        "rows": rows,
        "totals": {
            "measured": len(measured), "cases": len(rows),
            "labelledAdSeconds": round(total_ad, 1),
            "originalLabelledAdSeconds": round(total_raw_ad, 1),
            "labelOverhangSeconds": round(total_overhang, 3),
            "leftInSeconds": round(total_left, 1),
            "leftInPercent": round(left_percent, 2),
            "outsideSeconds": round(sum(row["outside"] for row in measured), 1),
            "keepLossSeconds": round(sum(row["keepLoss"] for row in measured), 1),
        },
        "targets": targets,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{report['runID']}.tmp")
    try:
        temporary.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fixture-dir", type=Path, required=True,
                        help="directory containing cases/<id>/{case.json,breaks.json}")
    parser.add_argument("--output", type=Path, required=True,
                        help="report path outside the fixture directory")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2],
                        help="Git worktree whose HEAD identifies this replay candidate")
    args = parser.parse_args(argv)
    if args.output.resolve().is_relative_to(args.fixture_dir.resolve()):
        parser.error("--output must be outside the fixture directory")
    report = score_fixture(args.fixture_dir, output=args.output, repo=args.repo)
    totals = report["totals"]
    print(
        f"scored {totals['measured']} of {totals['cases']} cases: "
        f"{totals['labelledAdSeconds']:.1f}s scored ad labels, "
        f"{totals['leftInSeconds']:.1f}s left in ({totals['leftInPercent']:.2f}%), "
        f"{totals['keepLossSeconds']:.1f}s programme loss, "
        f"{totals['labelOverhangSeconds']:.3f}s label overhang"
    )
    print(f"fixture {report['fixtureID']}; candidate {report['candidateCommit']}")
    print(f"wrote {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
