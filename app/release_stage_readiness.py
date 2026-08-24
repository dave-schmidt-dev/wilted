#!/usr/bin/env python3
"""Emit a v2 content-bound readiness or local-gate proof for the frozen Wilted candidate."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONFIGURATION = "Production"
CONTRACT_REVISION = "wilted-ios-v2"
READINESS_SCHEMA_V2 = "release.proof.readiness.v2"
LOCAL_GATE_SCHEMA_V2 = "release.proof.local-gate.v2"
PROOF_VERSION = "2.0.0"


def fail(code: str) -> int:
    print(code, file=sys.stderr)
    return 4


def now_utc_iso() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def environment_closure(
    schema: str,
    configuration: str = CONFIGURATION,
    contract_revision: str = CONTRACT_REVISION,
) -> str:
    material = b"\0".join(
        (
            schema.encode("utf-8"),
            configuration.encode("utf-8"),
            contract_revision.encode("utf-8"),
        )
    )
    return hashlib.sha256(material).hexdigest()


def git_common_candidates_dir(root: Path = ROOT) -> Path:
    common = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return Path(common).resolve() / "release-state" / "wilted-ios" / "candidates"


def validate_manifest_path(
    supplied: Path,
    candidates_root: Path | None = None,
    root: Path = ROOT,
) -> Path:
    if supplied.is_symlink():
        raise ValueError("readiness-manifest-invalid")
    if candidates_root is None:
        candidates_root = git_common_candidates_dir(root)
    resolved = supplied.resolve(strict=True)
    if (
        resolved.is_symlink()
        or resolved.parent.parent != candidates_root.resolve()
        or resolved.name != "manifest.json"
    ):
        raise ValueError("readiness-manifest-invalid")
    return resolved


def manifest_path(root: Path = ROOT) -> Path:
    supplied_str = os.environ.get("READINESS_MANIFEST")
    if not supplied_str:
        raise ValueError("readiness-manifest-invalid")
    return validate_manifest_path(Path(supplied_str), root=root)


def parse_manifest(raw: bytes) -> tuple[str, str]:
    manifest = json.loads(raw)
    if not isinstance(manifest, dict):
        raise ValueError("readiness-manifest-invalid")
    candidate = manifest.get("candidateId")
    source_snapshot = manifest.get("sourceSnapshot")
    source = (
        source_snapshot.get("sha256") if isinstance(source_snapshot, dict) else None
    )
    if (
        not isinstance(candidate, str)
        or not candidate
        or not isinstance(source, str)
        or len(source) != 64
    ):
        raise ValueError("readiness-manifest-invalid")
    return candidate, source


def build_proof(
    raw_manifest: bytes,
    candidate: str,
    source: str,
    *,
    local_gate: bool = False,
    configuration: str = CONFIGURATION,
    contract_revision: str = CONTRACT_REVISION,
    observed_at: str | None = None,
) -> dict[str, Any]:
    observed = observed_at if observed_at is not None else now_utc_iso()
    if local_gate:
        schema = LOCAL_GATE_SCHEMA_V2
        closure = environment_closure(
            schema,
            configuration=configuration,
            contract_revision=contract_revision,
        )
        material = b"\0".join(
            (raw_manifest, configuration.encode("utf-8"), b"authoritative")
        )
        return {
            "proofVersion": PROOF_VERSION,
            "proofSchema": schema,
            "operationClass": "localGate",
            "candidateId": candidate,
            "sourceDigest": source,
            "result": "passed",
            "observedAt": observed,
            "configuration": configuration,
            "scope": "authoritative",
            "environmentClosureSha256": closure,
            "evidenceSha256": hashlib.sha256(material).hexdigest(),
        }

    schema = READINESS_SCHEMA_V2
    closure = environment_closure(
        schema,
        configuration=configuration,
        contract_revision=contract_revision,
    )
    return {
        "proofVersion": PROOF_VERSION,
        "proofSchema": schema,
        "operationClass": "readiness",
        "candidateId": candidate,
        "sourceDigest": source,
        "result": "passed",
        "observedAt": observed,
        "environmentClosureSha256": closure,
        "evidenceSha256": hashlib.sha256(raw_manifest).hexdigest(),
    }


def write_proof(destination: Path, proof: dict[str, Any]) -> None:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp")
    content = json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n"
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(destination)


def main(argv: list[str] | None = None, root: Path = ROOT) -> int:
    if argv is None:
        argv = sys.argv[1:]
    local_gate = argv == ["--local-gate"]
    if argv not in ([], ["--local-gate"]):
        return fail("readiness-arguments-invalid")
    try:
        path = manifest_path(root=root)
        raw = path.read_bytes()
        candidate, source = parse_manifest(raw)
        if path.parent.name != candidate:
            raise ValueError("readiness-manifest-invalid")
        name = "local-gate.json" if local_gate else "readiness.json"
        proof = build_proof(
            raw,
            candidate=candidate,
            source=source,
            local_gate=local_gate,
            configuration=CONFIGURATION,
            contract_revision=CONTRACT_REVISION,
        )
        destination = root / ".release-state" / "evidence" / candidate / name
        write_proof(destination, proof)
    except (
        KeyError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ):
        return fail("readiness-manifest-invalid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
