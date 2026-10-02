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
Path(ready + '.leader').write_text(str(os.getpid()))
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
        self.fixture_identities: dict[int, tuple[str, int]] = {}
        self.fixture_number = 0
        self.stderr_seen: dict[int, str] = {}

    def tearDown(self) -> None:
        for supervisor in self.supervisors:
            if supervisor.poll() is None:
                os.kill(supervisor.pid, signal.SIGTERM)
                try:
                    supervisor.communicate(timeout=4)
                except subprocess.TimeoutExpired:
                    supervisor.kill()
                    supervisor.communicate(timeout=4)
        self._capture_fixture_markers()
        self._cleanup_fixture_groups()
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
        while time.monotonic() < deadline:
            if path.exists():
                pid_text = path.read_text()
                if pid_text:
                    pid = int(pid_text)
                    self._track_fixture_pid(pid)
                    return pid
            time.sleep(.01)
        self.fail(f"fixture did not write a PID before barrier deadline: {path}")

    def _process_identity(self, pid: int) -> tuple[str, int] | None:
        result = subprocess.run(
            ["/bin/ps", "-o", "lstart=,pgid=", "-p", str(pid)],
            text=True, capture_output=True, check=False, timeout=2,
        )
        fields = result.stdout.strip().rsplit(maxsplit=1)
        if result.returncode or len(fields) != 2:
            return None
        try:
            return fields[0], int(fields[1])
        except ValueError:
            return None

    def _track_fixture_pid(self, pid: int) -> None:
        identity = self._process_identity(pid)
        if identity is not None:
            self.fixture_identities[pid] = identity

    def _capture_fixture_markers(self) -> None:
        for marker in self.path.rglob("*.ready*"):
            try:
                self._track_fixture_pid(int(marker.read_text()))
            except (OSError, ValueError):
                continue

    def _cleanup_fixture_groups(self) -> None:
        def live_groups() -> set[int]:
            return {
                group for pid, identity in self.fixture_identities.items()
                if (current := self._process_identity(pid)) == identity
                for group in (identity[1],)
            }

        groups = live_groups()
        for group in groups:
            try:
                os.killpg(group, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 2
        while live_groups() and time.monotonic() < deadline:
            time.sleep(.03)
        for group in live_groups():
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def assert_dead(self, pid: int) -> None:
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.03)
        self.fail(f"owned child is still live: {pid}")

    def wait_tracked(self, process: subprocess.Popen[str], pid: int, timeout: float = 5) -> None:
        # Read the raw fd: select() cannot see lines already held in a text-mode buffer.
        seen = self.stderr_seen.setdefault(process.pid, "")
        fd = process.stderr.fileno()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if f"tracked pid={pid}" in seen:
                return
            ready, _, _ = select.select([fd], [], [], .1)
            if ready:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                seen += chunk.decode(errors="replace")
                self.stderr_seen[process.pid] = seen
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
        # A setsid child must be observed before releasing its parent.
        self.wait_tracked(process, pid)
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
            [PYTHON, str(RUNNER), "--timeout-seconds", "10", "--", "/bin/sh", "-c", "sleep 1.5"],
            text=True, capture_output=True, check=False, timeout=15, env=env,
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
        readiness_race = self.path / "readiness-race.ready"
        readiness_race.touch()
        # The PID is synthetic: never let teardown adopt a real process that reuses it.
        with (
            mock.patch.object(Path, "read_text", side_effect=["", "12345"]) as read_text,
            mock.patch.object(self, "_track_fixture_pid"),
        ):
            self.assertEqual(self.wait_file(readiness_race), 12345)
        self.assertEqual(read_text.call_count, 2)

        # The runner budget must outlast the serial observation waits below under load.
        launched = [self.command("separate", timeout=120) for _ in range(12)]
        launched += [self.command("exit-separate", timeout=120) for _ in range(13)]
        children = [self.wait_file(ready) for _, ready, _ in launched]
        self.assertEqual(len(set(children)), 25)
        for pid in children:
            self.assertEqual(os.getpgid(pid), pid)
        for (process, _, _), pid in zip(launched, children, strict=True):
            self.wait_tracked(process, pid, timeout=20)
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

    def test_owned_groups_exclude_zombies_and_reused_pids(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("run_bounded_owned_groups", RUNNER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        tree = module.OwnedTree(10, "parent-start")
        tree.known.update({
            20: "nested-leader-start",
            21: "nested-child-start",
            40: "zombie-only-start",
            50: "old-start",
            60: "foreign-group-start",
        })
        tree.groups.update({20, 40, 50})
        table = {
            10: module.Process(10, 1, "parent-start", "Z", 10),
            20: module.Process(20, 10, "nested-leader-start", "Z", 20),
            21: module.Process(21, 20, "nested-child-start", "S", 20),
            40: module.Process(40, 10, "zombie-only-start", "Z", 40),
            50: module.Process(50, 10, "replacement-start", "S", 50),
            60: module.Process(60, 10, "foreign-group-start", "S", 99),
        }
        self.assertEqual(tree.owned_groups(table), [20])

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

    def test_transient_inspection_timeouts_are_skipped_then_bounded(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("run_bounded_slow_ps", RUNNER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        original = module.process_table
        calls = 0

        def slow_twice():
            nonlocal calls
            calls += 1
            if calls in (2, 3):
                raise subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)
            return original()

        with mock.patch.object(module, "process_table", side_effect=slow_twice), \
             mock.patch.object(module, "INSPECTION_INTERVAL_SECONDS", 0.01):
            result = module.run(5, [PYTHON, "-c", "import time; time.sleep(.3)"])
        self.assertEqual(result, 0)

        def always_slow():
            raise subprocess.TimeoutExpired(module.PROCESS_TABLE_COMMAND, 5)

        started = time.monotonic()
        with mock.patch.object(module, "process_table", side_effect=always_slow), \
             mock.patch.object(module, "INSPECTION_INTERVAL_SECONDS", 0.01):
            result = module.run(5, [PYTHON, "-c", "import time; time.sleep(3)"])
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

    def test_killed_during_identity_lookup_cleans_unreleased_fixture(self) -> None:
        ready, release = self.path / "startup.ready", self.path / "startup.go"
        barrier = self.path / "startup-identity.ready"
        startup = """
import importlib.util, sys, time
from pathlib import Path
runner, fixture, ready, release, barrier = sys.argv[1:]
spec = importlib.util.spec_from_file_location('startup_run_bounded', runner)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
def held_identity(pid):
    Path(barrier).write_text(str(pid))
    while True: time.sleep(.01)
module.leader_start = held_identity
sys.exit(module.run(3, [sys.executable, fixture, ready, release, 'success']))
"""
        process = subprocess.Popen(
            [PYTHON, "-c", startup, str(RUNNER), str(self.fixture), str(ready),
             str(release), str(barrier)],
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        self.supervisors.append(process)
        leader = self.wait_file(barrier)
        descendant = self.wait_file(ready)
        os.kill(process.pid, signal.SIGKILL)
        code, stderr = self.finish(process)
        self.assertEqual(code, -signal.SIGKILL, stderr)
        self.assert_dead(leader)
        self.assert_dead(descendant)

    def test_early_interrupt_with_inherited_ignore_survives_startup_barrier(self) -> None:
        ready = self.path / "early-int.ready"
        release = self.path / "early-int.go"
        barrier = self.path / "identity.ready"
        resume = self.path / "identity.go"
        startup = """
import importlib.util, signal, sys, time
from pathlib import Path
runner, fixture, ready, release, barrier, resume = sys.argv[1:]
assert signal.getsignal(signal.SIGINT) == signal.SIG_IGN
spec = importlib.util.spec_from_file_location('early_run_bounded', runner)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original = module.leader_start
def held_identity(pid):
    Path(barrier).write_text(str(pid))
    while not Path(resume).exists(): time.sleep(.01)
    return original(pid)
module.leader_start = held_identity
sys.exit(module.run(3, [sys.executable, fixture, ready, release, 'success']))
"""

        def ignore_int() -> None:
            signal.signal(signal.SIGINT, signal.SIG_IGN)

        process = subprocess.Popen(
            [PYTHON, "-c", startup, str(RUNNER), str(self.fixture), str(ready),
             str(release), str(barrier), str(resume)],
            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            preexec_fn=ignore_int,
        )
        self.supervisors.append(process)
        leader = self.wait_file(barrier)
        descendant = self.wait_file(ready)
        os.kill(process.pid, signal.SIGINT)
        resume.touch()
        code, stderr = self.finish(process)
        self.assertEqual(code, -signal.SIGINT, stderr)
        self.assert_dead(leader)
        self.assert_dead(descendant)

    def test_original_signal_environment_reaches_child_and_is_restored(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("run_bounded_signal_state", RUNNER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        managed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        saved_handlers = {sig: signal.getsignal(sig) for sig in managed}
        saved_mask = signal.pthread_sigmask(signal.SIG_SETMASK, {signal.SIGUSR1})
        try:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, lambda *_args: None)
            expected_handlers = {sig: signal.getsignal(sig) for sig in managed}
            expected_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
            child = """
import signal, time
assert signal.getsignal(signal.SIGINT) == signal.SIG_IGN
assert signal.getsignal(signal.SIGTERM) == signal.SIG_DFL
assert signal.pthread_sigmask(signal.SIG_BLOCK, []) == {signal.SIGUSR1}
time.sleep(.1)
"""
            self.assertEqual(module.run(3, [PYTHON, "-c", child]), 0)
            self.assertEqual({sig: signal.getsignal(sig) for sig in managed}, expected_handlers)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), expected_mask)
            original_popen = module.subprocess.Popen
            def missing_command(argv, *args, **kwargs):
                if "--watchdog" in argv:
                    return original_popen(argv, *args, **kwargs)
                raise FileNotFoundError
            with mock.patch.object(module.subprocess, "Popen", side_effect=missing_command):
                with self.assertRaises(FileNotFoundError):
                    module.run(3, ["missing-command"])
            self.assertEqual({sig: signal.getsignal(sig) for sig in managed}, expected_handlers)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), expected_mask)
            with mock.patch.object(module, "leader_start", return_value=None):
                self.assertEqual(module.run(3, [PYTHON, "-c", "import time; time.sleep(5)"]), 125)
            self.assertEqual({sig: signal.getsignal(sig) for sig in managed}, expected_handlers)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), expected_mask)
            original_popen = module.subprocess.Popen
            startup_children = []
            def fail_watchdog(argv, *args, **kwargs):
                if "--watchdog" in argv:
                    raise OSError("controlled watchdog startup failure")
                process = original_popen(argv, *args, **kwargs)
                if argv[:2] == [PYTHON, "-c"]:
                    startup_children.append(process)
                return process
            with mock.patch.object(module.subprocess, "Popen", side_effect=fail_watchdog):
                self.assertEqual(module.run(3, [PYTHON, "-c", "import time; time.sleep(5)"]), 125)
            self.assertEqual(startup_children, [], "command launched without its watchdog")
            self.assertEqual({sig: signal.getsignal(sig) for sig in managed}, expected_handlers)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, []), expected_mask)
        finally:
            for sig, handler in saved_handlers.items():
                signal.signal(sig, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, saved_mask)

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
        # A setsid child must be observed before releasing its parent.
        self.wait_tracked(process, pid)
        release.touch()
        code, stderr = self.finish(process)
        self.assertEqual(code, 0, stderr)
        self.assert_dead(pid)
        self.assertIsNone(peer.poll(), "runner killed an unrelated peer")


if __name__ == "__main__":
    unittest.main()
