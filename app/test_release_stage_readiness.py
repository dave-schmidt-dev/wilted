#!/usr/bin/env python3
"""Hermetic unit tests for Wilted v2 readiness and local-gate proofs."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import release_stage_readiness

ROOT = Path(__file__).resolve().parents[1]


class ReleaseStageReadinessV2Tests(unittest.TestCase):
    def make_manifest_raw(
        self,
        candidate_id: str = "0.2.2-1",
        source_sha256: str = "a" * 64,
        build_number: str = "1",
    ) -> bytes:
        return json.dumps(
            {
                "formatVersion": 2,
                "immutable": True,
                "productIdentifier": "wilted-ios",
                "candidateId": candidate_id,
                "sourceSnapshot": {"sha256": source_sha256},
                "release": {"buildNumber": build_number, "frozen": True},
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    def write_manifest_file(
        self,
        root: Path,
        candidate_id: str = "0.2.2-1",
        source_sha256: str = "a" * 64,
        build_number: str = "1",
    ) -> Path:
        manifest_path = (
            root
            / "release-state"
            / "wilted-ios"
            / "candidates"
            / candidate_id
            / "manifest.json"
        )
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_bytes(
            self.make_manifest_raw(
                candidate_id=candidate_id,
                source_sha256=source_sha256,
                build_number=build_number,
            )
        )
        return manifest_path

    def test_v2_proofs_are_content_bound_and_not_time_bound(self) -> None:
        raw_manifest = self.make_manifest_raw(
            candidate_id="0.2.2-5", source_sha256="b" * 64
        )
        candidate = "0.2.2-5"
        source = "b" * 64

        readiness_proof = release_stage_readiness.build_proof(
            raw_manifest,
            candidate=candidate,
            source=source,
            local_gate=False,
            observed_at="2026-08-24T12:00:00Z",
        )
        local_gate_proof = release_stage_readiness.build_proof(
            raw_manifest,
            candidate=candidate,
            source=source,
            local_gate=True,
            observed_at="2026-08-24T12:00:00Z",
        )

        for proof, schema, op_class in (
            (readiness_proof, "release.proof.readiness.v2", "readiness"),
            (local_gate_proof, "release.proof.local-gate.v2", "localGate"),
        ):
            self.assertEqual(proof["proofVersion"], "2.0.0")
            self.assertEqual(proof["proofSchema"], schema)
            self.assertEqual(proof["operationClass"], op_class)
            self.assertEqual(proof["candidateId"], candidate)
            self.assertEqual(proof["sourceDigest"], source)
            self.assertEqual(proof["result"], "passed")
            if op_class == "localGate":
                self.assertEqual(proof["configuration"], "Production")
            self.assertEqual(proof["observedAt"], "2026-08-24T12:00:00Z")

            # Must not contain time-bound expiration fields
            self.assertNotIn("issuedAt", proof)
            self.assertNotIn("expiresAt", proof)

            # Must contain deterministic 64-character SHA-256 execution closure.
            self.assertIn("environmentClosureSha256", proof)
            self.assertRegex(proof["environmentClosureSha256"], r"^[0-9a-f]{64}$")
            expected_closure = release_stage_readiness.environment_closure(
                schema,
                configuration="Production",
                contract_revision=release_stage_readiness.CONTRACT_REVISION,
            )
            self.assertEqual(proof["environmentClosureSha256"], expected_closure)

        # Local gate proof must retain scope and material evidence
        self.assertEqual(local_gate_proof["scope"], "authoritative")
        expected_local_gate_material = b"\0".join(
            (raw_manifest, b"Production", b"authoritative")
        )
        self.assertEqual(
            local_gate_proof["evidenceSha256"],
            hashlib.sha256(expected_local_gate_material).hexdigest(),
        )

        # Readiness proof must retain raw manifest evidence
        self.assertEqual(
            readiness_proof["evidenceSha256"],
            hashlib.sha256(raw_manifest).hexdigest(),
        )

        # Proof identity across observation times remains content-bound
        later_readiness = release_stage_readiness.build_proof(
            raw_manifest,
            candidate=candidate,
            source=source,
            local_gate=False,
            observed_at="2026-08-24T18:00:00Z",
        )
        self.assertEqual(
            readiness_proof["environmentClosureSha256"],
            later_readiness["environmentClosureSha256"],
        )
        self.assertEqual(
            readiness_proof["evidenceSha256"], later_readiness["evidenceSha256"]
        )
        self.assertEqual(
            readiness_proof["sourceDigest"], later_readiness["sourceDigest"]
        )
        self.assertEqual(readiness_proof["candidateId"], later_readiness["candidateId"])

    def test_adapter_declares_only_local_v2_schemas(self) -> None:
        adapter_path = ROOT / ".release" / "release-adapter.json"
        adapter = json.loads(adapter_path.read_text(encoding="utf-8"))
        operations = adapter["operations"]

        local_ops = {"readiness", "local-gate"}
        for op in operations:
            op_id = op["id"]
            proof_schema = op.get("proofSchema", "")
            if op_id in local_ops:
                self.assertTrue(
                    proof_schema.endswith(".v2"),
                    f"Operation {op_id} must declare a v2 proofSchema, got {proof_schema}",
                )
                if op_id == "readiness":
                    self.assertEqual(proof_schema, "release.proof.readiness.v2")
                elif op_id == "local-gate":
                    self.assertEqual(proof_schema, "release.proof.local-gate.v2")
            else:
                self.assertFalse(
                    proof_schema.endswith(".v2"),
                    f"Non-local operation {op_id} must not declare a v2 proofSchema, got {proof_schema}",
                )
                self.assertTrue(
                    proof_schema.endswith(".v1"),
                    f"Non-local operation {op_id} should declare a v1 proofSchema, got {proof_schema}",
                )

    def test_environment_closure_is_sensitive_to_schema_config_and_contract(
        self,
    ) -> None:
        base = release_stage_readiness.environment_closure(
            "release.proof.readiness.v2",
            configuration="Production",
            contract_revision="wilted-ios-v2",
        )
        different_schema = release_stage_readiness.environment_closure(
            "release.proof.local-gate.v2",
            configuration="Production",
            contract_revision="wilted-ios-v2",
        )
        different_config = release_stage_readiness.environment_closure(
            "release.proof.readiness.v2",
            configuration="Staging",
            contract_revision="wilted-ios-v2",
        )
        different_contract = release_stage_readiness.environment_closure(
            "release.proof.readiness.v2",
            configuration="Production",
            contract_revision="wilted-ios-v3",
        )

        self.assertNotEqual(base, different_schema)
        self.assertNotEqual(base, different_config)
        self.assertNotEqual(base, different_contract)

    def test_manifest_validation_rejects_symlink_or_mismatched_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidates_root = root / "release-state" / "wilted-ios" / "candidates"
            manifest = self.write_manifest_file(root, candidate_id="0.2.2-1")

            # Valid manifest passes
            validated = release_stage_readiness.validate_manifest_path(
                manifest, candidates_root=candidates_root
            )
            self.assertEqual(validated, manifest.resolve())

            # Symlink is rejected
            symlink_manifest = root / "symlink_manifest.json"
            symlink_manifest.symlink_to(manifest)
            with self.assertRaises(ValueError):
                release_stage_readiness.validate_manifest_path(
                    symlink_manifest, candidates_root=candidates_root
                )

            # Outside candidate root is rejected
            external_manifest = root / "other" / "0.2.2-1" / "manifest.json"
            external_manifest.parent.mkdir(parents=True)
            external_manifest.write_bytes(manifest.read_bytes())
            with self.assertRaises(ValueError):
                release_stage_readiness.validate_manifest_path(
                    external_manifest, candidates_root=candidates_root
                )

            # Non manifest.json filename is rejected
            wrong_name = manifest.parent / "not_manifest.json"
            wrong_name.write_bytes(manifest.read_bytes())
            with self.assertRaises(ValueError):
                release_stage_readiness.validate_manifest_path(
                    wrong_name, candidates_root=candidates_root
                )

    def test_parse_manifest_validates_candidate_and_source(self) -> None:
        valid_raw = self.make_manifest_raw("0.2.2-1", "c" * 64)
        candidate, source = release_stage_readiness.parse_manifest(valid_raw)
        self.assertEqual(candidate, "0.2.2-1")
        self.assertEqual(source, "c" * 64)

        # Invalid JSON
        with self.assertRaises(ValueError):
            release_stage_readiness.parse_manifest(b"invalid-json")

        # Missing or bad candidateId
        with self.assertRaises(ValueError):
            release_stage_readiness.parse_manifest(
                json.dumps({"sourceSnapshot": {"sha256": "c" * 64}}).encode()
            )

        # Short sha256
        with self.assertRaises(ValueError):
            release_stage_readiness.parse_manifest(
                json.dumps(
                    {"candidateId": "0.2.2-1", "sourceSnapshot": {"sha256": "short"}}
                ).encode()
            )

    def test_main_emits_readiness_proof_with_atomic_0600_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.write_manifest_file(root, candidate_id="0.2.2-1")
            candidates_root = root / "release-state" / "wilted-ios" / "candidates"

            with (
                patch.dict(os.environ, {"READINESS_MANIFEST": str(manifest)}),
                patch.object(
                    release_stage_readiness,
                    "git_common_candidates_dir",
                    return_value=candidates_root,
                ),
            ):
                result = release_stage_readiness.main([], root=root)

            self.assertEqual(result, 0)
            proof_file = (
                root / ".release-state" / "evidence" / "0.2.2-1" / "readiness.json"
            )
            self.assertTrue(proof_file.exists())
            proof = json.loads(proof_file.read_text(encoding="utf-8"))
            self.assertEqual(proof["proofSchema"], "release.proof.readiness.v2")
            self.assertEqual(proof["operationClass"], "readiness")
            self.assertEqual(proof["candidateId"], "0.2.2-1")
            self.assertIn("environmentClosureSha256", proof)
            self.assertNotIn("issuedAt", proof)
            self.assertNotIn("expiresAt", proof)

            # Check 0600 permissions
            mode = stat.S_IMODE(proof_file.stat().st_mode)
            self.assertEqual(mode, 0o600)

    def test_main_emits_local_gate_proof_with_atomic_0600_write(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.write_manifest_file(root, candidate_id="0.2.2-2")
            candidates_root = root / "release-state" / "wilted-ios" / "candidates"

            with (
                patch.dict(os.environ, {"READINESS_MANIFEST": str(manifest)}),
                patch.object(
                    release_stage_readiness,
                    "git_common_candidates_dir",
                    return_value=candidates_root,
                ),
            ):
                result = release_stage_readiness.main(["--local-gate"], root=root)

            self.assertEqual(result, 0)
            proof_file = (
                root / ".release-state" / "evidence" / "0.2.2-2" / "local-gate.json"
            )
            self.assertTrue(proof_file.exists())
            proof = json.loads(proof_file.read_text(encoding="utf-8"))
            self.assertEqual(proof["proofSchema"], "release.proof.local-gate.v2")
            self.assertEqual(proof["operationClass"], "localGate")
            self.assertEqual(proof["candidateId"], "0.2.2-2")
            self.assertEqual(proof["scope"], "authoritative")
            self.assertEqual(proof["configuration"], "Production")
            self.assertIn("environmentClosureSha256", proof)
            self.assertNotIn("issuedAt", proof)
            self.assertNotIn("expiresAt", proof)

            mode = stat.S_IMODE(proof_file.stat().st_mode)
            self.assertEqual(mode, 0o600)

    def test_main_rejects_invalid_arguments(self) -> None:
        self.assertEqual(release_stage_readiness.main(["--unknown"]), 4)
        self.assertEqual(release_stage_readiness.main(["--local-gate", "extra"]), 4)

    def test_main_fails_on_candidate_directory_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self.write_manifest_file(root, candidate_id="0.2.2-1")
            candidates_root = root / "release-state" / "wilted-ios" / "candidates"

            # Modify manifest content to have a different candidateId than the parent dir
            mismatched_raw = self.make_manifest_raw(candidate_id="0.2.2-other")
            manifest.write_bytes(mismatched_raw)

            with (
                patch.dict(os.environ, {"READINESS_MANIFEST": str(manifest)}),
                patch.object(
                    release_stage_readiness,
                    "git_common_candidates_dir",
                    return_value=candidates_root,
                ),
            ):
                result = release_stage_readiness.main([], root=root)

            self.assertEqual(result, 4)


if __name__ == "__main__":
    unittest.main()
