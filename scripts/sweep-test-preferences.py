#!/usr/bin/env python3
"""Sweep leftover Mac test preference plists from exited test hosts."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import time

_UUID = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
_TESTS_PATTERN = re.compile(
    rf"^com\.zerodelta\.wilted\.mac\.tests\.[A-Za-z0-9_-]+\.([0-9]+)\.{_UUID}\.plist$"
)
_FIXTURE_PATTERN = re.compile(
    rf"^com\.zerodelta\.wilted\.mac\.ui-fixture\.([0-9]+)\.{_UUID}\.plist$"
)
_PID_CACHE: dict[int, tuple[bool, float | None]] = {}


def birth_time(path: Path) -> float:
    """Return creation birth time of path in seconds since epoch.

    Args:
        path: Path to target file.

    Returns:
        Birth time as a float.
    """
    stat = path.stat()
    return getattr(stat, "st_birthtime", stat.st_ctime)


def _inspect_pid(pid: int) -> tuple[bool, float | None]:
    """Inspect whether a pid exists and retrieve its start time.

    Args:
        pid: Process identifier.

    Returns:
        Tuple of (exists, start_time_or_none).
    """
    try:
        os.kill(pid, 0)
    except PermissionError:
        pass
    except OSError:
        return (False, None)

    try:
        res = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            env={**os.environ, "LC_ALL": "C"},
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            return (True, None)
        text = res.stdout.strip()
        if not text:
            return (True, None)
        t_struct = time.strptime(text, "%a %b %d %H:%M:%S %Y")
        return (True, time.mktime(t_struct))
    except Exception:
        return (True, None)


def creator_is_live(pid: int, born: float) -> bool:
    """Determine whether a process creator is still running.

    Args:
        pid: Process identifier of the creator.
        born: File birth time in seconds since epoch.

    Returns:
        True if the creator process is live; False otherwise.
    """
    if pid <= 0 or pid > 99_999_999:
        return False
    if pid not in _PID_CACHE:
        _PID_CACHE[pid] = _inspect_pid(pid)
    exists, start_time = _PID_CACHE[pid]
    if not exists:
        return False
    if start_time is None:
        return True
    return start_time <= born + 2.0


def candidates(directory: Path) -> list[tuple[Path, int]]:
    """Find candidate test preference plists in the directory.

    Args:
        directory: Directory to search for preference files.

    Returns:
        List of (path, pid) tuples for matching candidates.
    """
    if not directory.is_dir():
        return []
    results: list[tuple[Path, int]] = []
    try:
        entries = list(directory.iterdir())
    except OSError:
        return []

    for entry in entries:
        if entry.is_symlink() or not entry.is_file():
            continue
        m = _TESTS_PATTERN.match(entry.name) or _FIXTURE_PATTERN.match(entry.name)
        if m:
            results.append((entry, int(m.group(1))))
    return sorted(results, key=lambda item: item[0].name)


def main(argv: list[str] | None = None) -> int:
    """Run the test preferences sweep script.

    Args:
        argv: Optional command-line arguments.

    Returns:
        Exit code: 0 on success, 2 on invalid arguments.
    """
    if argv is not None:
        argv = [str(arg) for arg in argv]

    parser = argparse.ArgumentParser(description="Sweep Mac test preference plists.")
    parser.add_argument("--directory", type=Path, default=None, help="Directory to sweep.")
    parser.add_argument("--dry-run", action="store_true", help="Simulate removal.")
    args = parser.parse_args(argv)

    directory: Path | None = args.directory
    if directory is None:
        env_dir = os.environ.get("WILTED_PREFERENCES_DIR")
        directory = Path(env_dir) if env_dir else Path.home() / "Library" / "Preferences"
    directory = directory.expanduser()

    action = "would-remove" if args.dry_run else "removed"
    if not directory.is_dir():
        print(f"test-preferences.sweep {action}=0 kept-live=0 failed=0", file=sys.stderr)
        return 0

    removed = 0
    kept_live = 0
    failed = 0

    for path, pid in candidates(directory):
        try:
            born = birth_time(path)
        except OSError:
            failed += 1
            continue

        if creator_is_live(pid, born):
            kept_live += 1
        elif args.dry_run:
            removed += 1
        else:
            try:
                os.unlink(path)
                removed += 1
            except OSError:
                failed += 1

    print(
        f"test-preferences.sweep {action}={removed} kept-live={kept_live} failed={failed}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
