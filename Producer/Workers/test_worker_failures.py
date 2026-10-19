"""Tests for worker failure modes and termination handling."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from worker_test_support import WORKER_PATH


class WorkerTerminationTests(unittest.TestCase):
    def test_sigterm_unwinds_and_runs_finally_cleanup_with_status_143(self):
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            temp_path = Path(tf.name)
        self.addCleanup(temp_path.unlink, missing_ok=True)

        worker_dir = WORKER_PATH.parent
        child_code = f"""
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, {str(worker_dir)!r})
from wilted_pipeline import _terminate

signal.signal(signal.SIGTERM, _terminate)

temp_path = Path({str(temp_path)!r})
temp_path.write_text("running")

sys.stdout.write("ready\\n")
sys.stdout.flush()

try:
    while True:
        time.sleep(0.1)
finally:
    temp_path.unlink(missing_ok=True)
"""
        proc = subprocess.Popen(
            [sys.executable, "-c", child_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self._reap_process, proc)

        ready = proc.stdout.readline()
        self.assertEqual(ready.strip(), "ready")
        self.assertTrue(temp_path.exists())

        proc.terminate()
        returncode = proc.wait(timeout=5)

        self.assertEqual(returncode, 143)
        self.assertFalse(temp_path.exists())

    def test_main_installs_sigterm_handler(self):
        work = tempfile.TemporaryDirectory(prefix="wilted-sigterm-handler-")
        self.addCleanup(work.cleanup)
        request = json.dumps({"workDir": work.name})
        worker_dir = WORKER_PATH.parent
        child_code = f"""
import io
import signal
import sys
from unittest.mock import patch

sys.path.insert(0, {str(worker_dir)!r})
import wilted_pipeline

with patch("sys.stdin", io.StringIO({request!r})), patch("sys.stdout", io.StringIO()):
    wilted_pipeline.main()

handler = signal.getsignal(signal.SIGTERM)
assert handler is wilted_pipeline._terminate, f"expected _terminate but got {{handler}}"
sys.stdout.write("OK\\n")
sys.stdout.flush()
"""
        proc = subprocess.Popen(
            [sys.executable, "-c", child_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self._reap_process, proc)
        stdout, stderr = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, f"Child failed with stderr: {stderr}")
        self.assertIn("OK", stdout)

    @staticmethod
    def _reap_process(proc: subprocess.Popen) -> None:
        if proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if proc.stdout is not None:
            proc.stdout.close()
        if proc.stderr is not None:
            proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
