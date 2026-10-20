#!/usr/bin/env python3
"""Focused end-to-end checks for scripts/build-with-cache.py."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from test_bounded_runner import BoundedRunnerTests
from test_bounded_runner_slow_ps import SlowProcessScanTests

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "build-with-cache.py"
PYTHON = sys.executable


class BuildWithCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="build-with-cache-test-")
        self.temp_path = Path(self.temp.name)
        self.bin_dir = self.temp_path / "bin"
        self.bin_dir.mkdir()
        self.events = self.temp_path / "events.txt"
        self.fixture_products: list[tuple[Path, Path]] = []
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["BUILD_CACHE_TEST_EVENTS"] = str(self.events)
        self.write_fake_tool("swift")
        self.write_fake_tool("xcodebuild")

    def tearDown(self) -> None:
        for cache, lock in self.fixture_products:
            shutil.rmtree(cache, ignore_errors=True)
            lock.unlink(missing_ok=True)
        self.temp.cleanup()

    def track_fixture_cache(self, kind: str, key: str) -> None:
        if str(os.getpid()) not in key:
            return
        if kind == "swiftpm":
            cache = ROOT / ".build/swiftpm" / key
            lock = ROOT / ".build/swiftpm/.locks" / f"{key}.lock"
        elif kind == "xcode" and key.startswith("native-"):
            cache = ROOT / ".build/xcode" / key
            lock = ROOT / ".build/xcode-locks" / f"{key}.lock"
        else:
            return
        if not cache.exists() and not lock.exists() and (cache, lock) not in self.fixture_products:
            self.fixture_products.append((cache, lock))

    def write_fake_tool(self, name: str) -> None:
        tool = self.bin_dir / name
        tool.write_text(
            "#!/usr/bin/env python3\n"
            f"name = {name!r}\n"
            "import os, signal, sys, time\n"
            "with open(os.environ['BUILD_CACHE_TEST_EVENTS'], 'a', encoding='utf-8') as f:\n"
            "    f.write(name + '\\t' + '\\t'.join(sys.argv[1:]) + '\\n')\n"
            "args = sys.argv[1:]\n"
            "if os.environ.get('BUILD_CACHE_TEST_PID_FILE'):\n"
            "    from pathlib import Path\n"
            "    Path(os.environ['BUILD_CACHE_TEST_PID_FILE']).write_text("
            "str(os.getpid()), encoding='utf-8')\n"
            "if '--wait-release' in args:\n"
            "    from pathlib import Path\n"
            "    release = Path(args[args.index('--wait-release') + 1])\n"
            "    while not release.exists(): time.sleep(.05)\n"
            "if '--sleep-seconds' in args:\n"
            "    time.sleep(float(args[args.index('--sleep-seconds') + 1]))\n"
            "if '--terminate-self' in args:\n"
            "    os.kill(os.getpid(), signal.SIGTERM)\n"
            "if '--emit-bytes' in args:\n"
            "    sys.stdout.write('x' * 2000000)\n"
            "    sys.stdout.flush()\n"
            "if os.environ.get('BUILD_CACHE_TEST_DETRITUS') == 'always':\n"
            "    marker_path = (args[args.index('-derivedDataPath') + 1] "
            "if '-derivedDataPath' in args else name)\n"
            "    sys.stderr.write(marker_path + ': resource fork, Finder information, "
            "or similar detritus not allowed\\n')\n"
            "    sys.stderr.flush()\n"
            "    raise SystemExit(int(args[args.index('--exit-code') + 1]) "
            "if '--exit-code' in args else 65)\n"
            "if '--exit-code' in args:\n"
            "    raise SystemExit(int(args[args.index('--exit-code') + 1]))\n",
            encoding="utf-8",
        )
        tool.chmod(0o755)

    def run_helper(self, *args: str, timeout: float = 10) -> subprocess.CompletedProcess[str]:
        if len(args) >= 3:
            self.track_fixture_cache(args[1], args[2])
        return subprocess.run(
            [PYTHON, str(HELPER), *args],
            cwd=ROOT,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def read_events(self) -> list[str]:
        if not self.events.exists():
            return []
        return self.events.read_text(encoding="utf-8").splitlines()

    def test_path_reuses_the_same_cache(self) -> None:
        key = f"test-path-{os.getpid()}"
        first = self.run_helper("path", "swiftpm", key)
        second = self.run_helper("path", "swiftpm", key)
        other = self.run_helper("path", "swiftpm", key + "-other-label")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertNotEqual(first.stdout, other.stdout)
        self.assertTrue(Path(first.stdout.strip()).is_dir())
        self.assertEqual(Path(first.stdout.strip()), ROOT / ".build" / "swiftpm" / key)
        xcode_first = self.run_helper("path", "xcode", "mac-install")
        xcode_other = self.run_helper("path", "xcode", "mac-ui-tests")
        self.assertEqual(xcode_first.returncode, 0, xcode_first.stderr)
        self.assertEqual(xcode_first.stdout, xcode_other.stdout)
        self.assertEqual(Path(xcode_first.stdout.strip()), ROOT / ".build" / "xcode")

    def test_run_injects_swiftpm_and_xcode_cache_flags(self) -> None:
        swift_keys = [f"test-swift-{command}-{os.getpid()}" for command in ("build", "test", "run")]
        xcode_key = f"test-xcode-{os.getpid()}"
        swift_results = [
            self.run_helper("run", "swiftpm", key, "--", "swift", command, "--verbose")
            for command, key in zip(("build", "test", "run"), swift_keys, strict=True)
        ]
        xcode = self.run_helper(
            "run", "xcode", xcode_key, "--", "xcodebuild", "-scheme", "Sample"
        )

        for result in swift_results:
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(xcode.returncode, 0, xcode.stderr)
        events = [event.split("\t") for event in self.read_events()]
        for command, key, args in zip(("build", "test", "run"), swift_keys, events[:3], strict=True):
            self.assertEqual(args[:3], ["swift", command, "--scratch-path"])
            self.assertEqual(args[3], str(ROOT / ".build" / "swiftpm" / key))
            self.assertEqual(args[4:], ["--verbose"])
        xcode_args = events[3]
        self.assertEqual(xcode_args[:2], ["xcodebuild", "-derivedDataPath"])
        self.assertEqual(xcode_args[2], str(ROOT / ".build" / "xcode"))
        self.assertEqual(xcode_args[3:], ["-scheme", "Sample"])

    def test_run_tests_validates_command_and_does_not_inject_scratch(self) -> None:
        self.write_fake_tool("xcrun")
        key = f"test-bundle-{os.getpid()}"
        result = self.run_helper("run-tests", "swiftpm", key, "--", "xcrun", "xctest", "Current.xctest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("phase=test", result.stderr)
        self.assertEqual(self.read_events(), ["xcrun\txctest\tCurrent.xctest"])
        for args in (("xcode", "xcrun", "xctest", "Current.xctest"),
                     ("swiftpm", "swift", "test", "Current.xctest"),
                     ("swiftpm", "xcrun", "xctest", "--scratch-path"),
                     ("swiftpm", "xcrun", "xctest", "Current.xctest", "extra")):
            kind, *child = args
            invalid = self.run_helper("run-tests", kind, key, "--", *child)
            self.assertEqual(invalid.returncode, 2, invalid.stderr)
            self.assertIn("run-tests requires", invalid.stderr)
        self.assertEqual(len(self.read_events()), 1)
        self.env["WILTED_WORK_PHASE"] = "explicit-phase"
        result = self.run_helper("run-tests", "swiftpm", key, "--", "xcrun", "xctest", "Current.xctest")
        self.assertIn("phase=explicit-phase", result.stderr)

    def test_default_and_explicit_lock_wait_policy(self) -> None:
        import fcntl
        key = f"test-wait-policy-{os.getpid()}"
        self.track_fixture_cache("swiftpm", key)
        lock = ROOT / ".build/swiftpm/.locks" / f"{key}.lock"
        lock.parent.mkdir(parents=True, exist_ok=True)
        with lock.open("a") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.env["WILTED_BUILD_LOCK_TIMEOUT_SECONDS"] = "2"
            bounded = self.run_helper("run", "swiftpm", key, "--", "swift", "build", timeout=15)
            self.assertNotEqual(bounded.returncode, 0)
            self.assertIn("lock-timeout", bounded.stderr)
            self.assertEqual(self.read_events(), [])
            self.env.pop("WILTED_BUILD_LOCK_TIMEOUT_SECONDS")
            with (self.temp_path / "wait.log").open("w+") as log:
                waiting = subprocess.Popen([PYTHON, str(HELPER), "run", "swiftpm", key,
                                            "--", "swift", "build"], cwd=ROOT, env=self.env,
                                           stdout=subprocess.PIPE, stderr=log, text=True)
                try:
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        log.seek(0)
                        if "waiting kind=swiftpm" in log.read():
                            break
                        time.sleep(.05)
                    else:
                        self.fail("default wait never reported lock contention")
                    self.assertIsNone(waiting.poll())
                    fcntl.flock(held, fcntl.LOCK_UN)
                    waiting.communicate(timeout=15)
                    self.assertEqual(waiting.returncode, 0)
                    self.assertEqual(len(self.read_events()), 1)
                finally:
                    if waiting.poll() is None:
                        waiting.terminate(); waiting.communicate(timeout=15)

    def test_installer_product_cleanup_is_bounded(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("build_with_cache", HELPER)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cache = self.temp_path / "cache"
        app = cache / "Build/Products/Debug/WiltedMac.app"
        app.mkdir(parents=True)
        (app / "old").write_text("stale")
        other = cache / "Build/Products/Debug/Other.app"
        other.mkdir()
        development = cache / "Build/Products/Development/WiltedMac.app"
        development.mkdir(parents=True)
        (development / "old").write_text("stale")
        release = cache / "Build/Products/Release/WiltedMac.app"
        release.mkdir(parents=True)
        module.clean_app_product(cache)
        self.assertFalse(app.exists())
        self.assertFalse(development.exists(), "the installer's Development product is cleaned too")
        self.assertTrue(other.is_dir())
        self.assertTrue(release.is_dir(), "only installer configurations are cleaned")
        with self.assertRaisesRegex(ValueError, "clean-app-product-requires-xcode"):
            module.parse_arguments(
                ["run", "swiftpm", "probe", "--clean-app-product", "--", "swift", "build"]
            )

    def test_rejects_bad_keys_supplied_cache_flags_and_wrong_commands(self) -> None:
        cases = (
            (("path", "swiftpm", "../escape"), "key-invalid"),
            (("run", "swiftpm", "reject-flag", "--", "swift", "build", "--scratch-path=/invalid-cache/x"), "cache-flag-supplied"),
            (("run", "xcode", "reject-build-path", "--", "xcodebuild", "--build-path", "/invalid-cache/x"), "cache-flag-supplied"),
            (("run", "swiftpm", "reject-xcode", "--", "xcodebuild"), "command-mismatch"),
            (("run", "xcode", "reject-swift", "--", "swift", "build"), "command-mismatch"),
            (("run", "swiftpm", "reject-subcommand", "--", "swift", "package"), "swift-subcommand-invalid"),
        )
        for args, expected in cases:
            with self.subTest(args=args):
                result = self.run_helper(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)
        self.assertEqual(self.read_events(), [])

    def test_preserves_child_exit_code_and_signal(self) -> None:
        exit_result = self.run_helper(
            "run", "swiftpm", f"test-exit-{os.getpid()}", "--", "swift", "test",
            "--exit-code", "23",
        )
        signal_result = self.run_helper(
            "run", "swiftpm", f"test-signal-{os.getpid()}", "--", "swift", "run",
            "--terminate-self",
        )

        self.assertEqual(exit_result.returncode, 23)
        self.assertEqual(signal_result.returncode, 128 + signal.SIGTERM)


    def test_unmanaged_signal_uses_conventional_status(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "build_with_cache_signal_test", HELPER,
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original_handlers = {
            signum: signal.getsignal(signum)
            for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        }
        try:
            with open(os.devnull, "rb") as lock, mock.patch.object(
                module, "clear_xattrs", return_value=0,
            ):
                for signum in (signal.SIGTERM, signal.SIGKILL):
                    with self.subTest(signum=signum), mock.patch.object(
                        module, "relay_attempt", return_value=(-signum, False),
                    ):
                        status = module.run_swiftpm_with_retry(
                            ROOT / "scripts/run-bounded.py", ["swift", "build"],
                            self.temp_path, 10, lock.fileno(),
                        )
                        self.assertEqual(status, 128 + signum)
        finally:
            for signum, handler in original_handlers.items():
                signal.signal(signum, handler)

    def test_closed_output_pipe_still_drains_and_reaps_build(self) -> None:
        pid_file = self.temp_path / "child.pid"
        key = f"test-broken-pipe-{os.getpid()}"
        self.track_fixture_cache("swiftpm", key)
        env = self.env.copy()
        env["BUILD_CACHE_TEST_PID_FILE"] = str(pid_file)
        process = subprocess.Popen(
            [PYTHON, str(HELPER), "run", "swiftpm", key,
             "--", "swift", "run", "--emit-bytes"],
            cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        assert process.stdout is not None and process.stderr is not None
        process.stdout.close()
        try:
            status = process.wait(timeout=10)
            stderr = process.stderr.read().decode("utf-8", errors="replace")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stderr.close()
        self.assertEqual(status, 0, stderr)
        self.assertNotIn("Traceback", stderr)
        child_pid = int(pid_file.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)

    def test_xattr_cleanup_does_not_follow_cache_symlinks(self) -> None:
        xattr = Path("/usr/bin/xattr")
        if not xattr.exists():
            self.skipTest("macOS xattr utility is unavailable")
        import importlib.util

        cache = self.temp_path / "cache"
        cache.mkdir()
        external = self.temp_path / "outside-tagged-file"
        external.write_text("outside cache", encoding="utf-8")
        finder_info = "5445585454455854000000000000000000000000000000000000000000000000"
        subprocess.run(
            [str(xattr), "-wx", "com.apple.FinderInfo", finder_info, str(external)],
            check=True, capture_output=True,
        )
        (cache / "linked-tagged-file").symlink_to(external)

        spec = importlib.util.spec_from_file_location(
            "build_with_cache_xattr_test", HELPER,
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with open(os.devnull, "rb") as lock:
            status = module.clear_xattrs(
                cache, "symlink-safety-test", ROOT / "scripts/run-bounded.py",
                time.monotonic() + 10, lock.fileno(), [], [],
            )
        self.assertEqual(status, 0)
        preserved = subprocess.run(
            [str(xattr), "-p", "com.apple.FinderInfo", str(external)],
            check=False, capture_output=True,
        )
        self.assertEqual(
            preserved.returncode, 0, "cleanup stripped xattrs through a cache symlink",
        )

    def test_test_timeout_environment_bounds_the_cached_child(self) -> None:
        self.env["WILTED_TEST_TIMEOUT_SECONDS"] = "0.2"
        started = time.monotonic()
        result = self.run_helper(
            "run", "swiftpm", f"test-timeout-{os.getpid()}", "--", "swift", "test",
            "--sleep-seconds", "20",
            timeout=5,
        )
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 5)
        if "run-bounded: timeout" not in result.stderr:
            self.assertIn("native.xattr.budget-exhausted phase=pre-build", result.stderr)
            self.assertEqual(self.read_events(), [], "the build must not start after pre-clear consumes its budget")

    def test_reexec_deadline_does_not_seed_cache_command_deadline(self) -> None:
        """Exercise reexec -> cache helper -> runner -> Swift with recorded argv."""
        fixture = self.temp_path / "deadline-fixture"
        scripts = fixture / "scripts"
        (scripts / "lib").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/lib/test-runner.sh", scripts / "lib/test-runner.sh")
        shutil.copy(ROOT / "scripts/lib/test-temp-state.sh", scripts / "lib/test-temp-state.sh")
        shutil.copy(ROOT / "scripts/lib/temp-sweep.sh", scripts / "lib/temp-sweep.sh")
        shutil.copy(ROOT / "scripts/check-temp-leaks.py", scripts / "check-temp-leaks.py")
        shutil.copy(HELPER, scripts / "build-with-cache.py")
        shutil.copy(ROOT / "scripts/test-phase0.sh", scripts / "test-phase0.sh")
        shutil.copy(ROOT / "scripts/run-bounded.py", scripts / "run-bounded-real.py")
        reexec_record = self.temp_path / "reexec-deadline.txt"
        (self.bin_dir / "python3").write_text(
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = \"$REEXEC_RUNNER\" ]; then\n"
            "  printf '%s\\t%s\\t%s\\n' \"$1\" \"$2\" \"$3\" >> \"$REEXEC_RECORD\"\n"
            "fi\n"
            f"exec '{PYTHON}' \"$@\"\n",
            encoding="utf-8",
        )
        (self.bin_dir / "python3").chmod(0o755)
        (scripts / "run-bounded.py").write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys, time\n"
            "from pathlib import Path\n"
            "with Path(os.environ['DEADLINE_RECORD']).open('a', encoding='utf-8') as record:\n"
            "    record.write('\\t'.join((sys.argv[1], sys.argv[2], "
            "os.environ.get('WILTED_TEST_TIMEOUT_SECONDS', 'absent'), "
            "str(time.monotonic()))) + '\\n')\n"
            "os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name('run-bounded-real.py')), *sys.argv[1:]])\n",
            encoding="utf-8",
        )
        (scripts / "entry.sh").write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            "repo_root=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)\"\n"
            "if [[ \"${WILTED_BOUNDED_ENTRY:-0}\" != 1 ]]; then\n"
            "  source \"$repo_root/scripts/lib/test-runner.sh\"\n"
            "  wilted_reexec_bounded \"${BASH_SOURCE[0]}\" \"$@\"\n"
            "fi\n"
            "exec python3 \"$repo_root/scripts/build-with-cache.py\" run swiftpm deadline-collision -- swift test\n",
            encoding="utf-8",
        )
        (scripts / "entry.sh").chmod(0o755)
        (scripts / "phase-entry.sh").write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            "repo_root=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")/..\" && pwd)\"\n"
            "exec python3 \"$repo_root/scripts/build-with-cache.py\" run swiftpm phase-deadline-collision -- swift test\n",
            encoding="utf-8",
        )
        (scripts / "phase-entry.sh").chmod(0o755)
        fake_swift = self.bin_dir / "swift"
        fake_swift.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['SWIFT_RECORD']).write_text(os.environ.get('WILTED_TEST_TIMEOUT_SECONDS', 'absent'))\n"
            "raise SystemExit(int(os.environ.get('SWIFT_EXIT_STATUS', '0')))\n",
            encoding="utf-8",
        )
        fake_swift.chmod(0o755)

        def assert_shared_work_deadline(rows: list[list[str]], start: int,
                                        budget: str, expected_count: int) -> None:
            work_rows = rows[start:]
            self.assertEqual(len(work_rows), expected_count, rows)
            budgets = [float(row[1]) for row in work_rows]
            self.assertTrue(all(0 < value <= float(budget) for value in budgets), budgets)
            deadlines = [float(row[3]) + float(row[1]) for row in work_rows]
            self.assertLessEqual(max(deadlines) - min(deadlines), 0.5, deadlines)
            self.assertGreaterEqual(budgets[0], float(budget) - 1.0, budgets)
            measured_cleanup = float(work_rows[1][3]) - float(work_rows[0][3])
            self.assertAlmostEqual(
                budgets[1], budgets[0] - measured_cleanup, delta=0.5,
                msg=f"build timeout must deduct measured cleanup time: {work_rows}",
            )

        def invoke(extra: dict[str, str], expected: tuple[str, str], status: int = 0) -> None:
            deadline_record = self.temp_path / f"deadline-{expected[0]}-{expected[1]}.txt"
            swift_record = self.temp_path / f"swift-{expected[0]}-{expected[1]}.txt"
            deadline_record.unlink(missing_ok=True)
            swift_record.unlink(missing_ok=True)
            reexec_record.unlink(missing_ok=True)
            env = self.env.copy()
            for name in (
                "WILTED_BOUNDED_ENTRY", "WILTED_TEST_TIMEOUT_SECONDS",
                "WILTED_TEST_RUNNER_TIMEOUT_SECONDS",
            ):
                env.pop(name, None)
            env |= {
                "DEADLINE_RECORD": str(deadline_record),
                "REEXEC_RECORD": str(reexec_record),
                "REEXEC_RUNNER": str(scripts / "run-bounded.py"),
                "SWIFT_RECORD": str(swift_record),
                "SWIFT_EXIT_STATUS": str(status),
                **extra,
            }
            result = subprocess.run(
                ["bash", str(scripts / "entry.sh")], cwd=fixture, env=env,
                text=True, capture_output=True, timeout=12, check=False,
            )
            self.assertEqual(result.returncode, status, result.stderr)
            rows = [line.split("\t") for line in deadline_record.read_text().splitlines()]
            self.assertEqual((rows[0][0], float(rows[0][1])),
                             ("--timeout-seconds", float(expected[0])))
            assert_shared_work_deadline(rows, 1, expected[1], 2)
            self.assertEqual(reexec_record.read_text().splitlines(), [
                f"{scripts / 'run-bounded.py'}\t--timeout-seconds\t{expected[0]}"
            ])
            self.assertEqual(swift_record.read_text(), extra.get("WILTED_TEST_TIMEOUT_SECONDS", "absent"))

        def invoke_phase(extra: dict[str, str], command_timeout: str) -> None:
            deadline_record = self.temp_path / f"phase-deadline-{command_timeout}.txt"
            swift_record = self.temp_path / f"phase-swift-{command_timeout}.txt"
            phase_tmp = self.temp_path / f"phase-tmp-{command_timeout}"
            deadline_record.unlink(missing_ok=True)
            swift_record.unlink(missing_ok=True)
            phase_tmp.mkdir()
            env = self.env.copy()
            for name in (
                "WILTED_BOUNDED_ENTRY", "WILTED_TEST_TIMEOUT_SECONDS",
                "WILTED_TEST_RUNNER_TIMEOUT_SECONDS",
            ):
                env.pop(name, None)
            env |= {
                "DEADLINE_RECORD": str(deadline_record),
                "SWIFT_RECORD": str(swift_record),
                "SWIFT_EXIT_STATUS": "0",
                "TMPDIR": str(phase_tmp),
                "PHASE0_INTERRUPT_TEST_LEG": str(scripts / "phase-entry.sh"),
                "PHASE0_INTERRUPT_TEST_MODE": "sync",
                **extra,
            }
            result = subprocess.run(
                ["bash", str(scripts / "test-phase0.sh")], cwd=fixture, env=env,
                text=True, capture_output=True, timeout=12, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = [line.split("\t") for line in deadline_record.read_text().splitlines()]
            self.assertEqual([(row[0], float(row[1])) for row in rows[:2]], [
                ("--timeout-seconds", 1800.0),
                ("--timeout-seconds", 1800.0),
            ])
            assert_shared_work_deadline(rows, 2, command_timeout, 2)
            self.assertEqual(swift_record.read_text(), extra.get("WILTED_TEST_TIMEOUT_SECONDS", "absent"))
            self.assertFalse(any(phase_tmp.iterdir()), "phase fixture left a temp directory")

        invoke({}, ("1800", "300"))
        invoke({"WILTED_TEST_TIMEOUT_SECONDS": "17"}, ("1800", "17"))
        invoke({"WILTED_TEST_RUNNER_TIMEOUT_SECONDS": "9"}, ("9", "300"))
        invoke({}, ("1800", "300"), status=23)
        invoke_phase({}, "300")
        invoke_phase({"WILTED_TEST_TIMEOUT_SECONDS": "17"}, "17")

    def test_native_xcode_keys_build_independently(self) -> None:
        first_key = f"native-first-fixture-{os.getpid()}"
        second_key = f"native-second-fixture-{os.getpid()}"
        self.track_fixture_cache("xcode", first_key)
        release = self.temp_path / "first.release"
        first = subprocess.Popen(
            [PYTHON, str(HELPER), "run", "xcode", first_key, "--", "xcodebuild",
             "--wait-release", str(release)], cwd=ROOT, env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 20
            while not self.read_events() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(self.read_events(), "first native build never reached its release barrier")
            self.assertIn(f"xcode/{first_key}", self.read_events()[0])
            second = self.run_helper("run", "xcode", second_key, "--", "xcodebuild", timeout=20)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIsNone(first.poll(), "independent native keys serialized")
            self.assertNotIn("waiting kind=xcode", second.stderr)
            self.assertIn(f"xcode/{second_key}", self.read_events()[-1])
            release.touch()
            first.communicate(timeout=20)
            self.assertEqual(first.returncode, 0)
        finally:
            if first.poll() is None:
                first.terminate()
                first.communicate(timeout=5)

    def test_xcode_detritus_retries_once_then_fails(self) -> None:
        key = f"native-test-xcode-detritus-{os.getpid()}"
        cache = ROOT / ".build/xcode" / key
        self.track_fixture_cache("xcode", key)
        (cache / "Build").mkdir(parents=True)
        self.env["BUILD_CACHE_TEST_DETRITUS"] = "always"

        result = self.run_helper(
            "run", "xcode", key, "--", "xcodebuild", "-scheme", "Sample",
            "--exit-code", "65",
        )

        self.assertEqual(result.returncode, 65, result.stderr)
        events = [event.split("\t") for event in self.read_events()]
        self.assertEqual(len(events), 2)
        for event in events:
            self.assertEqual(event[:3], ["xcodebuild", "-derivedDataPath", str(cache)])
        self.assertEqual(result.stderr.count("native.xattr.retry attempt=2"), 1)
        self.assertIn(
            f"native.xattr.clear start reason=pre-build path={cache / 'Build'}",
            result.stderr,
        )
        self.assertIn(
            f"native.xattr.clear start reason=detritus path={cache / 'Build'}",
            result.stderr,
        )

    def test_xcode_plain_failure_is_not_retried(self) -> None:
        key = f"native-test-xcode-plain-{os.getpid()}"
        self.track_fixture_cache("xcode", key)
        result = self.run_helper(
            "run", "xcode", key, "--", "xcodebuild", "-scheme", "Sample",
            "--exit-code", "3",
        )

        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(len(self.read_events()), 1)
        self.assertNotIn("native.xattr.retry", result.stderr)

    def test_xattr_clear_root_scopes_xcode_to_build(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "build_with_cache_xattr_root_test", HELPER,
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cache = self.temp_path / "scope-cache"
        self.assertEqual(module.xattr_clear_root("swiftpm", cache), cache)
        self.assertEqual(module.xattr_clear_root("xcode", cache), cache / "Build")

        key = f"native-test-xcode-cold-{os.getpid()}-{time.time_ns()}"
        cold_cache = ROOT / ".build/xcode" / key
        self.track_fixture_cache("xcode", key)
        result = self.run_helper("run", "xcode", key, "--", "xcodebuild")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"native.xattr.clear skipped reason=pre-build "
            f"path={cold_cache / 'Build'}",
            result.stderr,
        )

    def test_installer_xcode_labels_share_a_lock(self) -> None:
        first = subprocess.Popen(
            [PYTHON, str(HELPER), "run", "xcode", "first", "--", "xcodebuild",
             "--sleep-seconds", "1.3"],
            cwd=ROOT, env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while not self.read_events() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.read_events(), "first fake Xcode build did not start")
            second = self.run_helper(
                "run", "xcode", "second", "--", "xcodebuild", timeout=8
            )
            _, first_stderr = first.communicate(timeout=5)
            self.assertEqual(first.returncode, 0, first_stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("waiting kind=xcode", second.stderr)
        finally:
            if first.poll() is None:
                first.terminate()
                first.communicate(timeout=5)

    def test_same_key_waits_and_reports_contention(self) -> None:
        key = f"test-lock-{os.getpid()}"
        self.track_fixture_cache("swiftpm", key)
        first = subprocess.Popen(
            [PYTHON, str(HELPER), "run", "swiftpm", key, "--", "swift", "build",
             "--sleep-seconds", "1.3"],
            cwd=ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while not self.read_events() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.read_events(), "first fake build did not start")

            second = self.run_helper(
                "run", "swiftpm", key, "--", "swift", "build", timeout=8
            )
            first_stdout, first_stderr = first.communicate(timeout=5)
            self.assertEqual(first.returncode, 0, first_stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("waiting kind=swiftpm", second.stderr)
            self.assertEqual(len(self.read_events()), 2)
        finally:
            if first.poll() is None:
                first.terminate()
                first.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
