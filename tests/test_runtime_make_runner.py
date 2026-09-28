#!/usr/bin/env python3
"""Behavioral routes for Runtime Makefile test commands."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_MAKEFILE = ROOT / "Producer" / "Runtime" / "Makefile"
TARGETS = {
    "test": ["pytest"],
    "test-unit": ["pytest", "-m", "unit"],
    "test-integration": ["pytest", "-m", "integration"],
    "test-e2e": ["pytest", "-m", "e2e"],
    "test-tui": ["pytest", "-m", "tui"],
}

UV = """#!/usr/bin/env python3
import os, sys
if sys.argv[1:4] != ['run', '--group', 'dev']:
    raise SystemExit(64)
argv = sys.argv[4:]
if argv[0] == 'python': argv[0] = sys.executable
os.execvp(argv[0], argv)
"""

HELPER = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
capture = Path(os.environ['RUNTIME_MAKE_CAPTURE'])
capture.mkdir(parents=True, exist_ok=True)
existing = list(capture.glob('*.json'))
(capture / f'{len(existing):02d}.json').write_text(json.dumps(sys.argv[1:]))
raise SystemExit(int(os.environ.get('RUNTIME_MAKE_HELPER_STATUS', '0')))
"""


class RuntimeMakeRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="wilted-runtime-make-")
        self.root = Path(self.temp.name)
        self.runtime = self.root / "Producer" / "Runtime"
        self.runtime.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "capture"
        shutil.copy2(RUNTIME_MAKEFILE, self.runtime / "Makefile")
        (self.bin / "uv").write_text(UV, encoding="utf-8")
        (self.bin / "uv").chmod(0o755)
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "run-bounded.py").write_text(HELPER, encoding="utf-8")
        (scripts / "run-bounded.py").chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_target(self, target: str, *, timeout: str | None = "17", status: str = "0") -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "RUNTIME_MAKE_CAPTURE": str(self.capture),
            "RUNTIME_MAKE_HELPER_STATUS": status,
        }
        if timeout is not None:
            env["WILTED_TEST_TIMEOUT_SECONDS"] = timeout
        return subprocess.run(
            ["make", "-f", "Makefile", target], cwd=self.runtime, env=env,
            text=True, capture_output=True, check=False,
        )

    def calls(self) -> list[list[str]]:
        return [json.loads(path.read_text(encoding="utf-8")) for path in sorted(self.capture.glob("*.json"))]

    def test_all_test_targets_use_bounded_argv_and_override_timeout(self) -> None:
        for target, expected in TARGETS.items():
            result = self.run_target(target)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls(),
            [["--timeout-seconds", "17", "--", *argv] for argv in TARGETS.values()],
        )

    def test_default_timeout_and_failure_remain_visible_to_make(self) -> None:
        inherited_timeout = os.environ.pop("WILTED_TEST_TIMEOUT_SECONDS", None)
        try:
            result = self.run_target("test", timeout=None, status="23")
        finally:
            if inherited_timeout is not None:
                os.environ["WILTED_TEST_TIMEOUT_SECONDS"] = inherited_timeout
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Error 23", result.stdout + result.stderr)
        self.assertEqual(self.calls(), [["--timeout-seconds", "1800", "--", "pytest"]])


if __name__ == "__main__":
    unittest.main()
