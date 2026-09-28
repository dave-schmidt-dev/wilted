#!/usr/bin/env python3
"""Synthetic process-tree regression checks for the bounded command runner."""

from __future__ import annotations

import os
import signal
import select
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "run-bounded.py"
PYTHON = sys.executable

FIXTURE = """
import os, sys, time
from pathlib import Path
ready, release, mode = sys.argv[1:]
if mode == 'child':
    if os.environ.get('SEPARATE_GROUP') == '1': os.setsid()
    Path(ready).write_text(str(os.getpid()))
    while True: time.sleep(.1)
env = os.environ.copy()
if mode in ('separate', 'exit-separate'): env['SEPARATE_GROUP'] = '1'
child = os.posix_spawn(sys.executable, [sys.executable, __file__, ready, release, 'child'], env)
while not Path(ready).exists(): time.sleep(.01)
if mode in ('exit', 'exit-separate'):
    while not Path(release).exists(): time.sleep(.01)
    sys.exit(0)
while not Path(release).exists(): time.sleep(.01)
sys.exit(23 if mode == 'failure' else 0)
"""


class BoundedRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="bounded-runner-test-")
        self.path = Path(self.temp.name)
        self.fixture = self.path / "fixture.py"
        self.fixture.write_text(FIXTURE, encoding="utf-8")
        self.peers: list[subprocess.Popen[bytes]] = []
        self.supervisors: list[subprocess.Popen[str]] = []
        self.fixture_number = 0

    def tearDown(self) -> None:
        for supervisor in self.supervisors:
            if supervisor.poll() is None:
                os.kill(supervisor.pid, signal.SIGTERM)
                try:
                    supervisor.communicate(timeout=4)
                except subprocess.TimeoutExpired:
                    supervisor.kill()
                    supervisor.communicate(timeout=4)
        for peer in self.peers:
            if peer.poll() is None:
                peer.kill()
            peer.wait()
        self.temp.cleanup()

    def command(self, mode: str, timeout: float = 3) -> tuple[subprocess.Popen[str], Path, Path]:
        self.fixture_number += 1
        ready = self.path / f"{mode}-{self.fixture_number}.ready"
        release = self.path / f"{mode}-{self.fixture_number}.go"
        process = subprocess.Popen(
            [PYTHON, str(RUNNER), "--timeout-seconds", str(timeout), "--", PYTHON,
             str(self.fixture), str(ready), str(release), mode],
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        self.supervisors.append(process)
        return process, ready, release

    def wait_file(self, path: Path) -> int:
        deadline = time.monotonic() + 4
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertTrue(path.exists(), f"fixture did not reach barrier: {path}")
        return int(path.read_text())

    def assert_dead(self, pid: int) -> None:
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.03)
        self.fail(f"owned child is still live: {pid}")

    def wait_tracked(self, process: subprocess.Popen[str], pid: int) -> None:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stderr], [], [], .1)
            if ready and f"tracked pid={pid}" in process.stderr.readline():
                return
        self.fail(f"runner never tracked separate descendant {pid}")

    def finish(self, process: subprocess.Popen[str]) -> tuple[int, str]:
        _, stderr = process.communicate(timeout=6)
        return process.returncode, stderr

    def test_success_cleans_same_group_descendant(self) -> None:
        process, ready, release = self.command("success")
        pid = self.wait_file(ready)
        self.assertNotEqual(os.getpgid(pid), pid, "same-group fixture escaped its parent group")
        release.touch()
        code, stderr = self.finish(process)
        self.assertEqual(code, 0, stderr)
        self.assert_dead(pid)

    def test_success_cleans_separate_group_descendant(self) -> None:
        process, ready, release = self.command("separate")
        pid = self.wait_file(ready)
        self.assertEqual(os.getpgid(pid), pid, "separate-group fixture did not create its own group")
        release.touch()
        code, stderr = self.finish(process)
        self.assertEqual(code, 0, stderr)
        self.assert_dead(pid)

    def test_leader_exit_still_cleans_observed_descendant(self) -> None:
        process, ready, release = self.command("exit")
        pid = self.wait_file(ready)
        release.touch()
        code, stderr = self.finish(process)
        self.assertEqual(code, 0, stderr)
        self.assert_dead(pid)

    def test_failure_and_timeout_preserve_status_and_cleanup(self) -> None:
        failure, ready, release = self.command("failure")
        failed_pid = self.wait_file(ready)
        release.touch()
        code, stderr = self.finish(failure)
        self.assertEqual(code, 23, stderr)
        self.assert_dead(failed_pid)
        timeout, ready, _ = self.command("success", timeout=.2)
        timeout_pid = self.wait_file(ready)
        code, stderr = self.finish(timeout)
        self.assertEqual(code, 124, stderr)
        self.assert_dead(timeout_pid)

    def test_direct_shell_timeout_cannot_return_success(self) -> None:
        started = time.monotonic()
        result = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "0.2", "--", "/bin/sh", "-c", "sleep 10"],
            text=True, capture_output=True, check=False, timeout=4,
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(time.monotonic() - started, 2)

    def test_short_commands_preserve_success_and_failure(self) -> None:
        success = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "2", "--", "/usr/bin/true"],
            text=True, capture_output=True, check=False, timeout=4,
        )
        failure = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "2", "--", "/bin/sh", "-c", "exit 23"],
            text=True, capture_output=True, check=False, timeout=4,
        )
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(failure.returncode, 23, failure.stderr)

    def test_fast_leader_exit_cleans_original_same_group(self) -> None:
        pid_file = self.path / "fast-leader-child.pid"
        command = f"sleep 20 </dev/null >/dev/null 2>&1 & echo $! > {shlex.quote(str(pid_file))}; exit 0"
        result = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "2", "--", "/bin/sh", "-c", command],
            text=True, capture_output=True, check=False, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(pid_file.exists(), result.stderr)
        self.assert_dead(int(pid_file.read_text()))

    def test_long_command_emits_progress_without_capturing_stdout(self) -> None:
        env = os.environ | {"WILTED_BOUNDED_HEARTBEAT_SECONDS": "0.05"}
        result = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "2", "--", "/bin/sh", "-c", "sleep .2"],
            text=True, capture_output=True, check=False, timeout=4, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("run-bounded: running", result.stderr)

    def test_twenty_five_parallel_deadlines_do_not_saturate_inspection(self) -> None:
        started = time.monotonic()
        runners = [
            subprocess.Popen(
                [PYTHON, str(RUNNER), "--timeout-seconds", "0.3", "--", "/bin/sh", "-c", "sleep 5"],
                text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            )
            for _ in range(25)
        ]
        try:
            for runner in runners:
                runner.communicate(timeout=12)
            statuses = [runner.returncode for runner in runners]
        finally:
            for runner in runners:
                if runner.poll() is None:
                    runner.kill()
                    runner.communicate(timeout=4)
        self.assertEqual(statuses, [124] * 25)
        self.assertLess(time.monotonic() - started, 10)

    def test_parallel_separate_groups_survive_leader_exit_cleanup(self) -> None:
        launched = [self.command("separate") for _ in range(12)]
        launched += [self.command("exit-separate") for _ in range(13)]
        children = [self.wait_file(ready) for _, ready, _ in launched]
        self.assertEqual(len(set(children)), 25)
        for pid in children:
            self.assertEqual(os.getpgid(pid), pid)
        for (process, _, _), pid in zip(launched, children, strict=True):
            self.wait_tracked(process, pid)
        for _, _, release in launched:
            release.touch()
        for process, _, _ in launched:
            _, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, stderr)
        for pid in children:
            self.assert_dead(pid)

    def test_child_receives_term_after_startup_signal_masking(self) -> None:
        marker = self.path / "term-marker"
        result = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "0.2", "--", "/bin/sh", "-c",
             f"trap 'touch {marker}; exit 0' TERM; while :; do sleep 1; done"],
            text=True, capture_output=True, check=False, timeout=4,
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertTrue(marker.exists(), result.stderr)

    def test_process_inspection_failure_is_bounded_and_nonzero(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("run_bounded", RUNNER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        started = time.monotonic()
        with mock.patch.object(module, "process_table", side_effect=OSError("blocked")):
            result = module.run(5, [PYTHON, "-c", "import time; time.sleep(.5)"])
        self.assertEqual(result, 125)
        self.assertLess(time.monotonic() - started, 2)

    def test_post_identity_inspection_failure_still_tears_down(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("run_bounded_post_identity", RUNNER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        original = module.process_table
        calls = 0

        def fail_after_identity():
            nonlocal calls
            calls += 1
            if calls > 1:
                raise OSError("inspection lost")
            return original()

        started = time.monotonic()
        with mock.patch.object(module, "process_table", side_effect=fail_after_identity), \
             mock.patch.object(module, "INSPECTION_INTERVAL_SECONDS", 0.01):
            result = module.run(3, [PYTHON, "-c", "import time; time.sleep(.2)"])
        self.assertEqual(result, 125)
        self.assertLess(time.monotonic() - started, 4)

    def test_process_table_timeout_reaps_its_probe(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("run_bounded_probe", RUNNER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        probes: list[subprocess.Popen[bytes]] = []
        original = module.subprocess.Popen

        def capture_probe(*args: object, **kwargs: object) -> subprocess.Popen[bytes]:
            probe = original(*args, **kwargs)
            probes.append(probe)
            return probe

        with mock.patch.object(module, "PROCESS_TABLE_COMMAND", [PYTHON, "-c", "import time; time.sleep(5)"]), \
             mock.patch.object(module, "PS_TIMEOUT_SECONDS", 0.05), \
             mock.patch.object(module.subprocess, "Popen", side_effect=capture_probe):
            with self.assertRaises(subprocess.TimeoutExpired):
                module.process_table()
        self.assertEqual(len(probes), 1)
        self.assertIsNotNone(probes[0].poll(), "timed-out inspection probe survived")

    def test_interrupts_and_killed_supervisor_clean_children(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGKILL):
            with self.subTest(signum=signum):
                process, ready, _ = self.command("success")
                pid = self.wait_file(ready)
                os.kill(process.pid, signum)
                code, stderr = self.finish(process)
                self.assertEqual(code, -signum, stderr)
                self.assert_dead(pid)

    def test_invalid_timeout_and_unrelated_peer(self) -> None:
        invalid = subprocess.run(
            [PYTHON, str(RUNNER), "--timeout-seconds", "nan", "--", "true"],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("timeout-seconds-invalid", invalid.stderr)
        peer = subprocess.Popen([PYTHON, "-c", "import time; time.sleep(20)"])
        self.peers.append(peer)
        process, ready, release = self.command("separate")
        pid = self.wait_file(ready)
        release.touch()
        code, stderr = self.finish(process)
        self.assertEqual(code, 0, stderr)
        self.assert_dead(pid)
        self.assertIsNone(peer.poll(), "runner killed an unrelated peer")


if __name__ == "__main__":
    unittest.main()
