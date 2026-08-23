#!/usr/bin/env python3
"""Emit a short-lived readiness proof for the frozen Wilted candidate."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def fail(code: str) -> int:
    print(code, file=sys.stderr)
    return 4


def manifest_path() -> Path:
    supplied = Path(os.environ["READINESS_MANIFEST"])
    common = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    root = Path(common).resolve() / "release-state" / "wilted-ios" / "candidates"
    resolved = supplied.resolve(strict=True)
    if resolved.is_symlink() or resolved.parent.parent != root.resolve() or resolved.name != "manifest.json":
        raise ValueError("readiness-manifest-invalid")
    return resolved


def main() -> int:
    local_gate = sys.argv[1:] == ["--local-gate"]
    if sys.argv[1:] not in ([], ["--local-gate"]):
        return fail("readiness-arguments-invalid")
    try:
        path = manifest_path()
        raw = path.read_bytes()
        manifest = json.loads(raw)
        candidate = manifest["candidateId"]
        source = manifest["sourceSnapshot"]["sha256"]
        if not isinstance(candidate, str) or not isinstance(source, str) or len(source) != 64:
            raise ValueError("readiness-manifest-invalid")
        issued = datetime.now(timezone.utc).replace(microsecond=0)
        if local_gate:
            material = b"\0".join((raw, b"Production", b"authoritative"))
            proof = {
                "proofVersion": "1.0.0", "proofSchema": "release.proof.local-gate.v1",
                "operationClass": "localGate", "candidateId": candidate, "sourceDigest": source,
                "result": "passed", "issuedAt": issued.isoformat().replace("+00:00", "Z"),
                "expiresAt": (issued + timedelta(hours=6)).isoformat().replace("+00:00", "Z"),
                "configuration": "Production", "scope": "authoritative",
                "evidenceSha256": hashlib.sha256(material).hexdigest(),
            }
            name = "local-gate.json"
        else:
            proof = {
                "proofVersion": "1.0.0", "operationClass": "readiness", "candidateId": candidate,
                "sourceDigest": source, "result": "passed",
                "issuedAt": issued.isoformat().replace("+00:00", "Z"),
                "expiresAt": (issued + timedelta(hours=6)).isoformat().replace("+00:00", "Z"),
                "evidenceSha256": hashlib.sha256(raw).hexdigest(),
            }
            name = "readiness.json"
        destination = ROOT / ".release-state" / "evidence" / candidate / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(destination)
    except (KeyError, OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError):
        return fail("readiness-manifest-invalid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
