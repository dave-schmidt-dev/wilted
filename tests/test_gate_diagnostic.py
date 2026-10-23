#!/usr/bin/env python3
"""Hermetic tests for the local-gate failure diagnostic writer."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gate_diagnostic", ROOT / "scripts" / "gate-diagnostic.py")
assert SPEC and SPEC.loader
DIAGNOSTIC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIAGNOSTIC)

LOG = """native.leg.start name=macos-unit-tests
Test Case '-[WiltedMacTests.LibraryModelTests testRemovesEpisode]' started.
Test Case '-[WiltedMacTests.LibraryModelTests testRemovesEpisode]' failed (0.004 seconds).
Test case 'PlaybackTests.testSeeksAcrossBreak()' failed on 'My Mac' (0.1 seconds)
Test Case '-[WiltedMacTests.LibraryModelTests testRemovesEpisode]' failed (0.004 seconds).
Test Case '-[WiltedMacTests.OtherTests testPasses]' passed (0.001 seconds).
native.leg.complete name=macos-unit-tests status=1
"""


class GateDiagnosticTests(unittest.TestCase):
    def run_main(self, log_text: str, failed: str = "macos-unit-tests") -> tuple[int, dict | None, Path]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        log = root / "logs" / "local-gate-output.attempt-1.log"
        log.parent.mkdir()
        log.write_text(log_text, encoding="utf-8")
        output = root / "evidence" / "local-gate-diagnostic.json"
        previous = Path.cwd()
        os.chdir(root)
        self.addCleanup(os.chdir, previous)
        status = DIAGNOSTIC.main(
            ["--log", "logs/local-gate-output.attempt-1.log", "--output", str(output), "--failed-legs", failed]
        )
        document = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
        return status, document, output

    def test_names_failing_tests_once_each_and_the_log_it_kept(self) -> None:
        status, document, output = self.run_main(LOG)

        self.assertEqual(status, 0)
        assert document is not None
        self.assertEqual(document["proofSchema"], "release.diagnostic.v1")
        self.assertEqual(document["operationId"], "local-gate")
        self.assertEqual(document["failureKind"], "gate-leg-failed")
        self.assertEqual(document["summary"], "legs failed: macos-unit-tests")
        self.assertEqual(document["failingTests"], ["LibraryModelTests/testRemovesEpisode", "PlaybackTests/testSeeksAcrossBreak"])
        self.assertEqual(document["failingTestsWithheld"], 0)
        self.assertEqual(document["detailPath"], "logs/local-gate-output.attempt-1.log")
        self.assertRegex(document["detailSha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_counts_tests_past_the_runner_limit_as_withheld(self) -> None:
        lines = "".join(f"Test Case '-[Suite.Many testCase{n}]' failed (0.1 seconds).\n" for n in range(25))
        status, document, _ = self.run_main(lines)

        self.assertEqual(status, 0)
        assert document is not None
        self.assertEqual(len(document["failingTests"]), 20)
        self.assertEqual(document["failingTestsWithheld"], 5)

    def test_a_log_without_test_names_still_records_the_failed_legs(self) -> None:
        status, document, _ = self.run_main("native.error xcodegen produced no project\n", failed="xcodegen-reproducible wiltedkit-tests")

        self.assertEqual(status, 0)
        assert document is not None
        self.assertEqual(document["failingTests"], [])
        self.assertEqual(document["summary"], "legs failed: xcodegen-reproducible wiltedkit-tests")

    def test_refuses_an_absolute_or_escaping_or_missing_log(self) -> None:
        for argument in ("/etc/hosts", "../outside.log", "absent.log"):
            with self.subTest(log=argument), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "diagnostic.json"
                status = DIAGNOSTIC.main(["--log", argument, "--output", str(output)])
                self.assertEqual(status, 4)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
