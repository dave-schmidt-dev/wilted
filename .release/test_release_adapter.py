"""Starter adoption check. Replace the expected failure after configuration."""

from __future__ import annotations

import unittest
from pathlib import Path

from release_tools.scaffold import audit_scaffold


class ReleaseAdapterAdoptionTests(unittest.TestCase):
    def test_project_adapter_is_configured(self) -> None:
        report = audit_scaffold(Path(__file__).resolve().parent.parent)
        self.assertEqual(report.status, "passed", report.as_dict())


if __name__ == "__main__":
    unittest.main(verbosity=2)
