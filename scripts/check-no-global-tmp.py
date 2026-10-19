#!/usr/bin/env python3
"""Reject temporary paths that escape the caller's owned TMPDIR.

Absolute global roots are rejected in scripts and docs. Shell sources must also
anchor every ``mktemp`` template: on macOS ``mktemp -t`` and a template-less
``mktemp`` use ``_CS_DARWIN_USER_TEMP_DIR`` and ignore ``TMPDIR``, so a gate
leg's scratch escaped its owned leg root into the shared per-user temp root,
where a sibling worktree's parent audit counted it as a leak. A top-level
``wilted-*`` root made under ``TMPDIR`` must be a directory marked owned on the
same line, so a concurrent gate's audit attributes it to its live owner.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = ("/" + "tmp", "/private/" + "tmp")
SCRIPT_SUFFIXES = {".sh", ".py"}
DOC_SUFFIXES = {".md", ".html"}
# A mktemp in command position: its flags, then an optional template word.
MKTEMP = re.compile(
    r"""(?:^|[;&|({]|\$\()\s*mktemp\b((?:\s+-[A-Za-z]+)*)(?:\s+("[^"]*"|'[^']*'|[^\s;&|)]+))?"""
)
TMPDIR_WILTED_ROOT = re.compile(r"""^["']?\$\{?TMPDIR\b[^/]*/wilted-""")


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


def shell_source(relative: Path) -> bool:
    """Return whether *relative* is a shell source whose mktemp calls are checked."""
    return relative.suffix == ".sh" or relative.name in {"Makefile", "makefile"}


def mktemp_findings(line: str) -> list[str]:
    """Return why each mktemp call on a shell *line* escapes or hides its owner."""
    if line.lstrip().startswith("#"):
        return []
    findings = []
    for match in MKTEMP.finditer(line):
        flags, template = match.group(1).replace("-", ""), match.group(2)
        if "t" in flags:
            findings.append("mktemp -t ignores TMPDIR on macOS; anchor the template in TMPDIR")
        elif template is None:
            findings.append("template-less mktemp ignores TMPDIR on macOS; anchor the template in TMPDIR")
        elif TMPDIR_WILTED_ROOT.match(template) and ("d" not in flags or "wilted_temp_mark_owned" not in line):
            findings.append("a top-level wilted-* temp root must be a directory marked by wilted_temp_mark_owned on the same line")
    return findings


def violations(relative: Path, contents: str) -> list[str]:
    """Return source locations that point at a global temp root or escape TMPDIR."""
    findings = []
    for number, line in enumerate(contents.splitlines(), 1):
        # Embedded image bytes in archived HTML are data, not an instruction.
        text = re.sub(r'data:image/[^"\s]+', 'data:image/embedded', line)
        if any(path in text for path in FORBIDDEN):
            findings.append(f"{relative}:{number}: absolute global temp path")
        if shell_source(relative):
            findings.extend(f"{relative}:{number}: {reason}" for reason in mktemp_findings(text))
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
