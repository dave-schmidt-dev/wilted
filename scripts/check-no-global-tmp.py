#!/usr/bin/env python3
"""Reject absolute global temporary paths in operational scripts and docs."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = ("/" + "tmp", "/private/" + "tmp")
SCRIPT_SUFFIXES = {".sh", ".py"}
DOC_SUFFIXES = {".md", ".html"}


def selected(relative: Path) -> bool:
    """Select scripts, production Python, Makefiles, and active docs."""
    if relative.name in {"HISTORY.md", "TASKS.md"}:
        return False
    if relative.name in {"Makefile", "makefile"}:
        return True
    if relative.suffix in DOC_SUFFIXES:
        return True
    if relative.suffix == ".sh":
        return True
    if relative.suffix == ".py":
        return "tests" not in relative.parts and not relative.name.startswith("test_")
    return False


def violations(relative: Path, contents: str) -> list[str]:
    """Return source locations that point at an absolute global temp root."""
    findings = []
    for number, line in enumerate(contents.splitlines(), 1):
        # Embedded image bytes in archived HTML are data, not an instruction.
        text = re.sub(r'data:image/[^"\s]+', 'data:image/embedded', line)
        if any(path in text for path in FORBIDDEN):
            findings.append(f"{relative}:{number}: absolute global temp path")
    return findings


def main() -> int:
    output = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT
    )
    findings: list[str] = []
    for name in output.decode().split("\0"):
        if not name:
            continue
        relative = Path(name)
        if not selected(relative):
            continue
        path = ROOT / relative
        if not path.is_file():
            continue
        try:
            contents = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        findings.extend(violations(relative, contents))
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        print(f"no-global-tmp: failed count={len(findings)}", file=sys.stderr)
        return 1
    print("no-global-tmp: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
