#!/usr/bin/env python3
"""Record and compare top-level Wilted temporary entries without deleting them."""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
from pathlib import Path


OWNER_MARKER = ".wilted-temp-owned"


def owner(directory: str) -> dict[str, str] | None:
    """Return the pid and start time a ``.wilted-temp-owned`` marker records, if any."""
    marker = os.path.join(directory, OWNER_MARKER)
    try:
        if not stat.S_ISREG(os.lstat(marker).st_mode):
            return None
        with open(marker, encoding="utf-8") as handle:
            fields = dict(line.rstrip("\n").split("=", 1) for line in handle if "=" in line)
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    if not fields.get("pid", "").isdigit() or not fields.get("started"):
        return None
    return {"pid": fields["pid"], "started": fields["started"]}


def owner_alive(recorded: dict[str, str]) -> bool:
    """Return whether the marker's pid still runs with the start time it recorded (no pid reuse)."""
    try:
        started = subprocess.run(
            ["ps", "-o", "lstart=", "-p", recorded["pid"]], capture_output=True, text=True, check=False
        ).stdout.strip()
    except OSError:
        return False
    return bool(started) and started == recorded["started"].strip()


def snapshot(root: Path) -> dict[str, object]:
    """Return identity data for every top-level ``wilted-*`` entry in *root*."""
    try:
        resolved = root.resolve(strict=True)
        if not resolved.is_dir():
            raise ValueError("root-not-directory")
        entries: list[dict[str, object]] = []
        with os.scandir(resolved) as scanned:
            for entry in scanned:
                if not entry.name.startswith("wilted-"):
                    continue
                try:
                    details = entry.stat(follow_symlinks=False)
                except OSError as error:
                    raise ValueError(f"entry-unverifiable:{entry.name}:{error.errno}") from error
                record: dict[str, object] = {
                    "name": entry.name,
                    "device": details.st_dev,
                    "inode": details.st_ino,
                    "mode": stat.S_IFMT(details.st_mode),
                    "symlink": stat.S_ISLNK(details.st_mode),
                }
                if stat.S_ISDIR(details.st_mode) and (marker := owner(entry.path)):
                    record["owner"] = marker
                entries.append(record)
    except OSError as error:
        raise ValueError(f"root-unverifiable:{error.errno}") from error
    entries.sort(key=lambda item: str(item["name"]))
    return {"root": str(resolved), "entries": entries}


def load(path: Path) -> dict[str, object]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data.get("entries"), list):
            raise ValueError("entries-missing")
        return data
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"snapshot-invalid:{path}:{error}") from error


def identities(data: dict[str, object]) -> set[tuple[object, ...]]:
    return {
        (entry["name"], entry["device"], entry["inode"], entry["mode"], entry["symlink"])
        for entry in data["entries"]  # type: ignore[index]
    }


def write_snapshot(root: Path, output: Path) -> int:
    data = snapshot(root)
    output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"temp.snapshot root={data['root']} entries={len(data['entries'])}")
    return 0


def foreign(data: dict[str, object], entry: tuple[object, ...], owner_pid: str | None) -> dict[str, str] | None:
    """Return the owner of an added root that another live Wilted run marked, else None.

    Concurrent gates in sibling worktrees share ``$TMPDIR``; their marked roots are
    not this run's leaks. An unmarked entry, a dead owner, or this run's own pid
    still counts.
    """
    if owner_pid is None:
        return None
    for record in data["entries"]:  # type: ignore[index]
        if (record["name"], record["device"], record["inode"]) == entry[:3]:
            recorded = record.get("owner")
            if isinstance(recorded, dict) and recorded.get("pid") != owner_pid and owner_alive(recorded):
                return recorded
    return None


def compare(before_path: Path, after_path: Path, label: str, owner_pid: str | None = None) -> int:
    before = load(before_path)
    after = load(after_path)
    if before.get("root") != after.get("root"):
        print(f"temp.leak.error label={label} reason=root-mismatch", file=sys.stderr)
        return 2
    before_entries, after_entries = identities(before), identities(after)
    additions = []
    for entry in sorted(after_entries - before_entries):
        if recorded := foreign(after, entry, owner_pid):
            print(f"temp.foreign label={label} entry={entry[0]} owner_pid={recorded['pid']}")
        else:
            additions.append(entry)
    removals = sorted(before_entries - after_entries)
    print(
        f"temp.audit label={label} root={before['root']} before={len(before_entries)} "
        f"after={len(after_entries)} additions={len(additions)} removals={len(removals)}"
    )
    for entry in additions:
        print(f"temp.leak label={label} entry={entry[0]} device={entry[1]} inode={entry[2]}", file=sys.stderr)
    for entry in removals:
        print(f"temp.removed-baseline label={label} entry={entry[0]}")
    return 1 if additions else 0


def parser() -> argparse.ArgumentParser:
    parsed = argparse.ArgumentParser()
    commands = parsed.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("snapshot")
    capture.add_argument("root", type=Path)
    capture.add_argument("output", type=Path)
    compare_parser = commands.add_parser("compare")
    compare_parser.add_argument("before", type=Path)
    compare_parser.add_argument("after", type=Path)
    compare_parser.add_argument("--label", required=True)
    compare_parser.add_argument("--owner-pid", help="this run's marker pid; other live runs' marked roots are exempt")
    return parsed


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "snapshot":
            return write_snapshot(args.root, args.output)
        return compare(args.before, args.after, args.label, args.owner_pid)
    except ValueError as error:
        print(f"temp.leak.error {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
