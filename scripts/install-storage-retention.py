#!/usr/bin/env python3
"""Render or install the weekly Wilted storage-retention LaunchAgent."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LABEL = "com.wilted.storage-retention"
WEEK_SECONDS = 7 * 24 * 60 * 60


def plist(repo: Path) -> dict[str, object]:
    """Build the fixed, weekly user LaunchAgent configuration."""
    script = (repo / "scripts" / "run-storage-retention.sh").resolve()
    return {
        "Label": LABEL,
        "ProgramArguments": ["/bin/bash", str(script), "--apply"],
        "RunAtLoad": True,
        "StartInterval": WEEK_SECONDS,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
        "ProcessType": "Background",
        "AbandonProcessGroup": True,
    }


def _atomic_write(target: Path, data: bytes) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink():
        raise OSError("refusing symlink LaunchAgent target")
    descriptor, temporary_name = tempfile.mkstemp(prefix="." + target.name + ".", suffix=".partial", dir=str(target.parent))
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(str(temporary), 0o644)
        os.replace(str(temporary), str(target))
        directory = os.open(str(target.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def _run_launchctl(executable: str, args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run([executable] + args, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=15, check=False)


def _activate(executable: str, target: Path) -> None:
    """Load this exact plist in the current GUI domain and request one run."""
    domain = "gui/{}".format(os.getuid())
    service = domain + "/" + LABEL
    current = _run_launchctl(executable, ["print", service])
    if current.returncode == 0:
        unloaded = _run_launchctl(executable, ["bootout", domain, str(target)])
        if unloaded.returncode != 0:
            raise RuntimeError("launchctl could not unload the existing agent")
    enabled = _run_launchctl(executable, ["enable", service])
    if enabled.returncode != 0:
        raise RuntimeError("launchctl enable failed")
    loaded = _run_launchctl(executable, ["bootstrap", domain, str(target)])
    if loaded.returncode != 0:
        raise RuntimeError("launchctl bootstrap failed; agent remains unloaded")
    kicked = _run_launchctl(executable, ["kickstart", "-k", service])
    if kicked.returncode != 0:
        raise RuntimeError("launchctl kickstart failed")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="install the LaunchAgent plist")
    mode.add_argument("--dry-run", action="store_true", help="print plist without installing")
    parser.add_argument("--activate", action="store_true", help="load agent and request an immediate run")
    parser.add_argument("--output", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--launchctl", default="/bin/launchctl", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.activate and not args.apply:
        parser.error("--activate requires --apply")
    repo = args.repo.expanduser().resolve()
    if not repo.is_dir():
        parser.error("--repo must name an existing directory")
    target = args.output or (Path.home() / "Library" / "LaunchAgents" / (LABEL + ".plist"))
    data = plistlib.dumps(plist(repo), sort_keys=False)
    if args.apply:
        try:
            _atomic_write(target.expanduser(), data)
            print("retention-install.ok plist={}".format(target.expanduser()))
            if args.activate:
                _activate(args.launchctl, target.expanduser())
                print("retention-install.ok activated={}".format(LABEL))
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            print("retention-install.error {}".format(error), file=sys.stderr)
            return 2
    else:
        sys.stdout.write(data.decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
