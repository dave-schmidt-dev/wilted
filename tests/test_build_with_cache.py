#!/usr/bin/env python3
"""Focused end-to-end checks for scripts/build-with-cache.py."""

from __future__ import annotations

import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from test_bounded_runner import BoundedRunnerTests


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
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin_dir}{os.pathsep}{self.env.get('PATH', '')}"
        self.env["BUILD_CACHE_TEST_EVENTS"] = str(self.events)
        self.write_fake_tool("swift")
        self.write_fake_tool("xcodebuild")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_fake_tool(self, name: str) -> None:
        tool = self.bin_dir / name
        tool.write_text(
            "#!/usr/bin/env python3\n"
            f"name = {name!r}\n"
            "import os, signal, sys, time\n"
            "with open(os.environ['BUILD_CACHE_TEST_EVENTS'], 'a', encoding='utf-8') as f:\n"
            "    f.write(name + '\\t' + '\\t'.join(sys.argv[1:]) + '\\n')\n"
            "args = sys.argv[1:]\n"
            "if '--sleep-seconds' in args:\n"
            "    time.sleep(float(args[args.index('--sleep-seconds') + 1]))\n"
            "if '--terminate-self' in args:\n"
            "    os.kill(os.getpid(), signal.SIGTERM)\n"
            "if '--exit-code' in args:\n"
            "    raise SystemExit(int(args[args.index('--exit-code') + 1]))\n",
            encoding="utf-8",
        )
        tool.chmod(0o755)

    def run_helper(self, *args: str, timeout: float = 10) -> subprocess.CompletedProcess[str]:
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
        module.clean_app_product(cache)
        self.assertFalse(app.exists())
        self.assertTrue(other.is_dir())
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
        self.assertEqual(signal_result.returncode, -signal.SIGTERM)

    def test_test_timeout_environment_bounds_the_cached_child(self) -> None:
        self.env["WILTED_TEST_TIMEOUT_SECONDS"] = "0.2"
        result = self.run_helper(
            "run", "swiftpm", f"test-timeout-{os.getpid()}", "--", "swift", "test",
            "--sleep-seconds", "20",
            timeout=5,
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn("run-bounded: timeout", result.stderr)

    def test_reexec_deadline_does_not_seed_cache_command_deadline(self) -> None:
        """Exercise reexec -> cache helper -> runner -> Swift with recorded argv."""
        fixture = self.temp_path / "deadline-fixture"
        scripts = fixture / "scripts"
        (scripts / "lib").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/lib/test-runner.sh", scripts / "lib/test-runner.sh")
        shutil.copy(ROOT / "scripts/lib/temp-sweep.sh", scripts / "lib/temp-sweep.sh")
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
            "import os, sys\n"
            "from pathlib import Path\n"
            "with Path(os.environ['DEADLINE_RECORD']).open('a', encoding='utf-8') as record:\n"
            "    record.write('\\t'.join((sys.argv[1], sys.argv[2], os.environ.get('WILTED_TEST_TIMEOUT_SECONDS', 'absent'))) + '\\n')\n"
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
            self.assertEqual([(row[0], float(row[1])) for row in rows], [
                ("--timeout-seconds", float(expected[0])),
                ("--timeout-seconds", float(expected[1])),
            ])
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
            self.assertEqual([(row[0], float(row[1])) for row in rows], [
                ("--timeout-seconds", 1800.0),
                ("--timeout-seconds", 1800.0),
                ("--timeout-seconds", float(command_timeout)),
            ])
            self.assertEqual(swift_record.read_text(), extra.get("WILTED_TEST_TIMEOUT_SECONDS", "absent"))
            self.assertFalse(any(phase_tmp.iterdir()), "phase fixture left a temp directory")

        invoke({}, ("1800", "300"))
        invoke({"WILTED_TEST_TIMEOUT_SECONDS": "17"}, ("1800", "17"))
        invoke({"WILTED_TEST_RUNNER_TIMEOUT_SECONDS": "9"}, ("9", "300"))
        invoke({}, ("1800", "300"), status=23)
        invoke_phase({}, "300")
        invoke_phase({"WILTED_TEST_TIMEOUT_SECONDS": "17"}, "17")

    def test_xcode_labels_share_a_lock(self) -> None:
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
