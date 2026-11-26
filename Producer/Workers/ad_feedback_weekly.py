"""Capture a private, repeat-safe weekly ad-feedback intake report.

This runner reads the app-owned inbox and prior local ledgers. It never edits
feedback, writes the app queue, opens Wilted, or performs a model replay.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import stat
import sys
import tempfile
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from ad_feedback_weekly_history import (
    WeeklyReportError,
    has_operator_annotations as _has_operator_annotations,
    identity as _identity,
    load_history as _load_history,
    new_ledger_row as _new_ledger_row,
    prior_paths as _prior_paths,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FEEDBACK = Path.home() / "Library" / "Application Support" / "Wilted" / "ad-feedback.json"
DEFAULT_RUNS_ROOT = REPO_ROOT / ".logs" / "ad-feedback-weekly"
DEFAULT_HISTORY_ROOT = REPO_ROOT / ".logs"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _load_feedback(path: Path) -> tuple[bytes, list[dict[str, Any]]]:
    """Read and validate the owner inbox without modifying it."""
    try:
        raw = path.read_bytes()
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WeeklyReportError("the ad-feedback inbox could not be read as UTF-8 JSON") from error
    if (not isinstance(payload, dict) or type(payload.get("version")) is not int
            or payload.get("version") not in (1, 2)):
        raise WeeklyReportError("the ad-feedback inbox has an unsupported version")
    entries = payload.get("entries")
    if not isinstance(entries, list):
        raise WeeklyReportError("the ad-feedback inbox has no entries list")
    if payload["version"] == 2 and not isinstance(payload.get("handledActions"), list):
        raise WeeklyReportError("the version-2 inbox has no action receipt list")
    seen: set[str] = set()
    valid: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise WeeklyReportError("the ad-feedback inbox contains a malformed entry")
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id or entry_id in seen:
            raise WeeklyReportError("the ad-feedback inbox has a missing or repeated report ID")
        seen.add(entry_id)
        valid.append(entry)
    return raw, valid


def _private_directory(path: Path) -> None:
    try:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = path.lstat()
    except OSError as error:
        raise WeeklyReportError(f"could not prepare a private weekly report directory: {path.name}") from error
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise WeeklyReportError("weekly report directories must be owner-only and owned by this user")


def _atomic_create(path: Path, data: bytes) -> bool:
    """Create immutable evidence once; accept only a byte-identical retry."""
    if path.exists() or path.is_symlink():
        _check_private_file(path)
        if path.read_bytes() != data:
            raise WeeklyReportError(f"immutable weekly evidence conflicts with an existing file: {path.name}")
        try:
            _fsync_existing_file(path)
            _fsync_directory(path.parent)
        except OSError as error:
            raise WeeklyReportError(f"could not confirm weekly evidence durability: {path.name}") from error
        return False
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path, follow_symlinks=False)
            created = True
        except FileExistsError:
            _check_private_file(path)
            if path.read_bytes() != data:
                raise WeeklyReportError(f"immutable weekly evidence conflicts with an existing file: {path.name}")
            created = False
        _fsync_directory(path.parent)
        return created
    except OSError as error:
        raise WeeklyReportError(f"could not save immutable weekly evidence: {path.name}") from error
    finally:
        temporary.unlink(missing_ok=True)


def _atomic_replace(path: Path, data: bytes) -> None:
    """Atomically replace a mutable report without appending duplicate output."""
    if path.exists() or path.is_symlink():
        _check_private_file(path)
        if path.read_bytes() == data:
            try:
                _fsync_existing_file(path)
                _fsync_directory(path.parent)
            except OSError as error:
                raise WeeklyReportError(f"could not confirm weekly report durability: {path.name}") from error
            return
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    except OSError as error:
        raise WeeklyReportError(f"could not atomically update weekly report: {path.name}") from error
    finally:
        temporary.unlink(missing_ok=True)


def _check_private_file(path: Path) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise WeeklyReportError(f"weekly report file could not be inspected: {path.name}") from error
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) & 0o077):
        raise WeeklyReportError("weekly report files must be owner-only regular files")


def _fsync_existing_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _load_existing_ledger(path: Path, snapshot_sha: str) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    _check_private_file(path)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WeeklyReportError("an existing weekly ledger is unreadable and was left untouched") from error
    if (not isinstance(value, dict) or value.get("schemaVersion") != 1
            or value.get("snapshotSHA256") != snapshot_sha
            or not isinstance(value.get("entries"), list)):
        raise WeeklyReportError("an existing weekly ledger does not match this immutable snapshot")
    entries = value["entries"]
    if any(not isinstance(row, dict) or not isinstance(row.get("id"), str) for row in entries):
        raise WeeklyReportError("an existing weekly ledger contains malformed rows")
    if len({row["id"] for row in entries}) != len(entries):
        raise WeeklyReportError("an existing weekly ledger repeats a report ID")
    return entries


def _merge_ledger(
    snapshot_sha: str, week_start: str, captured_at: str, entries: list[dict[str, Any]],
    prior_by_id: dict[str, list[dict[str, Any]]], history_root: Path, existing: list[dict[str, Any]],
    history_manifest: list[dict[str, str]],
) -> dict[str, Any]:
    existing_by_id = {row["id"]: row for row in existing}
    rows = []
    for entry in entries:
        row = _new_ledger_row(entry, prior_by_id.get(entry["id"], []), history_root)
        old = existing_by_id.pop(entry["id"], None)
        if old is not None:
            if old.get("identity") != row["identity"]:
                raise WeeklyReportError("an existing ledger row changed identity; it was not overwritten")
            if _has_operator_annotations(old):
                # Keep human notes while refreshing state generated from prior ledgers.
                for key, value in old.items():
                    if key not in {"id", "identity", "presence", "investigationStatus", "priorRecords"}:
                        row[key] = value
        rows.append(row)
    rows.extend(existing_by_id.values())
    rows.sort(key=lambda row: row["id"])
    return {
        "schemaVersion": 1,
        "weekStart": week_start,
        "capturedAt": captured_at,
        "snapshotSHA256": snapshot_sha,
        "historyLedgers": history_manifest,
        "entries": rows,
    }


def _summarize(snapshot: dict[str, Any]) -> dict[str, Any]:
    rows = snapshot["entries"]
    presence = Counter(row["presence"] for row in rows)
    investigation = Counter(row["investigationStatus"] for row in rows)
    unhandled = [row for row in rows if row["presence"] == "unhandled"]
    previous_dispositions = Counter(
        row["disposition"] for row in unhandled
        if row["investigationStatus"] == "previously-investigated"
    )
    return {
        "total": len(rows),
        "unhandled": len(unhandled),
        "handled": presence["handled"],
        "dismissed": presence["dismissed"],
        "other": presence["other"],
        "unhandledKinds": dict(sorted(Counter(row["identity"].get("kind", "unknown") for row in unhandled).items())),
        "new": investigation["new"],
        "previouslyInvestigated": investigation["previously-investigated"],
        "previouslyCaptured": investigation["previously-captured"],
        "changedSincePrior": investigation["changed-since-prior"],
        "previousDispositions": dict(sorted(previous_dispositions.items())),
    }


def _render_report(snapshot: dict[str, Any], summary: dict[str, Any]) -> bytes:
    """Render a stable private report; reruns replace this file rather than append."""
    rows = snapshot["entries"]
    sections = [
        f"# Ad feedback intake: week of {snapshot['weekStart']}",
        "",
        f"- Snapshot SHA-256: `{snapshot['snapshotSHA256']}`",
        f"- Captured: {snapshot['capturedAt']}",
        f"- Present: {summary['total']} reports; {summary['unhandled']} active and unhandled; "
        f"{summary['handled']} handled; {summary['dismissed']} dismissed.",
        f"- Unhandled kinds: {', '.join(f'{kind} {count}' for kind, count in summary['unhandledKinds'].items()) or 'none'}.",
        f"- History: {summary['new']} new; {summary['previouslyInvestigated']} previously investigated; "
        f"{summary['previouslyCaptured']} previously captured but not resolved; "
        f"{summary['changedSincePrior']} changed since prior evidence.",
        f"- Prior dispositions among unhandled reports: "
        f"{', '.join(f'{name} {count}' for name, count in summary['previousDispositions'].items()) or 'none'}.",
        "",
        "The runner only snapshots and reconciles ledgers. It does not replay, relabel, dismiss, "
        "mark handled, write the owner inbox, enqueue an app action, or launch a model.",
        "",
        "| Feedback ID | Kind | Current state | Investigation | Disposition |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        sections.append(
            f"| `{row['id']}` | {row['identity'].get('kind') or 'unknown'} | {row['presence']} | "
            f"{row['investigationStatus']} | {row['disposition']} |"
        )
    return ("\n".join(sections) + "\n").encode("utf-8")


def _run_is_complete(run_dir: Path, week_start: str) -> bool:
    """Check that every saved projection agrees with its immutable snapshot."""
    paths = [run_dir / name for name in
             ("ad-feedback.json", "run.json", "ledger.json", "REPORT.md", "summary.json")]
    if not all(path.is_file() for path in paths):
        return False
    snapshot_path, run_path, ledger_path, report_path, summary_path = paths
    try:
        for path in paths: _check_private_file(path)
        raw = snapshot_path.read_bytes()
        digest = _sha256(raw)
        entries = _validate_payload(json.loads(raw.decode("utf-8")))
        metadata = json.loads(run_path.read_text(encoding="utf-8"))
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        ledger_by_id = {row["id"]: row for row in _load_existing_ledger(ledger_path, digest)}
        if (run_dir.name != digest or not isinstance(metadata, dict)
                or metadata.get("snapshotSHA256") != digest or metadata.get("weekStart") != week_start
                or not isinstance(ledger, dict) or ledger.get("weekStart") != week_start
                or set(ledger_by_id) != {entry["id"] for entry in entries}
                or any(ledger_by_id[entry["id"]].get("identity") != _identity(entry) for entry in entries)):
            return False
        expected_summary = _summarize(ledger)
        return (summary == expected_summary
                and report_path.read_bytes() == _render_report(ledger, expected_summary))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, WeeklyReportError,
            KeyError, TypeError, ValueError):
        return False


def _process_snapshot(
    run_dir: Path, raw: bytes, week_start: str, history_root: Path,
    prior_by_id: dict[str, list[dict[str, Any]]], history_manifest: list[dict[str, str]],
    captured_at: str | None = None,
) -> dict[str, Any]:
    snapshot_sha = _sha256(raw)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WeeklyReportError("a saved weekly snapshot is not valid UTF-8 JSON") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("entries"), list):
        raise WeeklyReportError("a saved weekly snapshot has an invalid top-level shape")
    entries = _validate_payload(payload)
    if run_dir.name != snapshot_sha:
        raise WeeklyReportError("saved weekly snapshot does not match its content-addressed directory")
    _private_directory(run_dir)
    snapshot_path = run_dir / "ad-feedback.json"
    _atomic_create(snapshot_path, raw)

    run_path = run_dir / "run.json"
    if run_path.exists():
        _check_private_file(run_path)
        try:
            metadata = json.loads(run_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise WeeklyReportError("an existing weekly run record is unreadable") from error
        if (not isinstance(metadata, dict) or metadata.get("snapshotSHA256") != snapshot_sha
                or metadata.get("weekStart") != week_start):
            raise WeeklyReportError("an existing weekly run record conflicts with the snapshot")
    else:
        metadata = {
            "schemaVersion": 1,
            "weekStart": week_start,
            "capturedAt": captured_at or datetime.now().astimezone().isoformat(timespec="seconds"),
            "snapshotSHA256": snapshot_sha,
        }
        _atomic_create(run_path, _json_bytes(metadata))

    old_rows = _load_existing_ledger(run_dir / "ledger.json", snapshot_sha)
    merged = _merge_ledger(
        snapshot_sha, week_start, metadata["capturedAt"], entries, prior_by_id, history_root,
        old_rows, history_manifest,
    )
    _atomic_replace(run_dir / "ledger.json", _json_bytes(merged))
    summary = _summarize(merged)
    report_bytes = _render_report(merged, summary)
    _atomic_replace(run_dir / "REPORT.md", report_bytes)
    _atomic_replace(run_dir / "summary.json", _json_bytes(summary))
    return {"runDirectory": run_dir, "snapshotSHA256": snapshot_sha, "summary": summary}


def _validate_payload(payload: object) -> list[dict[str, Any]]:
    """Apply envelope and duplicate-ID checks to a decoded snapshot."""
    if (not isinstance(payload, dict) or type(payload.get("version")) is not int
            or payload.get("version") not in (1, 2)):
        raise WeeklyReportError("the ad-feedback snapshot has an unsupported version")
    entries = payload.get("entries")
    if not isinstance(entries, list):
        raise WeeklyReportError("the ad-feedback snapshot has no entries list")
    if payload["version"] == 2 and not isinstance(payload.get("handledActions"), list):
        raise WeeklyReportError("the version-2 snapshot has no action receipt list")
    seen: set[str] = set()
    valid: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise WeeklyReportError("the ad-feedback snapshot contains a malformed entry")
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id or entry_id in seen:
            raise WeeklyReportError("the ad-feedback snapshot has a missing or repeated report ID")
        seen.add(entry_id)
        valid.append(entry)
    return valid


def _week_start(value: str | None) -> str:
    if value is None:
        today = datetime.now().astimezone().date()
        monday = today - timedelta(days=today.weekday())
        return monday.isoformat()
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise WeeklyReportError("week start must be an ISO date") from error
    if parsed.weekday() != 0:
        raise WeeklyReportError("week start must be a Monday")
    return parsed.isoformat()


def run_weekly(
    *, feedback: Path = DEFAULT_FEEDBACK, runs_root: Path = DEFAULT_RUNS_ROOT,
    history_root: Path = DEFAULT_HISTORY_ROOT, week_start: str | None = None,
    prior_ledgers: list[Path] | None = None,
) -> list[dict[str, Any]]:
    """Capture the inbox and resume every incomplete report for the current week.

    Args:
        feedback: The app-owned inbox, opened read-only.
        runs_root: Private local root for snapshots, ledgers, and reports.
        history_root: Root used to discover prior ad-feedback ledgers.
        week_start: Local Monday as ``YYYY-MM-DD``; defaults to this week's Monday.
        prior_ledgers: Optional explicit history inputs, mainly for isolated tests.
    Returns:
        One result for each incomplete saved snapshot and the current inbox snapshot.
    """
    week = _week_start(week_start)
    feedback = feedback.expanduser().resolve()
    runs_root = runs_root.expanduser().resolve()
    history_root = history_root.expanduser().resolve()
    if feedback == runs_root or feedback.is_relative_to(runs_root):
        raise WeeklyReportError("weekly output may not contain the owner inbox")
    raw, _entries = _load_feedback(feedback)
    paths = _prior_paths(history_root, prior_ledgers)

    _private_directory(runs_root)
    week_dir = runs_root / week
    _private_directory(week_dir)
    lock_path = week_dir / ".runner.lock"
    try:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError as error:
        raise WeeklyReportError("weekly runner lock is unavailable") from error
    try:
        lock_info = os.fstat(descriptor)
        if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.geteuid()
                or stat.S_IMODE(lock_info.st_mode) & 0o077 or lock_info.st_nlink != 1):
            raise WeeklyReportError("weekly runner lock must be a private owner-only file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise WeeklyReportError("a weekly intake report is already running for this Monday") from error

        results: list[dict[str, Any]] = []
        current_sha = _sha256(raw)
        for run_dir in sorted(week_dir.iterdir()):
            if not run_dir.is_dir() or run_dir.name.startswith("."):
                continue
            saved = run_dir / "ad-feedback.json"
            if (saved.is_file() and run_dir.name != current_sha
                    and not _run_is_complete(run_dir, week)):
                run_history = [path for path in paths if path != (run_dir / "ledger.json").resolve()]
                prior_by_id, history_manifest = _load_history(run_history)
                results.append(_process_snapshot(
                    run_dir, saved.read_bytes(), week, history_root, prior_by_id,
                    history_manifest,
                ))

        run_dir = week_dir / current_sha
        _private_directory(run_dir)
        run_history = [path for path in paths if path != (run_dir / "ledger.json").resolve()]
        prior_by_id, history_manifest = _load_history(run_history)
        results.append(_process_snapshot(
            run_dir, raw, week, history_root, prior_by_id, history_manifest,
        ))
        return results
    finally:
        os.close(descriptor)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feedback", type=Path, default=DEFAULT_FEEDBACK,
                        help="read-only app-owned ad-feedback JSON")
    parser.add_argument("--runs-root", type=Path, default=DEFAULT_RUNS_ROOT,
                        help="private output root; defaults to .logs/ad-feedback-weekly")
    parser.add_argument("--history-root", type=Path, default=DEFAULT_HISTORY_ROOT,
                        help="local root searched for earlier ad-feedback ledgers")
    parser.add_argument("--prior-ledger", type=Path, action="append", default=None,
                        help="explicit prior ledger; may be repeated and disables discovery")
    parser.add_argument("--week-start", default=None,
                        help="local Monday YYYY-MM-DD; defaults to this week's Monday")
    args = parser.parse_args(argv)
    try:
        results = run_weekly(
            feedback=args.feedback, runs_root=args.runs_root, history_root=args.history_root,
            week_start=args.week_start, prior_ledgers=args.prior_ledger,
        )
    except WeeklyReportError as error:
        print(f"ad-feedback.weekly: {error}", file=sys.stderr)
        return 2
    for result in results:
        summary = result["summary"]
        print(
            f"ad-feedback.weekly snapshot={result['snapshotSHA256']} "
            f"present={summary['total']} unhandled={summary['unhandled']} "
            f"new={summary['new']} previously_investigated={summary['previouslyInvestigated']} "
            f"report={result['runDirectory'] / 'REPORT.md'}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
