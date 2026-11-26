"""Identity-aware reconciliation with prior local ad-feedback ledgers."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

IDENTITY_FIELDS = (
    "id", "kind", "itemID", "revisionID", "playedSeconds", "originalSeconds", "mapping",
    "nearestCut", "engineVersion", "pipelineFingerprint", "createdAt", "deviceID", "source",
    "showTitle", "episodeTitle", "review", "label", "reviewedAt",
)
DISPOSITION_RANK = {
    "needs-verification": 0,
    "duplicate-of": 1,
    "unresolved": 2,
    "trial-rejected": 3,
    "reproduced": 4,
    "source-verified": 5,
    "dismissed": 6,
}
_AUTOMATIC_NEXT_ACTIONS = {
    "Retain the dismissed report in the historical ledger.",
    "Recheck the changed feedback identity against its exact source and revision.",
    "Verify source, exact revision, original inputs, and local replay before classifying.",
}


class WeeklyReportError(RuntimeError):
    """The weekly report input or existing evidence cannot be safely reconciled."""


def has_operator_annotations(row: dict[str, Any]) -> bool:
    """Tell generated default state from operator-written report annotations."""
    return not (
        row.get("disposition") == "needs-verification"
        and row.get("evidenceStatus") == "metadata-only"
        and row.get("findings") is None
        and not row.get("evidencePaths")
        and row.get("nextAction") in _AUTOMATIC_NEXT_ACTIONS
    )


def identity(entry: dict[str, Any]) -> dict[str, Any]:
    """Select the feedback fields that make an investigation reusable."""
    return {field: entry.get(field) for field in IDENTITY_FIELDS}


def ledger_rows(value: object, path: Path) -> list[dict[str, Any]]:
    """Accept row ledgers and the older group envelope conservatively."""
    if isinstance(value, list):
        rows = value
    elif isinstance(value, dict):
        rows = value.get("entries", value.get("reports"))
        if rows is None and isinstance(value.get("groups"), list):
            rows = []
            for group in value["groups"]:
                if not isinstance(group, dict) or not isinstance(group.get("reports"), list):
                    raise WeeklyReportError(f"prior group ledger has malformed reports: {path.name}")
                for report in group["reports"]:
                    if not isinstance(report, dict):
                        raise WeeklyReportError(f"prior group ledger has a malformed report: {path.name}")
                    normalized = dict(report)
                    normalized.setdefault("id", report.get("feedbackID"))
                    normalized.setdefault("kind", report.get("reportedKind"))
                    normalized.setdefault("episodeTitle", group.get("episodeTitle"))
                    normalized.setdefault("nextAction", report.get("nextStep"))
                    rows.append(normalized)
    else:
        rows = None
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise WeeklyReportError(f"prior ledger is not a recognized row list: {path.name}")
    return rows


def _ledger_identity(row: dict[str, Any]) -> dict[str, Any]:
    value = row.get("identity")
    if isinstance(value, dict):
        return {field: value.get(field) for field in IDENTITY_FIELDS}
    return {field: row.get(field) for field in IDENTITY_FIELDS}


def _captured_snapshot(ledger_path: Path) -> tuple[dict[str, dict[str, Any]], str] | None:
    """Load the source inbox snapshot kept beside a historical ledger."""
    snapshot_path = ledger_path.parent / "ad-feedback.json"
    if not snapshot_path.is_file():
        return None
    if snapshot_path.is_symlink():
        raise WeeklyReportError(
            f"a prior ledger's captured inbox snapshot is not a regular file: {snapshot_path.name}"
        )
    try:
        raw = snapshot_path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WeeklyReportError(
            f"a prior ledger's captured inbox snapshot cannot be read: {snapshot_path.name}"
        ) from error
    if (not isinstance(payload, dict) or type(payload.get("version")) is not int
            or payload.get("version") not in (1, 2) or not isinstance(payload.get("entries"), list)):
        raise WeeklyReportError(
            f"a prior ledger's captured inbox snapshot is malformed: {snapshot_path.name}"
        )
    by_id: dict[str, dict[str, Any]] = {}
    for entry in payload["entries"]:
        if not isinstance(entry, dict):
            raise WeeklyReportError(
                f"a prior ledger's captured inbox snapshot has a malformed report: {snapshot_path.name}"
            )
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id or entry_id in by_id:
            raise WeeklyReportError(
                f"a prior ledger's captured inbox snapshot has a missing or repeated report ID: {snapshot_path.name}"
            )
        by_id[entry_id] = entry
    return by_id, hashlib.sha256(raw).hexdigest()


def _history_date(path: Path) -> str:
    match = re.search(r"ad-feedback-weekly/(\d{4}-\d{2}-\d{2})/", str(path))
    if match:
        return match.group(1)
    match = re.search(r"ad-feedback-intake-(\d{4}-\d{2}-\d{2})", str(path))
    if match:
        return match.group(1)
    match = re.search(r"ad-feedback-(\d{4}-\d{2}-\d{2})", str(path))
    return match.group(1) if match else "0000-00-00"


def _history_priority(path: Path, row: dict[str, Any]) -> tuple[str, int, int, str]:
    disposition = str(row.get("disposition", "needs-verification"))
    investigated = 1 if "investigated" in path.stem else 0
    rank = DISPOSITION_RANK.get(disposition, 0)
    return (_history_date(path), investigated, rank, path.as_posix())


def prior_paths(history_root: Path, explicit: list[Path] | None) -> list[Path]:
    """Discover known ad-feedback ledger layouts or use explicit fixtures."""
    paths = set(path.expanduser().resolve() for path in (explicit or []))
    if explicit is None and history_root.exists():
        for pattern in (
            "ad-feedback-intake-*/ledger*.json",
            "ad-feedback-*/feedback-ledger.json",
            "ad-feedback-*/weekly/*ledger*.json",
            "ad-feedback-weekly/*/*/ledger.json",
        ):
            paths.update(path.resolve() for path in history_root.glob(pattern) if path.is_file())
    return sorted(paths, key=lambda path: (_history_date(path), path.as_posix()))


def load_history(
    paths: list[Path],
) -> tuple[dict[str, list[dict[str, Any]]], list[dict[str, str]]]:
    """Load prior ledgers, retaining their digest and each report's provenance."""
    by_id: dict[str, list[dict[str, Any]]] = {}
    manifest: list[dict[str, str]] = []
    for path in paths:
        try:
            raw = path.read_bytes()
            value = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise WeeklyReportError(f"a prior ad-feedback ledger cannot be read: {path.name}") from error
        rows = ledger_rows(value, path)
        snapshot = _captured_snapshot(path)
        manifest_row = {"path": path.name, "sha256": hashlib.sha256(raw).hexdigest()}
        if snapshot is not None:
            snapshot_path = path.parent / "ad-feedback.json"
            try:
                snapshot_name = snapshot_path.resolve().relative_to(Path.cwd().resolve()).as_posix()
            except ValueError:
                snapshot_name = snapshot_path.name
            manifest_row["snapshotPath"] = snapshot_name
            manifest_row["snapshotSHA256"] = snapshot[1]
        manifest.append(manifest_row)
        for row in rows:
            feedback_id = row.get("id", row.get("feedbackID"))
            if not isinstance(feedback_id, str) or not feedback_id:
                raise WeeklyReportError(f"a prior ledger row has no report ID: {path.name}")
            captured = snapshot[0].get(feedback_id) if snapshot is not None else None
            ledger_identity = _ledger_identity(row)
            captured_identity = identity(captured) if captured is not None else None
            by_id.setdefault(feedback_id, []).append({
                "path": path,
                "row": row,
                "identity": captured_identity or ledger_identity,
                "identitySource": "snapshot" if captured_identity is not None else "ledger",
                "ledgerIdentityDifferences": (
                    [field for field in IDENTITY_FIELDS
                     if ledger_identity.get(field) != captured_identity.get(field)]
                    if captured_identity is not None else []
                ),
            })
    return by_id, manifest


def _best_prior(records: list[dict[str, Any]], current_identity: dict[str, Any]) -> dict[str, Any] | None:
    matching = [record for record in records if record["identity"] == current_identity]
    if not matching:
        return None
    return max(matching, key=lambda record: _history_priority(record["path"], record["row"]))


def _relative_source(path: Path, history_root: Path) -> str:
    try:
        return path.resolve().relative_to(history_root.resolve()).as_posix()
    except ValueError:
        return path.name


def new_ledger_row(
    entry: dict[str, Any], records: list[dict[str, Any]], history_root: Path,
) -> dict[str, Any]:
    """Carry a past disposition only when the full feedback identity still matches."""
    current_identity = identity(entry)
    matching = [record for record in records if record["identity"] == current_identity]
    prior = _best_prior(records, current_identity)
    if prior is not None:
        prior_row = prior["row"]
        prior_status = str(prior_row.get("disposition", "needs-verification"))
        investigation_status = (
            "previously-investigated" if prior_status != "needs-verification"
            else "previously-captured"
        )
        disposition = prior_status if prior_status in DISPOSITION_RANK else "needs-verification"
        evidence_status = prior_row.get("evidenceStatus", "metadata-only")
        findings = prior_row.get("findings")
        next_action = prior_row.get("nextAction")
        evidence_paths = prior_row.get("evidencePaths", [])
    elif records:
        investigation_status = "changed-since-prior"
        disposition = "dismissed" if entry.get("review") == "dismissed" else "needs-verification"
        evidence_status = "metadata-only"
        findings = None
        next_action = (
            "Retain the dismissed report in the historical ledger."
            if entry.get("review") == "dismissed" else
            "Recheck the changed feedback identity against its exact source and revision."
        )
        evidence_paths = []
    else:
        investigation_status = "new"
        disposition = "needs-verification" if entry.get("review") != "dismissed" else "dismissed"
        evidence_status = "metadata-only"
        findings = None
        next_action = (
            "Verify source, exact revision, original inputs, and local replay before classifying."
            if entry.get("review") != "dismissed" else "Retain the dismissed report in the historical ledger."
        )
        evidence_paths = []

    return {
        "id": entry["id"],
        "identity": current_identity,
        "presence": (
            "dismissed" if entry.get("review") == "dismissed" else
            "handled" if entry.get("handledAt") is not None else
            "unhandled" if entry.get("review") in ("accepted", "pending") else "other"
        ),
        "investigationStatus": investigation_status,
        "evidenceStatus": evidence_status,
        "disposition": disposition,
        "findings": findings,
        "nextAction": next_action,
        "evidencePaths": evidence_paths,
        "priorRecords": [
            {
                "ledger": _relative_source(record["path"], history_root),
                "disposition": record["row"].get("disposition", "needs-verification"),
                "evidenceStatus": record["row"].get("evidenceStatus", "unknown"),
                "identityMatched": record in matching,
                "identitySource": record["identitySource"],
                "ledgerIdentityDifferences": record["ledgerIdentityDifferences"],
            }
            for record in sorted(records, key=lambda item: _history_priority(item["path"], item["row"]))
        ],
    }
