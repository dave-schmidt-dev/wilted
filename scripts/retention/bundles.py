"""Export verifiable compact replacements for old Apple evidence bundles.

This module never removes source bundles. Callers may archive the returned
output files and remove a source only after independently verifying that
archive and rechecking the source fingerprint.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import subprocess
import tempfile
import time
from typing import Any
import zipfile

from .core import ArchiveError, check_deadline, ensure_safe_path, snapshot_tree

LOG_PREDICATE = (
    'process CONTAINS[c] "wilted" OR '
    'subsystem BEGINSWITH "com.zerodelta.wilted"'
)
MAX_COMMAND_SECONDS = 90
MAX_ARCHIVE_MEMBERS = 200_000
MAX_ARCHIVE_FILE_BYTES = 1024 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
SECRET_MEMBER_NAMES = {"auth.json", "credentials", ".netrc", "claude_desktop_config.json", ".claude.json"}


class ExportError(RuntimeError):
    """A compact export could not be safely produced."""


def _remaining(deadline: float | None) -> int:
    """Return a bounded command timeout or fail when the caller budget ended."""
    if deadline is None:
        return MAX_COMMAND_SECONDS
    remaining = int(deadline - time.monotonic())
    if remaining < 1:
        raise TimeoutError("retention work budget exhausted")
    return min(MAX_COMMAND_SECONDS, remaining)


def _run(command: tuple[str, ...], deadline: float | None) -> subprocess.CompletedProcess[bytes]:
    """Run one Apple export command with bounded time and captured diagnostics."""
    return subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=_remaining(deadline),
        check=False,
    )


def _file_record(path: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_BYTES), b""):
            digest.update(chunk)
            size += len(chunk)
    return {"path": path.name, "bytes": size, "sha256": digest.hexdigest()}


def _output_records(root: Path) -> list[dict[str, Any]]:
    """Inventory every exported regular file, including binary attachments."""
    records: list[dict[str, Any]] = []
    for current, dirs, files in os.walk(root, followlinks=False):
        base = Path(current)
        dirs.sort()
        for name in list(dirs):
            child = base / name
            if child.is_symlink() or not child.is_dir():
                raise ExportError("export-contains-linked-or-invalid-directory")
        for name in sorted(files):
            child = base / name
            if child.is_symlink() or not child.is_file():
                raise ExportError("export-contains-linked-or-invalid-file")
            record = _file_record(child)
            record["path"] = child.relative_to(root).as_posix()
            records.append(record)
    return records


def _export_xcresult(source: Path, staging: Path,
                     deadline: float | None) -> tuple[list[dict[str, Any]], str]:
    """Export a recognized result, its whole test tree and every failed attachment."""
    records: list[dict[str, Any]] = []
    for mode in ("summary", "tests"):
        completed = _run(("xcrun", "xcresulttool", "get", "test-results", mode,
                          "--path", str(source), "--compact"), deadline)
        if completed.returncode != 0:
            raise ExportError(f"xcresult-{mode}-failed")
        try:
            document = json.loads(completed.stdout.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ExportError(f"xcresult-{mode}-invalid-json") from error
        if mode == "summary":
            status = document.get("result") if isinstance(document, dict) else None
            if status not in {"Passed", "Failed"}:
                raise ExportError("xcresult-status-unknown")
        target = staging / f"test-results-{mode}.json"
        target.write_bytes(completed.stdout)
        record = _file_record(target)
        record["path"] = target.name
        if mode == "summary":
            record["result"] = status
        records.append(record)

    if status == "Failed":
        attachments = staging / "failure-attachments"
        attachments.mkdir()
        completed = _run(("xcrun", "xcresulttool", "export", "attachments",
                          "--path", str(source), "--output-path", str(attachments),
                          "--only-failures"), deadline)
        if completed.returncode != 0:
            raise ExportError("xcresult-failure-attachments-failed")
        records.extend(_output_records(attachments))
    return records, status


def _export_logarchive(source: Path, staging: Path,
                       deadline: float | None) -> list[dict[str, Any]]:
    """Export only filtered Wilted unified-log records, never the raw archive."""
    output = staging / "wilted-filtered.ndjson"
    completed = _run(("/usr/bin/log", "show", "--archive", str(source),
                      "--style", "ndjson", "--info", "--debug",
                      "--predicate", LOG_PREDICATE), deadline)
    if completed.returncode != 0:
        raise ExportError("logarchive-filtered-export-failed")
    output.write_bytes(completed.stdout)
    return [_file_record(output)]



def _safe_archive_name(raw_name: str) -> PurePosixPath:
    """Validate a member name without normalizing away traversal markers."""
    if "\\" in raw_name or "\x00" in raw_name or raw_name.startswith("/"):
        raise ExportError("archive-member-path-invalid")
    stripped = raw_name.rstrip("/")
    parts = stripped.split("/")
    if not stripped or any(part in {"", ".", ".."} for part in parts):
        raise ExportError("archive-member-path-invalid")
    return PurePosixPath(*parts)


def _stream_member(stream: Any, target: Path, digest: Any, *, deadline: float | None,
                   remaining_total: int) -> tuple[int, str]:
    """Copy a bounded archive member while hashing its exact bytes."""
    size = 0
    with target.open("xb") as output:
        while True:
            check_deadline(deadline)
            block = stream.read(CHUNK_BYTES)
            if not block:
                break
            size += len(block)
            if size > MAX_ARCHIVE_FILE_BYTES or size > remaining_total:
                raise ExportError("archive-uncompressed-size-limit")
            digest.update(block)
            output.write(block)
    return size, digest.hexdigest()


def _store_archive_member(stream: Any, staging: Path, *, deadline: float | None,
                          remaining_total: int) -> tuple[int, str]:
    """Store bytes once by SHA-256 and return size plus content identity."""
    temporary_dir = staging / ".member-work"
    temporary_dir.mkdir(exist_ok=True)
    temporary = temporary_dir / (str(time.time_ns()) + ".partial")
    try:
        size, digest = _stream_member(stream, temporary, hashlib.sha256(),
                                      deadline=deadline, remaining_total=remaining_total)
        content_dir = staging / "content"
        content_dir.mkdir(exist_ok=True)
        content = content_dir / digest
        if content.exists():
            if content.stat().st_size != size or _file_record(content)["sha256"] != digest:
                raise ExportError("archive-content-address-collision")
        else:
            os.replace(temporary, content)
        return size, digest
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        try:
            temporary_dir.rmdir()
        except OSError:
            pass


def _archive_entries(source: Path, staging: Path, deadline: float | None) -> list[dict[str, Any]]:
    """Read regular ZIP/TAR members without extraction or following links."""
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    total = 0

    def add(name: str, is_dir: bool, mode: int, modified: float, member_size: int,
            opener: Any, extra: dict[str, Any] | None = None) -> None:
        nonlocal total
        safe_name = _safe_archive_name(name)
        for component in safe_name.parts:
            folded = component.casefold()
            if folded in SECRET_MEMBER_NAMES or (folded.startswith(".env") and folded != ".env.example"):
                raise ExportError("archive-secret-bearing-member-name")
        key = safe_name.as_posix()
        if key in seen:
            raise ExportError("archive-duplicate-member-path")
        seen.add(key)
        row: dict[str, Any] = {"path": key, "kind": "directory" if is_dir else "file",
                               "mode": mode & 0o777, "mtime_ns": int(modified * 1_000_000_000)}
        if extra:
            row.update(extra)
        if is_dir:
            if member_size not in {0}:
                raise ExportError("archive-directory-has-data")
            records.append(row)
            return
        if member_size < 0 or member_size > MAX_ARCHIVE_FILE_BYTES or total + member_size > MAX_ARCHIVE_TOTAL_BYTES:
            raise ExportError("archive-uncompressed-size-limit")
        with opener() as stream:
            size, digest = _store_archive_member(stream, staging, deadline=deadline,
                                                remaining_total=MAX_ARCHIVE_TOTAL_BYTES - total)
        if size != member_size:
            raise ExportError("archive-member-size-mismatch")
        total += size
        row.update({"bytes": size, "sha256": digest, "content": "content/" + digest})
        records.append(row)
        if total > MAX_ARCHIVE_TOTAL_BYTES:
            raise ExportError("archive-uncompressed-size-limit")

    if zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            infos = archive.infolist()
            if len(infos) > MAX_ARCHIVE_MEMBERS:
                raise ExportError("archive-member-count-limit")
            for info in infos:
                check_deadline(deadline)
                mode = (info.external_attr >> 16) & 0xFFFF
                type_bits = stat.S_IFMT(mode)
                is_dir = info.is_dir()
                if type_bits not in {0, stat.S_IFDIR if is_dir else stat.S_IFREG}:
                    raise ExportError("archive-link-or-special-member")
                if info.flag_bits & 0x1:
                    raise ExportError("archive-encrypted-member")
                if is_dir:
                    add(info.filename, True, mode, time.mktime(info.date_time + (0, 0, -1)),
                        info.file_size, lambda: None)
                else:
                    add(info.filename, False, mode, time.mktime(info.date_time + (0, 0, -1)),
                        info.file_size, lambda item=info: archive.open(item, "r"))
    else:
        try:
            archive = tarfile.open(source, mode="r:*")
        except (tarfile.TarError, OSError) as error:
            raise ExportError("source-archive-unreadable") from error
        with archive:
            members = archive.getmembers()
            if len(members) > MAX_ARCHIVE_MEMBERS:
                raise ExportError("archive-member-count-limit")
            for info in members:
                check_deadline(deadline)
                if info.isdir():
                    add(info.name, True, info.mode, info.mtime, 0, lambda: None,
                        {"uid": info.uid, "gid": info.gid, "uname": info.uname, "gname": info.gname})
                elif info.isfile():
                    stream = archive.extractfile(info)
                    if stream is None:
                        raise ExportError("archive-member-unreadable")
                    add(info.name, False, info.mode, info.mtime, info.size,
                        lambda item=info: archive.extractfile(item),
                        {"uid": info.uid, "gid": info.gid, "uname": info.uname, "gname": info.gname})
                else:
                    raise ExportError("archive-link-or-special-member")
    records.sort(key=lambda row: str(row["path"]))
    (staging / "source-snapshot.json").write_text(
        json.dumps({"format": 1, "source_name": source.name, "members": records},
                   sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    return records


def restore_snapshot(snapshot: Path, destination: Path) -> dict[str, Any]:
    """Restore a source archive's ordinary member tree into a new directory.

    This recreates regular files and directories, not the original ZIP/TAR
    container. Link and special entries are never reconstructed.
    """
    raw_snapshot = Path(snapshot).expanduser().absolute()
    if raw_snapshot.is_symlink() or not raw_snapshot.is_dir():
        raise ExportError("snapshot-not-plain-directory")
    snapshot = raw_snapshot.resolve(strict=True)
    manifest_path = snapshot / "source-snapshot.json"
    if manifest_path.is_symlink() or not manifest_path.is_file() or manifest_path.stat().st_size > 256 * 1024 * 1024:
        raise ExportError("snapshot-manifest-invalid")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    rows = manifest.get("members")
    if manifest.get("format") != 1 or not isinstance(rows, list):
        raise ExportError("snapshot-manifest-invalid")
    destination = Path(destination).expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        raise ExportError("restore-destination-exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.parent.is_symlink():
        raise ExportError("restore-parent-unsafe")
    destination = destination.parent.resolve(strict=True) / destination.name
    stage = Path(tempfile.mkdtemp(prefix="." + destination.name + ".restore-",
                                 dir=destination.parent))
    try:
        for row in rows:
            relative = PurePosixPath(str(row["path"]))
            if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
                raise ExportError("snapshot-path-invalid")
            target = stage.joinpath(*relative.parts)
            if row["kind"] == "directory":
                target.mkdir(parents=True, exist_ok=True)
                continue
            if row["kind"] != "file":
                raise ExportError("snapshot-kind-invalid")
            content_relative = PurePosixPath(str(row["content"]))
            digest_name = str(row.get("sha256", ""))
            if (content_relative.is_absolute() or content_relative.parts != ("content", digest_name)
                    or len(digest_name) != 64 or any(ch not in "0123456789abcdef" for ch in digest_name)):
                raise ExportError("snapshot-content-path-invalid")
            content = snapshot.joinpath(*content_relative.parts)
            if content.is_symlink() or not content.is_file() or content.resolve(strict=True).parent != (snapshot / "content"):
                raise ExportError("snapshot-content-missing")
            identity = _file_record(content)
            if identity["sha256"] != digest_name or identity["bytes"] != row["bytes"]:
                raise ExportError("snapshot-content-hash-mismatch")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(content, target)
            os.chmod(target, int(row.get("mode", 0o600)) & 0o777)
            mtime_ns = int(row.get("mtime_ns", 0))
            if mtime_ns > 0:
                os.utime(target, ns=(mtime_ns, mtime_ns))
        for row in sorted((item for item in rows if item.get("kind") == "directory"),
                          key=lambda item: len(PurePosixPath(str(item["path"])).parts),
                          reverse=True):
            target = stage.joinpath(*PurePosixPath(str(row["path"])).parts)
            if not target.is_dir() or target.is_symlink():
                raise ExportError("snapshot-directory-invalid")
            os.chmod(target, int(row.get("mode", 0o755)) & 0o777)
            mtime_ns = int(row.get("mtime_ns", 0))
            if mtime_ns > 0:
                os.utime(target, ns=(mtime_ns, mtime_ns))
        os.replace(stage, destination)
    except Exception:
        if stage.exists() and not stage.is_symlink():
            shutil.rmtree(stage)
        raise
    return {"source_name": manifest.get("source_name"), "members": len(rows),
            "destination": str(destination), "container_recreated": False}


def export_bundle(path: Path, destination: Path, *,
                  deadline: float | None = None) -> dict[str, Any]:
    """Create a fresh, source-bound compact export for one Apple evidence bundle.

    `destination` must not exist. The returned `outputs` list names every
    regular file and its SHA-256 digest relative to the created directory.
    Unknown, changed, unreadable or failed exports are returned as `retained`;
    source files are always left in place by this function.
    """
    source = Path(path).expanduser().absolute()
    target = Path(destination).expanduser().absolute()
    kind = "xcresult" if source.suffix == ".xcresult" else (
        "logarchive" if source.suffix == ".logarchive" else (
            "source-archive" if source.suffix.lower() in {".zip", ".tar", ".tgz", ".gz"} else None
        )
    )
    base: dict[str, Any] = {"source_path": str(source), "kind": kind,
                             "status": "retained"}
    if kind is None:
        return {**base, "reason": "unsupported-bundle-type"}
    try:
        if source.is_symlink() or not (source.is_dir() if kind != "source-archive" else source.is_file()):
            raise ExportError("source-not-plain-directory")
        source = source.resolve(strict=True)
        if target.exists() or target.is_symlink():
            raise ExportError("destination-exists")
        parent = target.parent
        if not parent.is_dir() or parent.is_symlink():
            raise ExportError("destination-parent-unsafe")
        parent = parent.resolve(strict=True)
        target = parent / target.name
        source_root = source.parent
        ensure_safe_path(source_root, source)
        before = snapshot_tree(source, root=source_root, deadline=deadline)
        check_deadline(deadline)
        staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.partial-", dir=parent))
        try:
            if kind == "xcresult":
                _, status = _export_xcresult(source, staging, deadline)
            elif kind == "logarchive":
                status = None
                _export_logarchive(source, staging, deadline)
            else:
                status = None
                _archive_entries(source, staging, deadline)
            outputs = _output_records(staging)
            if not outputs:
                raise ExportError("export-empty")
            if not snapshot_source_matches(source, source_root, before, deadline=deadline):
                raise ExportError("source-changed-during-export")
            check_deadline(deadline)
            os.replace(staging, target)
        except Exception:
            if staging.exists() and not staging.is_symlink():
                shutil.rmtree(staging)
            raise
        return {**base, "status": "compacted", "reason": None,
                "result": status, "source_fingerprint": before.digest,
                "source_file_count": sum(1 for row in before.entries if row[1] == "file"),
                "output_directory": str(target),
                "outputs": [
                    {**row, "path": str((target / row["path"]).relative_to(target))}
                    for row in outputs
                ]}
    except (OSError, ArchiveError, ExportError, subprocess.SubprocessError,
            tarfile.TarError, zipfile.BadZipFile, TimeoutError, ValueError,
            json.JSONDecodeError) as error:
        return {**base, "reason": str(error)}


def snapshot_source_matches(source: Path, root: Path, expected: Any,
                            *, deadline: float | None = None) -> bool:
    """Return whether a complete source tree still matches its export snapshot."""
    try:
        return snapshot_tree(source, root=root, deadline=deadline) == expected
    except (OSError, ArchiveError):
        return False
