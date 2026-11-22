#!/usr/bin/env python3
"""Report host state and refuse overlapping hosted XCTest runs."""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


HOSTED_LEGS = {
    "macos-unit-tests",
    "ios-unit-tests",
    "macos-ui-tests",
    "ios-pixel-snapshot-tests",
    "watchos-build",
}
REFUSED = 2


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    elapsed: str
    command: str


def _run(command: list[str], timeout: float = 2.0) -> str | None:
    """Return bounded command output, or None when the command is unavailable."""
    try:
        result = subprocess.run(
            command, check=False, capture_output=True, text=True, timeout=timeout
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _tool(name: str, default: str) -> str:
    return os.environ.get(f"WILTED_HOST_STATE_{name}", default)


def _automation_state() -> str:
    output = _run([_tool("AUTOMATION_TOOL", "/usr/bin/automationmodetool")])
    if output is None:
        return "unknown"
    normalized = output.lower()
    if "automation mode is enabled" in normalized:
        return "enabled"
    if "automation mode is disabled" in normalized:
        return "disabled"
    return "unknown"


def _processes() -> list[Process] | None:
    output = _run(
        [_tool("PS", "/bin/ps"), "-axo", "pid=,ppid=,state=,etime=,command="]
    )
    if output is None:
        return None
    processes: list[Process] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5 or "Z" in fields[2]:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        processes.append(Process(pid, ppid, fields[3], fields[4]))
    return processes


def _argv(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return []


def _is_xcodebuild(process: Process) -> bool:
    args = _argv(process.command)
    return bool(args) and Path(args[0]).name == "xcodebuild"


def _is_hosted_xcodebuild(process: Process) -> bool:
    args = _argv(process.command)
    if not args or Path(args[0]).name != "xcodebuild":
        return False
    return any(arg in {"test", "test-without-building"} for arg in args[1:])


def _belongs_to_gate(process: Process, root_pid: int, parents: dict[int, int]) -> bool:
    seen: set[int] = set()
    pid = process.pid
    while pid and pid not in seen:
        if pid == root_pid:
            return True
        seen.add(pid)
        pid = parents.get(pid, 0)
    return False


def _elapsed_seconds(value: str) -> int | None:
    match = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", value)
    if match is None:
        return None
    days, hours, minutes, seconds = (int(part or 0) for part in match.groups())
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def _testmanagerd(processes: list[Process] | None) -> list[Process]:
    if processes is None:
        return []
    return [
        process
        for process in processes
        if Path((_argv(process.command) or [""])[0]).name == "testmanagerd"
    ]


def _sample_touch_id_prompt(processes: list[Process] | None) -> bool | None:
    """Sample testmanagerd briefly, returning None when evidence is unavailable."""
    daemons = _testmanagerd(processes)
    if not daemons:
        return False if processes is not None else None
    temp_root = os.environ.get("TMPDIR")
    if not temp_root or not Path(temp_root).is_dir():
        return None

    deadline = time.monotonic() + 4.5
    unknown = False
    try:
        with tempfile.TemporaryDirectory(prefix="wilted-host-state-", dir=temp_root) as scratch:
            sample_path = _tool("SAMPLE", "/usr/bin/sample")
            for daemon in daemons:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                output_path = Path(scratch) / f"{daemon.pid}.sample"
                try:
                    result = subprocess.run(
                        [sample_path, str(daemon.pid), "1", "-file", str(output_path)],
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=min(4.0, remaining),
                    )
                except (OSError, subprocess.TimeoutExpired):
                    unknown = True
                    continue
                if result.returncode != 0 or not output_path.is_file():
                    unknown = True
                    continue
                stack = output_path.read_text(encoding="utf-8", errors="replace")
                if "XAMLocalAuthenticationProvider" in stack and "LAContext evaluatePolicy" in stack:
                    return True
    except OSError:
        return None
    return None if unknown else False


def _load_average() -> str:
    output = _run([_tool("SYSCTL", "/usr/sbin/sysctl"), "vm.loadavg"])
    if output is None:
        return "unknown"
    match = re.search(r"\{\s*([^}]+)\s*\}", output)
    if match is None:
        return "unknown"
    values = " ".join(match.group(1).split())
    return values if re.fullmatch(r"[0-9. ]+", values) else "unknown"


def inspect(leg: str, root_pid: int) -> tuple[str, list[str]]:
    """Return the single host-state line and reasons that refuse this leg."""
    if leg not in HOSTED_LEGS:
        return "", []

    automation = _automation_state()
    processes = _processes()
    parents = {process.pid: process.ppid for process in processes or []}
    external_xcodebuilds = [
        process
        for process in processes or []
        if _is_xcodebuild(process) and not _belongs_to_gate(process, root_pid, parents)
    ]
    hosted_runs = [process for process in external_xcodebuilds if _is_hosted_xcodebuild(process)]
    daemons = _testmanagerd(processes)
    daemon_ages = [_elapsed_seconds(process.elapsed) for process in daemons]
    known_ages = [age for age in daemon_ages if age is not None]
    daemon_age = str(max(known_ages)) if known_ages else ("unknown" if daemons or processes is None else "absent")
    load = _load_average()
    prompt = _sample_touch_id_prompt(processes)
    prompt_state = "unknown" if prompt is None else "pending" if prompt else "clear"
    line = (
        "native.host-state "
        f"automation={automation} "
        f"xcodebuild_other={len(external_xcodebuilds) if processes is not None else 'unknown'} "
        f"testmanagerd_age_seconds={daemon_age} "
        f"loadavg={load} "
        f"touchid_prompt={prompt_state}"
    )
    reasons: list[str] = []
    if prompt:
        reasons.append("automation-touch-id-prompt")
    if hosted_runs:
        reasons.append("another-hosted-run")
    return line, reasons


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: host-state.py <leg> <gate-root-pid>", file=sys.stderr)
        return 2
    try:
        root_pid = int(argv[2])
    except ValueError:
        print("host-state: invalid gate PID", file=sys.stderr)
        return 2

    line, reasons = inspect(argv[1], root_pid)
    if not line:
        return 0
    print(line, file=sys.stderr)
    if reasons:
        print(f"native.environment.refused reason={','.join(reasons)}", file=sys.stderr)
        return REFUSED
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
