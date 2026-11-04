"""Conservative retention for automatic SQLite migration copies."""
from __future__ import annotations

import hashlib
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import quote

from .core import (ArchiveError, check_deadline, ensure_safe_path,
                   lsof_only_external_smbfs_warning, remove_tree_verified,
                   snapshot_tree)

PATTERN = re.compile(r"^library\.sqlite\.v[0-9]+-backup-[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$")
KNOWN_FILES = {"library.sqlite", "library.sqlite-wal", "library.sqlite-shm"}
THIRTY_DAYS = 30 * 24 * 60 * 60


def _layout(path: Path, root: Path) -> bool:
    """Require one ordinary SQLite database and known sidecars only."""
    try:
        ensure_safe_path(root, path)
        if path.is_symlink() or not path.is_dir():
            return False
        names: set[str] = set()
        for child in path.iterdir():
            info = child.lstat()
            if child.name not in KNOWN_FILES or child.is_symlink() or not child.is_file():
                return False
            if info.st_dev != root.stat().st_dev:
                return False
            names.add(child.name)
        return "library.sqlite" in names
    except (OSError, ArchiveError):
        return False


def quick_check(path: Path) -> bool:
    """Check SQLite without letting it modify a retained source backup."""
    try:
        database = path.expanduser().absolute()
        sources = (database, Path(str(database) + "-wal"), Path(str(database) + "-shm"))
        before = {source: _regular_file_state(source) for source in sources}
        wal_state = before[sources[1]]
        if wal_state is None or wal_state[2] == 0:
            valid = _sqlite_quick_check(database, immutable=True)
            after = {source: _regular_file_state(source) for source in sources}
            return valid and before == after

        with tempfile.TemporaryDirectory(prefix="wilted-backup-check-") as raw:
            scratch = Path(raw)
            for source in sources:
                state = before[source]
                if state is not None:
                    _copy_verified(source, scratch / source.name, state)
            after = {source: _regular_file_state(source) for source in sources}
            if before != after:
                return False
            return _sqlite_quick_check(scratch / database.name, immutable=False)
    except (OSError, sqlite3.Error, ValueError):
        return False


def _regular_file_state(path: Path) -> tuple[int, int, int, int, int] | None:
    """Return stable metadata for a regular member without following links."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise OSError(f"backup-check-member-not-regular:{path}")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _copy_verified(source: Path, destination: Path,
                   expected: tuple[int, int, int, int, int]) -> None:
    """Copy one source file to scratch and verify the exact copied bytes."""
    digest = hashlib.sha256()
    copied = 0
    with source.open("rb") as incoming, destination.open("xb") as outgoing:
        for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
            outgoing.write(chunk)
            digest.update(chunk)
            copied += len(chunk)
    if _regular_file_state(source) != expected or copied != expected[2]:
        raise OSError(f"backup-check-source-changed:{source}")
    copied_digest = hashlib.sha256()
    with destination.open("rb") as incoming:
        for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
            copied_digest.update(chunk)
    if copied_digest.digest() != digest.digest():
        raise OSError(f"backup-check-copy-mismatch:{source}")


def _sqlite_quick_check(path: Path, *, immutable: bool) -> bool:
    """Run SQLite quick_check on a read-only URI, immutable for source files."""
    uri = "file:" + quote(str(path.absolute()), safe="/:\\") + "?mode=ro"
    if immutable:
        uri += "&immutable=1"
    connection = sqlite3.connect(uri, uri=True, timeout=1.0)
    try:
        return connection.execute("PRAGMA quick_check").fetchone() == ("ok",)
    finally:
        connection.close()


def _timestamp(path: Path) -> float:
    """Use logical database payload times, ignoring transient SHM/directory touches."""
    database = path / "library.sqlite"
    state = _regular_file_state(database)
    if state is None:
        raise OSError(f"backup-database-missing:{database}")
    timestamps = [database.lstat().st_mtime]
    wal = path / "library.sqlite-wal"
    wal_state = _regular_file_state(wal)
    if wal_state is not None and wal_state[2] > 0:
        timestamps.append(wal.lstat().st_mtime)
    return max(timestamps)


def candidates(root: Path) -> list[Path]:
    """Return only UUID-named automatic copies with the known SQLite layout."""
    try:
        root = root.expanduser().absolute()
        if root.is_symlink() or not root.is_dir() or root.resolve(strict=True) != root:
            return []
        result = [path for path in root.iterdir()
                  if PATTERN.fullmatch(path.name) and _layout(path, root)]
        return sorted(result, key=lambda path: (_timestamp(path), path.name), reverse=True)
    except OSError:
        return []


def _in_use(path: Path) -> bool:
    """Fail closed unless lsof confirms the copy has no open references."""
    try:
        result = subprocess.run(("/usr/sbin/lsof", "+D", str(path)),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=3, check=False)
    except (OSError, subprocess.SubprocessError):
        return True
    stderr_safe = (not result.stderr.strip()
                   or lsof_only_external_smbfs_warning(result.stderr, path))
    if result.returncode == 1 and not result.stdout.strip() and stderr_safe:
        return False
    return True


def plan(root: Path, *, now: float | None = None, apply: bool = False,
         deadline: float | None = None) -> dict[str, object]:
    """Keep newest three and all copies younger than 30 days.

    Any integrity failure in the retained set prevents automatic deletion.
    All deletion targets are independently re-snapshotted and checked before
    the final rename-and-remove operation.
    """
    now = time.time() if now is None else now
    rows: list[dict[str, object]] = []
    root = root.expanduser().absolute()
    try:
        valid_root = (not root.is_symlink() and root.is_dir()
                      and root.resolve(strict=True) == root)
    except OSError:
        valid_root = False
    if not valid_root:
        return {"backups": rows, "status": "skipped", "reason": "backup-root-invalid"}
    backups = candidates(root)
    newest = set(backups[:3])
    retain_for_age: set[Path] = set()
    stamps: dict[Path, float] = {}
    for path in backups:
        check_deadline(deadline)
        stamps[path] = _timestamp(path)
        if now - stamps[path] < THIRTY_DAYS:
            retain_for_age.add(path)
    retained = newest | retain_for_age
    retained_integrity = {path: quick_check(path / "library.sqlite") for path in retained}
    retained_ok = all(retained_integrity.values())
    for path in backups:
        check_deadline(deadline)
        age = now - stamps[path]
        keep = path in retained
        valid = quick_check(path / "library.sqlite") if not keep else retained_integrity[path]
        status = "retained" if keep else "eligible"
        reason = "newest-three-or-age" if keep else "expired-automatic-copy"
        if not valid:
            status, reason = "retained-invalid", "quick-check-failed"
        elif not retained_ok and not keep:
            status, reason = "retained", "retained-backup-integrity-uncertain"
        if apply and not keep and valid and retained_ok:
            check_deadline(deadline)
            if _in_use(path):
                status, reason = "retained", "open-or-liveness-unknown"
            else:
                expected = snapshot_tree(path, root=root)
                if not _layout(path, root) or not quick_check(path / "library.sqlite"):
                    status, reason = "retained", "layout-or-integrity-changed"
                elif _in_use(path):
                    status, reason = "retained", "opened-before-removal"
                else:
                    remove_tree_verified(path, expected, root=root)
                    status, reason = "removed", "expired-automatic-copy"
        rows.append({"path": str(path), "status": status, "reason": reason,
                     "age_seconds": age, "quick_check": valid})
    return {"backups": rows, "status": "complete", "automatic_candidates": len(backups),
            "retained_integrity_ok": retained_ok}
