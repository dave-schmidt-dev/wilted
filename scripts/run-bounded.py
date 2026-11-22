#!/usr/bin/env python3
"""Run one argv-only command with a deadline and descendant cleanup.

Usage: ``python3 scripts/run-bounded.py --timeout-seconds N -- argv...``.
The command is launched in its own session.  A detached watchdog retains the
observed process tree and cleans it if this supervisor disappears.  The helper
returns the command's exit code, dies by the command's signal, or returns 124
for a deadline. Cleanup failure returns 125. ``--no-timeout -- argv...``
supervises a coordinator whose executable work has separate budgets.
"""

from __future__ import annotations

import math
import os
import select
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


LABEL = "run-bounded"
EXIT_TIMEOUT = 124
EXIT_CLEANUP_FAILED = 125
EXIT_USAGE = 2
POLL_SECONDS = 0.05
GRACE_SECONDS = 0.4
PS_TIMEOUT_SECONDS = 5.0
# A ps that times out under a busy process table is skipped, not fatal, until
# this many in a row; any other inspection error still tears down at once.
MAX_SLOW_INSPECTIONS = 6
INSPECTION_INTERVAL_SECONDS = 1.0
HEARTBEAT_SECONDS = 15.0
# One in-flight observation plus cleanup's initial, TERM-wait, pre-KILL,
# KILL-wait and final scans, which share MAX_SLOW_INSPECTIONS - 1 retried slow
# scans. Each grace loop can overshoot by one probe and poll; each probe can
# spend two grace waits terminating/reaping ps. A cleanup that still fails
# closed waits one more grace period between its group signals.
WATCHDOG_WAIT_SECONDS = (
    (5 + MAX_SLOW_INSPECTIONS) * (PS_TIMEOUT_SECONDS + 2 * GRACE_SECONDS)
    + 2 * (GRACE_SECONDS + POLL_SECONDS)
    + GRACE_SECONDS
    + INSPECTION_INTERVAL_SECONDS
)
PROCESS_TABLE_COMMAND = ["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart="]
TIMEOUT_EVIDENCE_ROOT = Path(__file__).resolve().parent.parent / ".logs" / "timeouts"
TIMEOUT_EVIDENCE_SECONDS = 5.0
TIMEOUT_TREE_SECONDS = 1.0
TIMEOUT_SAMPLE_SECONDS = 3.0
SAMPLE_COMMAND = "/usr/bin/sample"


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
                probe.communicate(timeout=GRACE_SECONDS)
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


class SlowScans:
    """Retry ps scans that time out on a busy host, up to MAX_SLOW_INSPECTIONS.

    The count is cumulative for one instance, so the several scans of one cleanup
    share one bound instead of each getting its own allowance. Any other
    inspection error propagates at once.
    """

    def __init__(self, site: str) -> None:
        self.site = site
        self.count = 0

    def retry(self, inspect: Callable[[], dict[int, Process]]) -> dict[int, Process]:
        while True:
            try:
                return inspect()
            except subprocess.TimeoutExpired as error:
                self.count += 1
                if self.count >= MAX_SLOW_INSPECTIONS:
                    raise
                emit(f"{self.site}-inspection-slow count={self.count}: {error}")


class OwnedTree:
    """Track only descendants observed from a known process identity."""

    def __init__(self, leader_pid: int, leader_start: str) -> None:
        self.leader_pid = leader_pid
        self.leader_start = leader_start
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
                if (parent := table.get(pid)) is not None
                and (parent.start == start or (
                    pid == self.leader_pid and not start and parent.pgid == self.leader_pid
                ))
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
        live = {
            pid for pid, start in self.known.items()
            if (process := table.get(pid)) is not None
            and (process.start == start or (
                pid == self.leader_pid and not start and process.pgid == self.leader_pid
            ))
            and not process.state.startswith("Z")
        }
        groups = set(self.owned_groups(table))
        live.update(
            process.pid for process in table.values()
            if process.pgid in groups and not process.state.startswith("Z")
        )
        return sorted(live)

    def cleanup(self, grace_seconds: float = GRACE_SECONDS) -> bool:
        """Signal observed owned PIDs, rescanning so reparented children remain owned.

        Slow scans are retried within MAX_SLOW_INSPECTIONS.
        """
        slow = SlowScans("cleanup")
        try:
            table = slow.retry(self.scan)
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
                table = slow.retry(self.scan)
                if not self.live(table):
                    return True
                time.sleep(POLL_SECONDS)
            table = slow.retry(self.scan)
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
                table = slow.retry(self.scan)
                if not self.live(table):
                    return True
                time.sleep(POLL_SECONDS)
            remaining = self.live(slow.retry(self.scan))
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
        """Return current live members of original or observed child-owned groups.

        The initial child session remains eligible while its original leader
        identity has not been replaced: a fast-exiting shell can leave an
        unobserved child in that initial group before the next table scan.
        """
        groups = {
            process.pgid
            for pid, start in self.known.items()
            if (process := table.get(pid)) is not None
            and (process.start == start or (
                pid == self.leader_pid and not start and process.pgid == self.leader_pid
            ))
            and not process.state.startswith("Z")
            and process.pgid in self.groups
        }
        leader = table.get(self.leader_pid)
        if (
            self.leader_pid in self.groups
            and (leader is None or leader.start == self.leader_start or not self.leader_start)
            and any(
                process.pgid == self.leader_pid and not process.state.startswith("Z")
                for process in table.values()
            )
        ):
            groups.add(self.leader_pid)
        return sorted(groups)

    @staticmethod
    def signal_group(pgid: int, signum: int) -> None:
        try:
            os.killpg(pgid, signum)
        except ProcessLookupError:
            pass


def leader_start(pid: int, retry_slow: bool = True) -> str | None:
    """Return the leader's identity, retrying slow scans unless this is the watchdog.

    The supervisor retries scans that time out on a busy host; the watchdog's
    late lookup after its supervisor is gone makes one attempt, because an
    empty identity still cleans by process group and its wait budget has no
    room for retries.
    """
    try:
        table = SlowScans("identity").retry(process_table) if retry_slow else process_table()
        process = table.get(pid)
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


def watchdog(startup_fd: int, control_fd: int) -> int:
    """Attach cleanup before launch, so an abandoned supervisor cannot orphan it."""
    startup = bytearray()
    control = bytearray()
    parent_gone = False
    control_open = True
    leader_pid: int | None = None
    while leader_pid is None:
        try:
            readable, _, _ = select.select(
                [startup_fd] + ([control_fd] if control_open else []),
                [], [], INSPECTION_INTERVAL_SECONDS,
            )
            if control_open and control_fd in readable:
                message = os.read(control_fd, 128)
                if not message:
                    parent_gone = True
                    control_open = False
                else:
                    control.extend(message)
            if startup_fd in readable:
                chunk = os.read(startup_fd, 64)
                if not chunk:
                    return 0
                startup.extend(chunk)
                if b"\n" in startup:
                    leader_pid = int(startup.split(b"\n", 1)[0])
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            emit(f"watchdog-startup-failed: {error}")
            return EXIT_CLEANUP_FAILED

    start: str | None = None
    while start is None and not parent_gone:
        if b"\n" in control:
            line, _, remainder = control.partition(b"\n")
            if not line.startswith(b"I") or remainder:
                emit("watchdog-identity-message-invalid")
                return EXIT_CLEANUP_FAILED
            try:
                start = line[1:].decode("ascii")
            except UnicodeDecodeError:
                emit("watchdog-identity-message-invalid")
                return EXIT_CLEANUP_FAILED
            break
        try:
            readable, _, _ = select.select([control_fd], [], [], INSPECTION_INTERVAL_SECONDS)
            if readable:
                message = os.read(control_fd, 128)
                if not message:
                    parent_gone = True
                    control_open = False
                else:
                    control.extend(message)
        except (OSError, subprocess.SubprocessError) as error:
            emit(f"watchdog-identity-read-failed: {error}")
            return EXIT_CLEANUP_FAILED
    if start is None:
        start = leader_start(leader_pid, retry_slow=False)
    if start is None:
        emit(f"watchdog-identity-unavailable pid={leader_pid}")
        start = ""
    tree = OwnedTree(leader_pid, start)
    emit(f"watchdog-ready pid={leader_pid}")
    if parent_gone:
        emit("watchdog-parent-gone")
        return 0 if tree.cleanup() else EXIT_CLEANUP_FAILED
    slow = 0
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
            try:
                tree.scan()
                slow = 0
            except subprocess.TimeoutExpired as error:
                slow += 1
                if slow >= MAX_SLOW_INSPECTIONS:
                    raise
                emit(f"watchdog-inspection-slow count={slow}: {error}")
        except (OSError, subprocess.SubprocessError) as error:
            emit(f"watchdog-inspection-failed: {error}")
            os.close(control_fd)  # Publish teardown before inspecting or signalling children.
            tree.cleanup()
            return EXIT_CLEANUP_FAILED


def parse(argv: list[str]) -> tuple[float, list[str]]:
    if len(argv) >= 3 and argv[:2] == ["--no-timeout", "--"]:
        return math.inf, argv[2:]
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


def finish_watchdog(watcher: subprocess.Popen[object]) -> bool:
    """Wait within its inspection budget, then kill and reap its owned session."""
    emit(f"watchdog-cleanup-wait budget={WATCHDOG_WAIT_SECONDS:g}s")
    deadline = time.monotonic() + WATCHDOG_WAIT_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        try:
            watcher.wait(timeout=max(0, min(HEARTBEAT_SECONDS, remaining)))
            break
        except subprocess.TimeoutExpired:
            if time.monotonic() < deadline:
                emit("watchdog-cleanup-running")
                continue
            emit("watchdog-cleanup-timeout")
            # Its ps probes inherit this detached session's group. Kill that
            # group too, so a timed-out watchdog cannot leave an inspector.
            try:
                os.killpg(watcher.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                emit(f"watchdog-cleanup-signal-failed errno={error.errno}")
            try:
                watcher.wait(timeout=GRACE_SECONDS)
            except (OSError, subprocess.SubprocessError) as error:
                emit(f"watchdog-cleanup-reap-failed error={type(error).__name__}")
            return False
    if watcher.returncode != 0:
        emit(f"watchdog-cleanup-failed status={watcher.returncode}")
        return False
    return True


def save_timeout_evidence(
    tree: OwnedTree, child_pid: int, budget: float
) -> Path | None:
    """Best-effort bounded diagnostics for a deadline, without command arguments."""
    run_id = f"{int(time.time())}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    evidence_dir = TIMEOUT_EVIDENCE_ROOT / run_id
    try:
        evidence_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError as error:
        emit(f"timeout-evidence-unavailable error={type(error).__name__}")
        return None

    deadline = time.monotonic() + budget
    process_tree_path = evidence_dir / "process-tree"
    sample_path = evidence_dir / "sample"
    lock_owner_path = evidence_dir / "gate-lock-owner"
    processes: dict[int, tuple[int, str, str, str]] = {}

    try:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired("ps", TIMEOUT_TREE_SECONDS)
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,stat=,etime=,comm="],
            capture_output=True,
            text=True,
            check=False,
            timeout=min(TIMEOUT_TREE_SECONDS, remaining),
        )
        if result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, "ps")
        for line in result.stdout.splitlines():
            fields = line.split(maxsplit=4)
            if len(fields) != 5:
                continue
            try:
                pid, ppid = int(fields[0]), int(fields[1])
            except ValueError:
                continue
            # `comm` reports the executable name without potentially sensitive argv.
            processes[pid] = (ppid, fields[2], fields[3], fields[4].replace("\t", " "))
        children: dict[int, list[int]] = {}
        for pid, (ppid, *_details) in processes.items():
            children.setdefault(ppid, []).append(pid)
        owned = set(tree.known) | {child_pid}
        pending = list(owned)
        while pending:
            for descendant in children.get(pending.pop(), []):
                if descendant not in owned:
                    owned.add(descendant)
                    pending.append(descendant)
        rows = ["pid ppid state elapsed command (executable name only; arguments omitted)"]
        for pid in sorted(owned):
            if pid in processes:
                ppid, state, elapsed, command = processes[pid]
                rows.append(f"{pid} {ppid} {state} {elapsed} {command}")
        if len(rows) == 1:
            rows.append("process tree unavailable: no owned processes remained in the snapshot")
        process_tree_path.write_text("\n".join(rows) + "\n", encoding="utf-8")
    except (OSError, subprocess.SubprocessError) as error:
        process_tree_path.write_text(
            f"process tree unavailable: {type(error).__name__}\n", encoding="utf-8"
        )

    if not os.path.isfile(SAMPLE_COMMAND) or not os.access(SAMPLE_COMMAND, os.X_OK):
        sample_path.write_text("sample unavailable: /usr/bin/sample is unavailable\n", encoding="utf-8")
    else:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            sample_path.write_text("sample skipped: evidence time limit reached\n", encoding="utf-8")
        else:
            sample_status = 0
            try:
                result = subprocess.run(
                    [SAMPLE_COMMAND, str(child_pid), str(int(TIMEOUT_SAMPLE_SECONDS)), "-file", str(sample_path)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=remaining,
                )
                sample_status = result.returncode
            except (OSError, subprocess.SubprocessError):
                sample_status = 1
            if sample_status != 0 or not sample_path.is_file() or sample_path.stat().st_size == 0:
                sample_path.write_text(
                    f"sample unavailable: sample command failed status={sample_status}\n",
                    encoding="utf-8",
                )

    lock_pid_file = os.environ.get("GATE_UI_TEST_LOCK_PID_FILE") or os.environ.get(
        "WILTED_UI_LOCK_PID_FILE"
    )
    lock_description = "no lock\n"
    if lock_pid_file and os.path.isfile(lock_pid_file):
        try:
            with open(lock_pid_file, "r", encoding="ascii") as lock_file:
                raw_pid = lock_file.read(32).strip()
            if raw_pid.isdecimal() and int(raw_pid) > 0:
                lock_pid = int(raw_pid)
                command = processes.get(lock_pid, (0, "", "", "unavailable"))[3]
                lock_description = f"owner_pid={lock_pid} command={command}\n"
            else:
                lock_description = "lock owner unavailable: PID not published\n"
        except (OSError, UnicodeError):
            lock_description = "lock owner unavailable: PID file could not be read\n"
    try:
        lock_owner_path.write_text(lock_description, encoding="utf-8")
    except OSError as error:
        emit(f"timeout-evidence-lock-owner-unavailable error={type(error).__name__}")
    emit(f"timeout-evidence path={evidence_dir}")
    return evidence_dir


def run(timeout: float, argv: list[str]) -> int:
    managed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    handlers = {sig: signal.getsignal(sig) for sig in managed}
    received: list[int] = []
    old_mask = None

    def interrupted(signum: int, _frame: object) -> None:
        received.append(signum)

    def restore_child_signal_state() -> None:
        # Replacing an inherited SIG_IGN in this supervisor must not change
        # the signal environment of the command or its detached watchdog.
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)

    try:
        # A Bash background leg inherits ignored INT. Blocking that signal
        # alone still discards it until SIG_IGN is replaced. Record it before
        # any child can publish readiness or identity inspection can stall.
        for sig in managed:
            signal.signal(sig, interrupted)
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, managed)
        startup_read_fd, startup_write_fd = os.pipe()
        control_read_fd, control_write_fd = os.pipe()
        try:
            watcher = subprocess.Popen(
                [sys.executable, __file__, "--watchdog", str(startup_read_fd), str(control_read_fd)],
                pass_fds=(startup_read_fd, control_read_fd), start_new_session=True,
                close_fds=True, preexec_fn=restore_child_signal_state,
            )
        except (OSError, subprocess.SubprocessError) as error:
            emit(f"watchdog-start-failed: {error}")
            for fd in (startup_read_fd, startup_write_fd, control_read_fd, control_write_fd):
                os.close(fd)
            return EXIT_CLEANUP_FAILED
        os.close(startup_read_fd)
        os.close(control_read_fd)

        def announce_child() -> None:
            restore_child_signal_state()
            try:
                os.write(startup_write_fd, f"{os.getpid()}\n".encode("ascii"))
            finally:
                os.close(startup_write_fd)

        work_started = time.monotonic()
        try:
            child = subprocess.Popen(
                argv, start_new_session=True, pass_fds=(startup_write_fd,),
                preexec_fn=announce_child,
            )
        except (OSError, subprocess.SubprocessError):
            os.close(startup_write_fd)
            os.close(control_write_fd)
            finish_watchdog(watcher)
            raise
        os.close(startup_write_fd)
        start = leader_start(child.pid)
        if start is None:
            result = kill_unidentified_group(child)
            os.close(control_write_fd)
            finish_watchdog(watcher)
            return result
        os.write(control_write_fd, b"I" + start.encode("ascii") + b"\n")
        tree = OwnedTree(child.pid, start)
        tree.ignored.add(watcher.pid)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        outcome: int | None = None
        cleanup_ok = False
        try:
            deadline = work_started + timeout
            interval = heartbeat_interval()
            last_heartbeat = time.monotonic()
            next_inspection = last_heartbeat
            slow = 0
            while True:
                now = time.monotonic()
                if now >= next_inspection:
                    known = set(tree.known)
                    try:
                        tree.scan()
                        slow = 0
                    except subprocess.TimeoutExpired as error:
                        slow += 1
                        if slow >= MAX_SLOW_INSPECTIONS:
                            raise
                        emit(f"supervisor-inspection-slow count={slow}: {error}")
                    for pid in sorted(set(tree.known) - known):
                        emit(f"tracked pid={pid}")
                    next_inspection = time.monotonic() + INSPECTION_INTERVAL_SECONDS
                now = time.monotonic()
                if now - last_heartbeat >= interval:
                    emit(f"running phase={os.environ.get('WILTED_WORK_PHASE', 'command')} elapsed={now - work_started:.0f}s pid={child.pid}")
                    last_heartbeat = now
                if received:
                    outcome = -received[0]
                    if math.isinf(timeout):
                        # Coordinators own semantic cleanup (for example shutting
                        # down only simulators they booted). Give their handlers
                        # time to complete before the final descendant sweep.
                        child.send_signal(received[0])
                        cleanup_deadline = time.monotonic() + 300
                        while child.poll() is None and time.monotonic() < cleanup_deadline:
                            try:
                                child.wait(timeout=interval)
                            except subprocess.TimeoutExpired:
                                emit("coordinator-cleanup-running")
                    break
                if child.poll() is not None:
                    outcome = child.returncode
                    break
                if now >= deadline:
                    emit(f"timeout seconds={timeout:g} pid={child.pid} phase={os.environ.get('WILTED_WORK_PHASE', 'command')} elapsed={now - work_started:.1f}s")
                    monitor = select.poll()
                    monitor.register(control_write_fd, select.POLLERR | select.POLLHUP)
                    if watcher.poll() is None and not monitor.poll(0):
                        try:
                            # Keep subsecond deadlines responsive while allowing a full sample on hosted runs.
                            budget = timeout if timeout < 1 else TIMEOUT_EVIDENCE_SECONDS
                            save_timeout_evidence(tree, child.pid, budget)
                        except (OSError, ValueError, subprocess.SubprocessError) as error:
                            emit(f"timeout-evidence-unavailable error={type(error).__name__}")
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
            os.close(control_write_fd)
            if not finish_watchdog(watcher):
                outcome = EXIT_CLEANUP_FAILED
        if outcome is None:
            return EXIT_CLEANUP_FAILED
        if outcome < 0:
            signal.signal(-outcome, signal.SIG_DFL)
            os.kill(os.getpid(), -outcome)
        return outcome

    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
        if old_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def main(argv: list[str]) -> int:
    if argv[:1] == ["--watchdog"] and len(argv) == 3:
        try:
            return watchdog(int(argv[1]), int(argv[2]))
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
