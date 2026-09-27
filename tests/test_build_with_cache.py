#!/usr/bin/env python3
"""Focused end-to-end checks for scripts/build-with-cache.py."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


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
        second = self.run_helper("path", "swiftpm", key + "-other-label")

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertTrue(Path(first.stdout.strip()).is_dir())
        self.assertEqual(Path(first.stdout.strip()), ROOT / ".build" / "swiftpm")

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
            self.assertEqual(args[3], str(ROOT / ".build" / "swiftpm"))
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

    def test_same_cache_waits_across_labels_and_reports_contention(self) -> None:
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
                "run", "swiftpm", key + "-other-label", "--", "swift", "build", timeout=8
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
