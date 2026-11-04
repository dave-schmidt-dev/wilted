"""Protected and lossless retention of quiet developer evidence in .logs."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import time
import uuid
from pathlib import Path

from .core import (ArchiveError, archive_paths, check_deadline, ensure_safe_path,
                   identity, lsof_only_external_smbfs_warning, remove_tree_verified,
                   snapshot_tree, verify_archive, verify_tree)
from .bundles import export_bundle

QUIET_SECONDS = 14 * 24 * 60 * 60
PROTECTED_NAMES = ("README.md", "INVARIANTS.md", "TASKS.md")
RUNTIME_NAMES = {"retention-due.json", "retention-run.lock"}
DOC_PATH = re.compile(r"(?:^|(?<=[^A-Za-z0-9_./-]))((?:[^\s\"'`<>|]*?/)?\.logs/[A-Za-z0-9._/-]+)")


def _logs_root(repo: Path) -> Path:
    root = repo.expanduser().absolute()
    if root.is_symlink() or not root.is_dir() or root.resolve(strict=True) != root:
        raise ArchiveError("repository-root-invalid")
    logs = root / ".logs"
    if logs.exists() and (logs.is_symlink() or not logs.is_dir()):
        raise ArchiveError("logs-root-invalid")
    return logs


def _relative_logs_path(repo: Path, raw: str) -> Path | None:
    """Normalize one citation, retaining an uncertain prefix as a pin."""
    token = raw.rstrip(".,;:!?)]}>")
    if ":" in token:
        token = token.split(":", 1)[0]
    marker = token.find(".logs/")
    if marker < 0:
        return None
    relative = Path(token[marker:])
    if relative.is_absolute() or ".." in relative.parts:
        return None
    return repo / relative


def pinned_paths(repo: Path) -> tuple[Path, ...] | None:
    """Read evidence citations from required docs; None means fail closed."""
    pins: set[Path] = set()
    for name in PROTECTED_NAMES:
        document = repo / name
        if not document.exists():
            continue
        try:
            body = document.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return None
        for match in DOC_PATH.finditer(body):
            path = _relative_logs_path(repo, match.group(1))
            if path is not None:
                pins.add(path)
    return tuple(sorted(pins))


def protected(path: Path, *, repo: Path | None = None, pins: tuple[Path, ...] = ()) -> bool:
    """Return true for explicit retention roots, personal evidence, or citations."""
    parts = path.parts
    logs_index = parts.index(".logs") if ".logs" in parts else -1
    reserved = False
    if logs_index >= 0:
        suffix = parts[logs_index + 1:]
        reserved = (
            any(part == "retained-evidence" or part.startswith("retention-") for part in suffix)
            or ("delivery" in suffix and any(part.startswith("storage-retained-") for part in suffix))
            or any(part.startswith(("ad-", "giant-bombcast-")) for part in suffix)
        )
    if path.name in PROTECTED_NAMES or path.name in RUNTIME_NAMES:
        return True
    if path.name.startswith(("storage-retention.log", "retention-launchd.")):
        return True
    if reserved:
        return True
    candidate = path.absolute()
    for pin in pins:
        if candidate == pin or pin in candidate.parents:
            return True
    return False


def evidence_kind(path: Path) -> str | None:
    """Classify only evidence types with a lossless recovery route."""
    name = path.name.lower()
    if name.startswith(("storage-retention.log", "retention-launchd.")):
        return None
    if name.endswith((".log", ".xcactivitylog")):
        return "log"
    if path.suffix.lower() in {".json", ".jsonl", ".md", ".status", ".txt"} and any(
        marker in name for marker in ("receipt", "result", "authorization", "status", "manifest")
    ):
        return "receipt"
    if path.suffix.lower() in {".zip", ".tar", ".gz", ".tgz"} and any(
        marker in name for marker in ("source", "snapshot", "archive", "candidate", "inputs")
    ):
        return "source-archive"
    if path.suffix.lower() == ".xcresult":
        return "xcresult"
    if path.suffix.lower() == ".logarchive":
        return "logarchive"
    return None


def _safe_walk_root(logs: Path, current: Path) -> bool:
    try:
        ensure_safe_path(logs, current, allow_root=True)
        return True
    except ArchiveError:
        return False


def _newest_mtime(path: Path, root: Path, deadline: float | None) -> float:
    """Find a bundle's newest timestamp without reading large file contents."""
    start = path.lstat()
    if stat.S_ISLNK(start.st_mode) or not stat.S_ISDIR(start.st_mode):
        raise ArchiveError("bundle-not-plain-directory")
    device = root.stat().st_dev
    newest = start.st_mtime
    def walk_error(error: OSError) -> None:
        raise ArchiveError(f"bundle-unreadable:{error.filename}") from error
    for current, dirs, files in os.walk(path, topdown=True, onerror=walk_error, followlinks=False):
        check_deadline(deadline)
        base = Path(current)
        for name in dirs + files:
            child = base / name
            info = child.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_dev != device:
                raise ArchiveError("bundle-link-or-mount")
            newest = max(newest, info.st_mtime)
    return newest


def candidates(repo: Path, now: float | None = None,
               deadline: float | None = None) -> list[Path]:
    """List old, unpinned developer evidence below .logs only."""
    now = time.time() if now is None else now
    repo = repo.expanduser().absolute()
    logs = _logs_root(repo)
    if not logs.exists():
        return []
    pins = pinned_paths(repo)
    if pins is None:
        return []
    result: list[Path] = []
    def walk_error(error: OSError) -> None:
        raise ArchiveError(f"logs-unreadable:{error.filename}") from error
    for current, dirs, files in os.walk(logs, topdown=True, onerror=walk_error, followlinks=False):
        check_deadline(deadline)
        base = Path(current)
        if not _safe_walk_root(logs, base):
            dirs[:] = []
            continue
        kept_dirs: list[str] = []
        for name in sorted(dirs):
            path = base / name
            kind = evidence_kind(path)
            if protected(path, repo=repo, pins=pins) or name.startswith("."):
                continue
            if kind in {"xcresult", "logarchive"}:
                try:
                    newest = _newest_mtime(path, logs, deadline)
                    if now - newest >= QUIET_SECONDS:
                        result.append(path)
                except (OSError, ArchiveError):
                    pass
                continue
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in sorted(files):
            path = base / name
            kind = evidence_kind(path)
            if kind is None or protected(path, repo=repo, pins=pins):
                continue
            try:
                ensure_safe_path(logs, path)
                info = path.lstat()
                if stat.S_ISREG(info.st_mode) and now - info.st_mtime >= QUIET_SECONDS:
                    result.append(path)
            except (OSError, ArchiveError):
                continue
    def age_key(path: Path) -> tuple[float, str]:
        try:
            return path.lstat().st_mtime, path.as_posix()
        except OSError:
            return float("inf"), path.as_posix()
    return sorted(set(result), key=age_key)


def _open_reference(path: Path) -> tuple[bool, str]:
    """Fail closed on any open reference or unavailable lsof probe."""
    executable = shutil.which("lsof")
    if not executable:
        return True, "lsof-unavailable"
    args = (executable, "-t", "+D", str(path)) if path.is_dir() else (executable, "-t", "--", str(path))
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=4, check=False)
    except (OSError, subprocess.SubprocessError):
        return True, "lsof-unknown"
    stderr_safe = (not result.stderr.strip()
                   or lsof_only_external_smbfs_warning(result.stderr, path))
    if result.returncode in {0, 1} and not result.stdout.strip() and stderr_safe:
        return False, ""
    if result.returncode == 0 and not result.stdout.strip():
        return False, ""
    return True, "open-or-liveness-unknown"


def _expire_incomplete(path: Path, expected: object, root: Path, reason: str,
                       now: float, deadline: float | None) -> dict[str, object]:
    """Delete an old incomplete result with fresh safeguards and a durable receipt."""
    logs = _logs_root(root)
    pins = pinned_paths(root)
    if pins is None or protected(path, repo=root, pins=pins) or any(
            path == pin or path in pin.parents for pin in pins):
        raise ArchiveError("incomplete-result-protected")
    if now - _newest_mtime(path, logs, deadline) < QUIET_SECONDS:
        raise ArchiveError("incomplete-result-too-recent")
    busy, busy_reason = _open_reference(path)
    if busy:
        raise ArchiveError(busy_reason)
    if not verify_tree(path, expected, root=logs, deadline=deadline):
        raise ArchiveError("incomplete-result-changed")
    allocated = sum((path / entry[0]).stat().st_blocks * 512
                    for entry in expected.entries if entry[1] == "file")
    receipt = {"source_path": path.relative_to(root).as_posix(), "reason": reason,
               "allocated_bytes": allocated, "source_sha256": expected.digest,
               "archive_created": False, "status": "pending", "recorded_at": now}
    directory = ensure_safe_path(logs, logs / "retained-evidence")
    target = directory / ("expired-result-" + uuid.uuid4().hex + ".json")

    def write_receipt() -> None:
        temporary = target.with_suffix(".partial")
        try:
            with temporary.open("x") as stream:
                json.dump(receipt, stream, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
            descriptor = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            temporary.unlink(missing_ok=True)

    write_receipt()  # Failure to retain intent prevents deletion.
    remove_tree_verified(path, expected, root=logs, deadline=deadline)
    receipt["status"] = "removed"
    try:
        write_receipt()
    except OSError:
        # The durable pending receipt survives; the enclosing run must still
        # report the completed deletion rather than a misleading source skip.
        receipt["receipt_status"] = "pending-confirmation"
    return {**receipt, "receipt": str(target)}


def compact(repo: Path, archive: Path, *, now: float | None = None, apply: bool = False,
            deadline: float | None = None) -> dict[str, object]:
    """Archive old evidence or expire incomplete results with deletion receipts."""
    now = time.time() if now is None else now
    try:
        selected = candidates(repo, now, deadline)
    except TimeoutError:
        return {"selected": [], "status": "skipped", "reason": "budget-exhausted"}
    result: dict[str, object] = {"selected": [str(path) for path in selected], "status": "dry-run"}
    if not apply or not selected:
        return result
    check_deadline(deadline)
    root = repo.expanduser().absolute()
    logs = _logs_root(root)
    pins = pinned_paths(root)
    if pins is None:
        return {**result, "status": "skipped", "reason": "pin-documents-unreadable"}
    snapshots: dict[Path, object] = {}
    eligible: list[Path] = []
    skipped: list[dict[str, str]] = []
    for path in selected:
        try:
            check_deadline(deadline)
        except TimeoutError:
            skipped.append({"path": str(path), "reason": "budget-exhausted"})
            break
        try:
            ensure_safe_path(logs, path)
            if protected(path, repo=root, pins=pins):
                skipped.append({"path": str(path), "reason": "protected"})
                continue
            busy, reason = _open_reference(path)
            if busy:
                skipped.append({"path": str(path), "reason": reason})
                continue
            snapshots[path] = snapshot_tree(path, root=logs, deadline=deadline)
            eligible.append(path)
        except (OSError, ArchiveError) as error:
            skipped.append({"path": str(path), "reason": error.__class__.__name__})
    if not eligible:
        return {**result, "status": "skipped", "skipped": skipped}

    evidence_root = logs / "retained-evidence"
    evidence_root.mkdir(parents=True, exist_ok=True)
    if evidence_root.is_symlink() or evidence_root.stat().st_dev != logs.stat().st_dev:
        return {**result, "status": "skipped", "reason": "retention-root-unsafe"}
    removed: list[str] = []
    discarded: list[dict[str, object]] = []
    retained_packs: list[str] = []
    total_files = 0
    total_bytes = 0
    for index, path in enumerate(eligible, start=1):
        try:
            check_deadline(deadline)
        except TimeoutError:
            skipped.append({"path": str(path), "reason": "budget-exhausted"})
            break
        stage: Path | None = None
        pack: Path | None = None
        pack_created = False
        removal_attempted = False
        source_removed = False
        archive_inputs: list[Path] = []
        kind = evidence_kind(path)
        manifest: dict[str, object] | None = None
        try:
            if kind == "xcresult" and not (path / "Info.plist").exists():
                discarded.append(_expire_incomplete(
                    path, snapshots[path], root, "missing-root-metadata", now, deadline))
                removed.append(str(path))
                continue
            if kind in {"xcresult", "logarchive", "source-archive"}:
                prefix = hashlib.sha256(path.relative_to(root).as_posix().encode()).hexdigest()[:16]
                stage = evidence_root / f".export-{prefix}-{os.getpid()}-{index}"
                export = export_bundle(path, stage, deadline=deadline)
                if export.get("status") != "compacted":
                    if kind == "xcresult" and export.get("reason") == "xcresult-status-unknown":
                        discarded.append(_expire_incomplete(
                            path, snapshots[path], root, "unknown-test-outcome", now, deadline))
                        removed.append(str(path))
                        continue
                    skipped.append({"path": str(path), "reason": str(export.get("reason", "export-retained"))})
                    continue
                expected = snapshots[path]
                if export.get("source_fingerprint") != expected.digest:
                    skipped.append({"path": str(path), "reason": "source-fingerprint-mismatch"})
                    continue
                output_root = Path(str(export["output_directory"]))
                ensure_safe_path(evidence_root, output_root)
                output_records = export.get("outputs")
                if not isinstance(output_records, list) or not output_records:
                    skipped.append({"path": str(path), "reason": "compact-export-empty"})
                    continue
                listed: set[str] = set()
                for row in output_records:
                    relative = Path(str(row["path"]))
                    if relative.is_absolute() or ".." in relative.parts:
                        raise ArchiveError("export-path-invalid")
                    output = ensure_safe_path(output_root, output_root / relative)
                    current = identity(output, root=evidence_root)
                    if current.digest != row.get("sha256") or current.size != int(row.get("bytes", -1)):
                        raise ArchiveError("compact-export-hash-mismatch")
                    listed.add(relative.as_posix())
                actual = {item.relative_to(output_root).as_posix()
                          for item in output_root.rglob("*") if item.is_file() and not item.is_symlink()}
                if actual != listed:
                    raise ArchiveError("compact-export-file-set-mismatch")
                receipt = {"format": 1, "source_path": path.relative_to(root).as_posix(),
                           "source_sha256": expected.digest, "kind": kind,
                           "result": export.get("result"), "outputs": output_records}
                receipt_path = output_root / "retention-source.json"
                receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                archive_inputs = [output_root]
            else:
                archive_inputs = [path]
            check_deadline(deadline)
            token = hashlib.sha256(path.relative_to(root).as_posix().encode()).hexdigest()[:12]
            pack = archive / f"item-{index:05d}-{token}"
            manifest = archive_paths(archive_inputs, root, pack, deadline=deadline)
            pack_created = True
            verify_archive(pack)
            # Generic files are copied byte-for-byte. Exported bundle packs
            # contain the complete exporter-listed file set plus provenance.
            if kind in {"xcresult", "logarchive", "source-archive"}:
                packed_paths = {str(row.get("path")) for row in manifest.get("files", [])
                                if isinstance(row, dict)}
                wanted_paths = {item.relative_to(root).as_posix() for item in archive_inputs[0].rglob("*")
                                if item.is_file() and not item.is_symlink()}
                if not wanted_paths.issubset(packed_paths):
                    raise ArchiveError("archive-does-not-cover-export")
            elif not _archive_covers(path, snapshots[path], manifest, root):
                raise ArchiveError("archive-does-not-cover-source")
            if stage is not None:
                output_root = Path(str(export["output_directory"]))
                ensure_safe_path(evidence_root, output_root)
                shutil.rmtree(output_root)
                stage = None
            # Recheck the exact source snapshot and current protection immediately
            # before its rename-based removal.
            busy, reason = _open_reference(path)
            if busy:
                skipped.append({"path": str(path), "reason": reason})
                continue
            if (protected(path, repo=root, pins=pins)
                    or not verify_tree(path, snapshots[path], root=logs, deadline=deadline)):
                skipped.append({"path": str(path), "reason": "protected-or-source-changed"})
                continue
            removal_attempted = True
            remove_tree_verified(path, snapshots[path], root=logs, deadline=deadline)
            source_removed = True
            removed.append(str(path))
            retained_packs.append(str(pack))
            total_files += len(manifest.get("files", []))
            total_bytes += int(manifest.get("unique_bytes", 0))
        except (OSError, ArchiveError, TimeoutError, ValueError, KeyError, TypeError) as error:
            skipped.append({"path": str(path), "reason": error.__class__.__name__})
        finally:
            # A recovery pack is retained only if its source was removed, or
            # if the source vanished/changed during the final removal race.
            # A routine busy/protected skip discards this run's exact pack so
            # weekly retries cannot accumulate duplicate protected archives.
            if stage is not None and stage.exists() and not stage.is_symlink():
                try:
                    ensure_safe_path(evidence_root, stage)
                    shutil.rmtree(stage)
                except (OSError, ArchiveError):
                    skipped.append({"path": str(path), "reason": "export-stage-cleanup-failed"})
            if pack_created and pack is not None and not source_removed:
                if removal_attempted:
                    # Removal may have partially completed; keep the verified
                    # recovery pack even if a path with the same name remains.
                    retained_packs.append(str(pack))
                    if manifest is not None:
                        total_files += len(manifest.get("files", []))
                        total_bytes += int(manifest.get("unique_bytes", 0))
                else:
                    try:
                        ensure_safe_path(archive, pack)
                        if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
                            raise ArchiveError("safe-recursive-delete-unavailable")
                        shutil.rmtree(pack)
                    except (OSError, ArchiveError):
                        skipped.append({"path": str(path), "reason": "unused-pack-cleanup-failed"})
                        if pack.exists() and not pack.is_symlink():
                            retained_packs.append(str(pack))
                            if manifest is not None:
                                total_files += len(manifest.get("files", []))
                                total_bytes += int(manifest.get("unique_bytes", 0))

    return {"status": "removed" if removed else "kept", "selected": [str(p) for p in selected],
            "removed": removed, "skipped": skipped, "archives": retained_packs,
            "discarded": discarded,
            "files": total_files, "unique_bytes": total_bytes}


def _archive_covers(path: Path, expected: object, manifest: dict[str, object], root: Path) -> bool:
    """Confirm archive manifest maps every current file beneath the target."""
    if not hasattr(expected, "entries"):
        return False
    prefix = path.relative_to(root).as_posix()
    if path.is_file():
        wanted = {prefix}
    else:
        wanted = {f"{prefix}/{row[0]}" for row in expected.entries if row[1] == "file"}
    actual = {str(row.get("path")) for row in manifest.get("files", []) if isinstance(row, dict)}
    return wanted.issubset(actual)
