"""Regression tests for the fast daemon-only speech policy hook."""

from __future__ import annotations

import shutil
from pathlib import Path

from scripts import check_repo_policy


def _policy_fixture(tmp_path: Path) -> Path:
    """Copy just the files inspected by the static policy into a temporary repo."""
    root = Path(__file__).resolve().parent.parent
    for relative_path in (
        Path("README.md"),
        Path("Makefile"),
        Path("scripts/wilted-runtime.sh"),
        Path("src/wilted/engine.py"),
        Path("src/wilted/transcribe.py"),
    ):
        destination = tmp_path / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / relative_path, destination)
    return tmp_path


def test_current_repository_satisfies_daemon_only_policy() -> None:
    assert check_repo_policy.check_policy() == []


def test_policy_rejects_reintroduced_backend_selector(tmp_path: Path) -> None:
    root = _policy_fixture(tmp_path)
    engine = root / "src/wilted/engine.py"
    engine.write_text(
        engine.read_text(encoding="utf-8") + '\nbackend = os.getenv("WILTED_TTS_BACKEND")\n',
        encoding="utf-8",
    )

    failures = check_repo_policy.check_policy(root)

    assert any("backend environment selector" in failure for failure in failures)


def test_policy_rejects_guarded_client_import(tmp_path: Path) -> None:
    root = _policy_fixture(tmp_path)
    engine = root / "src/wilted/engine.py"
    source = engine.read_text(encoding="utf-8")
    engine.write_text(
        source.replace(
            "from speech_stack import client\n",
            "try:\n    from speech_stack import client\nexcept ImportError:\n    client = None\n",
            1,
        ),
        encoding="utf-8",
    )

    failures = check_repo_policy.check_policy(root)

    assert any("unconditional top-level import" in failure for failure in failures)


def test_policy_rejects_nullable_client_guard_after_hard_import(tmp_path: Path) -> None:
    root = _policy_fixture(tmp_path)
    transcribe = root / "src/wilted/transcribe.py"
    transcribe.write_text(
        transcribe.read_text(encoding="utf-8") + "\nclient: object | None = None\nif client is None:\n    pass\n",
        encoding="utf-8",
    )

    failures = check_repo_policy.check_policy(root)

    assert any("nullable speech client" in failure for failure in failures)


def test_policy_rejects_restored_in_process_model_path(tmp_path: Path) -> None:
    root = _policy_fixture(tmp_path)
    engine = root / "src/wilted/engine.py"
    engine.write_text(
        engine.read_text(encoding="utf-8")
        + "\ndef load_model():\n    pass\n\ndef synthesize(model, text):\n    return model.generate(text)\n",
        encoding="utf-8",
    )

    failures = check_repo_policy.check_policy(root)

    assert any("in-process model loader" in failure for failure in failures)
    assert any("in-process model generation" in failure for failure in failures)
