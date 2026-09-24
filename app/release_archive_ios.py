"""Build an iOS archive only from bytes bound to a frozen candidate."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.zerodelta.wilted.ios"
TEAM_ID = "4CJ49V6QHW"
_SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")

# The wrapper runs this file directly without PYTHONPATH. Import only the fixed
# sibling release framework; the candidate cannot choose executable tooling.
_FRAMEWORK_PARENT = ROOT.parent / "apple_developer"
if not (_FRAMEWORK_PARENT / "release_tools/source_snapshot.py").is_file():
    raise RuntimeError("release-framework-unavailable")
sys.path.insert(0, str(_FRAMEWORK_PARENT))
from release_tools.adapter import AdapterError, load_adapter
from release_tools.artifact import verify_artifact_evidence
from release_tools.iterative_release import (
    ReleaseStateError,
    load_candidate_manifest,
)
from release_tools.source_snapshot import (
    DEFAULT_EXCLUSIONS,
    SNAPSHOT_POLICY_VERSION,
    SnapshotError,
    _entries,
    create_source_digest,
)


@dataclass(frozen=True)
class Candidate:
    candidate_id: str
    source_digest: str
    marketing_version: str
    build_number: str
    manifest_path: Path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def command(*args: str) -> bytes:
    """Capture signing output privately; callers never print its contents."""

    return subprocess.run(args, check=True, capture_output=True).stdout


def status(message: str) -> None:
    print(f"release-archive:{message}", file=sys.stderr, flush=True)


def run_visible(args: list[str], *, cwd: Path) -> None:
    """Keep a long build visible without exposing command output or credentials."""

    process = subprocess.Popen(args, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while True:
        try:
            code = process.wait(timeout=5)
            break
        except subprocess.TimeoutExpired:
            status("build-heartbeat")
    if code:
        raise subprocess.CalledProcessError(code, args)


def git_common_candidates_dir() -> Path:
    common = command(
        "git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"
    ).decode().strip()
    return Path(common).resolve(strict=True) / "release-state/wilted-ios/candidates"


def _candidate_from_manifest(path: Path) -> Candidate:
    """Validate both the common-dir location and canonical manifest content."""

    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("candidate-manifest-symlink")
    if ".." in path.parts:
        raise ValueError("candidate-manifest-path-mismatch")
    resolved = path.resolve(strict=True)
    if resolved.name != "manifest.json" or resolved.parent.parent != git_common_candidates_dir().resolve(strict=True):
        raise ValueError("candidate-manifest-path-mismatch")
    manifest = load_candidate_manifest(resolved)
    release = manifest.get("release")
    source = manifest.get("sourceSnapshot")
    if (manifest.get("formatVersion") != 2 or manifest.get("immutable") is not True
            or manifest.get("productIdentifier") != "wilted-ios"
            or not isinstance(release, dict) or not isinstance(source, dict)):
        raise ValueError("candidate-manifest-invalid")
    marketing = release.get("marketingVersion")
    build = release.get("buildNumber")
    if (not isinstance(marketing, str) or not _SEMVER.fullmatch(marketing)
            or isinstance(build, bool) or not isinstance(build, (str, int))
            or not str(build).isdigit() or int(build) < 1
            or str(int(build)) != str(build)
            or manifest.get("candidateId") != f"{marketing}-{build}"
            or resolved.parent.name != manifest.get("candidateId")
            or source.get("policyVersion") != SNAPSHOT_POLICY_VERSION):
        raise ValueError("candidate-manifest-invalid")
    return Candidate(manifest["candidateId"], source["sha256"], marketing, str(build), resolved)


def candidate_data() -> Candidate:
    supplied = os.environ.get("READINESS_MANIFEST")
    if supplied:
        return _candidate_from_manifest(Path(supplied))
    candidates = git_common_candidates_dir()
    active_path = candidates.parent / "active-candidate.json"
    if active_path.is_symlink():
        raise ValueError("active-candidate-symlink")
    active = json.loads(active_path.read_text(encoding="utf-8"))
    candidate_id = active.get("candidateId") if isinstance(active, dict) else None
    if (not isinstance(candidate_id, str) or candidate_id in {".", ".."}
            or not re.fullmatch(r"[A-Za-z0-9._-]+", candidate_id)):
        raise ValueError("active-candidate-invalid")
    return _candidate_from_manifest(candidates / candidate_id / "manifest.json")


def candidate() -> tuple[str, str, str]:
    value = candidate_data()
    return value.candidate_id, value.source_digest, value.build_number


def source_adapter(frozen: Candidate):
    """Use the exact framework source policy and frozen adapter identity."""

    adapter = load_adapter(ROOT / ".release/release-adapter.json", repository_root=ROOT)
    manifest = load_candidate_manifest(frozen.manifest_path)
    if manifest["adapter"].get("sha256") != adapter.digest:
        raise ValueError("candidate-adapter-drift")
    if (adapter.product.get("bundleIdentifier") != BUNDLE_ID
            or adapter.product.get("teamIdentifier") != TEAM_ID):
        raise ValueError("candidate-product-mismatch")
    return adapter


def source_digest(root: Path, adapter) -> str:
    return create_source_digest(
        root, declared_paths=adapter.source_paths or None,
        excluded_paths=adapter.non_source_paths,
    ).source_digest


def materialize_source(destination: Path, frozen: Candidate, adapter) -> None:
    """Copy selected entries, reject copy-time drift, then lock down the tree."""

    status("source-check-started")
    if source_digest(ROOT, adapter) != frozen.source_digest:
        raise ValueError("candidate-source-drift")
    entries = _entries(
        ROOT.resolve(), exclusions=DEFAULT_EXCLUSIONS,
        declared_paths=adapter.source_paths or None,
        excluded_paths=frozenset(adapter.non_source_paths),
    )
    destination.mkdir(mode=0o700)
    for entry in entries:
        relative = PurePosixPath(entry["normalizedRelativePath"])
        original = ROOT.joinpath(*relative.parts)
        target = destination.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        if entry["entryType"] == "symlink":
            if not original.is_symlink() or os.readlink(original) != entry["symlinkTarget"]:
                raise ValueError("candidate-source-drift-during-copy")
            target.symlink_to(entry["symlinkTarget"])
            if not target.resolve(strict=False).is_relative_to(destination.resolve()):
                raise ValueError("staged-source-symlink-escape")
        else:
            if original.is_symlink() or not original.is_file():
                raise ValueError("candidate-source-drift-during-copy")
            shutil.copyfile(original, target, follow_symlinks=False)
            executable = bool(original.stat().st_mode & stat.S_IXUSR)
            if digest(target) != entry["fileContentSha256"] or executable != entry["executable"]:
                raise ValueError("candidate-source-drift-during-copy")
            target.chmod(0o755 if executable else 0o644)
    if source_digest(destination, adapter) != frozen.source_digest:
        raise ValueError("staged-source-digest-mismatch")
    for directory, names, files in os.walk(destination, topdown=False, followlinks=False):
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink():
                path.chmod(0o555 if path.stat().st_mode & stat.S_IXUSR else 0o444)
        for name in names:
            path = Path(directory) / name
            if not path.is_symlink():
                path.chmod(0o555)
    destination.chmod(0o555)
    status("source-check-passed")


def build_archive(staged: Path, workspace: Path, frozen: Candidate) -> Path:
    """Generate outside source and archive with fresh derived data."""

    project_dir = workspace / "project"
    project_dir.mkdir(mode=0o700)
    derived = workspace / "DerivedData"
    archive = workspace / "artifacts/WiltediOS.xcarchive"
    archive.parent.mkdir(mode=0o700)
    if derived.exists() or archive.exists():
        raise ValueError("build-output-not-fresh")
    status("project-generation-started")
    run_visible(
        ["xcodegen", "generate", "--spec", str(staged / "project.yml"),
         "--project", str(project_dir), "--project-root", str(staged)], cwd=workspace,
    )
    generated = project_dir / "Wilted.xcodeproj"
    if not generated.is_dir():
        raise ValueError("generated-project-missing")
    # XcodeGen resolves plist and entitlements build settings relative to the
    # generated project, even though the source files resolve from project-root.
    for relative in (
        "WiltedMac/Info.plist", "WiltedMac/WiltedMac.entitlements",
        "WiltedMac/WiltedMacProduction.entitlements", "WiltediOS/Info.plist",
        "WiltediOS/WiltediOS.entitlements", "WiltediOS/WiltediOSProduction.entitlements",
    ):
        source = staged / relative
        if not source.is_file() or source.is_symlink():
            raise ValueError("staged-signing-input-missing")
        target = project_dir / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    status("archive-build-started")
    run_visible(
        ["xcodebuild", "archive", "-project", str(generated), "-scheme", "WiltediOS",
         "-configuration", "Release", "-destination", "generic/platform=iOS",
         "-derivedDataPath", str(derived), "-archivePath", str(archive),
         f"CURRENT_PROJECT_VERSION={frozen.build_number}"], cwd=workspace,
    )
    if not derived.is_dir() or not archive.is_dir():
        raise ValueError("archive-build-output-missing")
    return archive


def package_ipa(app: Path, ipa: Path) -> None:
    """Package a signed app and inspect the IPA payload layout."""

    with tempfile.TemporaryDirectory(dir=ipa.parent) as temporary:
        payload = Path(temporary) / "Payload"
        shutil.copytree(app, payload / app.name, symlinks=True)
        subprocess.run(
            ["ditto", "-c", "-k", "--norsrc", "--noqtn", "--keepParent", str(payload), str(ipa)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    with zipfile.ZipFile(ipa) as packaged:
        names = packaged.namelist()
        prefix = f"Payload/{app.name}/"
        if f"{prefix}Info.plist" not in names or any(
            not name.startswith(prefix) and name != "Payload/" for name in names
        ):
            raise ValueError("ipa-payload-layout-invalid")
        if packaged.read(f"{prefix}Info.plist") != (app / "Info.plist").read_bytes():
            raise ValueError("ipa-metadata-mismatch")


def inspect_artifact(archive: Path, ipa: Path, frozen: Candidate, workspace: Path) -> dict:
    """Measure signature, entitlements, provisioning, and IPA contents."""

    app = archive / "Products/Applications/WiltediOS.app"
    profile_path = app / "embedded.mobileprovision"
    if not app.is_dir() or not profile_path.is_file():
        raise ValueError("signed-app-missing")
    status("signature-inspection-started")
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    entitlements = plistlib.loads(command("codesign", "-d", "--entitlements", "-", str(app)))
    profile = plistlib.loads(command("security", "cms", "-D", "-i", str(profile_path)))
    if not isinstance(entitlements, dict) or not isinstance(profile, dict):
        raise TypeError("signing-metadata-invalid")
    cloud = entitlements.get("com.apple.developer.icloud-container-environment")
    app_id = f"{TEAM_ID}.{BUNDLE_ID}"
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise TypeError("profile-entitlements-missing")
    if (cloud != "Production" or entitlements.get("application-identifier") != app_id
            or entitlements.get("com.apple.developer.team-identifier") != TEAM_ID
            or profile_entitlements.get("com.apple.developer.icloud-container-environment") != cloud
            or profile_entitlements.get("application-identifier") != app_id
            or profile_entitlements.get("get-task-allow") is not False
            or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") is True):
        raise ValueError("production-signing-mismatch")
    certificate_prefix = workspace / "signing-certificate"
    command("codesign", "-d", "--extract-certificates", str(certificate_prefix), str(app))
    certificate_bytes = certificate_prefix.with_name(certificate_prefix.name + "0").read_bytes()
    if certificate_bytes not in profile.get("DeveloperCertificates", []):
        raise ValueError("signing-certificate-profile-mismatch")
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID
            or info.get("CFBundleShortVersionString") != frozen.marketing_version
            or str(info.get("CFBundleVersion")) != frozen.build_number):
        raise ValueError("signed-app-metadata-mismatch")
    status("ipa-inspection-started")
    package_ipa(app, ipa)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        raise ValueError("signed-app-executable-invalid")
    with zipfile.ZipFile(ipa) as packaged:
        packaged_executable = packaged.read(f"Payload/{app.name}/{executable}")
    if hashlib.sha256(packaged_executable).hexdigest() != digest(app / executable):
        raise ValueError("ipa-executable-mismatch")
    return {
        "archiveSha256": digest(ipa), "metadataSha256": digest(info_path),
        "embeddedProfileSha256": digest(profile_path),
        "signingCertificateSha256": hashlib.sha256(certificate_bytes).hexdigest(),
        "cloudKitEnvironment": cloud,
    }


def build_proofs(frozen: Candidate, measured: dict) -> dict[str, dict]:
    """Emit only measured local proof fields; no upload validation occurred."""

    common = {
        "proofVersion": "1.0.0", "candidateId": frozen.candidate_id,
        "sourceDigest": frozen.source_digest, "result": "passed",
    }
    archive_sha = measured["archiveSha256"]
    profile_sha = measured["embeddedProfileSha256"]
    cert_sha = measured["signingCertificateSha256"]
    return {
        "production-build.json": {**common, "proofSchema": "release.proof.production-build.v1",
            "operationClass": "productionReleaseBuild", "configuration": "Production",
            "cleanBuild": True, "signingMode": "appStore", "artifactSha256": archive_sha},
        "archive.json": {**common, "operationClass": "archive", "archiveSha256": archive_sha},
        "signing.json": {**common, "operationClass": "sign", "archiveSha256": archive_sha,
            "signedArtifactSha256": archive_sha, "signatureType": "distribution",
            "embeddedProfileSha256": profile_sha, "signingCertificateSha256": cert_sha},
        "artifact.json": {**common, "operationClass": "artifactVerify", "archiveSha256": archive_sha,
            "signedArtifactSha256": archive_sha, "metadataSha256": measured["metadataSha256"],
            "bundleIdentifierSha256": hashlib.sha256(BUNDLE_ID.encode()).hexdigest(),
            "marketingVersionSha256": hashlib.sha256(frozen.marketing_version.encode()).hexdigest(),
            "buildNumber": frozen.build_number,
            "applicationIdentifierSha256": hashlib.sha256(f"{TEAM_ID}.{BUNDLE_ID}".encode()).hexdigest(),
            "teamIdentifierSha256": hashlib.sha256(TEAM_ID.encode()).hexdigest(),
            "configuration": "Production", "cloudKitEnvironment": measured["cloudKitEnvironment"],
            "signed": True, "embeddedProfileSha256": profile_sha,
            "signingCertificateSha256": cert_sha, "strictSignatureResult": "passed",
            "localInspectionResult": "passed"},
    }


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    path.chmod(0o600)


def publish(workspace: Path, frozen: Candidate, proofs: dict[str, dict]) -> None:
    """Publish after all checks, restoring prior outputs if a rename fails."""

    staged_evidence = workspace / "evidence"
    for name, proof in proofs.items():
        write(staged_evidence / name, proof)
    targets = (
        (ROOT / ".release-state/artifacts" / frozen.candidate_id, workspace / "artifacts"),
        (ROOT / ".release-state/evidence" / frozen.candidate_id, staged_evidence),
    )
    backups: list[tuple[Path, Path]] = []
    promoted: list[Path] = []
    try:
        for target, staged in targets:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            backup = workspace / f"backup-{target.parent.name}"
            if target.exists():
                target.rename(backup)
                backups.append((target, backup))
            staged.rename(target)
            promoted.append(target)
    except OSError:
        for target in reversed(promoted):
            shutil.rmtree(target)
        for target, backup in reversed(backups):
            backup.rename(target)
        raise
    for _, backup in backups:
        shutil.rmtree(backup)


def main() -> int:
    if sys.argv[1:] != ["--prepare-only"]:
        return 64
    try:
        frozen = candidate_data()
        adapter = source_adapter(frozen)
        state_root = ROOT / ".release-state"
        state_root.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="archive-build-", dir=state_root) as temporary:
            workspace = Path(temporary)
            staged = workspace / "source"
            try:
                materialize_source(staged, frozen, adapter)
                archive = build_archive(staged, workspace, frozen)
                if source_digest(staged, adapter) != frozen.source_digest:
                    raise ValueError("staged-source-changed-during-build")
                ipa = workspace / "artifacts/WiltediOS.ipa"
                measured = inspect_artifact(archive, ipa, frozen, workspace)
                if source_digest(staged, adapter) != frozen.source_digest:
                    raise ValueError("staged-source-changed-during-inspection")
                proofs = build_proofs(frozen, measured)
                verify_artifact_evidence(
                    frozen.manifest_path,
                    {"proofs": {"archive": proofs["archive.json"],
                                "signing": proofs["signing.json"],
                                "artifactVerify": proofs["artifact.json"]}},
                    bundle_identifier=BUNDLE_ID, team_identifier=TEAM_ID,
                )
                publish(workspace, frozen, proofs)
                status("proofs-published")
            finally:
                if staged.exists():
                    for directory, names, _ in os.walk(staged, topdown=False, followlinks=False):
                        for name in names:
                            path = Path(directory) / name
                            if not path.is_symlink():
                                path.chmod(0o700)
                        Path(directory).chmod(0o700)
    except (AdapterError, ReleaseStateError, SnapshotError, KeyError, OSError, TypeError,
            ValueError, subprocess.CalledProcessError, json.JSONDecodeError,
            plistlib.InvalidFileException, zipfile.BadZipFile) as exc:
        status(f"refused:{type(exc).__name__}")
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
