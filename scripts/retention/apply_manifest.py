"""Apply a fresh, reviewed one-time storage cleanup manifest.

Dry-run is the default. This executor only removes files or trees below the
repository's .logs directory; build caches and application backups are handled
by their lock-aware policy owners. It rechecks identity, replacement evidence,
pins, and open references immediately before calling the shared core remover.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
import zipfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from retention.core import (
    ArchiveError,
    lsof_only_external_smbfs_warning,
    remove_tree_verified,
    snapshot_tree,
)
from retention.evidence import _open_reference, pinned_paths, protected
from retention.manifest_recovery import RecoveryError, safe_member, verify_git_pack


SCHEMA_VERSION = 2
OPEN_FILE_REFRESH_ITEMS = 1000
OPEN_FILE_MAX_AGE_SECONDS = 5.0
RECEIPT_REFRESH_ITEMS = 100
SOURCE_MANIFESTS = (
    ".logs/retention-audit-2026-11-04/file-decisions.json",
    ".logs/retention-other-2026-11-04/decisions.json",
    ".logs/retention-audit-2026-11-04/archive-reconstruction-map.json",
    ".logs/retention-other-2026-11-04/archive-reconstruction-map.json",
    ".logs/retention-other-2026-11-04/test-results.json",
    ".logs/retention-other-2026-11-04/system-results.json",
)
MEDIA_SUFFIXES = {
    ".m4a", ".mp3", ".wav", ".caf", ".aiff", ".aif", ".aac", ".flac", ".ogg",
    ".mov", ".mp4", ".m4v", ".3gp", ".png", ".jpg", ".jpeg", ".heic", ".gif",
    ".webp", ".tif", ".tiff", ".bmp",
}
_ZIP_CACHE: dict[Path, dict[str, str]] = {}


class ManifestError(RuntimeError):
    """The cleanup manifest or its evidence failed validation."""


class LivenessError(ManifestError):
    """A whole-root open-file snapshot was unavailable or stale."""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_relative(value: object) -> Path:
    """Accept only a lexical repository-relative .logs path."""
    if not isinstance(value, str) or not value or "\\" in value:
        raise ManifestError("manifest-path-invalid")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] != ".logs":
        raise ManifestError("manifest-path-outside-logs")
    return relative


def _manifest_path(repo: Path, raw: object) -> Path:
    """Resolve a required manifest-side file beneath a reserved audit root."""
    relative = _safe_relative(raw)
    candidate = repo / relative
    if not candidate.is_file() or candidate.is_symlink():
        raise ManifestError("replacement-pack-missing-or-linked")
    return candidate


def _zip_rows(path: Path) -> dict[str, str]:
    """Verify a ZIP's CRC and content hashes once per invocation."""
    path = path.absolute()
    if path in _ZIP_CACHE:
        return _ZIP_CACHE[path]
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            if len(names) != len(archive.namelist()):
                raise ManifestError("replacement-pack-duplicate-members")
            if "manifest.json" not in names:
                raise ManifestError("replacement-pack-manifest-missing")
            rows = json.loads(archive.read("manifest.json"))
            if not isinstance(rows, list):
                raise ManifestError("replacement-pack-manifest-invalid")
            digests: dict[str, str] = {}
            expected_members = {"manifest.json"}
            for row in rows:
                if not isinstance(row, dict):
                    raise ManifestError("replacement-pack-row-invalid")
                name = row.get("path")
                digest = row.get("sha256")
                member = row.get("member", digest)
                if not isinstance(name, str) or not isinstance(digest, str) or not isinstance(member, str):
                    raise ManifestError("replacement-pack-row-invalid")
                content = archive.read(member)
                if len(content) != int(row.get("size", -1)) or _sha256(content) != digest:
                    raise ManifestError("replacement-pack-content-hash-failed")
                if name in digests:
                    raise ManifestError("replacement-pack-path-duplicate")
                digests[name] = digest
                expected_members.add(member)
            if names != expected_members:
                raise ManifestError("replacement-pack-unindexed-members")
            _ZIP_CACHE[path] = digests
            return digests
    except (OSError, KeyError, TypeError, ValueError, zipfile.BadZipFile) as error:
        if isinstance(error, ManifestError):
            raise
        raise ManifestError("replacement-pack-invalid") from error


def _verify_zip_member(repo: Path, replacement: dict[str, Any]) -> None:
    """Verify a single member in a content-addressed historical ZIP."""
    pack = _manifest_path(repo, replacement.get("pack"))
    member = replacement.get("member")
    expected = replacement.get("sha256")
    if not isinstance(member, str) or not isinstance(expected, str):
        raise ManifestError("zip-member-reference-invalid")
    index = _pack_hash_index(pack)
    if index.get(member) != expected:
        raise ManifestError("zip-member-hash-mismatch")


def _pack_hash_index(path: Path) -> dict[str, str]:
    """Verify either an indexed content pack or a legacy path-keyed ZIP once."""
    path = path.absolute()
    if path in _ZIP_CACHE:
        return _ZIP_CACHE[path]
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ManifestError("replacement-pack-duplicate-members")
            if "manifest.json" in names:
                return _zip_rows(path)
            else:
                index = {}
                for member in names:
                    data = archive.read(member)
                    index[member] = _sha256(data)
            _ZIP_CACHE[path] = index
            return index
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as error:
        if isinstance(error, ManifestError):
            raise
        raise ManifestError("replacement-pack-invalid") from error


def _verify_pack_members(repo: Path, replacement: dict[str, Any]) -> None:
    """Verify mapped fresh exports against the retained indexed ZIP pack."""
    pack = _manifest_path(repo, replacement.get("pack"))
    expected = replacement.get("members")
    fresh = replacement.get("fresh_outputs")
    if not isinstance(expected, list) or not isinstance(fresh, dict) or not expected:
        raise ManifestError("replacement-member-map-invalid")
    index = _pack_hash_index(pack)
    expected_hashes: dict[str, str] = {}
    for row in expected:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise ManifestError("replacement-member-row-invalid")
        path, digest = row["path"], row.get("sha256")
        if not isinstance(digest, str) or index.get(path) != digest:
            raise ManifestError("replacement-pack-member-mismatch")
        expected_hashes[str(row.get("output", ""))] = digest
    if fresh != expected_hashes:
        raise ManifestError("fresh-export-does-not-match-retained-pack")


def verify_replacement(repo: Path, replacement: object, *, git_index: dict[str, dict[str, Any]],
                       source_sha256: str | None,
                       source_fingerprint: str | None) -> None:
    """Check a row's durable replacement without trusting its status flag."""
    if not isinstance(replacement, dict):
        raise ManifestError("replacement-descriptor-missing")
    kind = replacement.get("kind")
    if kind == "git-blob":
        pack = _manifest_path(repo, replacement.get("pack"))
        canonical_pack = repo / ".logs/retention-implementation-2026-11-04/recovery-git-blobs.zip"
        if pack != canonical_pack:
            raise ManifestError("git-recovery-pack-must-be-canonical-audit-pack")
        if not git_index:
            git_index.update(verify_git_pack(canonical_pack))
        index = git_index
        oid = replacement.get("git_blob")
        row = index.get(oid) if isinstance(oid, str) else None
        if (row is None or row.get("sha256") != replacement.get("sha256") or
                replacement.get("sha256") != source_sha256):
            raise ManifestError("git-recovery-reference-mismatch")
    elif kind == "zip-member":
        if replacement.get("sha256") != source_sha256:
            raise ManifestError("replacement-does-not-match-source-bytes")
        _verify_zip_member(repo, replacement)
    elif kind == "file":
        if replacement.get("sha256") != source_sha256:
            raise ManifestError("replacement-does-not-match-source-bytes")
        relative = _safe_relative(replacement.get("retained_path"))
        path = repo / relative
        snapshot = snapshot_tree(path, root=repo / ".logs")
        if snapshot.digest != replacement.get("sha256"):
            raise ManifestError("retained-file-hash-mismatch")
    elif kind in {"test-bundle", "system-filter"}:
        _verify_pack_members(repo, replacement)
        if (not isinstance(replacement.get("source_fingerprint"), str) or
                replacement.get("source_fingerprint") != source_fingerprint):
            raise ManifestError("fresh-source-fingerprint-missing")
    elif kind == "source-archive":
        if replacement.get("archive_sha256") != source_sha256:
            raise ManifestError("replacement-does-not-match-source-archive")
        map_path = _manifest_path(repo, replacement.get("map"))
        mapping = json.loads(map_path.read_text(encoding="utf-8"))
        matches = [row for row in mapping if isinstance(row, dict) and
                   row.get("archive") == replacement.get("archive")]
        if len(matches) != 1 or matches[0].get("archive_sha256") != replacement.get("archive_sha256"):
            raise ManifestError("source-map-archive-reference-mismatch")
        pack = _manifest_path(repo, replacement.get("content_pack"))
        content_index = _pack_hash_index(pack)
        seen_members: set[str] = set()
        for member in matches[0].get("members", []):
            if not isinstance(member, dict) or not isinstance(member.get("name"), str):
                raise ManifestError("source-map-member-invalid")
            member_path = safe_member(member["name"]).as_posix()
            if member_path in seen_members:
                raise ManifestError("source-map-member-duplicate")
            seen_members.add(member_path)
            if member.get("type") == "b'5'":
                if member.get("sha256") is not None or member.get("size") is not None:
                    raise ManifestError("source-map-directory-has-file-content")
                continue
            if member.get("type") is not None:
                raise ManifestError("source-map-member-type-unsupported")
            digest = member.get("sha256")
            retained = member.get("retained_in")
            if retained == "git":
                if not git_index:
                    git_index.update(verify_git_pack(repo / ".logs/retention-implementation-2026-11-04/recovery-git-blobs.zip"))
                oid = member.get("git_blob")
                git_row = git_index.get(oid) if isinstance(oid, str) else None
                if git_row is None or git_row.get("sha256") != digest:
                    raise ManifestError("source-member-git-reference-mismatch")
            elif content_index.get(digest) != digest:
                raise ManifestError("source-member-content-missing-or-corrupt")
    elif kind == "approved-removal":
        # The original owner-approved decision is the replacement rationale.
        # Exact source SHA and path identity remain mandatory at apply time.
        if replacement.get("owner_decision") != "remove":
            raise ManifestError("unapproved-no-replacement-removal")
    else:
        raise ManifestError("replacement-kind-unsupported")


def _pins(repo: Path, path: Path, pins: tuple[Path, ...]) -> bool:
    """Protect exact citations, their ancestors, and directories containing them."""
    absolute = path.absolute()
    if any(absolute == pin or pin in absolute.parents or absolute in pin.parents for pin in pins):
        return True
    return protected(absolute, repo=repo, pins=pins)


def _current_identity(repo: Path, item: dict[str, Any]) -> tuple[Path, Any]:
    """Resolve one approved .logs path and compare its prepared fingerprint."""
    relative = _safe_relative(item.get("path"))
    logs = repo / ".logs"
    target = repo / relative
    snapshot = snapshot_tree(target, root=logs)
    expected = item.get("fingerprint")
    if not isinstance(expected, dict):
        raise ManifestError("prepared-fingerprint-missing")
    identity_fields = ("digest", "bytes", "device", "inode", "mode", "mtime_ns", "ctime_ns")
    current_fields = {"digest": snapshot.digest, "bytes": snapshot.bytes,
                      "device": snapshot.device, "inode": snapshot.inode,
                      "mode": snapshot.mode, "mtime_ns": snapshot.mtime_ns,
                      "ctime_ns": snapshot.ctime_ns}
    if any(current_fields[key] != expected.get(key) for key in identity_fields):
        raise ManifestError("target-changed-since-preparation")
    old_hash = item.get("source_sha256")
    if old_hash and snapshot.digest != old_hash:
        raise ManifestError("target-does-not-match-audit-hash")
    old_size = item.get("source_bytes")
    if isinstance(old_size, int) and snapshot.bytes != old_size:
        raise ManifestError("target-does-not-match-audit-size")
    return target, snapshot


def _batch_open_files(root: Path, timeout: int = 10) -> tuple[set[Path], float]:
    """Take one global open-file snapshot and filter paths under ``root``."""
    executable = shutil.which("lsof")
    if executable is None:
        raise ManifestError("lsof-unavailable")
    try:
        result = subprocess.run((executable, "-nP", "-F0n"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise ManifestError("lsof-probe-failed-or-timed-out") from error
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return set(), time.monotonic()
    warning_only = bool(result.stderr.strip()) and lsof_only_external_smbfs_warning(result.stderr, root)
    if result.returncode not in {0, 1} or (result.stderr.strip() and not warning_only):
        raise ManifestError("lsof-probe-error")
    if result.returncode == 1 and not warning_only:
        raise ManifestError("lsof-probe-error")
    paths: set[Path] = set()
    saw_name = False
    root_path = Path(os.path.normpath(str(root.absolute())))
    fields = result.stdout.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if fields and fields[-1] == b"\n":
        fields.pop()
    for field in fields:
        if field.startswith(b"\n"):
            field = field[1:]
        if field.startswith(b"n"):
            try:
                raw_name = field[1:]
                if not raw_name:
                    continue
                name = Path(os.fsdecode(raw_name))
                if name.is_absolute():
                    absolute = Path(os.path.normpath(str(name)))
                    if absolute == root_path or root_path in absolute.parents:
                        paths.add(absolute)
                saw_name = True
            except (OSError, ValueError):
                raise ManifestError("lsof-path-output-invalid")
        elif field.startswith(b"p") and field[1:].isdigit():
            continue
        elif field.startswith(b"f") and len(field) > 1:
            continue
        else:
            raise ManifestError("lsof-path-output-invalid")
    if fields and not saw_name:
        raise ManifestError("lsof-path-output-invalid")
    return paths, time.monotonic()


def _is_open(target: Path, opened: set[Path]) -> bool:
    """Match an open file exactly or any open descendant of a directory."""
    if target in opened:
        return True
    return target.is_dir() and any(target in path.parents for path in opened)


def _load_manifest_bound(path: Path, repo: Path) -> tuple[dict[str, Any], str]:
    """Parse and validate one manifest byte sequence, returning its digest."""
    if path.is_symlink() or not path.is_file():
        raise ManifestError("cleanup-manifest-missing-or-linked")
    try:
        manifest_bytes = path.read_bytes()
        data = json.loads(manifest_bytes.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError("cleanup-manifest-invalid") from error
    if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
        raise ManifestError("cleanup-manifest-schema-mismatch")
    if Path(str(data.get("workspace", ""))).resolve() != repo.resolve():
        raise ManifestError("cleanup-workspace-mismatch")
    if not isinstance(data.get("items"), list):
        raise ManifestError("cleanup-item-list-invalid")
    bindings = data.get("source_manifests")
    if not isinstance(bindings, dict) or set(bindings) != set(SOURCE_MANIFESTS):
        raise ManifestError("source-manifest-bindings-incomplete")
    original_rows: dict[str, list[dict[str, Any]]] = {}
    for relative in SOURCE_MANIFESTS:
        source = repo / relative
        if source.is_symlink() or not source.is_file():
            raise ManifestError("source-manifest-hash-mismatch")
        try:
            source_bytes = source.read_bytes()
            if _sha256(source_bytes) != bindings.get(relative):
                raise ManifestError("source-manifest-hash-mismatch")
            rows = json.loads(source_bytes.decode("utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ManifestError("source-manifest-invalid") from error
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise ManifestError("source-manifest-row-invalid")
        original_rows[relative] = rows
    origins = {
        ".logs/retention-audit-2026-11-04/file-decisions.json": "action",
        ".logs/retention-other-2026-11-04/decisions.json": "decision",
    }
    for item in data["items"]:
        if not isinstance(item, dict) or item.get("status") != "ready":
            continue
        origin = item.get("origin")
        action_key = origins.get(str(origin))
        row_number = item.get("row")
        if action_key is None or not isinstance(row_number, int) or row_number < 0:
            raise ManifestError("ready-item-missing-audit-row-binding")
        source_rows = original_rows[str(origin)]
        if row_number >= len(source_rows):
            raise ManifestError("ready-item-audit-row-out-of-range")
        source_row = source_rows[row_number]
        audited_action = source_row.get(action_key)
        if (source_row.get("path") != item.get("path") or
                audited_action != item.get("decision") or audited_action not in {"remove", "replace"}):
            raise ManifestError("audit-decision-does-not-authorize-item")
        if source_row.get("sha256") is not None and item.get("source_sha256") != source_row.get("sha256"):
            raise ManifestError("source-hash-does-not-match-audit")
        if source_row.get("size") is not None and item.get("source_bytes") != source_row.get("size"):
            raise ManifestError("source-size-does-not-match-audit")
        suffix = Path(str(item.get("path"))).suffix.lower()
        replacement = item.get("replacement")
        if suffix in MEDIA_SUFFIXES:
            approved_video = (suffix == ".mp4" and
                "historical automated UI-test recording" in str(source_row.get("reason", "")) and
                "not original ad-feedback media" in str(source_row.get("reason", "")))
            approved_duplicate_png = False
            if (suffix == ".png" and audited_action == "remove" and
                    source_row.get("reason") == "SHA-256 identical duplicate; retained canonical path recorded" and
                    isinstance(replacement, dict) and replacement.get("kind") == "file" and
                    replacement.get("sha256") == item.get("source_sha256")):
                retained_at = str(source_row.get("retained_at", "")).split(";", 1)[0].strip()
                approved_duplicate_png = (
                    retained_at.startswith(".logs/") and
                    replacement.get("retained_path") == retained_at and
                    retained_at != item.get("path"))
            approved_git_png = (
                suffix == ".png" and audited_action == "remove" and
                source_row.get("reason") == "exact file bytes verified in reachable Git objects" and
                source_row.get("in_git") is True and
                isinstance(source_row.get("git_blob"), str) and
                str(source_row.get("retained_at", "")) == f"git blob {source_row.get('git_blob')}" and
                isinstance(replacement, dict) and replacement.get("kind") == "git-blob" and
                replacement.get("git_blob") == source_row.get("git_blob") and
                replacement.get("sha256") == item.get("source_sha256"))
            if not (approved_video or approved_duplicate_png or approved_git_png):
                raise ManifestError("original-media-preserved")
        if (isinstance(replacement, dict) and replacement.get("kind") == "approved-removal" and
                audited_action != "remove"):
            raise ManifestError("replacement-kind-not-authorized-by-audit")
    return data, _sha256(manifest_bytes)


def load_manifest(path: Path, repo: Path) -> dict[str, Any]:
    """Load a cleanup input document and validate its source-manifest binding."""
    data, _ = _load_manifest_bound(path, repo)
    return data


def apply_manifest(repo: Path, manifest_path: Path, *, apply: bool = False,
                   receipt: Path | None = None) -> dict[str, Any]:
    """Report or apply only items that still match the verified manifest."""
    repo = repo.expanduser().absolute()
    if repo.is_symlink() or not repo.is_dir() or repo.resolve(strict=True) != repo:
        raise ManifestError("workspace-root-invalid")
    manifest, manifest_digest = _load_manifest_bound(manifest_path, repo)
    pins = pinned_paths(repo)
    if pins is None:
        raise ManifestError("citation-documents-unreadable")
    git_index: dict[str, dict[str, Any]] = {}
    results: list[dict[str, Any]] = []
    prior_results: dict[str, dict[str, Any]] = {}
    if apply and receipt and receipt.exists():
        try:
            previous = json.loads(receipt.read_text(encoding="utf-8"))
            if previous.get("manifest_sha256") != manifest_digest:
                raise ManifestError("existing-receipt-belongs-to-another-manifest")
            prior_results = {str(row.get("path")): row for row in previous.get("items", [])
                             if isinstance(row, dict) and row.get("status") == "removed"}
        except (OSError, ValueError, AttributeError) as error:
            if isinstance(error, ManifestError):
                raise
            raise ManifestError("existing-receipt-invalid") from error
    eligible_paths = {
        str(item.get("path")) for item in manifest["items"]
        if isinstance(item, dict) and item.get("status") == "ready" and item.get("scope") == "repo-logs"
    }
    referenced_paths = {
        str(item.get("replacement", {}).get("retained_path"))
        for item in manifest["items"]
        if isinstance(item, dict) and item.get("status") == "ready" and
        isinstance(item.get("replacement"), dict) and item["replacement"].get("retained_path")
    }
    logs_root = repo / ".logs"
    opened: set[Path] = set()
    open_status = "not-checked"
    open_snapshot_at = 0.0
    processed = 0

    def refresh_liveness() -> None:
        """Cache a recent whole-root lsof snapshot, retrying a stale response."""
        nonlocal opened, open_status, open_snapshot_at
        print(f"retention-apply: liveness refresh before item {scan_index + 1}/{len(manifest['items'])}",
              file=sys.stderr, flush=True)
        open_status = "unknown"
        for _ in range(2):
            try:
                snapshot, observed = _batch_open_files(logs_root)
            except ManifestError as error:
                raise LivenessError(str(error)) from error
            age = time.monotonic() - observed
            if 0 <= age <= OPEN_FILE_MAX_AGE_SECONDS:
                opened, open_snapshot_at = snapshot, observed
                open_status = "verified"
                return
        raise LivenessError("liveness-snapshot-too-old")

    liveness_failure: str | None = None
    for scan_index, item in enumerate(manifest["items"]):
        if not isinstance(item, dict):
            raise ManifestError("cleanup-row-invalid")
        source_path = str(item.get("path", ""))
        if source_path in prior_results:
            results.append(prior_results[source_path])
            continue
        result: dict[str, Any] = {"path": source_path, "status": "skipped"}
        if item.get("scope") != "repo-logs" or item.get("status") != "ready":
            result["reason"] = str(item.get("skip_reason", "not-authorized-for-manifest-apply"))
            results.append(result)
            continue
        if source_path in referenced_paths:
            result["reason"] = "referenced-by-another-cleanup-item"
            results.append(result)
            continue
        try:
            if (processed % OPEN_FILE_REFRESH_ITEMS == 0 or
                    open_status != "verified" or
                    time.monotonic() - open_snapshot_at > OPEN_FILE_MAX_AGE_SECONDS):
                refresh_liveness()
            target, expected = _current_identity(repo, item)
            if _pins(repo, target, pins):
                raise ManifestError("pinned-or-reserved")
            if item.get("decision") not in {"remove", "replace"}:
                raise ManifestError("decision-not-removal")
            replacement = item.get("replacement")
            verify_replacement(repo, replacement, git_index=git_index,
                source_sha256=item.get("source_sha256"),
                source_fingerprint=str(item.get("fingerprint", {}).get("digest", "")))
            if not isinstance(replacement, dict):
                raise ManifestError("replacement-descriptor-missing")
            # A direct-file replacement cannot itself be another removal target.
            retained_path = replacement.get("retained_path")
            if retained_path and str(retained_path) in eligible_paths:
                raise ManifestError("replacement-is-also-scheduled-for-removal")
            if time.monotonic() - open_snapshot_at > OPEN_FILE_MAX_AGE_SECONDS:
                refresh_liveness()
                if _is_open(target, opened):
                    raise ManifestError("open-file-reference")
            if open_status != "verified":
                raise ManifestError("liveness-not-verified")
            if _is_open(target, opened):
                raise ManifestError("open-file-reference")
            # No-replacement removals and bundle directories get a direct probe
            # immediately before the final identity check; other files use the
            # time-bounded batched probe to avoid one lsof process per file.
            if replacement.get("kind") == "approved-removal" or target.is_dir():
                busy, reason = _open_reference(target)
                if busy:
                    raise ManifestError(reason or "open-or-liveness-unknown")
            current = snapshot_tree(target, root=repo / ".logs")
            if current != expected:
                raise ManifestError("target-changed-before-removal")
            if apply:
                remove_tree_verified(target, expected, root=repo / ".logs")
                result.update(status="removed", reason="verified-audit-decision")
            else:
                result.update(status="would-remove", reason="verified-audit-decision")
        except LivenessError as error:
            result["reason"] = str(error)
            results.append(result)
            liveness_failure = str(error)
            break
        except (OSError, ArchiveError, ManifestError, RecoveryError, ValueError, KeyError) as error:
            result["reason"] = str(error)
        results.append(result)
        processed += 1
        if processed % 100 == 0:
            print(f"retention-apply: processed {processed} manifest items", file=sys.stderr, flush=True)
        if apply and receipt and processed % RECEIPT_REFRESH_ITEMS == 0:
            partial = {"schema_version": 1, "mode": "apply", "workspace": str(repo),
                       "manifest_sha256": manifest_digest, "started_at": time.time(),
                       "liveness": open_status, "partial": True,
                       "items": results}
            _atomic_receipt(receipt, partial)
    counts: dict[str, int] = {}
    for row in results:
        key = str(row["status"])
        counts[key] = counts.get(key, 0) + 1
    if liveness_failure and apply and receipt:
        partial = {"schema_version": 1, "mode": "apply", "workspace": str(repo),
                   "manifest_sha256": manifest_digest, "started_at": time.time(),
                   "liveness": open_status, "partial": True, "items": results}
        _atomic_receipt(receipt, partial)
    if liveness_failure:
        print(f"retention-apply: stopped at item {scan_index + 1}/{len(manifest['items'])}; "
              f"liveness unavailable: {liveness_failure}", file=sys.stderr, flush=True)
    return {"schema_version": 1, "mode": "apply" if apply else "dry-run",
            "workspace": str(repo), "manifest_sha256": manifest_digest,
            "started_at": time.time(), "finished_at": time.time(), "liveness": open_status,
            "partial": bool(liveness_failure), "reason": liveness_failure,
            "counts": counts, "items": results}


def _atomic_receipt(path: Path, result: dict[str, Any]) -> None:
    """Persist a result receipt atomically after actual apply."""
    path = path.expanduser().absolute()
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ManifestError("receipt-path-invalid")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex + ".partial")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="verify and report without removing")
    mode.add_argument("--apply", action="store_true", help="remove only still-matching audited .logs items")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--manifest", type=Path,
                        default=Path(".logs/retention-implementation-2026-11-04/cleanup-inputs.json"))
    parser.add_argument("--receipt", type=Path,
                        default=Path(".logs/retention-implementation-2026-11-04/cleanup-receipt.json"))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    repo = args.repo.expanduser().absolute()
    manifest_path = args.manifest.expanduser()
    if not manifest_path.is_absolute():
        manifest_path = repo / manifest_path
    try:
        receipt = args.receipt if args.receipt.is_absolute() else repo / args.receipt
        result = apply_manifest(repo, manifest_path, apply=bool(args.apply),
                                receipt=receipt if args.apply else None)
        if args.apply:
            _atomic_receipt(receipt, result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (OSError, ManifestError, RecoveryError, ArchiveError, ValueError) as error:
        print(json.dumps({"status": "error", "reason": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
