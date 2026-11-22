#!/usr/bin/env python3
"""Stubbed command-output tests for hosted gate admission."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOST_STATE = ROOT / "scripts" / "lib" / "host-state.py"
ROOT_PID = 100


class HostStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="host-state-test-")
        self.path = Path(self.temp.name)
        self.stubs = self.path / "stubs"
        self.stubs.mkdir()
        self._stub("automation", "printf '%s\\n' \"$HOST_AUTOMATION_OUTPUT\"\n")
        self._stub("ps", "printf '%s\\n' \"$HOST_PROCESS_TABLE\"\n")
        self._stub("sysctl", "printf '%s\\n' 'vm.loadavg: { 1.20 2.30 3.40 }'\n")
        self._stub(
            "sample",
            "output_path=''; while [ \"$#\" -gt 0 ]; do if [ \"$1\" = '-file' ]; then shift; output_path=\"$1\"; fi; shift; done; printf '%s' \"$HOST_SAMPLE_OUTPUT\" >\"$output_path\"\n",
        )
        self.env = os.environ.copy()
        self.env.update(
            {
                "TMPDIR": str(self.path),
                "WILTED_HOST_STATE_AUTOMATION_TOOL": str(self.stubs / "automation"),
                "WILTED_HOST_STATE_PS": str(self.stubs / "ps"),
                "WILTED_HOST_STATE_SYSCTL": str(self.stubs / "sysctl"),
                "WILTED_HOST_STATE_SAMPLE": str(self.stubs / "sample"),
                "HOST_AUTOMATION_OUTPUT": "Automation Mode is enabled.",
                "HOST_PROCESS_TABLE": self.process_table(),
                "HOST_SAMPLE_OUTPUT": "healthy stack",
            }
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _stub(self, name: str, body: str) -> None:
        path = self.stubs / name
        path.write_text(f"#!/bin/sh\nset -eu\n{body}", encoding="utf-8")
        path.chmod(0o700)

    @staticmethod
    def process_table(extra: str = "") -> str:
        rows = [
            "100 1 Ss 00:10 bash scripts/test-gate.sh",
            "101 100 S 00:09 bash scripts/test-gate-worker",
            "200 101 S 00:01 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test",
            "300 1 Ss 1-02:03:04 /usr/libexec/testmanagerd",
        ]
        if extra:
            rows.append(extra)
        return "\n".join(rows)

    def invoke(self, leg: str = "macos-ui-tests") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HOST_STATE), leg, str(ROOT_PID)],
            check=False,
            capture_output=True,
            text=True,
            env=self.env,
            timeout=8,
        )

    def test_reports_host_state_and_ignores_same_gate_xcodebuild(self) -> None:
        self.env["HOST_PROCESS_TABLE"] = self.process_table(
            "400 1 Ss 00:05 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -version"
        )

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("native.host-state "), 1)
        self.assertIn("automation=enabled", result.stderr)
        self.assertIn("xcodebuild_other=1", result.stderr)
        self.assertIn("testmanagerd_age_seconds=93784", result.stderr)
        self.assertIn("loadavg=1.20 2.30 3.40", result.stderr)
        self.assertIn("touchid_prompt=clear", result.stderr)
        self.assertNotIn("native.environment.refused", result.stderr)

    def test_refuses_another_hosted_xcodebuild(self) -> None:
        self.env["HOST_PROCESS_TABLE"] = self.process_table(
            "400 1 Ss 00:05 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test-without-building"
        )

        result = self.invoke("ios-unit-tests")

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("xcodebuild_other=1", result.stderr)
        self.assertIn("native.environment.refused reason=another-hosted-run", result.stderr)

    def test_parallel_gate_returns_preflight_status(self) -> None:
        self.env.update({
            "PATH": str(self.stubs) + os.pathsep + self.env["PATH"],
            "HOST_PROCESS_TABLE": "400 1 S 00:05 xcodebuild test",
            "NATIVE_SELF_TEST": "1",
            "WILTED_BOUNDED_ENTRY": "1",
            "WILTED_GATE_LEGS": "macos-unit-tests",
        })
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/test-gate.sh")], env=self.env,
            text=True, capture_output=True, timeout=45, check=False,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr.count("native.host-state "), 1)
        self.assertIn("reason=another-hosted-run", result.stderr)
        self.assertNotIn("native.leg.start name=macos-unit-tests", result.stderr)

    def test_refuses_pending_touch_id_prompt(self) -> None:
        self.env["HOST_SAMPLE_OUTPUT"] = (
            "XAMLocalAuthenticationProvider\nLAContext evaluatePolicy"
        )

        result = self.invoke("watchos-build")

        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("touchid_prompt=pending", result.stderr)
        self.assertIn(
            "native.environment.refused reason=automation-touch-id-prompt", result.stderr
        )

    def test_unavailable_automation_tool_reports_unknown(self) -> None:
        self._stub("automation", "exit 1\n")

        result = self.invoke()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("automation=unknown", result.stderr)

    def test_unavailable_process_table_reports_unknown(self) -> None:
        self._stub("ps", "exit 1\n")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("xcodebuild_other=unknown", result.stderr)
        self.assertIn("testmanagerd_age_seconds=unknown", result.stderr)
        self.assertIn("touchid_prompt=unknown", result.stderr)

    def test_unhosted_leg_needs_no_host_commands(self) -> None:
        self.env["WILTED_HOST_STATE_AUTOMATION_TOOL"] = str(self.path / "missing")
        self.env["WILTED_HOST_STATE_PS"] = str(self.path / "missing")

        result = self.invoke("wiltedkit-tests")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
