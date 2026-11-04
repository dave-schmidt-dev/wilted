"""Whole-unit cache eviction with the build helper's lock namespaces."""
from __future__ import annotations

import fcntl
import hashlib
import os
import signal
import shutil
import stat
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from .core import (ArchiveError, check_deadline, ensure_safe_path,
                   lsof_only_external_smbfs_warning)

QUIET_SECONDS = 24 * 60 * 60
BUDGET_BYTES = 4 * 1024 ** 3
LEGACY_ROOTS = ("clang-module-cache", "swift-module-cache", "xcode-ios",
                "xcode-ios-class", "xcode-mac-class")


@dataclass(frozen=True)
class CacheUnit:
    path: Path
    members: tuple[Path, ...]
    lock: Path | None
    kind: str
    key: str


@dataclass(frozen=True)
class CacheEntry:
    path: str
    kind: str
    size: int
    mtime_ns: int
    ctime_ns: int
    mode: int
    device: int
    inode: int
    digest: str
    link_target: str = ""


@dataclass(frozen=True)
class CacheSnapshot:
    digest: str
    bytes: int
    entries: tuple[CacheEntry, ...]
    root_device: int
    root_inode: int
    root_mode: int


def _units(repo: Path) -> list[CacheUnit]:
    """Enumerate only known cache namespaces; never include lock directories."""
    build = repo / ".build"
    if not build.is_dir() or build.is_symlink():
        return []
    result: list[CacheUnit] = []
    swift = build / "swiftpm"
    if swift.is_dir() and not swift.is_symlink():
        for child in sorted(swift.iterdir()):
            if child.name != ".locks" and child.is_dir() and not child.is_symlink():
                result.append(CacheUnit(child, (child,), swift / ".locks" / f"{child.name}.lock",
                                        "swiftpm", child.name))
    xcode = build / "xcode"
    if xcode.is_dir() and not xcode.is_symlink():
        shared: list[Path] = []
        for child in sorted(xcode.iterdir()):
            if child.name.startswith("native-"):
                if child.is_dir() and not child.is_symlink():
                    result.append(CacheUnit(child, (child,), build / "xcode-locks" / f"{child.name}.lock",
                                            "xcode-native", child.name))
                continue
            # These are immediate installer products; nested native units are
            # excluded above and can never join the shared Xcode unit.
            try:
                info = child.lstat()
            except OSError:
                continue
            if stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                shared.append(child)
        if shared:
            result.append(CacheUnit(xcode, tuple(shared), build / "xcode.lock", "xcode-installer", "shared"))
    for key in LEGACY_ROOTS:
        child = build / key
        if child.is_dir() and not child.is_symlink():
            result.append(CacheUnit(child, (child,), None, "legacy", key))
    return result


def _allocated(path: Path) -> int:
    try:
        return int(path.lstat().st_blocks) * 512
    except (AttributeError, OSError):
        return path.lstat().st_size


def _size(path: Path, deadline: float | None = None) -> int:
    """Return allocated regular-file bytes without following links."""
    check_deadline(deadline)
    if path.is_symlink():
        return 0
    if path.is_file():
        return _allocated(path)
    total = 0
    for current, dirs, files in os.walk(path, topdown=True, followlinks=False):
        check_deadline(deadline)
        base = Path(current)
        dirs[:] = [name for name in dirs if not (base / name).is_symlink()]
        for name in files:
            child = base / name
            if child.is_symlink():
                continue
            try:
                if child.is_file():
                    total += _allocated(child)
            except OSError:
                raise ArchiveError(f"cache-unreadable:{child}")
    return total


def _cache_snapshot(root: Path, members: tuple[Path, ...], deadline: float | None = None,
                    *, unit_root: Path | None = None, validate_links: bool = True) -> CacheSnapshot:
    """Inventory payload and opaque internal symlinks without following links."""
    root = root.expanduser().absolute()
    if root.is_symlink() or not root.is_dir() or root.resolve(strict=True) != root:
        raise ArchiveError(f"cache-root-invalid:{root}")
    root_info = root.lstat()
    device = root_info.st_dev
    unit_root = unit_root or root
    entries: list[CacheEntry] = []
    total = 0

    def add(path: Path, relative: str) -> None:
        nonlocal total
        check_deadline(deadline)
        info = path.lstat()
        if info.st_dev != device:
            raise ArchiveError(f"cache-mount-boundary:{path}")
        if stat.S_ISLNK(info.st_mode):
            target_text = os.readlink(path)
            if validate_links:
                try:
                    target = path.resolve(strict=True)
                    target.relative_to(unit_root)
                except (OSError, ValueError) as error:
                    raise ArchiveError(f"cache-symlink-escapes-or-broken:{path}") from error
                if unit_root.name == "xcode":
                    first = target.relative_to(unit_root).parts[:1]
                    if first and first[0].startswith("native-"):
                        raise ArchiveError(f"cache-symlink-crosses-unit:{path}")
                if target.stat().st_dev != device:
                    raise ArchiveError(f"cache-symlink-crosses-device:{path}")
            entries.append(CacheEntry(relative, "link", info.st_size, info.st_mtime_ns,
                                      info.st_ctime_ns, stat.S_IMODE(info.st_mode), info.st_dev,
                                      info.st_ino, hashlib.sha256(target_text.encode()).hexdigest(),
                                      target_text))
            return
        if stat.S_ISDIR(info.st_mode):
            entries.append(CacheEntry(relative, "dir", 0, info.st_mtime_ns, info.st_ctime_ns,
                                      stat.S_IMODE(info.st_mode), info.st_dev, info.st_ino,
                                      ""))
            return
        if not stat.S_ISREG(info.st_mode):
            raise ArchiveError(f"cache-special-file:{path}")
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                check_deadline(deadline)
                digest.update(chunk)
        after = path.lstat()
        if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ArchiveError(f"cache-file-changed:{path}")
        entries.append(CacheEntry(relative, "file", info.st_size, info.st_mtime_ns,
                                  info.st_ctime_ns, stat.S_IMODE(info.st_mode), info.st_dev,
                                  info.st_ino, digest.hexdigest()))
        total += _allocated(path)

    for member in members:
        if not member.exists() and not member.is_symlink():
            raise ArchiveError(f"cache-member-missing:{member}")
        if member.is_symlink():
            add(member, member.relative_to(root).as_posix())
            continue
        if member.is_file():
            add(member, member.relative_to(root).as_posix())
            continue
        if not member.is_dir():
            raise ArchiveError(f"cache-member-type-unknown:{member}")
        add(member, member.relative_to(root).as_posix())
        def walk_error(error: OSError) -> None:
            raise ArchiveError(f"cache-unreadable:{error.filename}") from error
        for current, dirs, files in os.walk(member, topdown=True, onerror=walk_error, followlinks=False):
            check_deadline(deadline)
            base = Path(current)
            dirs[:] = sorted(dirs)
            files[:] = sorted(files)
            # os.walk places directory symlinks in dirs. Remove them from the
            # walk and record them as opaque objects below.
            child_dirs = list(dirs)
            dirs[:] = [name for name in child_dirs if not (base / name).is_symlink()]
            for name in child_dirs:
                child = base / name
                if child.is_symlink():
                    add(child, child.relative_to(root).as_posix())
                else:
                    add(child, child.relative_to(root).as_posix())
            for name in files:
                add(base / name, (base / name).relative_to(root).as_posix())
    entries.sort(key=lambda entry: entry.path)
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(("\0".join((entry.path, entry.kind, str(entry.size), str(entry.mtime_ns),
                                  str(entry.ctime_ns), str(entry.mode), str(entry.device),
                                  str(entry.inode), entry.digest, entry.link_target)) + "\n").encode())
    return CacheSnapshot(digest.hexdigest(), total, tuple(entries), device, root_info.st_ino,
                         stat.S_IMODE(root_info.st_mode))


def _member_snapshot(path: Path, unit_root: Path, *, deadline: float | None = None,
                     validate_links: bool = True) -> CacheSnapshot:
    """Return a member fingerprint independent of its top-level name."""
    raw = _cache_snapshot(path.parent, (path,), deadline, unit_root=unit_root,
                          validate_links=validate_links)
    prefix = path.name
    entries: list[CacheEntry] = []
    for entry in raw.entries:
        if entry.path == prefix:
            relative = "."
        elif entry.path.startswith(prefix + "/"):
            relative = entry.path[len(prefix) + 1:]
        else:
            raise ArchiveError(f"cache-member-inventory-escape:{path}")
        entries.append(CacheEntry(relative, entry.kind, entry.size, entry.mtime_ns,
                                  entry.ctime_ns, entry.mode, entry.device, entry.inode,
                                  entry.digest, entry.link_target))
    entries.sort(key=lambda entry: entry.path)
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(("\0".join((entry.path, entry.kind, str(entry.size), str(entry.mode),
                                  str(entry.device), str(entry.inode), entry.digest,
                                  entry.link_target, str(entry.mtime_ns), str(entry.ctime_ns))) + "\n").encode())
    info = path.lstat()
    return CacheSnapshot(digest.hexdigest(), raw.bytes, tuple(entries), info.st_dev,
                         info.st_ino, stat.S_IMODE(info.st_mode))


def _same_payload(left: CacheSnapshot, right: CacheSnapshot) -> bool:
    """Compare content and descendants while allowing rename-only root times."""
    if (left.bytes, left.root_device, left.root_inode, left.root_mode) != (
            right.bytes, right.root_device, right.root_inode, right.root_mode):
        return False
    if len(left.entries) != len(right.entries):
        return False
    for before, after in zip(left.entries, right.entries):
        stable_before = (before.path, before.kind, before.size, before.mode, before.device,
                         before.inode, before.digest, before.link_target)
        stable_after = (after.path, after.kind, after.size, after.mode, after.device,
                        after.inode, after.digest, after.link_target)
        if stable_before != stable_after:
            return False
        if before.path != "." and (before.mtime_ns, before.ctime_ns) != (after.mtime_ns, after.ctime_ns):
            return False
    return True


def _cache_idle(path: Path, deadline: float | None) -> tuple[bool, str]:
    """Confirm there are no open cache files; uncertainty means busy."""
    check_deadline(deadline)
    executable = shutil.which("lsof")
    if not executable:
        return False, "lsof-unavailable"
    timeout = max(1.0, min(10.0, deadline - time.monotonic())) if deadline else 10.0
    try:
        result = subprocess.run((executable, "-t", "+D", str(path)), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError):
        return False, "lsof-unknown"
    stderr_safe = (not result.stderr.strip()
                   or lsof_only_external_smbfs_warning(result.stderr, path))
    if result.returncode == 1 and not result.stdout.strip() and stderr_safe:
        return True, ""
    if result.returncode == 0 and not result.stdout.strip() and stderr_safe:
        return True, ""
    return False, "cache-open-or-lsof-unknown"


BUILD_PROCESS_BASENAMES = frozenset({
    "xcodebuild", "XCBBuildService", "swift", "swiftc", "swift-driver",
    "swift-frontend", "xctest", "clang", "clang++", "ld",
})


def _live_build_process() -> tuple[bool, str]:
    """Check executable names only; process arguments can contain unrelated text."""
    try:
        result = subprocess.run(("/bin/ps", "-axo", "pid=,comm="),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=3, check=False)
    except (OSError, subprocess.SubprocessError):
        return True, "process-probe-unknown"
    if result.returncode != 0 or result.stderr.strip():
        return True, "process-probe-unknown"
    try:
        lines = result.stdout.decode("utf-8").splitlines()
        if not lines:
            return True, "process-probe-unknown"
        for line in lines:
            fields = line.strip().split(None, 1)
            if len(fields) != 2 or not fields[0].isdigit():
                return True, "process-probe-unknown"
            if Path(fields[1].strip()).name in BUILD_PROCESS_BASENAMES:
                return True, "build-or-test-process-active"
    except (UnicodeError, ValueError):
        return True, "process-probe-unknown"
    return False, ""


def _owner_started(pid: int) -> str:
    result = subprocess.run(("/bin/ps", "-o", "lstart=", "-p", str(pid)),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=3, check=False, env=dict(os.environ, TZ="UTC0", LC_ALL="C"))
    if result.returncode != 0 or result.stderr.strip():
        raise ArchiveError("full-run-owner-identity-unavailable")
    value = result.stdout.decode("utf-8", "replace").strip()
    if not value:
        raise ArchiveError("full-run-owner-identity-empty")
    return value


def _acquire_full_run(build: Path) -> tuple[Path, tuple[int, int], str]:
    """Acquire test-temp-state.sh's mkdir lock without stale-lock recovery."""
    lock = build / "full-run.lock"
    recovery = build / "full-run.lock.recovery"
    if recovery.exists() or recovery.is_symlink():
        raise ArchiveError("full-run-recovery-busy")
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise ArchiveError("full-run-busy") from error
    info = lock.lstat()
    started: str | None = None
    temporary_identity: tuple[int, int] | None = None
    try:
        started = _owner_started(os.getpid())
        temporary = lock / "pid.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        temporary_info = os.fstat(descriptor)
        temporary_identity = (temporary_info.st_dev, temporary_info.st_ino)
        try:
            os.write(descriptor, f"pid={os.getpid()}\nstarted={started}\n".encode())
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, lock / "pid")
        if recovery.exists() or recovery.is_symlink():
            raise ArchiveError("full-run-recovery-busy")
        return lock, (info.st_dev, info.st_ino), started
    except Exception:
        try:
            current = lock.lstat()
            if (current.st_dev, current.st_ino) == (info.st_dev, info.st_ino) and not lock.is_symlink():
                for name in ("pid", "pid.tmp"):
                    owned = lock / name
                    if not owned.exists() or owned.is_symlink():
                        continue
                    owned_info = owned.lstat()
                    own_temp = name == "pid.tmp" and temporary_identity == (owned_info.st_dev, owned_info.st_ino)
                    try:
                        contents = owned.read_text(encoding="utf-8")
                    except OSError:
                        contents = ""
                    own_record = started is not None and contents == f"pid={os.getpid()}\nstarted={started}\n"
                    if stat.S_ISREG(owned_info.st_mode) and (own_temp or own_record):
                        owned.unlink()
                if not any(lock.iterdir()):
                    lock.rmdir()
        except OSError:
            pass
        raise


def _release_full_run(lock: Path, identity: tuple[int, int], started: str) -> None:
    """Release only the lock directory and owner record created by this run."""
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    try:
        try:
            info = lock.lstat()
            if (info.st_dev, info.st_ino) != identity or lock.is_symlink():
                return
            expected = f"pid={os.getpid()}\nstarted={started}\n"
            if (lock / "pid").read_text(encoding="utf-8") != expected:
                return
            (lock / "pid").unlink()
            lock.rmdir()
        except OSError:
            return
    finally:
        # A wall-clock alarm must not strand our own lock mid-cleanup.
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def _remove_member(repo: Path, member: Path, expected: CacheSnapshot,
                   unit_root: Path) -> None:
    """Quarantine one member, recheck opaque links/content, then remove it."""
    parent = member.parent
    quarantine = parent / f".retention-removing-{os.getpid()}-{time.time_ns()}-{member.name}"
    before = _member_snapshot(member, unit_root, validate_links=True)
    if before != expected:
        raise ArchiveError(f"cache-changed-before-rename:{member}")
    os.rename(member, quarantine)
    try:
        # Preserve absolute/relative link targets as opaque strings; after the
        # rename, absolute internal links may no longer resolve but are never followed.
        after = _member_snapshot(quarantine, unit_root, validate_links=False)
        if not _same_payload(expected, after):
            raise ArchiveError(f"cache-changed-after-rename:{member}")
        if quarantine.is_symlink():
            quarantine.unlink()
        elif quarantine.is_dir():
            if not shutil.rmtree.avoids_symlink_attacks:
                raise ArchiveError("safe-recursive-delete-unavailable")
            shutil.rmtree(quarantine)
        else:
            quarantine.unlink()
    except Exception:
        if quarantine.exists() or quarantine.is_symlink():
            if not member.exists() and not member.is_symlink():
                os.rename(quarantine, member)
        raise



def _payload_bytes(path: Path, device: int, deadline: float | None = None) -> int:
    """Measure allocated regular-file bytes without crossing links or mounts."""
    check_deadline(deadline)
    info = path.lstat()
    if info.st_dev != device:
        raise ArchiveError(f"cache-mount-boundary:{path}")
    if stat.S_ISLNK(info.st_mode):
        return 0
    if stat.S_ISREG(info.st_mode):
        return _allocated(path)
    if not stat.S_ISDIR(info.st_mode):
        raise ArchiveError(f"cache-special-file:{path}")
    total = 0
    def walk_error(error: OSError) -> None:
        raise ArchiveError(f"cache-unreadable:{error.filename}") from error
    for current, dirs, files in os.walk(path, topdown=True, onerror=walk_error, followlinks=False):
        check_deadline(deadline)
        base = Path(current)
        kept: list[str] = []
        for name in sorted(dirs):
            child = base / name
            child_info = child.lstat()
            if child_info.st_dev != device:
                raise ArchiveError(f"cache-mount-boundary:{child}")
            if stat.S_ISLNK(child_info.st_mode):
                continue
            if not stat.S_ISDIR(child_info.st_mode):
                raise ArchiveError(f"cache-special-file:{child}")
            kept.append(name)
        dirs[:] = kept
        for name in sorted(files):
            child = base / name
            child_info = child.lstat()
            if child_info.st_dev != device:
                raise ArchiveError(f"cache-mount-boundary:{child}")
            if stat.S_ISLNK(child_info.st_mode):
                continue
            if not stat.S_ISREG(child_info.st_mode):
                raise ArchiveError(f"cache-special-file:{child}")
            total += _allocated(child)
    return total


def _remaining_unit_bytes(unit: CacheUnit, device: int,
                          deadline: float | None = None) -> int:
    """Count live members and any quarantine left by an interrupted removal."""
    total = 0
    for member in unit.members:
        candidates: list[Path] = []
        if member.exists() or member.is_symlink():
            candidates.append(member)
        try:
            for sibling in member.parent.iterdir():
                if (sibling.name.startswith(".retention-removing-")
                        and sibling.name.endswith("-" + member.name)
                        and sibling != member):
                    candidates.append(sibling)
        except OSError as error:
            raise ArchiveError(f"cache-unreadable:{member.parent}") from error
        for candidate in candidates:
            total += _payload_bytes(candidate, device, deadline)
    return total

def evict(repo: Path, *, budget: int = BUDGET_BYTES, now: float | None = None,
          apply: bool = False, deadline: float | None = None,
          min_age: float = QUIET_SECONDS, preserve: tuple[str, ...] = ()) -> dict[str, object]:
    """Evict oldest whole cache units until under budget or no safe candidate remains."""
    now = time.time() if now is None else now
    if budget < 0 or min_age < 0:
        return {"status": "error", "reason": "invalid-budget-or-age", "remaining_bytes": 0}
    repo = repo.expanduser().absolute()
    build = repo / ".build"
    if build.is_symlink() or not build.is_dir() or build.resolve(strict=True) != build:
        return {"status": "skipped", "reason": "build-root-invalid", "remaining_bytes": 0}
    try:
        lock, lock_identity, started = _acquire_full_run(build)
    except (OSError, ArchiveError) as error:
        return {"status": "skipped", "reason": str(error), "budget": budget,
                "remaining_bytes": 0, "units": []}
    descriptors: dict[str, int] = {}
    rows: list[dict[str, object]] = []
    total = 0
    result: dict[str, object] = {"budget": budget, "remaining_bytes": total, "units": rows}
    try:
        live, reason = _live_build_process()
        if live:
            result.update(status="skipped", reason=reason)
            return result
        selected_units = _units(repo)
        preflight: list[tuple[CacheUnit, int]] = []
        for unit in selected_units:
            check_deadline(deadline)
            preflight_size = sum(_size(member, deadline) for member in unit.members)
            preflight.append((unit, preflight_size))
            total += preflight_size
            rows.append({"path": str(unit.path), "kind": unit.kind, "key": unit.key,
                         "bytes": preflight_size, "status": "protected"})
        result["remaining_bytes"] = total
        if total <= budget:
            result["status"] = "within-budget"
            return result

        # Over-budget work keeps the content-bound validation path below.
        total = 0
        rows.clear()
        snapshots: dict[str, CacheSnapshot] = {}
        for unit in selected_units:
            check_deadline(deadline)
            key = unit.key + ":" + unit.kind
            snapshots[key] = _cache_snapshot(build, unit.members, deadline,
                                              unit_root=unit.path)
            total += snapshots[key].bytes
            rows.append({"path": str(unit.path), "kind": unit.kind, "key": unit.key,
                         "bytes": snapshots[key].bytes, "status": "protected"})
        result["remaining_bytes"] = total
        if total <= budget:
            result["status"] = "within-budget"
            return result
        candidates: list[tuple[float, CacheUnit, CacheSnapshot, dict[str, object]]] = []
        for unit, row in zip(selected_units, rows):
            check_deadline(deadline)
            key = unit.key + ":" + unit.kind
            if snapshots[key].bytes == 0:
                row["status"] = "empty"
                continue
            snapshot = _cache_snapshot(build, unit.members, deadline, unit_root=unit.path)
            if snapshot != snapshots[key]:
                row["status"] = "protected-changed"
                continue
            newest_ns = max((entry.mtime_ns for entry in snapshot.entries), default=0)
            if newest_ns and now - newest_ns / 1_000_000_000 < min_age:
                row["status"] = "protected-young"
                continue
            if unit.key in preserve or unit.kind + ":" + unit.key in preserve:
                row["status"] = "protected-pinned"
                continue
            candidates.append((newest_ns / 1_000_000_000, unit, snapshot, row))
        candidates.sort(key=lambda item: (item[0], item[1].path.as_posix()))
        for _, unit, snapshot, row in candidates:
            check_deadline(deadline)
            if total <= budget:
                break
            okay, reason = _cache_idle(unit.path, deadline)
            if not okay:
                row["status"] = "protected-busy-or-unknown"
                row["reason"] = reason
                continue
            descriptor: int | None = None
            unit_key = unit.key + ":" + unit.kind
            removed_members: list[str] = []
            removed_member_bytes = 0
            removal_started = False
            member_snapshots: dict[Path, CacheSnapshot] = {}
            try:
                if unit.lock is not None:
                    unit.lock.parent.mkdir(parents=True, exist_ok=True)
                    descriptor = os.open(unit.lock, os.O_RDWR | os.O_CREAT, 0o644)
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    descriptors[unit_key] = descriptor
                live, reason = _live_build_process()
                okay, idle_reason = _cache_idle(unit.path, deadline)
                current = _cache_snapshot(build, unit.members, deadline, unit_root=unit.path)
                if live or not okay or current != snapshot:
                    row["status"] = "protected-raced-or-unknown"
                    row["reason"] = reason if live else idle_reason if not okay else "identity-changed"
                    continue
                # Validate every member before starting a multi-member removal.
                for member in unit.members:
                    member_snapshots[member] = _member_snapshot(
                        member, unit.path, deadline=deadline)
                if _cache_snapshot(build, unit.members, deadline,
                                   unit_root=unit.path) != snapshot:
                    row["status"] = "protected-raced-or-unknown"
                    row["reason"] = "member-prevalidation-changed"
                    continue
                if apply:
                    removal_started = True
                    for member in unit.members:
                        _remove_member(repo, member, member_snapshots[member], unit.path)
                        removed_members.append(str(member))
                        removed_member_bytes += member_snapshots[member].bytes
                    remaining = _remaining_unit_bytes(unit, build.stat().st_dev, deadline)
                    row["removed_members"] = removed_members
                    row["removed_bytes"] = max(0, snapshot.bytes - remaining)
                    row["remaining_bytes"] = remaining
                    if remaining == 0 and not any(
                            member.exists() or member.is_symlink() for member in unit.members):
                        row["status"] = "removed"
                    else:
                        row["status"] = "partially-removed"
                    total = max(0, total - snapshot.bytes) + remaining
                else:
                    row["status"] = "evictable"
                    row["removed_bytes"] = 0
                    row["remaining_bytes"] = snapshot.bytes
                    total -= snapshot.bytes
            except BlockingIOError:
                row["status"] = "protected-lock-busy"
            except (OSError, ArchiveError, TimeoutError) as error:
                row["reason"] = error.__class__.__name__
                if apply and removal_started:
                    try:
                        remaining = _remaining_unit_bytes(unit, build.stat().st_dev, deadline)
                        removed = max(0, snapshot.bytes - remaining)
                    except (OSError, ArchiveError, TimeoutError):
                        # Count only members whose removal returned successfully;
                        # this is a conservative upper bound on bytes still present.
                        removed = min(snapshot.bytes, removed_member_bytes)
                        remaining = max(0, snapshot.bytes - removed)
                    total = max(0, total - snapshot.bytes) + remaining
                    row.update(status="partially-removed" if removed else "protected-removal-failed",
                               removed_members=removed_members, removed_bytes=removed,
                               remaining_bytes=remaining)
                else:
                    row["status"] = "protected-removal-failed"
            finally:
                if descriptor is not None:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                    os.close(descriptor)
                    descriptors.pop(unit_key, None)

        result["remaining_bytes"] = total
        result["status"] = "complete" if total <= budget else "over-budget-protected"
        return result
    except (ArchiveError, OSError, TimeoutError) as error:
        result.update(status="partial", reason=error.__class__.__name__, remaining_bytes=total)
        return result
    finally:
        for descriptor in descriptors.values():
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)
            except OSError:
                pass
        _release_full_run(lock, lock_identity, started)
