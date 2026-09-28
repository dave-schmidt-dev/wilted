#!/usr/bin/env python3
"""Run one argv-only command with a deadline and descendant cleanup.

Usage: ``python3 scripts/run-bounded.py --timeout-seconds N -- argv...``.
The command is launched in its own session.  A detached watchdog retains the
observed process tree and cleans it if this supervisor disappears.  The helper
returns the command's exit code, dies by the command's signal, or returns 124
for a deadline.  Cleanup failure returns 125.
"""

from __future__ import annotations

import math
import os
import select
import signal
import subprocess
import sys
import time
from dataclasses import dataclass


LABEL = "run-bounded"
EXIT_TIMEOUT = 124
EXIT_CLEANUP_FAILED = 125
EXIT_USAGE = 2
POLL_SECONDS = 0.05
GRACE_SECONDS = 0.4
PS_TIMEOUT_SECONDS = 2.0
INSPECTION_INTERVAL_SECONDS = 1.0
HEARTBEAT_SECONDS = 15.0
WATCHDOG_WAIT_SECONDS = 4.0
PROCESS_TABLE_COMMAND = ["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart="]


def emit(message: str) -> None:
    print(f"{LABEL}: {message}", file=sys.stderr, flush=True)


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    start: str
    state: str
    pgid: int


def process_table() -> dict[int, Process]:
    """Return safe process identity data without reading command arguments."""
    probe = subprocess.Popen(
        PROCESS_TABLE_COMMAND,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        stdout, stderr = probe.communicate(timeout=PS_TIMEOUT_SECONDS)
    except BaseException:
        if probe.poll() is None:
            probe.terminate()
            try:
                probe.communicate(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                probe.kill()
                probe.communicate()
        raise
    if probe.returncode:
        raise subprocess.CalledProcessError(probe.returncode, probe.args, stdout, stderr)
    processes: dict[int, Process] = {}
    for line in stdout.splitlines():
        parts = line.split(maxsplit=4)
        if len(parts) != 5:
            continue
        try:
            processes[int(parts[0])] = Process(
                int(parts[0]), int(parts[1]), parts[4], parts[3], int(parts[2])
            )
        except ValueError:
            continue
    processes.pop(probe.pid, None)
    return processes


class OwnedTree:
    """Track only descendants observed from a known process identity."""

    def __init__(self, leader_pid: int, leader_start: str) -> None:
        self.known: dict[int, str] = {leader_pid: leader_start}
        self.groups: set[int] = {leader_pid}
        self.ignored: set[int] = set()

    def scan(self) -> dict[int, Process]:
        table = process_table()
        changed = True
        while changed:
            changed = False
            live_parents = {
                pid for pid, start in self.known.items()
                if (parent := table.get(pid)) is not None and parent.start == start
            }
            for process in table.values():
                if (process.pid not in self.known and process.pid not in self.ignored
                        and process.ppid in live_parents):
                    self.known[process.pid] = process.start
                    if process.pid == process.pgid:
                        self.groups.add(process.pgid)
                    changed = True
        return table

    def live(self, table: dict[int, Process]) -> list[int]:
        return [
            pid for pid, start in self.known.items()
            if (process := table.get(pid)) is not None
            and process.start == start and not process.state.startswith("Z")
        ]

    def cleanup(self, grace_seconds: float = GRACE_SECONDS) -> bool:
        """Signal observed owned PIDs, rescanning so reparented children remain owned."""
        try:
            table = self.scan()
            for pgid in self.owned_groups(table):
                self.signal_group(pgid, signal.SIGTERM)
            for pid in self.live(table):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    emit(f"cleanup-term-failed pid={pid}: {error}")
                    return False
            deadline = time.monotonic() + grace_seconds
            while time.monotonic() < deadline:
                table = self.scan()
                if not self.live(table):
                    return True
                time.sleep(POLL_SECONDS)
            table = self.scan()
            for pgid in self.owned_groups(table):
                self.signal_group(pgid, signal.SIGKILL)
            for pid in self.live(table):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    emit(f"cleanup-kill-failed pid={pid}: {error}")
                    return False
            deadline = time.monotonic() + grace_seconds
            while time.monotonic() < deadline:
                table = self.scan()
                if not self.live(table):
                    return True
                time.sleep(POLL_SECONDS)
            remaining = self.live(self.scan())
            if remaining:
                emit(f"cleanup-incomplete pids={','.join(map(str, remaining))}")
                return False
            return True
        except (OSError, subprocess.SubprocessError) as error:
            emit(f"cleanup-inspection-failed: {error}")
            self.signal_known_groups(signal.SIGTERM)
            time.sleep(grace_seconds)
            self.signal_known_groups(signal.SIGKILL)
            return False

    def signal_known_groups(self, signum: int) -> None:
        for pgid in self.groups:
            try:
                os.killpg(pgid, signum)
            except (ProcessLookupError, PermissionError):
                pass

    def owned_groups(self, table: dict[int, Process]) -> list[int]:
        """Return the original owned session group and observed child groups."""
        return sorted(self.groups)

    @staticmethod
    def signal_group(pgid: int, signum: int) -> None:
        try:
            os.killpg(pgid, signum)
        except ProcessLookupError:
            pass


def leader_start(pid: int) -> str | None:
    try:
        process = process_table().get(pid)
    except (OSError, subprocess.SubprocessError):
        return None
    return process.start if process else None


def kill_unidentified_group(child: subprocess.Popen[object]) -> int:
    """Fail closed without waiting indefinitely when process identity is unavailable."""
    emit(f"process-inspection-unavailable pid={child.pid}")
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    time.sleep(GRACE_SECONDS)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        child.wait(timeout=GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        emit(f"process-inspection-cleanup-incomplete pid={child.pid}")
    return EXIT_CLEANUP_FAILED


def watchdog(control_fd: int, leader_pid: int, start: str) -> int:
    """Keep cleanup independent from the supervisor's process group and life."""
    tree = OwnedTree(leader_pid, start)
    while True:
        try:
            readable, _, _ = select.select(
                [control_fd], [], [], INSPECTION_INTERVAL_SECONDS
            )
            if readable:
                if os.read(control_fd, 1) == b"D":
                    return 0 if tree.cleanup() else EXIT_CLEANUP_FAILED
                emit("watchdog-parent-gone")
                return 0 if tree.cleanup() else EXIT_CLEANUP_FAILED
            tree.scan()
        except (OSError, subprocess.SubprocessError) as error:
            emit(f"watchdog-inspection-failed: {error}")
            tree.cleanup()
            return EXIT_CLEANUP_FAILED


def parse(argv: list[str]) -> tuple[float, list[str]]:
    if len(argv) < 4 or argv[0] != "--timeout-seconds" or argv[2] != "--":
        raise ValueError("usage: run-bounded.py --timeout-seconds N -- argv...")
    try:
        timeout = float(argv[1])
    except ValueError as error:
        raise ValueError("timeout-seconds-invalid") from error
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout-seconds-invalid")
    if not argv[3:]:
        raise ValueError("command-required")
    return timeout, argv[3:]


def heartbeat_interval() -> float:
    raw = os.environ.get("WILTED_BOUNDED_HEARTBEAT_SECONDS", str(HEARTBEAT_SECONDS))
    try:
        value = float(raw)
    except ValueError as error:
        raise ValueError("heartbeat-seconds-invalid") from error
    if not math.isfinite(value) or value <= 0:
        raise ValueError("heartbeat-seconds-invalid")
    return value


def run(timeout: float, argv: list[str]) -> int:
    managed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, managed)
    restore_mask = lambda: signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    child = subprocess.Popen(
        argv, start_new_session=True, close_fds=False, preexec_fn=restore_mask
    )
    start = leader_start(child.pid)
    if start is None:
        result = kill_unidentified_group(child)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        return result
    tree = OwnedTree(child.pid, start)
    try:
        read_fd, write_fd = os.pipe()
        watcher = subprocess.Popen(
            [sys.executable, __file__, "--watchdog", str(read_fd), str(child.pid), start],
            pass_fds=(read_fd,), start_new_session=True, close_fds=True,
            preexec_fn=restore_mask,
        )
    except (OSError, subprocess.SubprocessError) as error:
        emit(f"watchdog-start-failed: {error}")
        tree.cleanup()
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        return EXIT_CLEANUP_FAILED
    os.close(read_fd)
    tree.ignored.add(watcher.pid)
    received: list[int] = []

    def interrupted(signum: int, _frame: object) -> None:
        received.append(signum)

    handlers = {sig: signal.signal(sig, interrupted) for sig in managed}
    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    outcome: int | None = None
    cleanup_ok = False
    try:
        deadline = time.monotonic() + timeout
        interval = heartbeat_interval()
        last_heartbeat = time.monotonic()
        next_inspection = last_heartbeat
        while True:
            now = time.monotonic()
            if now >= next_inspection:
                known = set(tree.known)
                tree.scan()
                for pid in sorted(set(tree.known) - known):
                    emit(f"tracked pid={pid}")
                next_inspection = now + INSPECTION_INTERVAL_SECONDS
            if now - last_heartbeat >= interval:
                emit(f"running elapsed={now - (deadline - timeout):.0f}s pid={child.pid}")
                last_heartbeat = now
            if received:
                outcome = -received[0]
                break
            if child.poll() is not None:
                outcome = child.returncode
                break
            if now >= deadline:
                emit(f"timeout seconds={timeout:g} pid={child.pid}")
                outcome = EXIT_TIMEOUT
                break
            time.sleep(POLL_SECONDS)
        cleanup_ok = tree.cleanup()
        if not cleanup_ok:
            outcome = EXIT_CLEANUP_FAILED
        try:
            child.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            outcome = EXIT_CLEANUP_FAILED
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        emit(f"supervisor-inspection-failed: {error}")
        cleanup_ok = tree.cleanup()
        try:
            child.wait(timeout=GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            emit(f"supervisor-cleanup-incomplete pid={child.pid}")
        outcome = EXIT_CLEANUP_FAILED
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        try:
            if cleanup_ok:
                os.write(write_fd, b"D")
        except OSError:
            pass
        os.close(write_fd)
        try:
            watcher.wait(timeout=WATCHDOG_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            emit("watchdog-cleanup-timeout")
            outcome = EXIT_CLEANUP_FAILED
        else:
            if watcher.returncode != 0:
                emit(f"watchdog-cleanup-failed status={watcher.returncode}")
                outcome = EXIT_CLEANUP_FAILED
    if outcome is None:
        return EXIT_CLEANUP_FAILED
    if outcome < 0:
        signal.signal(-outcome, signal.SIG_DFL)
        os.kill(os.getpid(), -outcome)
    return outcome


def main(argv: list[str]) -> int:
    if argv[:1] == ["--watchdog"] and len(argv) == 4:
        try:
            return watchdog(int(argv[1]), int(argv[2]), argv[3])
        except ValueError:
            return EXIT_USAGE
    try:
        timeout, command = parse(argv)
        return run(timeout, command)
    except ValueError as error:
        emit(str(error))
        return EXIT_USAGE
    except FileNotFoundError:
        emit(f"command-not-found: {argv[3] if len(argv) > 3 else ''}")
        return 127
    except PermissionError:
        emit("command-not-executable")
        return 126


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
