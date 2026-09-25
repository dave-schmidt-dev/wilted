#!/usr/bin/env python3
"""Read-only inventory of retained workspaces, the repo .build, and wilted-spec temp dirs."""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from pathlib import Path


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--tmp-root", type=Path, default=Path(os.environ.get("TMPDIR") or "/tmp"))
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()
    repo = args.repo.expanduser().resolve()
    try:
        archives = [measure(p) for p in list_prefix(repo / ".logs/delivery", "storage-retained-")]
        build = measure(repo / ".build")
        specs = [measure(p) for p in list_prefix(args.tmp_root.expanduser(), "wilted-spec")]
    except RuntimeError as error:
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
    data = {"mode": "dry-run", "retained_archives": archives, "repo_build": build, "wilted_spec_temp": specs, "totals": totals}
    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print("storage-backlog mode=dry-run (read-only)")
        for row in archives:
            print(f"retained path={row['path']} entries={row['entry_count']} allocated_bytes={row['allocated_bytes']}")
        print(f"retained_total count={len(archives)} allocated_bytes={archive_bytes}")
        print(f"repo_build path={build['path']} entries={build['entry_count']} allocated_bytes={build['allocated_bytes']}")
        for row in specs:
            print(f"wilted_spec path={row['path']} entries={row['entry_count']} allocated_bytes={row['allocated_bytes']}")
        print(f"wilted_spec_total count={len(specs)} allocated_bytes={spec_bytes}")
        print(f"all_total allocated_bytes={totals['all_allocated_bytes']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
