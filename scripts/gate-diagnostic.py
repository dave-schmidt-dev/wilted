#!/usr/bin/env python3
"""Write the bounded local-gate failure diagnostic the release runner reads.

The runner keeps no child output; a failing operation names what failed through a
closed-field document (release.diagnostic.v1) instead. This reads one attempt log,
collects the failing XCTest identifiers it can see, and records the log's path and
digest so the failure can be opened later. The log itself is never copied.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

# The runner screens names to a structured identifier and keeps at most 20.
MAX_TESTS = 20
# `Test Case '-[Module.Suite testName]' failed` and `Test case 'Suite.testName()' failed`.
OBJC_STYLE = re.compile(r"Test Case '-\[(?:[A-Za-z0-9_]+\.)?([A-Za-z_][A-Za-z0-9_]*) ([A-Za-z_][A-Za-z0-9_]*)\]' failed")
SWIFT_STYLE = re.compile(r"Test [Cc]ase '([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\(\)' failed")
SUMMARY_LIMIT = 200


def failing_tests(log: Path) -> list[str]:
    """Return the distinct failing test identifiers in log order."""
    found: list[str] = []
    with log.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            for pattern in (OBJC_STYLE, SWIFT_STYLE):
                match = pattern.search(line)
                if match:
                    name = f"{match[1]}/{match[2]}"
                    if name not in found:
                        found.append(name)
    return found


def build(operation: str, log: Path, relative_log: str, failed_legs: list[str]) -> dict[str, object]:
    """Build the diagnostic document for one failed attempt."""
    tests = failing_tests(log)
    summary = ("legs failed: " + " ".join(failed_legs)) if failed_legs else "the local gate failed"
    return {
        "schemaVersion": "1.0.0",
        "proofSchema": "release.diagnostic.v1",
        "operationId": operation,
        "failureKind": "gate-leg-failed",
        "summary": summary[:SUMMARY_LIMIT],
        "detailSha256": hashlib.sha256(log.read_bytes()).hexdigest(),
        "detailPath": relative_log,
        "failingTests": tests[:MAX_TESTS],
        "failingTestsWithheld": max(0, len(tests) - MAX_TESTS),
    }


def write_atomic(destination: Path, document: dict[str, object]) -> None:
    """Replace the destination with the document, readable only by the owner."""
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=destination.parent, prefix=".diagnostic-", delete=False
    ) as handle:
        json.dump(document, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    os.chmod(temporary, 0o600)
    os.replace(temporary, destination)


def main(argv: list[str] | None = None) -> int:
    """Parse arguments and write the diagnostic; exit 4 on an unusable log."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", default="local-gate")
    parser.add_argument("--log", required=True, help="attempt log path relative to the repository root")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--failed-legs", default="", help="space-separated leg ids")
    args = parser.parse_args(argv)
    log = Path(args.log)
    if log.is_absolute() or ".." in log.parts or not log.is_file():
        print("gate-diagnostic: log must be an existing relative path", file=sys.stderr)
        return 4
    write_atomic(args.output, build(args.operation, log, args.log, args.failed_legs.split()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
