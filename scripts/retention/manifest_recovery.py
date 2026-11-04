"""Recover files and source archive members preserved by the 2026 audits.

The original audit ZIP formats predate the recurring retention archive format.
This helper verifies their manifests and content hashes before writing a file or
reconstructed source tree to a new destination.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


REPO = Path(__file__).resolve().parents[2]
AUDIT = REPO / ".logs/retention-audit-2026-11-04"
OTHER = REPO / ".logs/retention-other-2026-11-04"
IMPLEMENTATION = REPO / ".logs/retention-implementation-2026-11-04"
GIT_PACK = IMPLEMENTATION / "recovery-git-blobs.zip"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class RecoveryError(RuntimeError):
    """A recovery map, archive, or destination did not pass validation."""


def sha256(data: bytes) -> str:
    """Return the SHA-256 digest of bytes."""
    return hashlib.sha256(data).hexdigest()


def git_object_id(data: bytes) -> str:
    """Return Git's object ID for an ordinary blob."""
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def safe_member(name: str) -> PurePosixPath:
    """Reject archive paths that could escape a reconstruction destination."""
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or ".." in path.parts or "" in path.parts:
        raise RecoveryError("archive-member-path-unsafe")
    if path.parts[0].endswith(":"):
        raise RecoveryError("archive-member-path-unsafe")
    return path


def verify_git_pack(path: Path = GIT_PACK) -> dict[str, dict[str, Any]]:
    """Verify the standalone Git blob pack and return its object index."""
    if path.is_symlink() or not path.is_file():
        raise RecoveryError("git-recovery-pack-missing-or-linked")
    try:
        with zipfile.ZipFile(path) as archive:
            member_names = archive.namelist()
            names = set(member_names)
            if len(member_names) != len(names):
                raise RecoveryError("git-recovery-pack-duplicate-members")
            if "index.json" not in names:
                raise RecoveryError("git-recovery-pack-index-missing")
            rows = json.loads(archive.read("index.json"))
            if not isinstance(rows, list):
                raise RecoveryError("git-recovery-pack-index-invalid")
            result: dict[str, dict[str, Any]] = {}
            expected_names = {"index.json"}
            for row in rows:
                if not isinstance(row, dict):
                    raise RecoveryError("git-recovery-pack-row-invalid")
                oid = row.get("git_blob")
                digest = row.get("sha256")
                size = row.get("size")
                if (not isinstance(oid, str) or not HEX40.fullmatch(oid) or
                        not isinstance(digest, str) or not HEX64.fullmatch(digest) or
                        not isinstance(size, int) or size < 0 or oid in result):
                    raise RecoveryError("git-recovery-pack-row-invalid")
                member = "blobs/" + digest
                if member not in names:
                    raise RecoveryError("git-recovery-pack-blob-missing")
                data = archive.read(member)
                if len(data) != size or sha256(data) != digest or git_object_id(data) != oid:
                    raise RecoveryError("git-recovery-pack-blob-hash-mismatch")
                result[oid] = row
                expected_names.add(member)
            if names != expected_names:
                raise RecoveryError("git-recovery-pack-unindexed-members")
            return result
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        if isinstance(error, RecoveryError):
            raise
        raise RecoveryError("git-recovery-pack-invalid") from error


def _write_new_file(destination: Path, data: bytes, mode: int = 0o600) -> None:
    """Write data atomically, only when the destination does not exist."""
    destination = destination.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        raise RecoveryError("destination-already-exists")
    parent = destination.parent
    if parent.is_symlink() or not parent.is_dir():
        raise RecoveryError("destination-parent-missing-or-linked")
    staging = Path(tempfile.mkdtemp(prefix=".retention-restore-", dir=parent))
    try:
        staged = staging / "recovered"
        descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if sha256(staged.read_bytes()) != sha256(data):
            raise RecoveryError("staged-file-hash-mismatch")
        os.rename(staged, destination)
        parent_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging)


def restore_git_blob(object_id: str, destination: Path, pack: Path = GIT_PACK) -> dict[str, Any]:
    """Restore one Git-backed file from the independently verified ZIP."""
    if not HEX40.fullmatch(object_id):
        raise RecoveryError("git-object-id-invalid")
    index = verify_git_pack(pack)
    row = index.get(object_id)
    if row is None:
        raise RecoveryError("git-object-not-in-recovery-pack")
    with zipfile.ZipFile(pack) as archive:
        data = archive.read("blobs/" + row["sha256"])
    _write_new_file(destination, data)
    return {"git_blob": object_id, "sha256": row["sha256"], "bytes": len(data)}


def _read_content_pack(pack: Path, digest: str) -> bytes:
    """Read one SHA-keyed member from an audit source-content pack."""
    if not HEX64.fullmatch(digest) or pack.is_symlink() or not pack.is_file():
        raise RecoveryError("source-content-reference-invalid")
    try:
        with zipfile.ZipFile(pack) as archive:
            if archive.testzip() is not None or digest not in archive.namelist():
                raise RecoveryError("source-content-member-missing-or-corrupt")
            data = archive.read(digest)
            if sha256(data) != digest:
                raise RecoveryError("source-content-hash-mismatch")
            return data
    except (OSError, zipfile.BadZipFile) as error:
        if isinstance(error, RecoveryError):
            raise
        raise RecoveryError("source-content-pack-invalid") from error


def load_source_maps() -> list[tuple[Path, dict[str, Any]]]:
    """Read the two exact source reconstruction maps used by the audit."""
    result = []
    for root in (AUDIT, OTHER):
        path = root / "archive-reconstruction-map.json"
        try:
            rows = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise RecoveryError("source-reconstruction-map-unreadable") from error
        if not isinstance(rows, list):
            raise RecoveryError("source-reconstruction-map-invalid")
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("members"), list):
                raise RecoveryError("source-reconstruction-row-invalid")
            result.append((path, row))
    return result


def _member_bytes(member: dict[str, Any], pack: Path, git_index: dict[str, dict[str, Any]]) -> bytes:
    """Resolve one map member through the appropriate verified recovery store."""
    digest = member.get("sha256")
    if not isinstance(digest, str) or not HEX64.fullmatch(digest):
        raise RecoveryError("source-map-member-hash-invalid")
    retained = str(member.get("retained_in", ""))
    if retained == "git":
        oid = member.get("git_blob")
        row = git_index.get(oid) if isinstance(oid, str) else None
        if row is None or row.get("sha256") != digest:
            raise RecoveryError("source-map-git-reference-missing")
        with zipfile.ZipFile(GIT_PACK) as archive:
            data = archive.read("blobs/" + digest)
        if git_object_id(data) != oid:
            raise RecoveryError("source-map-git-blob-corrupt")
        return data
    return _read_content_pack(pack, digest)


def _safe_mode(member: dict[str, Any]) -> int | None:
    """Return only ordinary permission bits from mapped archive metadata."""
    mode = member.get("mode")
    return (mode & 0o777) if isinstance(mode, int) and mode >= 0 else None


def _set_mtime(path: Path, member: dict[str, Any]) -> None:
    """Restore a mapped timestamp only when it is a numeric Unix timestamp."""
    stamp = member.get("mtime")
    if isinstance(stamp, (int, float)) and stamp >= 0:
        os.utime(path, (stamp, stamp), follow_symlinks=False)


def restore_source_archive(archive_path: str, destination: Path) -> dict[str, Any]:
    """Rebuild one original ZIP's member tree at a new destination directory."""
    matches = [(map_path, row) for map_path, row in load_source_maps()
               if row.get("archive") == archive_path]
    if len(matches) != 1:
        raise RecoveryError("source-archive-not-found-or-ambiguous")
    map_path, row = matches[0]
    pack = AUDIT / "unique-archive-content.zip" if map_path.parent == AUDIT else OTHER / "unique-archive-content.zip"
    destination = destination.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        raise RecoveryError("destination-already-exists")
    parent = destination.parent
    if parent.is_symlink() or not parent.is_dir():
        raise RecoveryError("destination-parent-missing-or-linked")
    staging = Path(tempfile.mkdtemp(prefix=".retention-tree-restore-", dir=parent))
    git_index = ({} if not any(isinstance(member, dict) and member.get("retained_in") == "git"
                               for member in row.get("members", []))
                 else verify_git_pack())
    count = total = directory_count = 0
    explicit_directories: list[tuple[Path, dict[str, Any]]] = []
    seen: set[str] = set()
    try:
        for member in row["members"]:
            if not isinstance(member, dict) or not isinstance(member.get("name"), str):
                raise RecoveryError("source-map-member-invalid")
            relative = safe_member(member["name"])
            output = staging.joinpath(*relative.parts)
            key = relative.as_posix()
            if key in seen:
                raise RecoveryError("source-map-member-collision")
            seen.add(key)
            member_type = member.get("type")
            if member_type == "b'5'":
                if member.get("sha256") is not None or member.get("size") is not None:
                    raise RecoveryError("source-map-directory-has-file-content")
                output.mkdir(parents=True, exist_ok=True)
                if output.is_symlink() or not output.is_dir():
                    raise RecoveryError("source-map-directory-collision")
                explicit_directories.append((output, member))
                directory_count += 1
                continue
            if member_type is not None:
                raise RecoveryError("source-map-member-type-unsupported")
            output.parent.mkdir(parents=True, exist_ok=True)
            if output.exists() or output.is_symlink():
                raise RecoveryError("source-map-member-collision")
            data = _member_bytes(member, pack, git_index)
            if len(data) != int(member.get("size", -1)):
                raise RecoveryError("source-map-member-size-mismatch")
            descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            mode = _safe_mode(member)
            if mode is not None:
                output.chmod(mode)
            _set_mtime(output, member)
            count += 1
            total += len(data)
        for directory, member in sorted(explicit_directories,
                                        key=lambda item: len(item[0].parts), reverse=True):
            mode = _safe_mode(member)
            if mode is not None:
                directory.chmod(mode)
            _set_mtime(directory, member)
        os.rename(staging, destination)
        parent_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        return {"archive": archive_path, "destination": str(destination),
                "members": count, "directories": directory_count, "bytes": total,
                "kind": "reconstructed-directory"}
    except Exception:
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging)
        raise


def restore_original_path(source_path: str, destination: Path) -> dict[str, Any]:
    """Restore one original audited path using its recorded retention pointer."""
    row = next((item for item in json.loads((AUDIT / "file-decisions.json").read_text(encoding="utf-8"))
                if item.get("path") == source_path), None)
    if row is None:
        raise RecoveryError("original-path-not-in-source-audit")
    retained = str(row.get("retained_at", ""))
    if retained.startswith("git blob "):
        oid = retained.removeprefix("git blob ")
        result = restore_git_blob(oid, destination)
        if row.get("sha256") and result["sha256"] != row["sha256"]:
            raise RecoveryError("restored-git-file-does-not-match-audit")
        return result
    if retained.startswith("historical-records.zip::"):
        member = retained.split("::", 1)[1]
        pack = AUDIT / "historical-records.zip"
        try:
            with zipfile.ZipFile(pack) as archive:
                if archive.testzip() is not None or member not in archive.namelist():
                    raise RecoveryError("historical-member-missing-or-corrupt")
                data = archive.read(member)
        except (OSError, zipfile.BadZipFile) as error:
            if isinstance(error, RecoveryError):
                raise
            raise RecoveryError("historical-records-pack-invalid") from error
        if sha256(data) != row.get("sha256"):
            raise RecoveryError("historical-member-hash-mismatch")
        _write_new_file(destination, data)
        return {"source_path": source_path, "sha256": row["sha256"], "bytes": len(data)}
    if retained == "archive-reconstruction-map.json":
        return restore_source_archive(source_path, destination)
    raise RecoveryError("path-has-no-supported-recovery-pointer")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    one = commands.add_parser("restore-path", help="restore one audited source file")
    one.add_argument("--source-path", required=True, help="exact original path from file-decisions.json")
    one.add_argument("--destination", type=Path, required=True)
    archive = commands.add_parser("restore-archive", help="rebuild a source archive as a directory tree")
    archive.add_argument("--source-archive", required=True, help="exact archive path in the reconstruction map")
    archive.add_argument("--destination", type=Path, required=True)
    blob = commands.add_parser("restore-git-blob", help="restore one Git blob by object ID")
    blob.add_argument("--object-id", required=True)
    blob.add_argument("--destination", type=Path, required=True)
    commands.add_parser("verify", help="verify the standalone Git recovery pack")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "verify":
            index = verify_git_pack()
            print(json.dumps({"status": "verified", "git_blobs": len(index)}, sort_keys=True))
        elif args.command == "restore-path":
            print(json.dumps(restore_original_path(args.source_path, args.destination), sort_keys=True))
        elif args.command == "restore-archive":
            print(json.dumps(restore_source_archive(args.source_archive, args.destination), sort_keys=True))
        else:
            print(json.dumps(restore_git_blob(args.object_id, args.destination), sort_keys=True))
        return 0
    except (RecoveryError, OSError, ValueError, KeyError) as error:
        print(json.dumps({"status": "error", "reason": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
