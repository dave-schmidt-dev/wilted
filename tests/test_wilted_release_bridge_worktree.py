#!/usr/bin/env python3
"""The Wilted ASC bridge reads frozen candidates through the git common directory."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "wilted_release_bridge", ROOT / "app" / "wilted_app_store_connect_bridge.py"
)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class LinkedWorktreeStateTests(unittest.TestCase):
    """Frozen candidates live in the git common directory, which a linked worktree shares."""

    @staticmethod
    def _git(cwd: Path, *args: str) -> None:
        identity = ("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid")
        subprocess.run(["git", *identity, "-C", str(cwd), *args], check=True, capture_output=True)

    def test_a_linked_worktree_reads_candidates_from_the_owner_common_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(temporary).resolve() / "owner"
            linked = Path(temporary).resolve() / "release-checkout"
            owner.mkdir()
            self._git(owner, "init", "-q")
            self._git(owner, "commit", "-q", "--allow-empty", "-m", "fixture")
            self._git(owner, "worktree", "add", "-q", "--detach", str(linked))
            self.assertTrue((linked / ".git").is_file())
            version = BRIDGE.marketing_version()
            candidate = owner / ".git/release-state/wilted-ios/candidates" / f"{version}-7"
            candidate.mkdir(parents=True)
            (candidate / "manifest.json").write_text(
                json.dumps({"formatVersion": 2, "immutable": True, "productIdentifier": "wilted-ios", "candidateId": f"{version}-7", "release": {"frozen": True, "marketingVersion": version, "buildNumber": 7}}),
                encoding="utf-8",
            )

            self.assertEqual(BRIDGE.candidates_dir(linked), owner / ".git/release-state/wilted-ios/candidates")
            self.assertEqual(BRIDGE._local_highest_build(version, root=linked), 7)
            self.assertEqual(BRIDGE._candidate_release(f"{version}-7", root=linked), (version, "7"))

    def test_outside_a_git_repository_the_literal_git_directory_is_used(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(BRIDGE.candidates_dir(root), root / ".git/release-state/wilted-ios/candidates")


if __name__ == "__main__":
    unittest.main()
