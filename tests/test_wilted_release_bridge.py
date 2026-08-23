#!/usr/bin/env python3
"""Hermetic tests for the credential-free Wilted ASC bridge boundary."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "wilted_release_bridge", ROOT / "app" / "wilted_app_store_connect_bridge.py"
)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class IdentityAllocationTests(unittest.TestCase):
    def test_post_upload_proof_includes_a_fresh_observation_time(self) -> None:
        proof = BRIDGE._proof("compliance", "0.1.7-6", "build-6")

        self.assertEqual(proof["candidateId"], "0.1.7-6")
        self.assertEqual(proof["uploadedBuildIdentifier"], "build-6")
        self.assertRegex(proof["observedAt"], r"^\d{4}-\d{2}-\d{2}T")

    def test_tester_group_uses_the_live_bridge_bearer_for_candidate_lookup(self) -> None:
        request = lambda *_: {"data": []}
        with (
            patch.object(BRIDGE, "_request_context", return_value=("live-bearer", request)),
            patch.object(BRIDGE, "_candidate_context", return_value=("upload-1", "app-1", "build-1")) as context,
            patch.object(BRIDGE, "_internal_group", return_value="group-1"),
        ):
            BRIDGE.tester_group_candidate("0.1.8-10")

        self.assertEqual(context.call_args.kwargs["bearer"], "live-bearer")

    def test_notification_validates_a_created_resource_for_the_exact_build(self) -> None:
        requests: list[tuple[str, str, str, dict | None]] = []

        def request(method: str, path: str, bearer: str, body: dict | None) -> dict:
            requests.append((method, path, bearer, body))
            return {"data": {"type": "buildBetaNotifications", "id": "notification-1"}}

        with (
            patch.object(BRIDGE, "_request_context", return_value=("live-bearer", request)),
            patch.object(BRIDGE, "_candidate_context", return_value=("upload-1", "app-1", "build-1")),
        ):
            proof = BRIDGE.notification_candidate("0.1.8-10")

        self.assertEqual(requests, [("POST", "/buildBetaNotifications", "live-bearer", {"data": {"type": "buildBetaNotifications", "relationships": {"build": {"data": {"type": "builds", "id": "build-1"}}}}})])
        self.assertNotIn("alreadySent", proof)
        self.assertEqual(proof["deliveryReceiptSha256"], BRIDGE.digest({"buildIdentifier": "build-1", "notificationIdentifier": "notification-1"}))

    def test_notification_409_returns_an_already_sent_proof_for_the_exact_build(self) -> None:
        def conflict(*_: object) -> dict:
            raise BRIDGE.ASCError("app-store-connect-http-409")

        with (
            patch.object(BRIDGE, "_request_context", return_value=("live-bearer", conflict)),
            patch.object(BRIDGE, "_candidate_context", return_value=("upload-1", "app-1", "build-1")),
        ):
            proof = BRIDGE.notification_candidate("0.1.8-10")

        self.assertEqual(proof["candidateId"], "0.1.8-10")
        self.assertEqual(proof["uploadedBuildIdentifier"], "upload-1")
        self.assertTrue(proof["alreadySent"])
        self.assertEqual(proof["deliveryReceiptSha256"], BRIDGE.digest({"buildIdentifier": "build-1", "alreadySent": True}))

    def test_notification_non_409_error_remains_blocked(self) -> None:
        def unavailable(*_: object) -> dict:
            raise BRIDGE.ASCError("app-store-connect-network-failed")

        with (
            patch.object(BRIDGE, "_request_context", return_value=("live-bearer", unavailable)),
            patch.object(BRIDGE, "_candidate_context", return_value=("upload-1", "app-1", "build-1")),
        ):
            with self.assertRaisesRegex(BRIDGE.ASCError, "app-store-connect-network-failed"):
                BRIDGE.notification_candidate("0.1.8-10")

    def test_identity_allocation_evidence_may_advance_for_a_successor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "allocate-identity.json"
            BRIDGE.write_json(path, {"buildNumber": 5}, exclusive=True)
            BRIDGE.write_json(path, {"buildNumber": 6})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["buildNumber"], 6)

    def test_blocked_proofs_expose_a_safe_runner_code(self) -> None:
        captured: dict = {}
        with patch.object(BRIDGE, "write_json", side_effect=lambda _, payload: captured.update(payload)):
            self.assertEqual(BRIDGE.blocked("identity-allocation", None, "app-identity-count-0"), 3)
        self.assertEqual(captured["code"], "app-identity-count-0")

    def test_identity_allocation_uses_only_the_registered_app_and_highest_build(self) -> None:
        requests: list[str] = []

        def get(path: str, _: str) -> dict:
            requests.append(path)
            if path.startswith("/apps?"):
                return {"data": [{"id": "app-1", "attributes": {"bundleId": BRIDGE.BUNDLE_ID}}]}
            return {"data": [
                {"id": "build-3", "attributes": {"version": "3"}, "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "pre-17"}}}},
                {"id": "build-9", "attributes": {"version": "9"}, "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "pre-16"}}}},
            ], "included": [
                {"type": "preReleaseVersions", "id": "pre-17", "attributes": {"version": "0.1.7"}},
                {"type": "preReleaseVersions", "id": "pre-16", "attributes": {"version": "0.1.6"}},
            ]}

        with tempfile.TemporaryDirectory() as temporary:
            proof = BRIDGE.allocate_identity(get=get, root=Path(temporary))

        self.assertEqual(proof["productKey"], "wilted-ios")
        self.assertEqual(proof["marketingVersion"], "0.2.0")
        self.assertEqual(proof["buildNumber"], 10)
        self.assertEqual(proof["remoteHighestMarketingVersion"], "0.1.7")
        self.assertEqual(proof["remoteHighestBuildNumber"], 9)
        self.assertRegex(proof["responseSha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(len(requests), 2)
        self.assertTrue(requests[0].startswith("/apps?filter[bundleId]=com.zerodelta.wilted.ios"))
        self.assertIn("filter%5Bapp%5D=app-1", requests[1])
        self.assertIn("include=preReleaseVersion", requests[1])

    def test_identity_allocation_reports_actual_remote_marketing_version(self) -> None:
        def get(path: str, _: str) -> dict:
            if path.startswith("/apps?"):
                return {"data": [{"id": "app-1", "attributes": {"bundleId": BRIDGE.BUNDLE_ID}}]}
            return {
                "data": [{
                    "id": "build-7",
                    "attributes": {"version": "7"},
                    "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "pre-17"}}},
                }],
                "included": [{"type": "preReleaseVersions", "id": "pre-17", "attributes": {"version": "0.1.7"}}],
            }

        with tempfile.TemporaryDirectory() as temporary:
            proof = BRIDGE.allocate_identity(get=get, root=Path(temporary))

        self.assertEqual(proof["marketingVersion"], "0.2.0")
        self.assertEqual(proof["buildNumber"], 8)
        self.assertEqual(proof["remoteHighestMarketingVersion"], "0.1.7")
        self.assertEqual(proof["remoteHighestBuildNumber"], 7)

    def test_identity_allocation_reports_a_redacted_app_count(self) -> None:
        with self.assertRaisesRegex(BRIDGE.ASCError, "app-identity-count-0"):
            BRIDGE._one_app({"data": []})

    def test_identity_allocation_rejects_non_positive_build(self) -> None:
        with self.assertRaisesRegex(BRIDGE.ASCError, "build-response-invalid"):
            BRIDGE._next_build({"data": [{"id": "build-0", "attributes": {"version": "0"}}]})

    def test_identity_allocation_advances_past_a_locally_failed_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / ".git/release-state/wilted-ios/candidates/0.2.0-1/manifest.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({"immutable": True, "release": {"marketingVersion": "0.2.0", "buildNumber": "1"}}), encoding="utf-8")

            def get(path: str, _: str) -> dict:
                if path.startswith("/apps?"):
                    return {"data": [{"id": "app-1", "attributes": {"bundleId": BRIDGE.BUNDLE_ID}}]}
                return {"data": []}

            proof = BRIDGE.allocate_identity(get=get, root=root)

        self.assertEqual(proof["buildNumber"], 2)
        self.assertEqual(proof["remoteHighestBuildNumber"], 0)
        self.assertIsNone(proof["remoteHighestMarketingVersion"])

    def test_app_registration_uses_fixed_metadata_after_a_bundle_id_check(self) -> None:
        requests: list[tuple[str, str, dict | None]] = []

        def request(method: str, path: str, _: str, body: dict | None) -> dict:
            requests.append((method, path, body))
            if path.startswith("/apps?"):
                return {"data": []}
            if path.startswith("/bundleIds?"):
                return {"data": [{"id": "bundle-1", "attributes": {"identifier": BRIDGE.BUNDLE_ID}}]}
            return {"data": {"id": "app-1", "attributes": {"bundleId": BRIDGE.BUNDLE_ID}}}

        result = BRIDGE.register_app(request=request)

        self.assertEqual(result["result"], "registered")
        self.assertEqual(requests[-1][0:2], ("POST", "/apps"))
        self.assertEqual(requests[-1][2]["data"]["attributes"], {"name": "Wilted", "bundleId": BRIDGE.BUNDLE_ID, "sku": "wilted-ios", "primaryLocale": "en-US"})

    def test_app_registration_rejects_an_inexact_bundle_id_response(self) -> None:
        def request(method: str, path: str, _: str, body: dict | None) -> dict:
            del method, body
            if path.startswith("/apps?"):
                return {"data": []}
            return {"data": [{"id": "bundle-other", "attributes": {"identifier": "com.zerodelta.other"}}]}

        with self.assertRaisesRegex(BRIDGE.ASCError, "bundle-id-exact-count-0"):
            BRIDGE.register_app(request=request)

    def test_upload_uses_only_typed_https_ranges_then_commits_the_ipa_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = "0.1.6-1"
            manifest = root / ".git/release-state/wilted-ios/candidates" / candidate / "manifest.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({"formatVersion": 2, "immutable": True, "productIdentifier": "wilted-ios", "candidateId": candidate, "release": {"frozen": True, "marketingVersion": "0.1.6", "buildNumber": 1}}), encoding="utf-8")
            ipa = root / ".release-state/artifacts" / candidate / "WiltediOS.ipa"
            ipa.parent.mkdir(parents=True)
            ipa.write_bytes(b"abcdef")
            requests: list[tuple[str, str, dict | None]] = []
            binary: list[tuple[str, str, bytes, dict]] = []

            def request(method: str, path: str, _: str, body: dict | None) -> dict:
                requests.append((method, path, body))
                if path.startswith("/apps?"):
                    return {"data": [{"type": "apps", "id": "app-1", "attributes": {"bundleId": BRIDGE.BUNDLE_ID}}]}
                if path == "/buildUploads":
                    return {"data": {"type": "buildUploads", "id": "upload-1"}}
                if path == "/buildUploadFiles":
                    return {"data": {"type": "buildUploadFiles", "id": "file-1", "attributes": {"uploadOperations": [{"url": "https://upload.example/one", "method": "PUT", "requestHeaders": [{"name": "x-upload", "value": "one"}], "offset": 0, "length": 3}, {"url": "https://upload.example/two", "method": "PUT", "requestHeaders": [{"name": "x-upload", "value": "two"}], "offset": 3, "length": 3}]}}}
                self.assertEqual(path, "/buildUploadFiles/file-1")
                return {"data": {"type": "buildUploadFiles", "id": "file-1"}}

            def put(method: str, url: str, payload: bytes, headers: dict) -> int:
                binary.append((method, url, payload, headers))
                return 200

            proof = BRIDGE.upload_candidate(candidate, root=root, request=request, binary_request=put)

        self.assertEqual(proof["uploadedBuildIdentifier"], "upload-1")
        self.assertEqual(proof["signedArtifactSha256"], hashlib.sha256(b"abcdef").hexdigest())
        self.assertEqual(binary, [("PUT", "https://upload.example/one", b"abc", {"x-upload": "one"}), ("PUT", "https://upload.example/two", b"def", {"x-upload": "two"})])
        self.assertEqual(requests[-1], ("PATCH", "/buildUploadFiles/file-1", {"data": {"type": "buildUploadFiles", "id": "file-1", "attributes": {"uploaded": True, "sourceFileChecksums": {"file": {"algorithm": "MD5", "hash": hashlib.md5(b"abcdef").hexdigest()}}}}}))

    def test_processing_polls_only_the_uploaded_candidate_exact_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = "0.1.7-1"
            manifest = root / ".git/release-state/wilted-ios/candidates" / candidate / "manifest.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({"formatVersion": 2, "immutable": True, "productIdentifier": "wilted-ios", "candidateId": candidate, "release": {"frozen": True, "marketingVersion": "0.1.7", "buildNumber": 1}}), encoding="utf-8")
            proof_path = root / ".release-state/evidence" / candidate / "upload.json"
            proof_path.parent.mkdir(parents=True)
            proof_path.write_text(json.dumps({"result": "passed", "candidateId": candidate, "uploadedBuildIdentifier": "upload-1"}), encoding="utf-8")
            requests: list[str] = []

            def request(method: str, path: str, _: str, body: dict | None) -> dict:
                self.assertEqual(method, "GET")
                self.assertIsNone(body)
                requests.append(path)
                if path.startswith("/apps?"):
                    return {"data": [{"type": "apps", "id": "app-1", "attributes": {"bundleId": BRIDGE.BUNDLE_ID}}]}
                if path == "/buildUploads/upload-1":
                    return {"data": {"type": "buildUploads", "id": "upload-1", "attributes": {"state": {"state": "COMPLETE"}}}}
                return {"data": [{"type": "builds", "id": "build-1", "attributes": {"version": "1", "processingState": "VALID"}, "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "pre-1"}}}}], "included": [{"type": "preReleaseVersions", "id": "pre-1", "attributes": {"version": "0.1.7"}}]}

            proof = BRIDGE.process_candidate(candidate, root=root, request=request, sleep=lambda _: self.fail("must not sleep"))

        self.assertEqual(proof["uploadedBuildIdentifier"], "upload-1")
        self.assertEqual(proof["operationClass"], "processing")
        self.assertEqual(len(requests), 3)
        self.assertEqual(requests[1], "/buildUploads/upload-1")
        self.assertIn("filter%5Bversion%5D=1", requests[2])


if __name__ == "__main__":
    unittest.main()
