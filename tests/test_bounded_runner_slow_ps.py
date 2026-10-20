#!/usr/bin/env python3
"""Regression checks for bounded-runner cleanup when ps scans are slow."""

from __future__ import annotations

import os
import shlex
import signal
import subprocess
import tempfile
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

from test_bounded_runner import load_runner


class SlowProcessScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_runner("run_bounded_slow_scans")
        self.temp = tempfile.TemporaryDirectory(prefix="bounded-slow-ps-")
        self.path = Path(self.temp.name)
        self.leader = self.module.Process(4242, 1, "leader-start", "S", 4242)

    def tearDown(self) -> None:
        # A surviving `sleep 30` ends by itself; never signal a PID that may be reused.
        self.temp.cleanup()

    def _sequence(self, events: list[object], *steps: object):
        remaining = list(steps)

        def scan():
            step = remaining.pop(0) if len(remaining) > 1 else remaining[0]
            if isinstance(step, BaseException):
                events.append("slow")
                raise step
            events.append("scan")
            return step

        return scan

    def _patched_host(self, stack: ExitStack, module, events, scan) -> None:
        def kill(pid, sig):
            events.append(("kill", pid, sig))

        def killpg(pgid, sig):
            events.append(("killpg", pgid, sig))

        for patch in (
            mock.patch.object(module, "process_table", side_effect=scan),
            mock.patch.object(module.os, "kill", side_effect=kill),
            mock.patch.object(module.os, "killpg", side_effect=killpg),
            mock.patch.object(module.time, "sleep"),
        ):
            stack.enter_context(patch)

    def test_cleanup_retries_slow_scans_before_signalling(self) -> None:
        module = self.module
        events: list[object] = []
        timeout = subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
        scan = self._sequence(events, timeout, timeout, {4242: self.leader}, {})
        with ExitStack() as stack:
            self._patched_host(stack, module, events, scan)
            emit = stack.enter_context(mock.patch.object(module, "emit"))
            self.assertTrue(module.OwnedTree(4242, "leader-start").cleanup())
        self.assertEqual(
            events[:4],
            ["slow", "slow", "scan", ("killpg", 4242, signal.SIGTERM)],
        )
        self.assertIn(("kill", 4242, signal.SIGTERM), events)
        self.assertFalse(any(
            isinstance(event, tuple) and event[2] == signal.SIGKILL
            for event in events
        ))
        messages = [call.args[0] for call in emit.call_args_list]
        self.assertTrue(any(
            message.startswith("cleanup-inspection-slow count=1")
            for message in messages
        ))
        self.assertTrue(any(
            message.startswith("cleanup-inspection-slow count=2")
            for message in messages
        ))

    def test_cleanup_fails_closed_after_persistent_slow_scans(self) -> None:
        module = self.module
        events: list[object] = []
        timeout = subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
        scan = self._sequence(events, timeout)
        with ExitStack() as stack:
            self._patched_host(stack, module, events, scan)
            emit = stack.enter_context(mock.patch.object(module, "emit"))
            self.assertFalse(module.OwnedTree(4242, "leader-start").cleanup())
        self.assertEqual(events.count("slow"), module.MAX_SLOW_INSPECTIONS)
        self.assertFalse(any(
            isinstance(event, tuple) and event[0] == "kill" for event in events
        ))
        self.assertIn(("killpg", 4242, signal.SIGTERM), events)
        self.assertIn(("killpg", 4242, signal.SIGKILL), events)
        messages = [call.args[0] for call in emit.call_args_list]
        self.assertTrue(any(
            message.startswith("cleanup-inspection-failed")
            for message in messages
        ))

    def test_cleanup_slow_budget_is_cumulative(self) -> None:
        module = self.module
        events: list[object] = []
        timeout = subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
        steps = [timeout] * (module.MAX_SLOW_INSPECTIONS - 1)
        steps += [{4242: self.leader}, timeout]
        scan = self._sequence(events, *steps)
        with ExitStack() as stack:
            self._patched_host(stack, module, events, scan)
            stack.enter_context(mock.patch.object(module, "emit"))
            self.assertFalse(module.OwnedTree(4242, "leader-start").cleanup())
        self.assertEqual(events.count("slow"), module.MAX_SLOW_INSPECTIONS)
        self.assertEqual(events.count("scan"), 1)

    def test_leader_start_retries_only_slow_scans(self) -> None:
        module = self.module
        timeout = subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
        cases = (
            ("retries", (timeout, timeout, {4242: self.leader}), True, "leader-start", 3),
            ("bounded", (timeout,), True, None, module.MAX_SLOW_INSPECTIONS),
            ("oserror", (OSError("blocked"),), True, None, 1),
            ("called-process-error", (subprocess.CalledProcessError(1, "ps"),), True, None, 1),
            ("missing", ({},), True, None, 1),
            ("watchdog-single-attempt", (timeout, {4242: self.leader}), False, None, 1),
        )
        for name, steps, retry_slow, expected, expected_calls in cases:
            with self.subTest(name=name):
                calls = 0
                remaining = list(steps)

                def scan():
                    nonlocal calls
                    calls += 1
                    step = remaining.pop(0) if len(remaining) > 1 else remaining[0]
                    if isinstance(step, BaseException):
                        raise step
                    return step

                with mock.patch.object(module, "process_table", side_effect=scan), \
                     mock.patch.object(module, "emit"):
                    result = module.leader_start(4242, retry_slow=retry_slow)
                self.assertEqual(result, expected)
                self.assertEqual(calls, expected_calls)

    def _command(self, pid_file: Path) -> list[str]:
        return [
            "/bin/sh", "-c",
            f"sleep 30 </dev/null >/dev/null 2>&1 & echo $! > "
            f"{shlex.quote(str(pid_file))}; exit 0",
        ]

    def _pid_from(self, pid_file: Path) -> int:
        self.assertTrue(pid_file.exists())
        return int(pid_file.read_text())

    def assert_dead(self, pid: int) -> None:
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.03)
        self.fail(f"owned child is still live: {pid}")

    def _track_cleanup(self, module):
        state = {"in_cleanup": False}
        original = module.OwnedTree.cleanup

        def tracked_cleanup(tree, *args, **kwargs):
            state["in_cleanup"] = True
            try:
                return original(tree, *args, **kwargs)
            finally:
                state["in_cleanup"] = False

        return state, tracked_cleanup

    def test_run_succeeds_after_slow_identity_and_cleanup_scans(self) -> None:
        module = self.module
        pid_file = self.path / "slow-success.pid"
        original = module.process_table
        state, tracked_cleanup = self._track_cleanup(module)
        calls = 0
        cleanup_timeouts = 0

        def slow_process_table():
            nonlocal calls, cleanup_timeouts
            calls += 1
            if calls == 1:
                raise subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
            if state["in_cleanup"] and cleanup_timeouts < 2:
                cleanup_timeouts += 1
                raise subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
            return original()

        with (
            mock.patch.object(module, "process_table", side_effect=slow_process_table),
            mock.patch.object(module.OwnedTree, "cleanup", tracked_cleanup),
            mock.patch.object(module, "INSPECTION_INTERVAL_SECONDS", 0.01),
        ):
            result = module.run(10, self._command(pid_file))
        self.assertEqual(result, 0)
        self.assertEqual(cleanup_timeouts, 2)
        self.assert_dead(self._pid_from(pid_file))

    def test_run_fails_closed_when_cleanup_scans_stay_slow(self) -> None:
        module = self.module
        pid_file = self.path / "slow-failure.pid"
        original = module.process_table
        state, tracked_cleanup = self._track_cleanup(module)
        cleanup_timeouts = 0

        def slow_process_table():
            nonlocal cleanup_timeouts
            if state["in_cleanup"]:
                cleanup_timeouts += 1
                raise subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
            return original()

        started = time.monotonic()
        with (
            mock.patch.object(module, "process_table", side_effect=slow_process_table),
            mock.patch.object(module.OwnedTree, "cleanup", tracked_cleanup),
            mock.patch.object(module, "INSPECTION_INTERVAL_SECONDS", 0.01),
        ):
            result = module.run(10, self._command(pid_file))
        elapsed = time.monotonic() - started
        self.assertEqual(result, 125)
        self.assertEqual(cleanup_timeouts, module.MAX_SLOW_INSPECTIONS)
        self.assert_dead(self._pid_from(pid_file))
        self.assertLess(elapsed, module.WATCHDOG_WAIT_SECONDS)


if __name__ == "__main__":
    unittest.main()
