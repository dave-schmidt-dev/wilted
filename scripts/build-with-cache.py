#!/usr/bin/env python3
"""Runs every SwiftPM and Xcode build through one shared, gitignored cache.

    python3 scripts/build-with-cache.py path <swiftpm|xcode> <key>
    python3 scripts/build-with-cache.py run <swiftpm|xcode> <key> -- <command> [args...]

`path` prints the cache directory for a key on stdout. `run` injects that
directory into the child build command -- `--scratch-path` directly after the
`swift build|test|run` subcommand, `-derivedDataPath` directly after
`xcodebuild` -- then execs the child, so the child's exit status and signal
death become the helper's own and stdout stays the child's.

The cache lives at `.build/<kind>` under the checkout root resolved
from this file's own location, which the repository `.gitignore` already
covers. Builds of the same kind serialize on an advisory flock whose descriptor
is inherited across the exec, so the lock is held for exactly the child's
lifetime and is released by the child's exit; while another build holds the
lock, a wait heartbeat is emitted at least every 15 seconds. The start line
carrying the cache path goes to stderr.

For installer builds, `--clean-app-product` removes only the Debug WiltedMac.app
inside the Xcode cache lock before building.

The helper owns the cache location, so a child command that already supplies
`--scratch-path`, `--build-path`, or `-derivedDataPath` is rejected, as are
malformed keys, commands that do not match the kind, and missing arguments.
"""

from __future__ import annotations

import fcntl
import os
import re
import shutil
import sys
import time
from collections.abc import Callable
from pathlib import Path

LABEL = "build-with-cache"
USAGE = (
    "usage: build-with-cache.py path <swiftpm|xcode> <key>\n"
    "       build-with-cache.py run <swiftpm|xcode> <key> "
    "[--clean-app-product] -- <command> [args...]"
)
KINDS = ("swiftpm", "xcode")
SWIFT_SUBCOMMANDS = ("build", "test", "run")
CACHE_FLAGS = {"swiftpm": "--scratch-path", "xcode": "-derivedDataPath"}
FORBIDDEN_CACHE_FLAGS = ("--scratch-path", "--build-path", "-derivedDataPath")
KEY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
KEY_MAX_LENGTH = 128
HEARTBEAT_SECONDS = 15.0
LOCK_POLL_SECONDS = 0.2
EXIT_USAGE = 2
EXIT_NOT_EXECUTABLE = 126
EXIT_NOT_FOUND = 127


def emit(message: str) -> None:
    print(f"{LABEL}: {message}", file=sys.stderr)


def checkout_root(script_path: str | Path) -> Path:
    """Return the checkout root that holds *script_path* under scripts/."""
    return Path(script_path).resolve().parents[1]


def cache_paths(root: Path, kind: str, key: str) -> tuple[Path, Path]:
    """Return the cache directory and the advisory-lock path for a key."""
    cache = root / ".build" / kind
    lock = root / ".build" / f"{kind}.lock"
    return cache, lock


def validate_key(key: str) -> None:
    """Reject keys that are not one safe path component."""
    if len(key) > KEY_MAX_LENGTH or not KEY_PATTERN.match(key):
        raise ValueError(
            f"key-invalid: {key!r} must be 1..{KEY_MAX_LENGTH} characters "
            f"matching {KEY_PATTERN.pattern}"
        )


def validate_child(kind: str, child: list[str]) -> None:
    """Reject cache flags the helper owns and commands foreign to the kind."""
    for argument in child:
        for flag in FORBIDDEN_CACHE_FLAGS:
            if argument == flag or argument.startswith(f"{flag}="):
                raise ValueError(f"cache-flag-supplied: {flag} is injected by this helper")
    command = child[0] if child else ""
    expected = "swift" if kind == "swiftpm" else "xcodebuild"
    if command != expected:
        raise ValueError(f"command-mismatch: kind {kind} runs {expected}, not {command!r}")
    if kind == "swiftpm":
        subcommand = child[1] if len(child) > 1 else ""
        if subcommand not in SWIFT_SUBCOMMANDS:
            raise ValueError(
                f"swift-subcommand-invalid: {subcommand!r} must be one of "
                f"{'/'.join(SWIFT_SUBCOMMANDS)}"
            )


def plan_child(kind: str, cache: Path, child: list[str]) -> list[str]:
    """Return the child argv with the kind's cache flag injected."""
    validate_child(kind, child)
    flag = CACHE_FLAGS[kind]
    if kind == "swiftpm":
        return ["swift", child[1], flag, str(cache), *child[2:]]
    return ["xcodebuild", flag, str(cache), *child[1:]]


def ensure_cache(cache: Path) -> None:
    try:
        cache.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise ValueError(f"cache-create-failed: {error}") from error


def acquire_lock(
    lock_path: Path,
    kind: str,
    key: str,
    heartbeat_seconds: float = HEARTBEAT_SECONDS,
    poll_seconds: float = LOCK_POLL_SECONDS,
    report: Callable[[str], None] = emit,
) -> int:
    """Hold the advisory lock for a key, heartbeating while it is contended.

    The returned descriptor is inheritable, so the lock survives the exec
    into the child and is released when the child exits.
    """
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as error:
        raise ValueError(f"lock-open-failed: {error}") from error
    os.set_inheritable(descriptor, True)
    started = time.monotonic()
    last_heartbeat: float | None = None
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            now = time.monotonic()
            if last_heartbeat is None or now - last_heartbeat >= heartbeat_seconds:
                report(
                    f"waiting kind={kind} key={key} lock={lock_path} "
                    f"waited={now - started:.0f}s"
                )
                last_heartbeat = now
            time.sleep(poll_seconds)
        else:
            return descriptor


def parse_arguments(argv: list[str]) -> tuple[str, str, str, bool, list[str]]:
    """Return (action, kind, key, clean product, child argv)."""
    if len(argv) < 3 or argv[0] not in ("path", "run"):
        raise ValueError(USAGE)
    action, kind, key = argv[0], argv[1], argv[2]
    if kind not in KINDS:
        raise ValueError(f"kind-invalid: {kind!r} must be one of {'/'.join(KINDS)}")
    validate_key(key)
    if action == "path":
        if len(argv) != 3:
            raise ValueError(USAGE)
        return action, kind, key, False, []
    rest = argv[3:]
    clean_product = bool(rest and rest[0] == "--clean-app-product")
    if clean_product:
        if kind != "xcode":
            raise ValueError("clean-app-product-requires-xcode")
        rest = rest[1:]
    if not rest or rest[0] != "--":
        raise ValueError("usage: run separates the child command with --")
    child = rest[1:]
    if not child:
        raise ValueError("usage: run needs a command after --")
    return action, kind, key, clean_product, child


def clean_app_product(cache: Path) -> None:
    """Remove only the installer app product while holding the Xcode cache lock."""
    target = cache / "Build/Products/Debug/WiltedMac.app"
    for parent in (cache / "Build", cache / "Build/Products", target.parent):
        if parent.is_symlink():
            raise ValueError(f"clean-app-product-symlink-parent: {parent}")
    try:
        if target.is_symlink():
            target.unlink()
        elif target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            raise ValueError(f"clean-app-product-unexpected-type: {target}")
    except OSError as error:
        raise ValueError(f"clean-app-product-failed: {error}") from error
    emit(f"clean-app-product path={target}")


def main(argv: list[str]) -> int:
    try:
        action, kind, key, clean_product, child = parse_arguments(argv)
        cache, lock = cache_paths(checkout_root(__file__), kind, key)
        if action == "path":
            ensure_cache(cache)
            print(cache)
            return 0
        plan = plan_child(kind, cache, child)
        ensure_cache(cache)
        emit(f"start kind={kind} key={key} cache={cache}")
        acquire_lock(lock, kind, key)
        if clean_product:
            clean_app_product(cache)
        sys.stderr.flush()
        try:
            os.execvp(plan[0], plan)
        except FileNotFoundError:
            emit(f"command-not-found: {plan[0]}")
            return EXIT_NOT_FOUND
        except PermissionError:
            emit(f"command-not-executable: {plan[0]}")
            return EXIT_NOT_EXECUTABLE
    except ValueError as error:
        emit(str(error))
        return EXIT_USAGE
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
