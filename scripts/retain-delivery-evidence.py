#!/usr/bin/env python3
"""Retain delivery logs/receipts without copying source trees or `.build`."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

MARKERS = ("receipt", "result", "authorization", "status", "manifest")
RECEIPT_SUFFIXES = {".json", ".jsonl", ".md", ".status", ".txt"}


def evidence_kind(path: Path) -> str | None:
    name = path.name.lower()
    if name.endswith((".log", ".xcactivitylog")):
        return "log"
    if path.suffix.lower() in RECEIPT_SUFFIXES and any(marker in name for marker in MARKERS):
        return "receipt"
    return None


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def copy_result_bundle(source: Path, destination: Path) -> tuple[int, int]:
    """Copy regular files from an xcresult bundle, omitting symlinks."""
    count = size = 0
    destination.mkdir(parents=True, exist_ok=False)
    for current, dirs, files in os.walk(source, topdown=True, followlinks=False):
        current_path = Path(current)
        target_dir = destination / current_path.relative_to(source)
        target_dir.mkdir(parents=True, exist_ok=True)
        safe_dirs = []
        for name in dirs:
            child = current_path / name
            if stat.S_ISDIR(child.lstat().st_mode):
                safe_dirs.append(name)
        dirs[:] = safe_dirs
        for name in files:
            child = current_path / name
            if not stat.S_ISREG(child.lstat().st_mode):
                continue
            shutil.copy2(child, target_dir / name)
            count += 1
            size += child.stat().st_size
    return count, size


def collect(source: Path, destination: Path, staging: Path) -> list[dict[str, object]]:
    items: list[dict[str, object]] = []
    for current, dirs, files in os.walk(source, topdown=True, followlinks=False):
        current_path = Path(current)
        safe_dirs: list[str] = []
        for name in dirs:
            child = current_path / name
            if name in {".build", ".git"} or name.startswith("storage-retained-"):
                continue
            if not stat.S_ISDIR(child.lstat().st_mode):
                continue
            if child.resolve() == destination or child.resolve() == staging:
                continue
            if name.endswith(".xcresult"):
                relative = child.relative_to(source)
                count, size = copy_result_bundle(child, staging / relative)
                items.append({"path": str(relative), "kind": "xcresult", "file_count": count, "bytes": size})
            else:
                safe_dirs.append(name)
        dirs[:] = safe_dirs
        for name in files:
            path = current_path / name
            kind = evidence_kind(path)
            if kind is None or not stat.S_ISREG(path.lstat().st_mode):
                continue
            relative = path.relative_to(source)
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
            items.append({"path": str(relative), "kind": kind, "bytes": path.stat().st_size})
    return sorted(items, key=lambda item: str(item["path"]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="workspace tree to scan")
    parser.add_argument("destination", type=Path, help="new archive directory; must not exist")
    args = parser.parse_args()
    source = args.source.expanduser().resolve()
    raw_destination = args.destination.expanduser()
    destination = raw_destination.resolve()
    if not source.is_dir() or destination == source or is_within(destination, source):
        print("retain-evidence.error invalid source or destination", file=sys.stderr)
        return 2
    if raw_destination.is_symlink() or destination.exists():
        print("retain-evidence.error destination already exists", file=sys.stderr)
        return 2
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=f".{destination.name}.partial-", dir=destination.parent))
    except OSError as error:
        print(f"retain-evidence.error cannot create staging: {error.__class__.__name__}", file=sys.stderr)
        return 2
    try:
        items = collect(source, destination, staging)
        manifest = {
            "format": 1,
            "source_name": source.name,
            "retained_items": items,
            "retained_file_count": sum(int(item.get("file_count", 1)) for item in items),
            "retained_bytes": sum(int(item["bytes"]) for item in items),
        }
        (staging / "retained-evidence-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        if raw_destination.is_symlink() or destination.exists():
            raise RuntimeError("destination appeared during retention")
        os.rename(staging, destination)
    except (OSError, RuntimeError) as error:
        if staging.is_dir() and not staging.is_symlink():
            shutil.rmtree(staging)
        print(f"retain-evidence.error {error}", file=sys.stderr)
        return 2
    print(f"retain-evidence.ok destination={destination} items={len(items)} files={manifest['retained_file_count']} bytes={manifest['retained_bytes']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
