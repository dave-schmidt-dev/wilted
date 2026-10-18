#!/usr/bin/env python3
"""Tests for tests/pipeline_suite_discovery.py."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from pipeline_suite_discovery import undiscovered_modules

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tests" / "pipeline_suite_discovery.py"


def verbose_line(module: str, test_name: str) -> str:
    return f"{test_name} ({module}.Suite.{test_name}) ... ok\n"


class UndiscoveredModulesTests(unittest.TestCase):
    def test_files_that_yield_tests_pass(self) -> None:
        output = verbose_line("test_alpha", "test_one") + verbose_line("test_beta", "test_two")
        self.assertEqual(
            undiscovered_modules(["test_alpha.py", "test_beta.py"], output),
            [],
        )

    def test_file_that_yields_no_tests_is_reported(self) -> None:
        output = verbose_line("test_alpha", "test_one")
        self.assertEqual(
            undiscovered_modules(["test_alpha.py", "test_silent.py"], output),
            ["test_silent"],
        )

    def test_module_that_is_a_prefix_of_another_is_not_falsely_matched(self) -> None:
        output = verbose_line("test_ad_kind", "test_kind")
        self.assertEqual(
            undiscovered_modules(["test_ad.py", "test_ad_kind.py"], output),
            ["test_ad"],
        )
        output += verbose_line("test_ad", "test_detect")
        self.assertEqual(
            undiscovered_modules(["test_ad.py", "test_ad_kind.py"], output),
            [],
        )

    def test_paths_are_matched_by_module_name(self) -> None:
        output = verbose_line("test_alpha", "test_one")
        self.assertEqual(
            undiscovered_modules(["Producer/Workers/test_alpha.py"], output),
            [],
        )

    def test_test_noise_between_name_and_result_does_not_hide_the_module(self) -> None:
        output = (
            'test_one (test_alpha.Suite.test_one) ...'
            ' {"stage":"pipeline.work","detail":"noise"}\nok\n'
        )
        self.assertEqual(undiscovered_modules(["test_alpha.py"], output), [])


    def test_a_test_with_a_docstring_still_credits_its_module(self) -> None:
        output = "test_one (test_alpha.Suite.test_one)\nWhat the test proves. ... ok\n"
        self.assertEqual(undiscovered_modules(["test_alpha.py"], output), [])

class CliTests(unittest.TestCase):
    def run_helper(self, test_files: list[str], verbose_output: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="pipeline-suite-discovery-") as temp:
            verbose_path = Path(temp) / "verbose.log"
            verbose_path.write_text(verbose_output, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(HELPER), str(verbose_path)],
                input="".join(f"{path}\n" for path in test_files),
                text=True,
                capture_output=True,
                check=False,
            )

    def test_cli_passes_when_every_module_contributed(self) -> None:
        result = self.run_helper(["test_alpha.py"], verbose_line("test_alpha", "test_one"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_cli_names_each_undiscovered_module(self) -> None:
        result = self.run_helper(
            ["test_alpha.py", "test_silent.py"],
            verbose_line("test_alpha", "test_one"),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("test_silent", result.stderr)
        self.assertNotIn("test_alpha", result.stderr)


if __name__ == "__main__":
    unittest.main()
