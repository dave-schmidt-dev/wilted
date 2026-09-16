#!/usr/bin/env python3
"""Fast static checks for Wilted's daemon-only speech and launch contract."""

from __future__ import annotations

import argparse
import ast
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SPEECH_SEAMS = (Path("src/wilted/engine.py"), Path("src/wilted/transcribe.py"))


def _read(root: Path, path: Path, failures: list[str]) -> str:
    """Read a required policy file, adding a clear failure when it is absent."""
    target = root / path
    if not target.is_file():
        failures.append(f"missing required policy file: {path}")
        return ""
    return target.read_text(encoding="utf-8")


def _has_unconditional_client_import(source: str) -> bool:
    """Return whether ``speech_stack.client`` is imported outside control flow."""
    try:
        module = ast.parse(source)
    except SyntaxError:
        return False

    for statement in module.body:
        if not isinstance(statement, ast.ImportFrom) or statement.module != "speech_stack":
            continue
        if any(alias.name == "client" and alias.asname is None for alias in statement.names):
            return True
    return False


def check_speech_routes(root: Path = REPO_ROOT) -> list[str]:
    """Reject backend selection or an in-process speech path in production seams."""
    failures: list[str] = []
    forbidden = {
        "backend environment selector": r"\bWILTED_(?:STT|TTS)_BACKEND\b",
        "backend selector helper": r"\b_(?:stt|tts)_backend\b",
        "in-process Kokoro import": r"(?:from|import)\s+mlx_audio\.tts(?:\.kokoro)?\b|\bKokoroTTS\b",
        "in-process Parakeet import": r"(?:from|import)\s+parakeet_mlx\b",
        "isolated STT fallback": r"\bisolated\.run\s*\(",
        "nullable speech client": r"\bclient(?:\s*:[^=\n]+)?\s*=\s*None\b|\bclient\s+is\s+None\b",
        "in-process model loader": r"\b_?load_model\s*\(",
        "in-process model generation": r"\b(?:self\.)?_?model\.generate\s*\(",
    }

    for path in SPEECH_SEAMS:
        source = _read(root, path, failures)
        if not source:
            continue
        if not _has_unconditional_client_import(source):
            failures.append(f"{path}: speech_stack.client must be an unconditional top-level import")
        for label, pattern in forbidden.items():
            if re.search(pattern, source):
                failures.append(f"{path}: forbidden {label} in daemon-only speech seam")
    return failures


def check_launch_contract(root: Path = REPO_ROOT) -> list[str]:
    """Ensure the documented launch path and Makefile daemon proxy stay aligned."""
    failures: list[str] = []
    readme = _read(root, Path("README.md"), failures)
    makefile = _read(root, Path("Makefile"), failures)

    required_readme_fragments = (
        "## Launch Contract",
        "alias wilted='~/Documents/Projects/wilted/scripts/wilted-runtime.sh'",
        "wilted-runtime.sh → /usr/local/bin/bws run → allowlisted environment",
        "wilted.cli:main",
        "~/.venvs/wilted",
        "make install-daemon",
        "daemon is mandatory",
    )
    for fragment in required_readme_fragments:
        if fragment not in readme:
            failures.append(f"README.md: missing launch-contract fragment: {fragment!r}")

    proxy_pattern = r"(?m)^install-daemon:\n\t\$\(MAKE\) -C .*speech-stack.* install-daemon$"
    if not re.search(proxy_pattern, makefile):
        failures.append("Makefile: install-daemon must proxy to speech-stack's install-daemon target")
    return failures


def check_policy(root: Path = REPO_ROOT) -> list[str]:
    """Run all fast, static repository policy checks."""
    return [*check_speech_routes(root), *check_launch_contract(root)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args()

    failures = check_policy(args.root.resolve())
    for failure in failures:
        print(f"policy: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
