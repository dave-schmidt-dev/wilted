#!/usr/bin/env python3
"""Check that every app logger can be found with the one documented log query.

Every `Logger(subsystem:category:)` in shipped Swift sources must name a Wilted
subsystem as a string literal and a PascalCase category, and every `log show`
predicate written in a source comment must start from the shared subsystem
prefix, so one query reaches the Mac, iOS, Watch and shared-package lines.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

PREFIX = "com.zerodelta.wilted"
SUBSYSTEMS = {PREFIX, f"{PREFIX}.mac", f"{PREFIX}.watch"}
DECLARATION = re.compile(r'Logger\(subsystem: "([^"]*)", category: "([^"]*)"\)')
CATEGORY = re.compile(r"[A-Z][A-Za-z]*\Z")
QUERY = re.compile(r"log (?:show|stream) --predicate '([^']*)'")


def selected(path: Path) -> bool:
    """Shipped Swift sources only; test targets may log however they like."""
    return path.suffix == ".swift" and not any(part.endswith(("Tests", "UITests")) for part in path.parts)


def violations(path: Path, text: str) -> list[str]:
    """Return one message per logger or documented query that breaks the convention."""
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        where = f"{path}:{number}"
        if "Logger(subsystem:" in line:
            match = DECLARATION.search(line)
            if match is None:
                found.append(f"{where}: logger subsystem and category must be string literals on one line")
                continue
            subsystem, category = match.groups()
            if subsystem not in SUBSYSTEMS:
                found.append(f"{where}: subsystem {subsystem!r} is not one of {sorted(SUBSYSTEMS)}")
            if not CATEGORY.match(category):
                found.append(f"{where}: category {category!r} is not PascalCase")
        for query in QUERY.findall(line):
            if f'subsystem BEGINSWITH "{PREFIX}"' not in query:
                found.append(f"{where}: documented log query must use subsystem BEGINSWITH \"{PREFIX}\"")
    return found


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", "*.swift"],
        check=True, capture_output=True, text=True,
    ).stdout.split("\0")
    found = []
    for name in filter(None, listed):
        path = Path(name)
        if selected(path):
            found += violations(path, (root / path).read_text(encoding="utf-8"))
    for message in found:
        print(f"log-conventions: {message}", file=sys.stderr)
    if found:
        return 1
    print("log-conventions: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
