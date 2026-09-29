#!/usr/bin/env python3
"""Regression coverage for identity-set temporary-entry auditing."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "check-temp-leaks.py"
spec = importlib.util.spec_from_file_location("check_temp_leaks", CHECKER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TempLeakChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="temp-leak-check-")
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def save(self, name: str) -> Path:
        path = self.root / name
        module.write_snapshot(self.root, path)
        return path

    def test_new_entry_fails_even_when_baseline_shrinks(self) -> None:
        old = self.root / "wilted-old"
        old.mkdir()
        before = self.save("before.json")
        old.rmdir()
        (self.root / "wilted-new").mkdir()
        after = self.save("after.json")
        self.assertEqual(module.compare(before, after, "net-decrease"), 1)

    def test_unchanged_baseline_passes(self) -> None:
        (self.root / "wilted-existing").mkdir()
        before = self.save("before.json")
        after = self.save("after.json")
        self.assertEqual(module.compare(before, after, "stable"), 0)

    def test_symlink_is_an_identity_and_never_followed(self) -> None:
        target = self.root / "outside"
        target.mkdir()
        before = self.save("before.json")
        os.symlink(target, self.root / "wilted-link")
        after = self.save("after.json")
        self.assertEqual(module.compare(before, after, "symlink"), 1)
        payload = json.loads(after.read_text())
        self.assertTrue(payload["entries"][0]["symlink"])

    def test_missing_root_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "root-unverifiable"):
            module.snapshot(self.root / "missing")


if __name__ == "__main__":
    unittest.main()
