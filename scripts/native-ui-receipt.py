#!/usr/bin/env python3
"""Bind a green native UI gate to a clean commit and check it before an install."""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parent.parent
RECEIPT = ROOT / ".logs" / "native-ui-receipt.json"
FILTER_ENV = "WILTED_GATE_LEGS"
SKIP_ENV = "WILTED_SKIP_UI_RECEIPT"
SURFACE = ROOT / "scripts" / "mac-ui-surface.paths"
EXPECTED_LEGS = (
    "xcodegen-reproducible",
    "wiltedkit-tests",
    "cloudsync-tests",
    "listener-tests",
    "wiltedproducer-tests",
    "macos-unit-tests",
    "ios-unit-tests",
    "macos-ui-tests",
    "ios-pixel-snapshot-tests",
)
COMMIT_OID = re.compile(r"^[0-9a-f]{40,64}$")
TEST_LINE = re.compile(r"^native\.tests label=([^ ]+) reported=([0-9]+)(?: |$)")
LEG_LINE = re.compile(r"^native\.leg\.complete name=([^ ]+) status=([0-9]+)$")
COMPLETE_LINE = re.compile(
    r"^native\.complete failed_legs=([0-9]+) total_legs=([0-9]+) deferred_legs=([0-9]+)$"
)
PASSED_LINE = re.compile(r"^native\.passed count=([0-9]+)$")


def status(message: str) -> None:
    """Emit gate progress on stderr without contaminating Git's ref input."""
    print(f"native.receipt.{message}", file=sys.stderr, flush=True)


def git(*args: str, input_data: bytes | None = None) -> bytes:
    """Run Git in the repository, raising on an unusable comparison."""
    result = subprocess.run(
        ["git", *args], cwd=ROOT, input=input_data, capture_output=True, check=True
    )
    return result.stdout.strip()


def clean_commit() -> tuple[str, str]:
    """Return commit identity only when every tracked and untracked path is clean."""
    if git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("working tree is dirty; commit changes before make native-ui")
    commit = git("rev-parse", "HEAD").decode()
    describe = git("describe", "--always", "--dirty").decode()
    if not COMMIT_OID.fullmatch(commit) or describe.endswith("-dirty"):
        raise ValueError("native UI result has no clean commit identity")
    return commit, describe


def read_surface() -> list[str]:
    """Read the single commented path list the install comparison uses."""
    paths = [
        line.strip()
        for line in SURFACE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not paths or any(path.startswith("/") or ".." in Path(path).parts for path in paths):
        raise ValueError("Mac UI surface list is empty or unsafe")
    return paths


def green_counts(lines: list[str]) -> dict[str, int]:
    """Require the full gate's zero-failure, zero-deferral terminal evidence."""
    reported: dict[str, int] = {}
    completed: dict[str, int] = {}
    terminal: tuple[int, int, int] | None = None
    passed: int | None = None
    for line in lines:
        if match := TEST_LINE.match(line):
            reported[match[1]] = int(match[2])
        if match := LEG_LINE.match(line):
            completed[match[1]] = int(match[2])
        if match := COMPLETE_LINE.match(line):
            terminal = tuple(int(value) for value in match.groups())
        if match := PASSED_LINE.match(line):
            passed = int(match[1])
    if terminal != (0, len(EXPECTED_LEGS), 0) or passed != len(EXPECTED_LEGS):
        raise ValueError("full native gate did not finish with zero failed and deferred legs")
    if set(completed) != set(EXPECTED_LEGS) or any(completed.values()):
        raise ValueError("full native gate has missing or failed leg evidence")
    if set(reported) != set(EXPECTED_LEGS) - {"xcodegen-reproducible"}:
        raise ValueError("full native gate has missing per-leg test counts")
    if any(count <= 0 for count in reported.values()):
        raise ValueError("full native gate reported zero tests in a test leg")
    return {leg: reported.get(leg, 0) for leg in EXPECTED_LEGS}


def heartbeat(stop: threading.Event) -> None:
    """Keep long silent native legs visible on the active terminal."""
    started = time.monotonic()
    while not stop.wait(30):
        status(f"wait elapsed_seconds={int(time.monotonic() - started)}")


def record() -> int:
    """Run the screen-seizing gate once and atomically mint its receipt."""
    if FILTER_ENV in os.environ:
        status(f"refused reason=filtered-gate detail={FILTER_ENV}-is-set action=\"unset it and run make native-ui\"")
        return 1
    before_commit, before_describe = clean_commit()
    status(f"start commit={before_commit} gate=make-native-ui")
    stop = threading.Event()
    monitor = threading.Thread(target=heartbeat, args=(stop,), daemon=True)
    monitor.start()
    lines: list[str] = []
    try:
        with subprocess.Popen(
            ["bash", str(ROOT / "scripts" / "test-gate.sh")],
            cwd=ROOT,
            env={**os.environ, "WILTED_MAC_UI": "1"},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        ) as process:
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                if line.startswith("native."):
                    lines.append(line.rstrip("\n"))
            gate_status = process.wait()
    finally:
        stop.set()
        monitor.join(timeout=1)
    if gate_status:
        status(f"refused reason=gate-exit status={gate_status}")
        return gate_status
    counts = green_counts(lines)
    after_commit, after_describe = clean_commit()
    if (after_commit, after_describe) != (before_commit, before_describe):
        raise ValueError("commit changed during native UI gate; receipt refused")
    receipt = {
        "schemaVersion": 1,
        "commit": before_commit,
        "describe": before_describe,
        "createdAt": dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z"),
        "testCounts": counts,
    }
    RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=RECEIPT.parent, prefix=".native-ui-receipt-", delete=False
    ) as temporary:
        json.dump(receipt, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, RECEIPT)
    status(f"minted commit={before_commit} legs={len(counts)} path={RECEIPT}")
    return 0


def receipt_commit() -> str | None:
    """Return the last usable receipt commit, or None for a missing receipt."""
    try:
        commit = json.loads(RECEIPT.read_text(encoding="utf-8"))["commit"]
        if not isinstance(commit, str) or not COMMIT_OID.fullmatch(commit):
            raise ValueError("invalid receipt commit")
        git("cat-file", "-e", f"{commit}^{{commit}}")
        return commit
    except (FileNotFoundError, KeyError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError):
        return None


def surface_changes(base: str) -> list[str]:
    """Mac UI surface paths that differ between the receipt commit and the working tree."""
    surface = read_surface()
    tracked = git("diff", "--name-only", "-z", base, "--", *surface)
    untracked = git("ls-files", "--others", "--exclude-standard", "-z", "--", *surface)
    return sorted({p.decode("utf-8", "replace") for p in (tracked + b"\0" + untracked).split(b"\0") if p})


def check_head() -> int:
    """Refuse an install whose Mac UI surface has no green receipt behind it.

    The tree being installed is compared with the receipt commit, so staged,
    unstaged and untracked surface changes count as well as new commits.
    WILTED_SKIP_UI_RECEIPT=1 proceeds with a loud warning instead.
    """
    receipt = receipt_commit()
    if os.environ.get(SKIP_ENV) == "1":
        status(f"WARNING skipped=true reason={SKIP_ENV}=1 receipt={receipt or 'none'} detail=\"installing a Mac UI surface no green make native-ui covers\"")
        return 0
    if receipt is None:
        status('block reason=missing-receipt action="make native-ui"')
        return 1
    try:
        changed = surface_changes(receipt)
    except subprocess.CalledProcessError:
        status('block reason=unusable-baseline action="make native-ui"')
        return 1
    if changed:
        status(f'block changed={changed[0]} count={len(changed)} reason=stale-receipt receipt={receipt} action="make native-ui"')
        return 1
    status(f"pass receipt={receipt} reason=surface-unchanged")
    return 0


def main() -> int:
    """Dispatch the receipt writer or the install-time verifier."""
    if len(sys.argv) != 2 or sys.argv[1] not in {"record", "check-head"}:
        print("usage: native-ui-receipt.py record|check-head", file=sys.stderr)
        return 2
    try:
        return record() if sys.argv[1] == "record" else check_head()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        status(f'error detail="{error}" action="make native-ui"')
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
