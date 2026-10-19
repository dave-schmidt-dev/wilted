#!/usr/bin/env python3
"""Runs SwiftPM and Xcode commands through stable, locked project caches.

    python3 scripts/build-with-cache.py path <swiftpm|xcode> <key>
    python3 scripts/build-with-cache.py run <swiftpm|xcode> <key> -- <command> [args...]
    python3 scripts/build-with-cache.py run-tests swiftpm <key> -- xcrun xctest <bundle>

`path` prints the cache directory for a key on stdout. `run` injects that
directory into the child build command -- `--scratch-path` directly after the
`swift build|test|run` subcommand, `-derivedDataPath` directly after
`xcodebuild` -- then supervises the child, so the child's exit status and
signal death become the helper's own and stdout stays the child's.

`run swiftpm` and `run xcode` both supervise the child so it can survive File
Provider tagging under ~/Documents: they clear extended attributes before the
build and, when a failed build reports codesign's "resource fork, Finder
information, or similar detritus", clear again and retry exactly once within
the remaining budget (`native.xattr.retry`). SwiftPM clears the whole cache;
Xcode clears only `<cache>/Build`, since the installer/recorder cache is
`<cache>` itself and other native keys' DerivedData lives beside it under
different locks. Child stdout and stderr are relayed live to the helper's own
streams, INT/TERM/HUP are forwarded, and the child's exit status or signal
death still becomes the helper's own. The streams are pipes, so interactive TTY
progress and color are not preserved; the supervisor's periodic status remains
visible. Raw `swift` or `xcodebuild` calls outside this helper get no detritus
protection.

Every build command is supervised by ``run-bounded.py``.  Its default 300s
work budget can be changed with ``WILTED_TEST_TIMEOUT_SECONDS``. Lock waits
are unbounded with heartbeats unless explicitly bounded for a diagnostic by
``WILTED_BUILD_LOCK_TIMEOUT_SECONDS``; work timing starts after acquisition.

SwiftPM caches live at `.build/swiftpm/<key>`, native Xcode DerivedData at
`.build/xcode/<native-key>`, and installer products at `.build/xcode`, under
the checkout root resolved from this file. The
repository `.gitignore` covers the whole tree. SwiftPM builds sharing a stable
package key serialize; each native Xcode key and the shared installer cache
have separate advisory locks whose descriptor
is inherited across the exec, so the lock is held for exactly the child's
lifetime and is released by the child's exit; while another build holds the
lock, a wait heartbeat is emitted at least every 15 seconds. The start line
carrying the cache path goes to stderr.

For installer builds, `--clean-app-product` removes only the Debug and Development
WiltedMac.app inside the Xcode cache lock before building.

The helper owns the cache location, so a child command that already supplies
`--scratch-path`, `--build-path`, or `-derivedDataPath` is rejected, as are
malformed keys, commands that do not match the kind, and missing arguments.
"""

from __future__ import annotations

import fcntl
import math
import os
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

LABEL = "build-with-cache"
USAGE = (
    "usage: build-with-cache.py path <swiftpm|xcode> <key>\n"
    "       build-with-cache.py run <swiftpm|xcode> <key> "
    "[--clean-app-product] -- <command> [args...]\n"
    "       build-with-cache.py run-tests swiftpm <key> -- xcrun xctest <bundle>"
)
KINDS = ("swiftpm", "xcode")
SWIFT_SUBCOMMANDS = ("build", "test", "run")
CACHE_FLAGS = {"swiftpm": "--scratch-path", "xcode": "-derivedDataPath"}
FORBIDDEN_CACHE_FLAGS = ("--scratch-path", "--build-path", "-derivedDataPath")
KEY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
KEY_MAX_LENGTH = 128
HEARTBEAT_SECONDS = 15.0
LOCK_POLL_SECONDS = 0.2
DEFAULT_TIMEOUT_SECONDS = 300.0
DEFAULT_LOCK_TIMEOUT_SECONDS = 300.0
EXIT_USAGE = 2
EXIT_NOT_EXECUTABLE = 126
EXIT_NOT_FOUND = 127
DETRITUS_MARKER = b"resource fork, Finder information, or similar detritus"


def emit(message: str) -> None:
    print(f"{LABEL}: {message}", file=sys.stderr)


def checkout_root(script_path: str | Path) -> Path:
    """Return the checkout root that holds *script_path* under scripts/."""
    return Path(script_path).resolve().parents[1]


def cache_paths(root: Path, kind: str, key: str) -> tuple[Path, Path]:
    """Return the cache directory and the advisory-lock path for a key."""
    if kind == "swiftpm":
        cache = root / ".build" / "swiftpm" / key
        lock = root / ".build" / "swiftpm" / ".locks" / f"{key}.lock"
    else:
        # Native legs own separate products; installers retain their shared cache.
        if key.startswith("native-"):
            cache = root / ".build" / "xcode" / key
            lock = root / ".build" / "xcode-locks" / f"{key}.lock"
        else:
            cache = root / ".build" / "xcode"
            lock = root / ".build" / "xcode.lock"
    return cache, lock


def xattr_clear_root(kind: str, cache: Path) -> Path:
    """Return the subtree whose extended attributes a build kind clears."""
    return cache / "Build" if kind == "xcode" else cache


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
    timeout_seconds: float | None = None,
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
            if timeout_seconds is not None and now - started >= timeout_seconds:
                os.close(descriptor)
                raise ValueError(f"lock-timeout: kind={kind} key={key} waited={now - started:.0f}s")
            if last_heartbeat is None or now - last_heartbeat >= heartbeat_seconds:
                report(
                    f"waiting kind={kind} key={key} lock={lock_path} "
                    f"waited={now - started:.0f}s"
                )
                last_heartbeat = now
            time.sleep(poll_seconds)
        else:
            return descriptor


def environment_timeout(name: str, default: float) -> float:
    """Read one finite positive timeout from the environment."""
    raw = os.environ.get(name, str(default))
    try:
        value = float(raw)
    except ValueError as error:
        raise ValueError(f"{name.lower()}-invalid") from error
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name.lower()}-invalid")
    return value


def parse_arguments(argv: list[str]) -> tuple[str, str, str, bool, list[str]]:
    """Return (action, kind, key, clean product, child argv)."""
    if len(argv) < 3 or argv[0] not in ("path", "run", "run-tests"):
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
        raise ValueError(f"usage: {action} separates the child command with --")
    child = rest[1:]
    if not child:
        raise ValueError(f"usage: {action} needs a command after --")
    return action, kind, key, clean_product, child


INSTALLER_APP_CONFIGURATIONS = ("Debug", "Development")


def clean_app_product(cache: Path) -> None:
    """Remove only the installer app products while holding the Xcode cache lock.

    The installer builds Development; Debug is cleaned too so a product left by an
    earlier installer cannot carry stale Finder metadata into a later signing pass.
    """
    for configuration in INSTALLER_APP_CONFIGURATIONS:
        target = cache / "Build/Products" / configuration / "WiltedMac.app"
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


def clear_xattrs_if_present(
    cache: Path, reason: str, runner: Path, deadline: float,
    lock_descriptor: int, pending: list[int],
    current: list[subprocess.Popen[bytes]],
) -> int:
    """Skip xattr cleanup when the clear root is absent."""
    if not cache.exists():
        emit(f"native.xattr.clear skipped reason={reason} path={cache} absent")
        return 0
    return clear_xattrs(
        cache, reason, runner, deadline, lock_descriptor, pending, current
    )


def clear_xattrs(cache: Path, reason: str, runner: Path, deadline: float,
                 lock_descriptor: int, pending: list[int],
                 current: list[subprocess.Popen[bytes]]) -> int:
    """Strip extended attributes (File Provider FinderInfo) from the cache tree.

    A failure is reported and tolerated: some attributes refuse removal and the
    build itself remains the authority on whether signing succeeds. Cleanup is
    supervised within the same work deadline as the build and retries.
    """
    started = time.monotonic()
    emit(f"native.xattr.clear start reason={reason} path={cache}")
    sys.stderr.flush()
    budget = deadline - started
    if budget <= 0:
        emit(f"native.xattr.clear skipped reason={reason} budget=exhausted")
        return 124

    previous_phase = os.environ.get("WILTED_WORK_PHASE")
    previous_heartbeat = os.environ.get("WILTED_BOUNDED_HEARTBEAT_SECONDS")
    os.environ["WILTED_WORK_PHASE"] = "native-xattr-cleanup"
    os.environ["WILTED_BOUNDED_HEARTBEAT_SECONDS"] = str(HEARTBEAT_SECONDS)
    try:
        returncode, _ = relay_attempt(
            [sys.executable, str(runner), "--timeout-seconds", f"{budget:g}", "--",
             "/usr/bin/xattr", "-crs", str(cache)],
            lock_descriptor, pending, current,
        )
    except (OSError, subprocess.SubprocessError) as error:
        returncode = 127
        status = f"warning={error!r}"
    else:
        status = f"status={returncode}"
        if returncode not in (0, 124):
            status += " warning=cleanup failed; build remains authoritative"
    finally:
        if previous_phase is None:
            os.environ.pop("WILTED_WORK_PHASE", None)
        else:
            os.environ["WILTED_WORK_PHASE"] = previous_phase
        if previous_heartbeat is None:
            os.environ.pop("WILTED_BOUNDED_HEARTBEAT_SECONDS", None)
        else:
            os.environ["WILTED_BOUNDED_HEARTBEAT_SECONDS"] = previous_heartbeat
    emit(
        f"native.xattr.clear done reason={reason} "
        f"elapsed={time.monotonic() - started:.1f}s {status}"
    )
    return returncode


def relay_attempt(argv: list[str], lock_descriptor: int, pending: list[int],
                  current: list[subprocess.Popen[bytes]]) -> tuple[int, bool]:
    """Run one supervised attempt, relaying its output live.

    Returns (returncode, saw detritus marker). The lock descriptor is passed so
    the runner holds the cache lock even if this parent dies first.
    """
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             pass_fds=(lock_descriptor,))
    current[:] = [child]
    if pending:
        child.send_signal(pending[-1])
    sinks = {child.stdout.fileno(): sys.stdout.buffer, child.stderr.fileno(): sys.stderr.buffer}
    tails = dict.fromkeys(sinks, b"")
    keep = len(DETRITUS_MARKER) - 1
    seen = False
    broken_sinks: set[int] = set()
    try:
        with selectors.DefaultSelector() as selector:
            for descriptor in sinks:
                selector.register(descriptor, selectors.EVENT_READ)
            while selector.get_map():
                for key, _ in selector.select():
                    descriptor = key.fd
                    chunk = os.read(descriptor, 65536)
                    if not chunk:
                        selector.unregister(descriptor)
                        continue
                    sink = sinks[descriptor]
                    if descriptor not in broken_sinks:
                        try:
                            sink.write(chunk)
                            sink.flush()
                        except BrokenPipeError:
                            # Keep draining the runner so it cannot block or outlive us.
                            broken_sinks.add(descriptor)
                            try:
                                null_fd = os.open(os.devnull, os.O_WRONLY)
                                try:
                                    os.dup2(null_fd, sink.fileno())
                                finally:
                                    os.close(null_fd)
                            except (AttributeError, OSError):
                                pass
                    window = tails[descriptor] + chunk
                    seen = seen or DETRITUS_MARKER in window
                    tails[descriptor] = window[-keep:]
        returncode = child.wait()
        return returncode, seen
    except BaseException:
        if child.poll() is None:
            try:
                child.kill()
            except ProcessLookupError:
                pass
        child.wait()
        raise
    finally:
        child.stdout.close()
        child.stderr.close()
        current.clear()


def run_swiftpm_with_retry(runner: Path, plan: list[str], cache: Path,
                           command_timeout: float, lock_descriptor: int) -> int:
    """Build either kind under the runner, retrying once after detritus."""
    deadline = time.monotonic() + command_timeout
    pending: list[int] = []
    current: list[subprocess.Popen[bytes]] = []

    def forward(signum: int, _frame: object) -> None:
        pending.append(signum)
        for child in current:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass

    for managed in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        # An ignored disposition (Bash background INT) stays ignored, as under exec.
        if signal.getsignal(managed) is not signal.SIG_IGN:
            signal.signal(managed, forward)
    cleanup_status = clear_xattrs_if_present(
        cache, "pre-build", runner, deadline, lock_descriptor, pending, current
    )
    budget = deadline - time.monotonic()
    if pending:
        returncode = -pending[0]
    elif cleanup_status in (124, 125):
        returncode = cleanup_status
    elif budget <= 0:
        emit("native.xattr.budget-exhausted phase=pre-build")
        returncode = 124
    else:
        attempt = 1
        while True:
            budget = deadline - time.monotonic()
            if budget <= 0:
                emit("native.xattr.budget-exhausted phase=detritus")
                returncode = 124
                break
            argv = [sys.executable, str(runner), "--timeout-seconds", f"{budget:g}", "--", *plan]
            sys.stderr.flush()
            returncode, detritus = relay_attempt(argv, lock_descriptor, pending, current)
            budget = deadline - time.monotonic()
            if pending:
                returncode = -pending[0]
                break
            if attempt > 1 or returncode == 0 or not detritus:
                break
            if budget <= 0:
                returncode = 124
                break
            cleanup_status = clear_xattrs_if_present(
                cache, "detritus", runner, deadline, lock_descriptor, pending, current
            )
            budget = deadline - time.monotonic()
            if pending:
                returncode = -pending[0]
                break
            if cleanup_status in (124, 125):
                returncode = cleanup_status
                break
            if budget <= 0:
                returncode = 124
                break
            emit(f"native.xattr.retry attempt=2 previous-status={returncode} budget={budget:.0f}s")
            attempt += 1
    if returncode < 0:
        signum = -returncode
        if pending:
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
            return -signum
        return 128 + signum
    return returncode


def main(argv: list[str]) -> int:
    try:
        action, kind, key, clean_product, child = parse_arguments(argv)
        cache, lock = cache_paths(checkout_root(__file__), kind, key)
        if action == "path":
            ensure_cache(cache)
            print(cache)
            return 0
        if action == "run-tests":
            if (kind != "swiftpm" or child[:2] != ["xcrun", "xctest"] or len(child) != 3
                    or child[2].startswith("-") or not child[2].endswith(".xctest")):
                raise ValueError("run-tests requires one SwiftPM XCTest bundle")
            plan = child
        else:
            plan = plan_child(kind, cache, child)
        ensure_cache(cache)
        emit(f"start kind={kind} key={key} cache={cache}")
        lock_timeout = (environment_timeout("WILTED_BUILD_LOCK_TIMEOUT_SECONDS", DEFAULT_LOCK_TIMEOUT_SECONDS)
                        if "WILTED_BUILD_LOCK_TIMEOUT_SECONDS" in os.environ else None)
        command_timeout = environment_timeout(
            "WILTED_TEST_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS
        )
        lock_descriptor = acquire_lock(lock, kind, key, timeout_seconds=lock_timeout)
        os.environ.setdefault("WILTED_WORK_PHASE", "test" if action == "run-tests" else "build")
        emit(f"work-start kind={kind} key={key} phase={os.environ.get('WILTED_WORK_PHASE', 'build')} budget={command_timeout:g}s")
        if clean_product:
            clean_app_product(cache)
        sys.stderr.flush()
        runner = Path(__file__).with_name("run-bounded.py")
        if action == "run":
            return run_swiftpm_with_retry(
                runner, plan, xattr_clear_root(kind, cache), command_timeout,
                lock_descriptor,
            )
        try:
            os.execvpe(
                sys.executable,
                [sys.executable, str(runner), "--timeout-seconds", str(command_timeout), "--", *plan],
                os.environ,
            )
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
