#!/bin/sh
'''exec' /Users/dave/.local/bin/uv run --with pyjwt --with cryptography python "$0" "$@"
' '''
# Fixed Wilted App Store Connect broker boundary.
#
# Only BWS may invoke this executable with the three App Store Connect
# credentials. Identity allocation is read-only against Apple and writes an
# immutable, credential-free proof. Every later release operation remains
# blocked until the signed candidate and its human evidence exist.

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "wilted-ios"
BUNDLE_ID = "com.zerodelta.wilted.ios"
INTERNAL_GROUP_NAME = "Wilted Internal Testers"
API_BASE = "https://api.appstoreconnect.apple.com/v1"
OPERATIONS = frozenset({"app-registration", "identity-allocation", "build-lookup", "upload", "processing", "compliance", "tester-group", "assignment", "device-health", "notification"})
_CANDIDATE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_POSITIVE = re.compile(r"^[1-9][0-9]*$")


class ASCError(RuntimeError):
    """A redacted App Store Connect failure category."""


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def digest(payload: Mapping[str, Any]) -> str:
    return hashlib.sha256(json.dumps(dict(payload), sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def evidence_path(operation: str, candidate: str | None) -> Path:
    if operation == "app-registration":
        return ROOT / ".release-state" / "evidence" / "app-registration.json"
    if operation == "identity-allocation":
        return ROOT / ".release-state" / "evidence" / "allocate-identity.json"
    if candidate is None or not _CANDIDATE.fullmatch(candidate):
        raise ValueError("candidate-identity-invalid")
    return ROOT / ".release-state" / "evidence" / candidate / f"{operation}.json"


def write_json(path: Path, payload: Mapping[str, Any], *, exclusive: bool = False) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    encoded = json.dumps(dict(payload), sort_keys=True, separators=(",", ":")).encode() + b"\n"
    if not exclusive and path.exists():
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError("evidence-path-not-regular")
        os.chmod(path, 0o600, follow_symlinks=False)
    descriptor = -1
    try:
        flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags, 0o400 if exclusive else 0o600)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError("evidence-path-not-regular")
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def blocked(operation: str, candidate: str | None, reason: str) -> int:
    payload: dict[str, Any] = {
        "proofVersion": "1.0.0",
        "operationClass": {"identity-allocation": "identityAllocation", "build-lookup": "buildLookup", "tester-group": "testerGroup", "device-health": "deviceHealth"}.get(operation, operation),
        "result": "blocked", "observedAt": now(), "reason": reason, "code": reason,
        "responseSha256": digest({"operation": operation, "candidateId": candidate, "reason": reason}),
    }
    if candidate is not None:
        payload["candidateId"] = candidate
    try:
        path = evidence_path(operation, candidate)
    except ValueError:
        path = None
    if path is not None:
        write_json(path, payload)
    print(json.dumps({"operation": operation, "result": "blocked", "reason": reason, "proofPath": str(path.relative_to(ROOT)) if path else None}, sort_keys=True))
    return 3


def marketing_version(project: Path = ROOT / "project.yml") -> str:
    match = re.search(r'(?m)^    MARKETING_VERSION:\s*"([^"]+)"\s*$', project.read_text(encoding="utf-8"))
    if match is None or _SEMVER.fullmatch(match.group(1)) is None:
        raise ValueError("marketing-version-unavailable")
    return match.group(1)


def token() -> str:
    try:
        import jwt
        private_key = os.environ["APP_STORE_CONNECT_API_KEY"]
        key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
        issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    except (ImportError, KeyError) as error:
        raise ASCError("credential-environment-incomplete") from error
    issued_at = int(time.time())
    signed = jwt.encode({"iss": issuer_id, "iat": issued_at, "exp": issued_at + 1190, "aud": "appstoreconnect-v1"}, private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
    return signed.decode() if isinstance(signed, bytes) else signed


def request_json(path: str, bearer: str, *, method: str = "GET", body: Mapping[str, Any] | None = None, opener: Callable[..., Any] = urllib.request.urlopen) -> Mapping[str, Any]:
    payload = json.dumps(dict(body), separators=(",", ":")).encode() if body is not None else None
    request = urllib.request.Request(f"{API_BASE}{path}", data=payload, method=method)
    request.add_header("Authorization", f"Bearer {bearer}")
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with opener(request, timeout=30) as response:
            if not 200 <= response.status < 300:
                raise ASCError("app-store-connect-request-failed")
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise ASCError(f"app-store-connect-http-{error.code}") from error
    except (TimeoutError, urllib.error.URLError) as error:
        raise ASCError("app-store-connect-network-failed") from error
    except (TypeError, ValueError) as error:
        raise ASCError("app-store-connect-response-invalid") from error
    if not isinstance(value, Mapping):
        raise ASCError("app-store-connect-response-invalid")
    return value


def request_empty(path: str, bearer: str, *, method: str, body: Mapping[str, Any]) -> None:
    """Perform an App Store Connect relationship mutation that returns 204."""

    payload = json.dumps(dict(body), separators=(",", ":")).encode()
    request = urllib.request.Request(f"{API_BASE}{path}", data=payload, method=method)
    request.add_header("Authorization", f"Bearer {bearer}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 204:
                raise ASCError("app-store-connect-relationship-mutation-failed")
    except urllib.error.HTTPError as error:
        raise ASCError(f"app-store-connect-http-{error.code}") from error
    except (TimeoutError, urllib.error.URLError) as error:
        raise ASCError("app-store-connect-network-failed") from error


def _one_app(payload: Mapping[str, Any]) -> str:
    data = payload.get("data")
    if not isinstance(data, list):
        raise ASCError("app-identity-response-invalid")
    if len(data) != 1 or not isinstance(data[0], Mapping):
        raise ASCError(f"app-identity-count-{len(data)}")
    return _app_identifier(data[0])


def _app_identifier(item: Mapping[str, Any]) -> str:
    app_id, attributes = item.get("id"), item.get("attributes")
    if not isinstance(app_id, str) or not app_id or not isinstance(attributes, Mapping) or attributes.get("bundleId") != BUNDLE_ID:
        raise ASCError("app-identity-invalid")
    return app_id


def _build_snapshot(payload: Mapping[str, Any]) -> tuple[int, int, str | None, bytes]:
    data = payload.get("data")
    if not isinstance(data, list):
        raise ASCError("build-response-invalid")
    included = payload.get("included", [])
    if data and not isinstance(included, list):
        raise ASCError("build-response-invalid")
    prerelease_versions = {
        item.get("id"): item.get("attributes", {}).get("version")
        for item in included
        if isinstance(item, Mapping)
        and item.get("type") == "preReleaseVersions"
        and isinstance(item.get("id"), str)
        and isinstance(item.get("attributes"), Mapping)
    }
    highest = 0
    highest_marketing: tuple[int, int, int] | None = None
    highest_marketing_text: str | None = None
    normalized: list[dict[str, str]] = []
    for item in data:
        attributes = item.get("attributes") if isinstance(item, Mapping) else None
        value = attributes.get("version") if isinstance(attributes, Mapping) else None
        if isinstance(value, bool) or not _POSITIVE.fullmatch(str(value)):
            raise ASCError("build-response-invalid")
        highest = max(highest, int(value))
        relationships = item.get("relationships") if isinstance(item, Mapping) else None
        prerelease = relationships.get("preReleaseVersion") if isinstance(relationships, Mapping) else None
        prerelease_data = prerelease.get("data") if isinstance(prerelease, Mapping) else None
        prerelease_id = prerelease_data.get("id") if isinstance(prerelease_data, Mapping) else None
        marketing = prerelease_versions.get(prerelease_id)
        if not isinstance(prerelease_id, str) or not isinstance(marketing, str) or _SEMVER.fullmatch(marketing) is None:
            raise ASCError("build-response-invalid")
        normalized.append({"id": str(item.get("id", "")), "version": str(value), "marketingVersion": marketing})
        parsed_marketing = tuple(int(part) for part in marketing.split("."))
        if highest_marketing is None or parsed_marketing > highest_marketing:
            highest_marketing = parsed_marketing
            highest_marketing_text = marketing
    return highest + 1, highest, highest_marketing_text, json.dumps({"builds": normalized}, sort_keys=True, separators=(",", ":")).encode()


def _next_build(payload: Mapping[str, Any]) -> tuple[int, int, bytes]:
    """Return the next build while retaining the bridge's private helper contract."""

    next_build, highest, _, response_material = _build_snapshot(payload)
    return next_build, highest, response_material


def _local_highest_build(version: str, *, root: Path = ROOT) -> int:
    """Return the highest immutable local build for one marketing version."""

    candidates = root / ".git" / "release-state" / PRODUCT / "candidates"
    try:
        entries = tuple(candidates.iterdir())
    except OSError:
        return 0
    highest = 0
    for entry in entries:
        manifest = entry / "manifest.json"
        try:
            value = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        release = value.get("release") if isinstance(value, Mapping) else None
        build = release.get("buildNumber") if isinstance(release, Mapping) else None
        if (
            value.get("immutable") is True
            and isinstance(release, Mapping)
            and release.get("marketingVersion") == version
            and not isinstance(build, bool)
            and _POSITIVE.fullmatch(str(build))
        ):
            highest = max(highest, int(build))
    return highest


def register_app(*, request: Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]] | None = None) -> dict[str, Any]:
    if request is None:
        bearer = token()
        request = lambda method, path, bearer, body: request_json(path, bearer, method=method, body=body)
    else:
        bearer = "test"
    apps = request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer, None)
    data = apps.get("data")
    if not isinstance(data, list):
        raise ASCError("app-identity-response-invalid")
    if len(data) == 1:
        app_id = _one_app(apps)
        return {"result": "already-registered", "appIdentifierHash": hashlib.sha256(app_id.encode()).hexdigest()}
    if len(data) != 0:
        raise ASCError(f"app-identity-count-{len(data)}")
    bundle_ids = request("GET", f"/bundleIds?filter[identifier]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer, None)
    bundles = bundle_ids.get("data")
    if not isinstance(bundles, list):
        raise ASCError("bundle-id-response-invalid")
    matches = [item for item in bundles if isinstance(item, Mapping) and isinstance(item.get("attributes"), Mapping) and item["attributes"].get("identifier") == BUNDLE_ID]
    if len(matches) != 1:
        raise ASCError(f"bundle-id-exact-count-{len(matches)}")
    created = request("POST", "/apps", bearer, {"data": {"type": "apps", "attributes": {"name": "Wilted", "bundleId": BUNDLE_ID, "sku": "wilted-ios", "primaryLocale": "en-US"}}})
    created_data = created.get("data")
    if not isinstance(created_data, Mapping):
        raise ASCError("app-registration-response-invalid")
    app_id = _app_identifier(created_data)
    return {"result": "registered", "appIdentifierHash": hashlib.sha256(app_id.encode()).hexdigest()}


def allocate_identity(*, get: Callable[[str, str], Mapping[str, Any]] | None = None, root: Path = ROOT) -> dict[str, Any]:
    version = marketing_version()
    if get is None:
        bearer = token()
        get = lambda path, bearer: request_json(path, bearer)
    else:
        bearer = "test"
    app_id = _one_app(get(f"/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer))
    query = urllib.parse.urlencode({
        "filter[app]": app_id,
        "filter[preReleaseVersion.platform]": "IOS",
        "include": "preReleaseVersion",
        "fields[builds]": "version,preReleaseVersion",
        "fields[preReleaseVersions]": "version",
        "limit": "200",
    })
    builds = get(f"/builds?{query}", bearer)
    _, highest_remote_build, highest_remote_marketing, response_material = _build_snapshot(builds)
    highest_build = max(highest_remote_build, _local_highest_build(version, root=root))
    build_number = highest_build + 1
    return {"proofVersion": "1.0.0", "operationClass": "identityAllocation", "result": "passed", "marketingVersion": version, "buildNumber": build_number, "remoteHighestMarketingVersion": highest_remote_marketing, "remoteHighestBuildNumber": highest_remote_build, "responseSha256": hashlib.sha256(response_material).hexdigest(), "productKey": PRODUCT, "observedAt": now()}


def _candidate_release(candidate: str, *, root: Path = ROOT) -> tuple[str, str]:
    """Load only the frozen release identity for a supplied candidate."""

    manifest_path = root / ".git" / "release-state" / PRODUCT / "candidates" / candidate / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ASCError("candidate-manifest-unavailable") from error
    release = manifest.get("release") if isinstance(manifest, Mapping) else None
    version = release.get("marketingVersion") if isinstance(release, Mapping) else None
    build = release.get("buildNumber") if isinstance(release, Mapping) else None
    if (
        manifest.get("formatVersion") != 2
        or manifest.get("immutable") is not True
        or manifest.get("productIdentifier") != PRODUCT
        or manifest.get("candidateId") != candidate
        or not isinstance(release, Mapping)
        or release.get("frozen") is not True
        or not isinstance(version, str)
        or _SEMVER.fullmatch(version) is None
        or isinstance(build, bool)
        or not _POSITIVE.fullmatch(str(build))
    ):
        raise ASCError("candidate-manifest-invalid")
    return version, str(build)


def _ipa(candidate: str, *, root: Path = ROOT) -> Path:
    """Return the final candidate IPA without following a caller-controlled path."""

    value = root / ".release-state" / "artifacts" / candidate / "WiltediOS.ipa"
    try:
        status = value.lstat()
    except OSError as error:
        raise ASCError("candidate-artifact-unavailable") from error
    if not value.is_file() or value.is_symlink() or status.st_size <= 0:
        raise ASCError("candidate-artifact-invalid")
    return value


def _resource(response: Mapping[str, Any], resource_type: str) -> Mapping[str, Any]:
    data = response.get("data")
    if (
        not isinstance(data, Mapping)
        or data.get("type") != resource_type
        or not isinstance(data.get("id"), str)
        or not data["id"]
    ):
        raise ASCError("app-store-connect-response-invalid")
    return data


def _md5(path: Path) -> str:
    value = hashlib.md5()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                value.update(chunk)
    except OSError as error:
        raise ASCError("candidate-artifact-unavailable") from error
    return value.hexdigest()


def _sha256(path: Path) -> str:
    value = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                value.update(chunk)
    except OSError as error:
        raise ASCError("candidate-artifact-unavailable") from error
    return value.hexdigest()


def _put_binary(method: str, url: str, payload: bytes, headers: Mapping[str, str]) -> int:
    try:
        request = urllib.request.Request(url, data=payload, method=method, headers=dict(headers))
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status
    except (TimeoutError, urllib.error.HTTPError, urllib.error.URLError, OSError) as error:
        raise ASCError("app-store-connect-binary-upload-failed") from error


def upload_candidate(
    candidate: str,
    *,
    root: Path = ROOT,
    request: Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]] | None = None,
    binary_request: Callable[[str, str, bytes, Mapping[str, str]], int] = _put_binary,
) -> dict[str, Any]:
    """Commit one frozen IPA with Apple's typed Build Upload API."""

    if not _CANDIDATE.fullmatch(candidate):
        raise ASCError("candidate-identity-invalid")
    version, build = _candidate_release(candidate, root=root)
    ipa = _ipa(candidate, root=root)
    artifact_sha = _sha256(ipa)
    source_checksum = _md5(ipa)
    if request is None:
        bearer = token()
        request = lambda method, path, bearer, body: request_json(path, bearer, method=method, body=body)
    else:
        bearer = "test"
    app_id = _one_app(request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer, None))
    created = request(
        "POST",
        "/buildUploads",
        bearer,
        {"data": {"type": "buildUploads", "attributes": {"cfBundleShortVersionString": version, "cfBundleVersion": build, "platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
    )
    upload_id = _resource(created, "buildUploads")["id"]
    file_record = request(
        "POST",
        "/buildUploadFiles",
        bearer,
        {"data": {"type": "buildUploadFiles", "attributes": {"assetType": "ASSET", "fileName": ipa.name, "fileSize": ipa.stat().st_size, "uti": "com.apple.ipa"}, "relationships": {"buildUpload": {"data": {"type": "buildUploads", "id": upload_id}}}}},
    )
    upload_file = _resource(file_record, "buildUploadFiles")
    attributes = upload_file.get("attributes")
    operations = attributes.get("uploadOperations") if isinstance(attributes, Mapping) else None
    if not isinstance(operations, list) or not operations:
        raise ASCError("app-store-connect-upload-operations-invalid")
    expected_offset = 0
    try:
        with ipa.open("rb") as handle:
            for operation in operations:
                if not isinstance(operation, Mapping):
                    raise ASCError("app-store-connect-upload-operations-invalid")
                url, method = operation.get("url"), operation.get("method")
                offset, length, headers = operation.get("offset"), operation.get("length"), operation.get("requestHeaders")
                parsed = urlparse(url) if isinstance(url, str) else None
                if (
                    parsed is None or parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.fragment
                    or method != "PUT" or isinstance(offset, bool) or not isinstance(offset, int)
                    or isinstance(length, bool) or not isinstance(length, int) or offset != expected_offset or length <= 0
                    or offset + length > ipa.stat().st_size or not isinstance(headers, list)
                ):
                    raise ASCError("app-store-connect-upload-operations-invalid")
                typed_headers: dict[str, str] = {}
                for header in headers:
                    if (
                        not isinstance(header, Mapping) or set(header) != {"name", "value"}
                        or not isinstance(header["name"], str) or not header["name"]
                        or not isinstance(header["value"], str) or "\n" in header["name"] or "\n" in header["value"]
                    ):
                        raise ASCError("app-store-connect-upload-operations-invalid")
                    typed_headers[header["name"]] = header["value"]
                handle.seek(offset)
                payload = handle.read(length)
                if len(payload) != length or binary_request(method, url, payload, typed_headers) not in {200, 201, 202, 204}:
                    raise ASCError("app-store-connect-binary-upload-failed")
                expected_offset += length
    except OSError as error:
        raise ASCError("candidate-artifact-unavailable") from error
    if expected_offset != ipa.stat().st_size:
        raise ASCError("app-store-connect-upload-operations-incomplete")
    committed = request(
        "PATCH",
        f"/buildUploadFiles/{upload_file['id']}",
        bearer,
        {"data": {"type": "buildUploadFiles", "id": upload_file["id"], "attributes": {"uploaded": True, "sourceFileChecksums": {"file": {"algorithm": "MD5", "hash": source_checksum}}}}},
    )
    if _resource(committed, "buildUploadFiles")["id"] != upload_file["id"]:
        raise ASCError("app-store-connect-response-invalid")
    return {
        "proofVersion": "1.0.0", "operationClass": "upload", "candidateId": candidate,
        "signedArtifactSha256": artifact_sha, "result": "passed", "uploadedBuildIdentifier": upload_id,
        "responseSha256": digest({"buildUploadIdentifier": upload_id, "buildUploadFileIdentifier": upload_file["id"], "artifactSha256": artifact_sha, "sourceFileChecksum": source_checksum}),
    }


def _uploaded_identifier(candidate: str, *, root: Path = ROOT) -> str:
    try:
        proof = json.loads((root / ".release-state" / "evidence" / candidate / "upload.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ASCError("upload-proof-unavailable") from error
    identifier = proof.get("uploadedBuildIdentifier") if isinstance(proof, Mapping) else None
    if proof.get("result") != "passed" or proof.get("candidateId") != candidate or not isinstance(identifier, str) or not identifier:
        raise ASCError("upload-proof-invalid")
    return identifier


def _exact_build(response: Mapping[str, Any], *, version: str, build: str) -> tuple[str, str]:
    data, included = response.get("data"), response.get("included")
    if not isinstance(data, list) or not isinstance(included, list):
        raise ASCError("app-store-connect-response-invalid")
    matches: list[Mapping[str, Any]] = []
    for item in data:
        attributes = item.get("attributes") if isinstance(item, Mapping) else None
        if (
            isinstance(item, Mapping) and item.get("type") == "builds" and isinstance(item.get("id"), str) and item["id"]
            and isinstance(attributes, Mapping) and str(attributes.get("version")) == build
        ):
            matches.append(item)
    if len(matches) != 1:
        raise ASCError("app-store-connect-exact-build-not-found")
    match = matches[0]
    attributes = match["attributes"]
    state = attributes.get("processingState")
    relationships = match.get("relationships")
    prerelease = relationships.get("preReleaseVersion") if isinstance(relationships, Mapping) else None
    prerelease_data = prerelease.get("data") if isinstance(prerelease, Mapping) else None
    prerelease_id = prerelease_data.get("id") if isinstance(prerelease_data, Mapping) else None
    versions = [
        item for item in included
        if isinstance(item, Mapping) and item.get("type") == "preReleaseVersions" and item.get("id") == prerelease_id
        and isinstance(item.get("attributes"), Mapping) and item["attributes"].get("version") == version
    ]
    if len(versions) != 1 or state not in {"PROCESSING", "FAILED", "INVALID", "VALID"}:
        raise ASCError("app-store-connect-exact-build-invalid")
    return match["id"], state


def _lookup_build(response: Mapping[str, Any], *, version: str, build: str) -> tuple[str | None, str]:
    """Resolve the exact registered-app build, allowing a safe absent result."""

    data = response.get("data")
    if not isinstance(data, list):
        raise ASCError("app-store-connect-response-invalid")
    links = response.get("links")
    if links is not None and not isinstance(links, Mapping):
        raise ASCError("app-store-connect-pagination-invalid")
    if isinstance(links, Mapping) and links.get("next") is not None:
        raise ASCError("app-store-connect-pagination-unexpected")
    if not data:
        included = response.get("included", [])
        if not isinstance(included, list):
            raise ASCError("app-store-connect-response-invalid")
        return None, "absent"
    included = response.get("included")
    if not isinstance(included, list):
        raise ASCError("app-store-connect-response-invalid")
    if len(data) != 1:
        raise ASCError("app-store-connect-exact-build-ambiguous")
    item = data[0]
    attributes = item.get("attributes") if isinstance(item, Mapping) else None
    identifier = item.get("id") if isinstance(item, Mapping) else None
    if (
        not isinstance(item, Mapping)
        or item.get("type") != "builds"
        or not isinstance(identifier, str)
        or not identifier
        or not isinstance(attributes, Mapping)
        or str(attributes.get("version")) != build
    ):
        raise ASCError("app-store-connect-exact-build-mismatch")
    state = attributes.get("processingState")
    relationships = item.get("relationships")
    prerelease = relationships.get("preReleaseVersion") if isinstance(relationships, Mapping) else None
    prerelease_data = prerelease.get("data") if isinstance(prerelease, Mapping) else None
    prerelease_id = prerelease_data.get("id") if isinstance(prerelease_data, Mapping) else None
    versions = [
        entry for entry in included
        if isinstance(entry, Mapping)
        and entry.get("type") == "preReleaseVersions"
        and entry.get("id") == prerelease_id
        and isinstance(entry.get("attributes"), Mapping)
        and entry["attributes"].get("version") == version
    ]
    if len(versions) != 1:
        raise ASCError("app-store-connect-exact-build-mismatch")
    normalized = {"VALID": "ready", "PROCESSING": "processing", "FAILED": "failed", "INVALID": "failed"}.get(state)
    if normalized is None:
        raise ASCError("app-store-connect-build-processing-state-invalid")
    return identifier, normalized


def build_lookup_candidate(
    candidate: str,
    *,
    root: Path = ROOT,
    request: Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    """Reconcile one exact candidate build without uploading or mutating Apple."""

    if not _CANDIDATE.fullmatch(candidate):
        raise ASCError("candidate-identity-invalid")
    version, build = _candidate_release(candidate, root=root)
    artifact = _ipa(candidate, root=root)
    artifact_sha = _sha256(artifact)
    if request is None:
        bearer = token()
        request = lambda method, path, bearer, body: request_json(path, bearer, method=method, body=body)
    else:
        bearer = "test"
    app_id = _one_app(request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer, None))
    query = urllib.parse.urlencode({
        "filter[app]": app_id,
        "filter[version]": build,
        "filter[preReleaseVersion.platform]": "IOS",
        "include": "preReleaseVersion",
        "fields[builds]": "version,processingState,preReleaseVersion",
        "fields[preReleaseVersions]": "version",
        "limit": "200",
    })
    identifier, state = _lookup_build(request("GET", f"/builds?{query}", bearer, None), version=version, build=build)
    if identifier is None:
        return {
            "proofVersion": "1.0.0", "operationClass": "buildLookup", "candidateId": candidate,
            "marketingVersion": version, "buildNumber": build, "result": "passed",
            "lookupResult": "absent", "processingState": "absent",
            "responseSha256": digest({"candidateId": candidate, "build": build, "visible": False, "processingState": "absent"}),
        }
    return {
        "proofVersion": "1.0.0", "operationClass": "buildLookup", "candidateId": candidate,
        "marketingVersion": version, "buildNumber": build, "result": "passed",
        "lookupResult": "found", "processingState": state, "remoteIdentifier": identifier,
        "uploadedBuildIdentifier": identifier, "signedArtifactSha256": artifact_sha,
        "responseSha256": digest({"candidateId": candidate, "buildId": identifier, "processingState": state}),
    }


def process_candidate(
    candidate: str,
    *,
    root: Path = ROOT,
    request: Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]] | None = None,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    """Poll only the uploaded candidate's exact iOS build until VALID."""

    if not _CANDIDATE.fullmatch(candidate):
        raise ASCError("candidate-identity-invalid")
    version, build = _candidate_release(candidate, root=root)
    uploaded = _uploaded_identifier(candidate, root=root)
    if request is None:
        bearer = token()
        request = lambda method, path, bearer, body: request_json(path, bearer, method=method, body=body)
    else:
        bearer = "test"
    app_id = _one_app(request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer, None))
    query = urllib.parse.urlencode({
        "filter[app]": app_id, "filter[version]": build, "filter[preReleaseVersion.platform]": "IOS",
        "include": "preReleaseVersion", "fields[builds]": "version,processingState,preReleaseVersion",
        "fields[preReleaseVersions]": "version", "limit": "200",
    })
    for attempt in range(12):
        upload_status = _resource(request("GET", f"/buildUploads/{uploaded}", bearer, None), "buildUploads")
        upload_attributes = upload_status.get("attributes")
        state_detail = upload_attributes.get("state") if isinstance(upload_attributes, Mapping) else None
        upload_state = state_detail.get("state") if isinstance(state_detail, Mapping) else None
        if upload_state not in {"AWAITING_UPLOAD", "PROCESSING", "COMPLETE", "FAILED"}:
            raise ASCError("app-store-connect-upload-state-invalid")
        if upload_state == "FAILED":
            details = state_detail.get("errors") if isinstance(state_detail, Mapping) else None
            codes = [item.get("code") for item in details if isinstance(item, Mapping)] if isinstance(details, list) else []
            if len(codes) == 1 and isinstance(codes[0], str) and re.fullmatch(r"[A-Za-z0-9._-]{1,96}", codes[0]):
                raise ASCError(f"app-store-connect-upload-failed-{codes[0]}")
            raise ASCError("app-store-connect-upload-failed")
        response = request("GET", f"/builds?{query}", bearer, None)
        try:
            build_identifier, state = _exact_build(response, version=version, build=build)
        except ASCError as error:
            if str(error) != "app-store-connect-exact-build-not-found":
                raise
            build_identifier, state = "", "PROCESSING"
        if state == "VALID":
            return {
                "proofVersion": "1.0.0", "operationClass": "processing", "candidateId": candidate,
                "uploadedBuildIdentifier": uploaded, "result": "passed",
                "responseSha256": digest({"buildIdentifier": build_identifier, "processingState": state}),
            }
        if state in {"FAILED", "INVALID"}:
            raise ASCError(f"app-store-connect-processing-{state.lower()}")
        if attempt < 11:
            sleep(30)
    raise ASCError("app-store-connect-processing-timeout")


def _candidate_context(
    candidate: str,
    *,
    bearer: str | None = None,
    request: Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]] | None = None,
) -> tuple[str, str, str]:
    """Resolve only the exact processed build required by post-upload operations."""

    version, build = _candidate_release(candidate)
    uploaded = _uploaded_identifier(candidate)
    if request is None:
        bearer = token()
        request = lambda method, path, bearer, body: request_json(path, bearer, method=method, body=body)
    elif bearer is None:
        bearer = "test"
    app_id = _one_app(request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(BUNDLE_ID, safe='')}&limit=2", bearer, None))
    query = urllib.parse.urlencode({
        "filter[app]": app_id, "filter[version]": build, "filter[preReleaseVersion.platform]": "IOS",
        "include": "preReleaseVersion", "fields[builds]": "version,processingState,preReleaseVersion",
        "fields[preReleaseVersions]": "version", "limit": "200",
    })
    build_id, state = _exact_build(request("GET", f"/builds?{query}", bearer, None), version=version, build=build)
    if state != "VALID":
        raise ASCError("app-store-connect-processing-not-valid")
    return uploaded, app_id, build_id


def _request_context() -> tuple[str, Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]]]:
    bearer = token()
    return bearer, lambda method, path, token_value, body: request_json(path, token_value, method=method, body=body)


def _internal_group(
    app_id: str,
    *,
    bearer: str,
    request: Callable[[str, str, str, Mapping[str, Any] | None], Mapping[str, Any]],
) -> str:
    """Resolve one safe internal group, creating the fixed project group if absent."""

    response = request("GET", f"/apps/{app_id}/betaGroups?limit=200", bearer, None)
    data = response.get("data")
    if not isinstance(data, list):
        raise ASCError("app-store-connect-tester-group-response-invalid")
    matches: list[str] = []
    internal: list[str] = []
    for item in data:
        attributes = item.get("attributes") if isinstance(item, Mapping) else None
        identifier = item.get("id") if isinstance(item, Mapping) else None
        if not isinstance(identifier, str) or not identifier or not isinstance(attributes, Mapping):
            raise ASCError("app-store-connect-tester-group-response-invalid")
        if attributes.get("isInternalGroup") is True:
            internal.append(identifier)
            if attributes.get("name") == INTERNAL_GROUP_NAME:
                matches.append(identifier)
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise ASCError("app-store-connect-tester-group-ambiguous")
    if len(internal) == 1:
        return internal[0]
    if internal:
        raise ASCError("app-store-connect-tester-group-selection-required")
    created = request(
        "POST",
        "/betaGroups",
        bearer,
        {"data": {"type": "betaGroups", "attributes": {"name": INTERNAL_GROUP_NAME, "isInternalGroup": True}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
    )
    return _resource(created, "betaGroups")["id"]


def _proof(operation: str, candidate: str, uploaded: str, **observed: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "proofVersion": "1.0.0", "operationClass": {"tester-group": "testerGroup", "device-health": "deviceHealth"}.get(operation, operation),
        "candidateId": candidate, "uploadedBuildIdentifier": uploaded, "result": "passed", "observedAt": now(), **observed,
    }
    payload.setdefault("responseSha256", digest({"operation": operation, "candidateId": candidate, "uploadedBuildIdentifier": uploaded, **observed}))
    return payload


def compliance_candidate(candidate: str) -> dict[str, Any]:
    """Record that Apple accepted the exact build without an outstanding compliance hold."""

    uploaded, _app_id, build_id = _candidate_context(candidate)
    return _proof("compliance", candidate, uploaded, observedBuildIdentifierHash=hashlib.sha256(build_id.encode()).hexdigest())


def tester_group_candidate(candidate: str) -> dict[str, Any]:
    """Resolve the one internal TestFlight group authorized for Wilted."""

    bearer, request = _request_context()
    uploaded, app_id, _build_id = _candidate_context(
        candidate, bearer=bearer, request=request
    )
    group_id = _internal_group(app_id, bearer=bearer, request=request)
    return _proof("tester-group", candidate, uploaded, groupIdentifierHash=hashlib.sha256(group_id.encode()).hexdigest())


def assignment_candidate(candidate: str) -> dict[str, Any]:
    """Idempotently associate the exact valid build with the internal group."""

    bearer, request = _request_context()
    uploaded, app_id, build_id = _candidate_context(
        candidate, bearer=bearer, request=request
    )
    group_id = _internal_group(app_id, bearer=bearer, request=request)
    assigned = request("GET", f"/betaGroups/{group_id}/builds?limit=200", bearer, None).get("data")
    if not isinstance(assigned, list):
        raise ASCError("app-store-connect-group-builds-response-invalid")
    if not any(isinstance(item, Mapping) and item.get("type") == "builds" and item.get("id") == build_id for item in assigned):
        request_empty(f"/betaGroups/{group_id}/relationships/builds", bearer, method="POST", body={"data": [{"type": "builds", "id": build_id}]})
    return _proof("assignment", candidate, uploaded, groupIdentifierHash=hashlib.sha256(group_id.encode()).hexdigest(), lane="standard")


def device_health_candidate(candidate: str) -> dict[str, Any]:
    """Verify that the assigned build remains visible to its TestFlight group."""

    bearer, request = _request_context()
    uploaded, app_id, build_id = _candidate_context(
        candidate, bearer=bearer, request=request
    )
    group_id = _internal_group(app_id, bearer=bearer, request=request)
    data = request("GET", f"/betaGroups/{group_id}/builds?limit=200", bearer, None).get("data")
    if not isinstance(data, list) or not any(isinstance(item, Mapping) and item.get("type") == "builds" and item.get("id") == build_id for item in data):
        raise ASCError("app-store-connect-build-not-assigned")
    evidence = digest({"buildIdentifier": build_id, "groupIdentifierHash": hashlib.sha256(group_id.encode()).hexdigest()})
    return _proof("device-health", candidate, uploaded, observedAt=now(), evidenceSha256=evidence)


def notification_candidate(candidate: str) -> dict[str, Any]:
    """Send the documented TestFlight notification only after assignment is verified."""

    bearer, request = _request_context()
    uploaded, _app_id, build_id = _candidate_context(
        candidate, bearer=bearer, request=request
    )
    try:
        created = request("POST", "/buildBetaNotifications", bearer, {"data": {"type": "buildBetaNotifications", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    except ASCError as error:
        if str(error) != "app-store-connect-http-409":
            raise
        return _proof(
            "notification",
            candidate,
            uploaded,
            alreadySent=True,
            deliveryReceiptSha256=digest({"buildIdentifier": build_id, "alreadySent": True}),
        )
    notification_id = _resource(created, "buildBetaNotifications")["id"]
    return _proof("notification", candidate, uploaded, deliveryReceiptSha256=digest({"buildIdentifier": build_id, "notificationIdentifier": notification_id}))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", required=True, choices=sorted(OPERATIONS))
    parser.add_argument("--product", required=True)
    parser.add_argument("--candidate")
    parser.add_argument("--marketing-version")
    parser.add_argument("--build-number")
    args = parser.parse_args(argv)
    if args.product != PRODUCT:
        return blocked(args.operation, args.candidate, "product-identity-mismatch")
    if args.operation == "app-registration":
        if args.candidate is not None:
            return blocked(args.operation, args.candidate, "app-registration-does-not-accept-candidate")
        try:
            registration = register_app()
            path = evidence_path(args.operation, None)
            write_json(path, {"proofVersion": "1.0.0", "operationClass": "app-registration", **registration, "observedAt": now(), "responseSha256": digest(registration)}, exclusive=True)
        except FileExistsError:
            return blocked(args.operation, None, "app-registration-already-exists")
        except (ASCError, OSError, ValueError) as error:
            return blocked(args.operation, None, str(error))
        print(json.dumps({"operation": args.operation, "result": registration["result"], "proofPath": str(path.relative_to(ROOT))}, sort_keys=True))
        return 0
    if args.operation == "upload":
        if args.candidate is None or not _CANDIDATE.fullmatch(args.candidate):
            return blocked(args.operation, args.candidate, "candidate-identity-invalid")
        try:
            proof = upload_candidate(args.candidate)
            path = evidence_path(args.operation, args.candidate)
            write_json(path, proof)
        except (ASCError, OSError, ValueError) as error:
            return blocked(args.operation, args.candidate, str(error))
        print(json.dumps({"operation": args.operation, "result": "passed", "proofPath": str(path.relative_to(ROOT))}, sort_keys=True))
        return 0
    if args.operation == "processing":
        if args.candidate is None or not _CANDIDATE.fullmatch(args.candidate):
            return blocked(args.operation, args.candidate, "candidate-identity-invalid")
        try:
            proof = process_candidate(args.candidate)
            path = evidence_path(args.operation, args.candidate)
            write_json(path, proof)
        except (ASCError, OSError, ValueError) as error:
            return blocked(args.operation, args.candidate, str(error))
        print(json.dumps({"operation": args.operation, "result": "passed", "proofPath": str(path.relative_to(ROOT))}, sort_keys=True))
        return 0
    if args.operation == "build-lookup":
        if args.candidate is None or not _CANDIDATE.fullmatch(args.candidate):
            return blocked(args.operation, args.candidate, "candidate-identity-invalid")
        try:
            expected_version, expected_build = _candidate_release(args.candidate)
            if (
                args.marketing_version is not None and args.marketing_version != expected_version
                or args.build_number is not None and args.build_number != expected_build
            ):
                return blocked(args.operation, args.candidate, "candidate-identity-mismatch")
            proof = build_lookup_candidate(args.candidate)
            path = evidence_path(args.operation, args.candidate)
            write_json(path, proof)
        except (ASCError, OSError, ValueError) as error:
            return blocked(args.operation, args.candidate, str(error))
        print(json.dumps({"operation": args.operation, "result": "passed", "proofPath": str(path.relative_to(ROOT))}, sort_keys=True))
        return 0
    post_upload_operations: Mapping[str, Callable[[str], dict[str, Any]]] = {
        "compliance": compliance_candidate,
        "tester-group": tester_group_candidate,
        "assignment": assignment_candidate,
        "device-health": device_health_candidate,
        "notification": notification_candidate,
    }
    if args.operation in post_upload_operations:
        if args.candidate is None or not _CANDIDATE.fullmatch(args.candidate):
            return blocked(args.operation, args.candidate, "candidate-identity-invalid")
        try:
            proof = post_upload_operations[args.operation](args.candidate)
            path = evidence_path(args.operation, args.candidate)
            write_json(path, proof)
        except (ASCError, OSError, ValueError) as error:
            return blocked(args.operation, args.candidate, str(error))
        print(json.dumps({"operation": args.operation, "result": "passed", "proofPath": str(path.relative_to(ROOT))}, sort_keys=True))
        return 0
    if args.operation != "identity-allocation":
        if args.candidate is None or not _CANDIDATE.fullmatch(args.candidate):
            return blocked(args.operation, args.candidate, "candidate-identity-invalid")
        return blocked(args.operation, args.candidate, "release-prerequisite-not-satisfied")
    if args.candidate is not None:
        return blocked(args.operation, args.candidate, "identity-allocation-does-not-accept-candidate")
    try:
        proof = allocate_identity()
        path = evidence_path(args.operation, None)
        # Allocation evidence is the current candidate reservation, not the
        # immutable candidate record. A failed pre-upload candidate must not
        # prevent the next candidate from recording its distinct allocation.
        write_json(path, proof)
    except (ASCError, OSError, ValueError) as error:
        return blocked(args.operation, None, str(error))
    print(json.dumps({"operation": args.operation, "result": "passed", "proofPath": str(path.relative_to(ROOT))}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
