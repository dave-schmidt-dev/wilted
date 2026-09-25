#!/usr/bin/env python3
"""Inventory the delivery backlog and optionally remove stale spec scratch dirs."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

# Historical spec workspaces used six mktemp characters; the wrapper uses eight.
SPEC_NAME = re.compile(r"^wilted-spec\.(?:[A-Za-z0-9]{6}|[A-Za-z0-9]{8})$")
SPEC_PREFIX = "wilted-spec"
DEFAULT_MIN_AGE_HOURS = 24.0
DEFAULT_PROBE_TIMEOUT_SECONDS = 15.0


def allocated(info: os.stat_result) -> int:
    blocks = getattr(info, "st_blocks", None)
    return int(blocks) * 512 if blocks is not None else int(info.st_size)


def measure(path: Path) -> dict[str, object]:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"path": str(path), "exists": False, "entry_count": 0, "allocated_bytes": 0}
    except OSError as error:
        raise RuntimeError(f"cannot inspect {path}: {error.__class__.__name__}") from error
    size, entries = allocated(info), 1
    if stat.S_ISDIR(info.st_mode):
        stack = [path]
        while stack:
            current = stack.pop()
            try:
                children = list(os.scandir(current))
            except OSError as error:
                raise RuntimeError(f"cannot scan {current}: {error.__class__.__name__}") from error
            for child in children:
                try:
                    child_info = child.stat(follow_symlinks=False)
                except OSError as error:
                    raise RuntimeError(f"cannot inspect {child.path}: {error.__class__.__name__}") from error
                size += allocated(child_info)
                entries += 1
                if stat.S_ISDIR(child_info.st_mode):
                    stack.append(Path(child.path))
    return {"path": str(path), "exists": True, "entry_count": entries, "allocated_bytes": size}


def list_prefix(root: Path, prefix: str) -> list[Path]:
    if not root.is_dir():
        return []
    try:
        return sorted(
            (Path(e.path) for e in os.scandir(root) if e.name.startswith(prefix) and e.is_dir(follow_symlinks=False)),
            key=lambda p: p.name,
        )
    except OSError as error:
        raise RuntimeError(f"cannot list {root}: {error.__class__.__name__}") from error


def list_spec_entries(root: Path) -> list[Path]:
    """Return direct prefix entries so noncanonical names and symlinks are reported."""
    if not root.is_dir():
        return []
    try:
        return sorted(
            (Path(entry.path) for entry in os.scandir(root) if entry.name.startswith(SPEC_PREFIX)),
            key=lambda path: path.name,
        )
    except OSError as error:
        raise RuntimeError(f"cannot list {root}: {error.__class__.__name__}") from error


def inspect_tree(path: Path) -> dict[str, int | bool]:
    """Measure a tree without following symlinks and find its newest mtime."""
    root_info = path.lstat()
    if not stat.S_ISDIR(root_info.st_mode):
        raise RuntimeError("not-a-directory")
    newest = root_info.st_mtime_ns
    size, has_symlink, entries = allocated(root_info), False, 1
    stack = [path]
    while stack:
        current = stack.pop()
        with os.scandir(current) as iterator:
            children = list(iterator)
        for child in children:
            info = child.stat(follow_symlinks=False)
            newest = max(newest, info.st_mtime_ns)
            size += allocated(info)
            entries += 1
            if stat.S_ISLNK(info.st_mode):
                has_symlink = True
            elif stat.S_ISDIR(info.st_mode):
                stack.append(Path(child.path))
    return {"newest_mtime_ns": newest, "allocated_bytes": size, "has_symlink": has_symlink, "entry_count": entries}


def probe(command: list[str], timeout: float) -> tuple[bool | None, str | None]:
    """Return in-use state; command failures and timeouts are indeterminate."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return None, "probe-timeout"
    except OSError as error:
        return None, f"probe-error-{error.__class__.__name__.lower()}"
    output = (result.stdout or "").strip()
    errors = (result.stderr or "").strip()
    if result.returncode == 0:
        return True, None
    if result.returncode == 1 and not output and not errors:
        return False, None
    return None, f"probe-error-exit-{result.returncode}"


def in_use(path: Path, timeout: float) -> tuple[bool | None, str | None]:
    """Check open files and command lines, failing closed on either probe error."""
    lsof_used, error = probe(["lsof", "-t", "+D", str(path)], timeout)
    if error:
        return None, f"lsof-{error}"
    if lsof_used:
        return True, "open-files"
    pgrep_used, error = probe(["pgrep", "-f", "--", str(path)], timeout)
    if error:
        return None, f"pgrep-{error}"
    if pgrep_used:
        return True, "process-reference"
    return False, None


def canonical_child(path: Path, tmp_root: Path) -> bool:
    return bool(SPEC_NAME.fullmatch(path.name)) and path.parent == tmp_root


def newest_is_stale(tree: dict[str, int | bool], cutoff_ns: int, now_ns: int) -> bool:
    return now_ns - int(tree["newest_mtime_ns"]) >= cutoff_ns


def evidence_destination(repo: Path, candidate: Path) -> Path:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    base = repo / ".logs/delivery" / f"storage-retained-{candidate.name}-{stamp}"
    destination = base
    suffix = 0
    while destination.exists() or destination.is_symlink():
        suffix += 1
        destination = Path(f"{base}-{suffix}")
    return destination


def preserve_evidence(repo: Path, candidate: Path, retainer: Path) -> tuple[bool, str | None, Path | None]:
    destination = evidence_destination(repo, candidate)
    try:
        result = subprocess.run(
            [sys.executable, str(retainer), str(candidate), str(destination)],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"evidence-retention-{error.__class__.__name__.lower()}", None
    manifest = destination / "retained-evidence-manifest.json"
    if result.returncode != 0 or not manifest.is_file() or manifest.is_symlink():
        return False, f"evidence-retention-failed-exit-{result.returncode}", None
    return True, None, destination


def remove_tree(path: Path, tmp_root: Path, expected: os.stat_result) -> None:
    """Delete by parent dirfd after checking the original directory identity."""
    if not getattr(shutil.rmtree, "avoids_symlink_attacks", False) or not hasattr(os, "O_DIRECTORY"):
        raise RuntimeError("safe-dirfd-delete-unavailable")
    if not canonical_child(path, tmp_root):
        raise RuntimeError("noncanonical-path-before-delete")
    root_fd = os.open(tmp_root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        current = os.stat(path.name, dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError("directory-changed-before-delete")
        shutil.rmtree(path.name, dir_fd=root_fd)
    finally:
        os.close(root_fd)


def apply_candidate(path: Path, tmp_root: Path, repo: Path, retainer: Path, cutoff_ns: int, timeout: float) -> dict[str, object]:
    result: dict[str, object] = {"path": str(path), "status": "skipped", "reason": "unclassified", "allocated_bytes": 0}
    try:
        info = path.lstat()
    except FileNotFoundError:
        result.update(reason="disappeared-before-inspection")
        return result
    if stat.S_ISLNK(info.st_mode):
        result.update(reason="symlink", allocated_bytes=allocated(info))
        return result
    if not canonical_child(path, tmp_root):
        result.update(reason="noncanonical-name-or-path", allocated_bytes=allocated(info))
        return result
    if not stat.S_ISDIR(info.st_mode):
        result.update(reason="not-a-directory", allocated_bytes=allocated(info))
        return result
    try:
        tree = inspect_tree(path)
    except OSError as error:
        result.update(reason=f"inspection-error-{error.__class__.__name__.lower()}")
        return result
    result["allocated_bytes"] = int(tree["allocated_bytes"])
    if not newest_is_stale(tree, cutoff_ns, time.time_ns()):
        result.update(reason="newest-entry-younger-than-cutoff")
        return result
    used, reason = in_use(path, timeout)
    if reason:
        result.update(reason=reason)
        return result
    if used:
        result.update(reason="in-use")
        return result

    retained, reason, archive = preserve_evidence(repo, path, retainer)
    if not retained:
        result.update(reason=reason or "evidence-retention-failed")
        return result

    # Recheck path identity, newest recursive mtime, and both in-use probes after
    # retention so a changed or newly active workspace remains untouched.
    try:
        current_info = path.lstat()
        current_tree = inspect_tree(path)
    except OSError as error:
        result.update(reason=f"revalidation-error-{error.__class__.__name__.lower()}", evidence_archive=str(archive))
        return result
    if stat.S_ISLNK(current_info.st_mode) or not stat.S_ISDIR(current_info.st_mode):
        result.update(reason="path-type-changed", evidence_archive=str(archive))
        return result
    if (current_info.st_dev, current_info.st_ino) != (info.st_dev, info.st_ino):
        result.update(reason="directory-changed-before-delete", evidence_archive=str(archive))
        return result
    if not newest_is_stale(current_tree, cutoff_ns, time.time_ns()):
        result.update(reason="newest-entry-younger-after-retention", evidence_archive=str(archive))
        return result
    used, reason = in_use(path, timeout)
    if reason:
        result.update(reason=reason, evidence_archive=str(archive))
        return result
    if used:
        result.update(reason="in-use-after-retention", evidence_archive=str(archive))
        return result
    try:
        remove_tree(path, tmp_root, current_info)
    except (OSError, RuntimeError) as error:
        result.update(reason=f"delete-error-{str(error) if isinstance(error, RuntimeError) else error.__class__.__name__.lower()}", evidence_archive=str(archive))
        return result
    result.update(status="removed", reason="stale-and-unused", evidence_archive=str(archive))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tmp-root", type=Path, default=Path(os.environ.get("TMPDIR") or "/tmp"))
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    parser.add_argument("--apply", action="store_true", help="remove stale, unused canonical wilted-spec scratch dirs")
    parser.add_argument("--min-age-hours", type=float, default=DEFAULT_MIN_AGE_HOURS)
    parser.add_argument("--probe-timeout-seconds", type=float, default=DEFAULT_PROBE_TIMEOUT_SECONDS)
    args = parser.parse_args()
    if not math.isfinite(args.min_age_hours) or not math.isfinite(args.probe_timeout_seconds) or args.min_age_hours < 0 or args.probe_timeout_seconds <= 0:
        parser.error("age must be nonnegative and probe timeout must be positive")
    if args.apply and args.min_age_hours < DEFAULT_MIN_AGE_HOURS:
        parser.error("--apply requires a minimum age of at least 24 hours")
    try:
        repo = args.repo.expanduser().resolve(strict=True)
        tmp_root = args.tmp_root.expanduser().resolve(strict=True)
        if not repo.is_dir() or not tmp_root.is_dir():
            raise RuntimeError("repo and temp root must be directories")
        archives = [measure(path) for path in list_prefix(repo / ".logs/delivery", "storage-retained-")]
        build = measure(repo / ".build")
        specs = [measure(path) for path in list_prefix(tmp_root, SPEC_PREFIX)]
        entries = list_spec_entries(tmp_root)
    except (RuntimeError, OSError) as error:
        print(f"storage-backlog.error {error}", file=sys.stderr)
        return 2
    archive_bytes = sum(int(row["allocated_bytes"]) for row in archives)
    spec_bytes = sum(int(row["allocated_bytes"]) for row in specs)
    totals = {
        "retained_archive_count": len(archives),
        "retained_allocated_bytes": archive_bytes,
        "repo_build_allocated_bytes": int(build["allocated_bytes"]),
        "wilted_spec_count": len(specs),
        "wilted_spec_allocated_bytes": spec_bytes,
        "all_allocated_bytes": archive_bytes + int(build["allocated_bytes"]) + spec_bytes,
    }
    cutoff_ns = int(args.min_age_hours * 60 * 60 * 1_000_000_000)
    if args.apply:
        retainer = Path(__file__).with_name("retain-delivery-evidence.py")
        outcomes = [apply_candidate(path, tmp_root, repo, retainer, cutoff_ns, args.probe_timeout_seconds) for path in entries]
        cleanup_summary = {
            "removed_count": sum(row["status"] == "removed" for row in outcomes),
            "freed_bytes": sum(int(row["allocated_bytes"]) for row in outcomes if row["status"] == "removed"),
            "skipped_count": sum(row["status"] == "skipped" for row in outcomes),
        }
        data = {"mode": "apply", "retained_archives": archives, "repo_build": build, "wilted_spec_temp": specs, "totals": totals, "cleanup": outcomes, "cleanup_summary": cleanup_summary}
    else:
        now_ns = time.time_ns()
        outcomes: list[dict[str, object]] = []
        for path in entries:
            try:
                info = path.lstat()
                if stat.S_ISLNK(info.st_mode):
                    outcomes.append({"path": str(path), "status": "skipped", "reason": "symlink", "allocated_bytes": allocated(info)})
                elif not canonical_child(path, tmp_root):
                    outcomes.append({"path": str(path), "status": "skipped", "reason": "noncanonical-name-or-path", "allocated_bytes": allocated(info)})
                else:
                    tree = inspect_tree(path)
                    stale = newest_is_stale(tree, cutoff_ns, now_ns)
                    reason = "eligible" if stale else "newest-entry-younger-than-cutoff"
                    outcomes.append({"path": str(path), "status": "would-remove" if stale else "skipped", "reason": reason, "allocated_bytes": int(tree["allocated_bytes"])})
            except (OSError, RuntimeError) as error:
                outcomes.append({"path": str(path), "status": "skipped", "reason": f"inspection-error-{error.__class__.__name__.lower()}", "allocated_bytes": 0})
        cleanup_summary = {
            "removed_count": 0,
            "freed_bytes": 0,
            "skipped_count": sum(row["status"] == "skipped" for row in outcomes),
        }
        data = {"mode": "dry-run", "retained_archives": archives, "repo_build": build, "wilted_spec_temp": specs, "totals": totals, "cleanup": outcomes, "cleanup_summary": cleanup_summary}
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        mode_note = "apply" if args.apply else "dry-run (read-only)"
        print(f"storage-backlog mode={mode_note}")
        for row in archives:
            print(f"retained path={row['path']} entries={row['entry_count']} allocated_bytes={row['allocated_bytes']}")
        print(f"retained_total count={len(archives)} allocated_bytes={archive_bytes}")
        print(f"repo_build path={build['path']} entries={build['entry_count']} allocated_bytes={build['allocated_bytes']}")
        for row in specs:
            print(f"wilted_spec path={row['path']} entries={row['entry_count']} allocated_bytes={row['allocated_bytes']}")
        print(f"wilted_spec_total count={len(specs)} allocated_bytes={spec_bytes}")
        for row in data["cleanup"]:
            print(f"cleanup status={row['status']} path={row['path']} reason={row['reason']} allocated_bytes={row['allocated_bytes']}")
        summary = data["cleanup_summary"]
        print(f"cleanup_total removed_count={summary['removed_count']} freed_bytes={summary['freed_bytes']} skipped_count={summary['skipped_count']}")
        print(f"all_total allocated_bytes={totals['all_allocated_bytes']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
