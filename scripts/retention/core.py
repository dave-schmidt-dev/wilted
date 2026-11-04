"""Path, identity, archive, and removal primitives for retention.

Every destructive caller must snapshot, preserve and verify its replacement,
then pass the same snapshot to :func:`remove_tree_verified` immediately before
removal. Unknown filesystem objects fail closed.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


class ArchiveError(RuntimeError):
    """An archive or filesystem safety check failed."""


@dataclass(frozen=True)
class Identity:
    kind: str
    size: int
    mtime_ns: int
    ctime_ns: int
    digest: str
    device: int
    inode: int
    mode: int


@dataclass(frozen=True)
class TreeIdentity:
    """Content and file-set identity for a regular-file tree."""
    digest: str
    bytes: int
    entries: tuple[tuple[str, str, int, int, int, int, int, int], ...]
    device: int
    inode: int
    mode: int
    mtime_ns: int
    ctime_ns: int


def check_deadline(deadline: float | None) -> None:
    """Raise when a monotonic work deadline has passed."""
    if deadline is not None and time.monotonic() >= deadline:
        raise TimeoutError("retention work budget exhausted")


_LSOF_EXTERNAL_SMBFS_WARNING = re.compile(
    r'lsof: WARNING: can\'t stat\(\) smbfs file system (?P<mount>[^\r\n]+)\r?\n'
    r' {6}Output information may be incomplete\.\r?\n'
    r' {6}assuming "dev=(?P<device>[0-9A-Fa-f]+)" from mount table\r?\n?'
)


def lsof_only_external_smbfs_warning(stderr: bytes | str, target: Path) -> bool:
    """Recognize only the exact warning for an unrelated SMB mount.

    The warning is suppressible only when its absolute mount path is disjoint
    from ``target`` and both decimal and hexadecimal interpretations of the
    reported device differ from the target device.
    """
    try:
        text = stderr.decode("utf-8") if isinstance(stderr, bytes) else stderr
        match = _LSOF_EXTERNAL_SMBFS_WARNING.fullmatch(text)
        if match is None:
            return False
        mount = Path(match.group("mount"))
        target_path = Path(os.path.abspath(target))
        if not mount.is_absolute() or not target_path.is_absolute():
            return False
        mount = Path(os.path.normpath(str(mount)))
        target_info = target_path.lstat()
        if stat.S_ISLNK(target_info.st_mode):
            return False
        try:
            common = Path(os.path.commonpath((str(mount), str(target_path))))
        except ValueError:
            return False
        if common == mount or common == target_path:
            return False
        value = match.group("device")
        device_values: set[int] = set()
        if re.fullmatch(r"[0-9]+", value):
            device_values.add(int(value, 10))
        if re.fullmatch(r"[0-9A-Fa-f]+", value):
            device_values.add(int(value, 16))
        if not device_values:
            return False
        return target_info.st_dev not in device_values
    except (OSError, UnicodeError, ValueError):
        return False


def _root(root: Path) -> Path:
    expanded = root.expanduser()
    if ".." in expanded.parts:
        raise ArchiveError(f"root-parent-component:{root}")
    raw = expanded.absolute()
    try:
        info = raw.lstat()
    except OSError as error:
        raise ArchiveError(f"root-unreadable:{raw}") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ArchiveError(f"root-not-plain-directory:{raw}")
    resolved = raw.resolve(strict=True)
    if resolved != raw:
        raise ArchiveError(f"root-not-canonical:{raw}")
    return raw


def ensure_safe_path(root: Path, candidate: Path, *, allow_root: bool = False) -> Path:
    """Validate lexical containment and every ancestor without following links."""
    root = _root(root)
    expanded = candidate.expanduser()
    if ".." in expanded.parts:
        raise ArchiveError(f"path-parent-component:{candidate}")
    candidate = expanded.absolute()
    try:
        relative = candidate.relative_to(root)
    except ValueError as error:
        raise ArchiveError(f"path-outside-root:{candidate}") from error
    if not relative.parts and not allow_root:
        raise ArchiveError(f"root-not-allowed:{candidate}")
    device = root.stat().st_dev
    current = root
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            info = current.lstat()
        except OSError as error:
            raise ArchiveError(f"path-missing-or-unreadable:{current}") from error
        if stat.S_ISLNK(info.st_mode) or info.st_dev != device:
            raise ArchiveError(f"symlink-or-mount:{current}")
        if index < len(relative.parts) - 1 and not stat.S_ISDIR(info.st_mode):
            raise ArchiveError(f"non-directory-ancestor:{current}")
    return candidate


def _file_identity(path: Path, deadline: float | None = None) -> Identity:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ArchiveError(f"not-regular:{path}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            check_deadline(deadline)
            digest.update(chunk)
    after = path.lstat()
    fields_before = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    fields_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    if fields_before != fields_after:
        raise ArchiveError(f"changed-while-reading:{path}")
    return Identity("file", info.st_size, info.st_mtime_ns, info.st_ctime_ns,
                    digest.hexdigest(), info.st_dev, info.st_ino, stat.S_IMODE(info.st_mode))


def identity(path: Path, *, root: Path | None = None,
             deadline: float | None = None) -> Identity:
    """Return a content identity, rejecting links and racing writes."""
    path = ensure_safe_path(root, path) if root is not None else path.absolute()
    return _file_identity(path, deadline)


def _tree_entries(path: Path, deadline: float | None = None) -> list[tuple[str, str, int, int, int, int, int, int]]:
    """Return a sorted tree inventory; reject links, mounts and special files."""
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ArchiveError(f"not-plain-directory:{path}")
    device = info.st_dev
    result: list[tuple[str, str, int, int, int, int, int, int]] = []
    def walk_error(error: OSError) -> None:
        raise ArchiveError(f"tree-unreadable:{error.filename}") from error
    for current, dirs, files in os.walk(path, topdown=True, onerror=walk_error, followlinks=False):
        check_deadline(deadline)
        base = Path(current)
        names = sorted(dirs + files)
        dirs[:] = sorted(dirs)
        for name in names:
            child = base / name
            child_info = child.lstat()
            if stat.S_ISLNK(child_info.st_mode) or child_info.st_dev != device:
                raise ArchiveError(f"symlink-or-mount:{child}")
            relative = child.relative_to(path).as_posix()
            if stat.S_ISDIR(child_info.st_mode):
                result.append((relative, "dir", 0, child_info.st_mtime_ns,
                               child_info.st_ctime_ns, stat.S_IMODE(child_info.st_mode),
                               child_info.st_dev, child_info.st_ino))
            elif stat.S_ISREG(child_info.st_mode):
                result.append((relative, "file", child_info.st_size,
                               child_info.st_mtime_ns, child_info.st_ctime_ns,
                               stat.S_IMODE(child_info.st_mode), child_info.st_dev,
                               child_info.st_ino))
            else:
                raise ArchiveError(f"special-file:{child}")
    return sorted(result)


def snapshot_tree(path: Path, *, root: Path | None = None,
                  deadline: float | None = None) -> TreeIdentity:
    """Hash a tree's names, types and contents; an individual file is supported."""
    path = ensure_safe_path(root, path) if root is not None else path.absolute()
    if path.is_file():
        item = _file_identity(path, deadline)
        entry = (path.name, "file", item.size, item.mtime_ns, item.ctime_ns, item.mode,
                 item.device, item.inode)
        return TreeIdentity(item.digest, item.size, (entry,), item.device, item.inode,
                            item.mode, item.mtime_ns, item.ctime_ns)
    root_info = path.lstat()
    entries = _tree_entries(path, deadline)
    digest = hashlib.sha256()
    total = 0
    for relative, kind, size, mtime_ns, ctime_ns, mode, device, inode in entries:
        digest.update(relative.encode("utf-8") + b"\0" + kind.encode() + b"\0")
        digest.update(f"{size}:{mtime_ns}:{ctime_ns}:{mode}:{device}:{inode}\0".encode())
        if kind == "file":
            child = path / relative
            current = _file_identity(child, deadline)
            actual = (relative, "file", current.size, current.mtime_ns,
                      current.ctime_ns, current.mode, current.device, current.inode)
            expected = (relative, kind, size, mtime_ns, ctime_ns, mode, device, inode)
            if actual != expected:
                raise ArchiveError(f"changed-since-inventory:{child}")
            digest.update(bytes.fromhex(current.digest))
            total += size
    return TreeIdentity(digest.hexdigest(), total, tuple(entries), root_info.st_dev,
                        root_info.st_ino, stat.S_IMODE(root_info.st_mode),
                        root_info.st_mtime_ns, root_info.st_ctime_ns)


def verify_tree(path: Path, expected: TreeIdentity, *, root: Path | None = None,
                deadline: float | None = None) -> bool:
    """Recompute a tree identity and compare the complete snapshot."""
    try:
        return snapshot_tree(path, root=root, deadline=deadline) == expected
    except (OSError, ArchiveError):
        return False


def tree_digest(root: Path) -> str:
    """Return the content digest of a plain directory tree."""
    return snapshot_tree(root).digest


def _fsync(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _archive_files(path: Path, deadline: float | None = None) -> list[Path]:
    if path.is_dir():
        return [path / relative for relative, kind, *_ in _tree_entries(path, deadline) if kind == "file"]
    return [path]


def archive_paths(paths: Iterable[Path], root: Path, destination: Path,
                  *, deadline: float | None = None) -> dict[str, object]:
    """Atomically preserve selected files/trees in a deduplicated verified ZIP."""
    root = _root(root)
    destination = destination.expanduser().absolute()
    try:
        destination.relative_to(root)
    except ValueError as error:
        raise ArchiveError(f"destination-outside-root:{destination}") from error
    if destination.exists() or destination.is_symlink():
        raise ArchiveError(f"destination-exists:{destination}")
    selected = list(dict.fromkeys(ensure_safe_path(root, path) for path in paths))
    for path in selected:
        if path.is_dir() and path in destination.parents:
            raise ArchiveError(f"destination-inside-source:{destination}")
    parent = destination.parent
    relative_parent = parent.relative_to(root)
    current = root
    device = root.stat().st_dev
    for part in relative_parent.parts:
        current = current / part
        try:
            current.mkdir()
        except FileExistsError:
            pass
        info = current.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_dev != device:
            raise ArchiveError(f"destination-parent-unsafe:{current}")
    ensure_safe_path(root, parent, allow_root=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.partial-", dir=parent))
    try:
        archive = staging / "content.zip"
        entries: list[dict[str, object]] = []
        directories_by_path: dict[str, dict[str, object]] = {}
        seen: set[str] = set()
        root_device = root.stat().st_dev
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            for selected_path in selected:
                check_deadline(deadline)
                files = _archive_files(selected_path, deadline)
                if selected_path.is_dir():
                    for relative, kind, _, mtime_ns, ctime_ns, mode, _, _ in _tree_entries(selected_path, deadline):
                        if kind == "dir":
                            directory_path = (selected_path / relative).relative_to(root).as_posix()
                            directories_by_path[directory_path] = {
                                "path": directory_path, "mtime_ns": mtime_ns,
                                "ctime_ns": ctime_ns, "mode": mode}
                for path in files:
                    check_deadline(deadline)
                    safe = ensure_safe_path(root, path)
                    before = _file_identity(safe, deadline)
                    relative = safe.relative_to(root).as_posix()
                    row = {"path": relative, "sha256": before.digest, "bytes": before.size,
                           "mtime_ns": before.mtime_ns, "mode": before.mode}
                    if before.digest not in seen:
                        with safe.open("rb") as source, output.open(f"content/{before.digest}", "w") as target:
                            copied = hashlib.sha256()
                            copied_bytes = 0
                            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                                check_deadline(deadline)
                                copied.update(chunk)
                                copied_bytes += len(chunk)
                                target.write(chunk)
                            if copied.hexdigest() != before.digest or copied_bytes != before.size:
                                raise ArchiveError(f"archive-source-hash-mismatch:{safe}")
                        seen.add(before.digest)
                    if _file_identity(safe, deadline) != before:
                        raise ArchiveError(f"source-changed-while-archiving:{safe}")
                    entries.append(row)
        if root.stat().st_dev != root_device:
            raise ArchiveError("root-device-changed")
        unique_sizes = {str(row["sha256"]): int(row["bytes"]) for row in entries}
        manifest = {"format": 1, "created": int(time.time()), "root": str(root),
                    "files": entries, "directories": list(directories_by_path.values()),
                    "unique_bytes": sum(unique_sizes.values())}
        manifest_path = staging / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        _fsync(archive)
        _fsync(manifest_path)
        verify_archive(staging, deadline=deadline)
        os.rename(staging, destination)
        _fsync(destination.parent)
        verify_archive(destination, deadline=deadline)
        return manifest
    except Exception:
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def verify_archive(archive_root: Path, *, deadline: float | None = None) -> dict[str, object]:
    """Verify every manifest reference, ZIP member and checksum."""
    if archive_root.is_symlink() or not archive_root.is_dir():
        raise ArchiveError(f"archive-root-invalid:{archive_root}")
    try:
        manifest_path = archive_root / "manifest.json"
        content_path = archive_root / "content.zip"
        if (manifest_path.is_symlink() or not manifest_path.is_file()
                or content_path.is_symlink() or not content_path.is_file()):
            raise ArchiveError("archive-component-not-regular")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if (manifest.get("format") != 1 or not isinstance(manifest.get("files"), list)
                or not isinstance(manifest.get("directories", []), list)):
            raise ArchiveError("archive-manifest-format")
        with zipfile.ZipFile(archive_root / "content.zip") as archive:
            archive_names = archive.namelist()
            names = set(archive_names)
            if len(names) != len(archive_names):
                raise ArchiveError("archive-duplicate-members")
            expected_members: set[str] = set()
            verified_members: set[str] = set()
            seen_paths: set[str] = set()
            for row in manifest.get("directories", []):
                relative = Path(str(row["path"]))
                if relative.is_absolute() or ".." in relative.parts:
                    raise ArchiveError("archive-directory-path-escape")
                key = relative.as_posix()
                if key in seen_paths:
                    raise ArchiveError("archive-duplicate-path")
                seen_paths.add(key)
            for row in manifest["files"]:
                relative = Path(str(row["path"]))
                digest = str(row["sha256"])
                if (relative.is_absolute() or ".." in relative.parts or len(digest) != 64
                        or any(char not in "0123456789abcdef" for char in digest)):
                    raise ArchiveError("archive-manifest-path-or-hash")
                key = relative.as_posix()
                if key in seen_paths:
                    raise ArchiveError("archive-duplicate-path")
                seen_paths.add(key)
                member = f"content/{digest}"
                if member not in names:
                    raise ArchiveError(f"archive-member-missing:{member}")
                expected_members.add(member)
                size = int(row["bytes"])
                if size < 0:
                    raise ArchiveError(f"archive-hash-mismatch:{row['path']}")
                if member not in verified_members:
                    hasher = hashlib.sha256()
                    count = 0
                    with archive.open(member, "r") as source:
                        for block in iter(lambda: source.read(1024 * 1024), b""):
                            check_deadline(deadline)
                            hasher.update(block)
                            count += len(block)
                    if count != size or hasher.hexdigest() != digest:
                        raise ArchiveError(f"archive-hash-mismatch:{row['path']}")
                    verified_members.add(member)
            if names != expected_members:
                raise ArchiveError("archive-unreferenced-member")
        return manifest
    except (OSError, KeyError, TypeError, ValueError, zipfile.BadZipFile) as error:
        if isinstance(error, ArchiveError):
            raise
        raise ArchiveError(f"archive-invalid:{archive_root}") from error


def restore_archive(archive_root: Path, destination: Path) -> dict[str, object]:
    """Restore verified archive members to a new destination tree."""
    manifest = verify_archive(archive_root)
    destination = destination.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        raise ArchiveError(f"restore-destination-exists:{destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.restore-", dir=destination.parent))
    try:
        with zipfile.ZipFile(archive_root / "content.zip") as archive:
            for row in sorted(manifest.get("directories", []), key=lambda item: len(Path(str(item["path"])).parts)):
                relative = Path(str(row["path"]))
                if relative.is_absolute() or ".." in relative.parts:
                    raise ArchiveError("restore-directory-path-escape")
                (staging / relative).mkdir(parents=True, exist_ok=True)
            for row in manifest["files"]:
                relative = Path(str(row["path"]))
                if relative.is_absolute() or ".." in relative.parts:
                    raise ArchiveError("restore-path-escape")
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                data = archive.read(f"content/{row['sha256']}")
                if hashlib.sha256(data).hexdigest() != row["sha256"]:
                    raise ArchiveError(f"restore-hash-mismatch:{relative}")
                target.write_bytes(data)
                if "mode" in row:
                    target.chmod(int(row["mode"]))
        os.rename(staging, destination)
        _fsync(destination.parent)
        return manifest
    except Exception:
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def _same_after_rename(expected: TreeIdentity, actual: TreeIdentity) -> bool:
    """Compare payload identity while ignoring root rename timestamps/name."""
    payload_matches = (actual.digest == expected.digest and actual.bytes == expected.bytes
                       and actual.device == expected.device and actual.inode == expected.inode
                       and actual.mode == expected.mode)
    if expected.entries and expected.entries[0][1] == "dir":
        payload_matches = payload_matches and actual.entries == expected.entries
    return payload_matches


def remove_tree_verified(path: Path, expected: TreeIdentity, *, root: Path,
                         deadline: float | None = None) -> None:
    """Remove a plain file/tree only after two matching full inventories.

    The tree is first renamed to a unique sibling; its identity is checked
    again at the renamed path before recursive removal. A changed target is
    restored when the original name remains free and is never recursively
    removed.
    """
    check_deadline(deadline)
    root = _root(root)
    safe = ensure_safe_path(root, path)
    if not verify_tree(safe, expected, root=root, deadline=deadline):
        raise ArchiveError(f"identity-changed:{safe}")
    parent = safe.parent
    quarantine = parent / f"retention-removing-{os.getpid()}-{time.time_ns()}-{safe.name}"
    if quarantine.exists() or quarantine.is_symlink():
        raise ArchiveError("quarantine-name-exists")
    os.rename(safe, quarantine)
    try:
        after_rename = snapshot_tree(quarantine, root=root, deadline=deadline)
        if not _same_after_rename(expected, after_rename):
            if not safe.exists() and not safe.is_symlink():
                os.rename(quarantine, safe)
            raise ArchiveError(f"renamed-target-changed:{safe}")
        check_deadline(deadline)
        if quarantine.is_dir():
            shutil.rmtree(quarantine)
        else:
            quarantine.unlink()
    except Exception:
        if quarantine.exists() or quarantine.is_symlink():
            if not safe.exists() and not safe.is_symlink():
                try:
                    if _same_after_rename(expected, snapshot_tree(quarantine, root=root)):
                        os.rename(quarantine, safe)
                except (OSError, ArchiveError):
                    # A partial quarantine is preserved for recovery; never
                    # put an incomplete tree back under the original path.
                    pass
        raise


def delete_verified(path: Path, expected: Identity, *, root: Path) -> None:
    """Delete an unchanged regular file through the tree-safe operation."""
    tree = TreeIdentity(expected.digest, expected.size,
                        ((path.name, "file", expected.size, expected.mtime_ns,
                          expected.ctime_ns, expected.mode, expected.device, expected.inode),),
                        expected.device, expected.inode, expected.mode,
                        expected.mtime_ns, expected.ctime_ns)
    remove_tree_verified(path, tree, root=root)
