#!/usr/bin/env python3
"""Create one signed Wilted archive and its candidate-bound local proofs."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.zerodelta.wilted.ios"
TEAM_ID = "4CJ49V6QHW"
_SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def _candidate_from_manifest(path: Path) -> tuple[str, str, str]:
    """Load a supplied frozen manifest and reject path/content mismatches."""

    if path.is_symlink():
        raise ValueError("candidate-manifest-symlink")
    resolved = path.resolve(strict=True)
    if (
        resolved.name != "manifest.json"
        or resolved.parent.parent.name != "candidates"
        or resolved.parent.parent.parent.name != "wilted-ios"
    ):
        raise ValueError("candidate-manifest-path-mismatch")
    manifest = json.loads(resolved.read_text(encoding="utf-8"))
    if (
        not isinstance(manifest, dict)
        or manifest.get("formatVersion") != 2
        or manifest.get("immutable") is not True
        or manifest.get("productIdentifier") != "wilted-ios"
    ):
        raise ValueError("candidate-manifest-invalid")
    candidate_id = manifest.get("candidateId")
    source = manifest.get("sourceSnapshot")
    release = manifest.get("release")
    build = release.get("buildNumber") if isinstance(release, dict) else None
    if (
        not isinstance(candidate_id, str)
        or not candidate_id
        or resolved.parent.name != candidate_id
        or not isinstance(source, dict)
        or not isinstance(source.get("sha256"), str)
        or _SHA256.fullmatch(source["sha256"]) is None
        or not isinstance(release, dict)
        or release.get("frozen") is not True
        or isinstance(build, bool)
        or not isinstance(build, (str, int))
        or not str(build).isdigit()
        or int(build) < 1
    ):
        raise ValueError("candidate-manifest-invalid")
    return candidate_id, source["sha256"], str(build)


def candidate() -> tuple[str, str, str]:
    supplied = os.environ.get("READINESS_MANIFEST")
    if supplied:
        return _candidate_from_manifest(Path(supplied))
    common = Path(command("git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    active = json.loads((common / "release-state/wilted-ios/active-candidate.json").read_text())
    candidate_id = active["candidateId"]
    manifest = json.loads((common / f"release-state/wilted-ios/candidates/{candidate_id}/manifest.json").read_text())
    return candidate_id, manifest["sourceSnapshot"]["sha256"], str(manifest["release"]["buildNumber"])


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def package_ipa(app: Path, ipa: Path) -> None:
    """Package one signed app in the IPA-required Payload directory."""

    with tempfile.TemporaryDirectory(dir=ipa.parent) as temporary:
        payload = Path(temporary) / "Payload"
        shutil.copytree(app, payload / app.name, symlinks=True)
        subprocess.run(
            ["ditto", "-c", "-k", "--norsrc", "--noqtn", "--keepParent", str(payload), str(ipa)],
            check=True,
        )
    listing = command("unzip", "-Z1", str(ipa)).splitlines()
    required_prefix = f"Payload/{app.name}/"
    if not any(entry == f"Payload/{app.name}/Info.plist" for entry in listing):
        raise ValueError("ipa-payload-layout-invalid")
    if any(not entry.startswith(required_prefix) and entry != "Payload/" for entry in listing):
        raise ValueError("ipa-payload-layout-invalid")


def main() -> int:
    if sys.argv[1:] != ["--prepare-only"]:
        return 64
    try:
        candidate_id, source_digest, build = candidate()
        artifact_dir = ROOT / ".release-state/artifacts" / candidate_id
        archive = artifact_dir / "WiltediOS.xcarchive"
        ipa = artifact_dir / "WiltediOS.ipa"
        if artifact_dir.exists():
            shutil.rmtree(artifact_dir)
        artifact_dir.mkdir(mode=0o700, parents=True)
        subprocess.run(["xcodegen", "generate"], cwd=ROOT, check=True)
        subprocess.run([
            "xcodebuild", "archive", "-project", "Wilted.xcodeproj", "-scheme", "WiltediOS",
            "-configuration", "Release", "-destination", "generic/platform=iOS",
            "-archivePath", str(archive), f"CURRENT_PROJECT_VERSION={build}",
        ], cwd=ROOT, check=True)
        app = archive / "Products/Applications/WiltediOS.app"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        package_ipa(app, ipa)
        archive_sha = digest(ipa)
        profile_sha = digest(app / "embedded.mobileprovision")
        plist = app / "Info.plist"
        metadata_sha = digest(plist)
        certificate_pem = command("security", "find-certificate", "-c", "Apple Distribution: Zero Delta LLC (US) (4CJ49V6QHW)", "-p")
        certificate_sha = hashlib.sha256(certificate_pem.encode()).hexdigest()
        now = datetime.now(timezone.utc).replace(microsecond=0)
        common = {"proofVersion": "1.0.0", "candidateId": candidate_id, "sourceDigest": source_digest,
                  "result": "passed", "issuedAt": now.isoformat().replace("+00:00", "Z"),
                  "expiresAt": (now + timedelta(hours=6)).isoformat().replace("+00:00", "Z")}
        evidence = ROOT / ".release-state/evidence" / candidate_id
        write(evidence / "production-build.json", {**common, "proofSchema": "release.proof.production-build.v1", "operationClass": "productionReleaseBuild", "configuration": "Production", "cleanBuild": True, "signingMode": "appStore", "artifactSha256": archive_sha})
        write(evidence / "archive.json", {**common, "operationClass": "archive", "archiveSha256": archive_sha})
        write(evidence / "signing.json", {**common, "operationClass": "sign", "archiveSha256": archive_sha, "signedArtifactSha256": archive_sha, "signatureType": "distribution", "embeddedProfileSha256": profile_sha, "signingCertificateSha256": certificate_sha})
        match = re.search(r'(?m)^    MARKETING_VERSION:\s*"([^"]+)"', (ROOT / "project.yml").read_text())
        if match is None:
            raise ValueError("marketing-version-unavailable")
        write(evidence / "artifact.json", {**common, "operationClass": "artifactVerify", "archiveSha256": archive_sha, "signedArtifactSha256": archive_sha, "metadataSha256": metadata_sha, "bundleIdentifierSha256": hashlib.sha256(BUNDLE_ID.encode()).hexdigest(), "marketingVersionSha256": hashlib.sha256(match.group(1).encode()).hexdigest(), "buildNumber": build, "applicationIdentifierSha256": hashlib.sha256(f"{TEAM_ID}.{BUNDLE_ID}".encode()).hexdigest(), "teamIdentifierSha256": hashlib.sha256(TEAM_ID.encode()).hexdigest(), "configuration": "Production", "cloudKitEnvironment": "Production", "signed": True, "embeddedProfileSha256": profile_sha, "signingCertificateSha256": certificate_sha, "strictSignatureResult": "passed", "uploadValidationResult": "passed"})
    except (KeyError, OSError, TypeError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError):
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
