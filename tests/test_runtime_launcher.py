"""Behavioral tests for the least-privilege Wilted runtime launcher."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "scripts" / "wilted-runtime.sh"


def _write_executable(path: Path, content: str) -> None:
    """Write an executable shell stub used only by a subprocess test."""
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def _runtime_environment(
    tmp_path: Path,
    *,
    missing_secret: bool = False,
    security_fails: bool = False,
    bws_leaks_credentials: bool = False,
) -> tuple[dict, Path, Path]:
    """Create fake Keychain, BWS, and uv commands without real secrets."""
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    capture = tmp_path / "capture"
    marker = tmp_path / "bws-marker"

    security = "#!/usr/bin/env bash\n"
    if security_fails:
        security += "exit 1\n"
    else:
        security += "printf '%s' 'test-runtime-token'\n"
    _write_executable(fake_bin / "security", security)

    missing_export = "" if missing_secret else "export WILTED_FEED_NPR_PLUS_WAIT_WAIT='feed-c'\n"
    remove_bws_state = "" if bws_leaks_credentials else "unset BWS_ACCESS_TOKEN BWS_PROJECT_ID\n"
    _write_executable(
        fake_bin / "bws",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s' \"${BWS_ACCESS_TOKEN:-missing}\" > \"$BWS_MARKER\"\n"
        "[[ \"$1\" == run && \"$2\" == -- ]]\n"
        "shift 2\n"
        "export WILTED_FEED_NPR_PLUS_HOW_TO_DO_EVERYTHING='feed-a'\n"
        "export WILTED_FEED_NPR_PLUS_POP_CULTURE_HAPPY_HOUR='feed-b'\n"
        + missing_export
        + "export BWS_PROJECT_ID='not-for-wilted'\n"
        + "export UNRELATED_SECRET='not-for-wilted'\n"
        + remove_bws_state
        + "exec \"$@\"\n",
    )

    test_launcher = tmp_path / "wilted-runtime.sh"
    test_launcher.write_text(
        SCRIPT.read_text(encoding="utf-8")
        .replace('readonly BWS_BINARY="/usr/local/bin/bws"', f'readonly BWS_BINARY="{fake_bin / "bws"}"')
        .replace('readonly SECURITY_BINARY="/usr/bin/security"', f'readonly SECURITY_BINARY="{fake_bin / "security"}"')
        .replace('readonly UV_BINARY="/Users/dave/.local/bin/uv"', f'readonly UV_BINARY="{fake_bin / "uv"}"'),
        encoding="utf-8",
    )
    test_launcher.chmod(0o755)
    _write_executable(
        fake_bin / "uv",
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "env | sort > \"$TMPDIR/capture\"\n"
        "printf '%s\\n' \"$@\" > \"$TMPDIR/capture.args\"\n",
    )

    env = {
        "HOME": str(tmp_path / "home"),
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
        "TMPDIR": str(tmp_path),
        "BWS_MARKER": str(marker),
        "BWS_ACCESS_TOKEN": "inherited-token-must-not-reach-wilted",
        "BWS_PROJECT_ID": "inherited-project-must-not-reach-wilted",
        "UNRELATED_SECRET": "inherited-unrelated-must-not-reach-wilted",
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
        "WILTED_DEBUG": "1",
        "WILTED_WEATHER_TEST_TRIGGER": "/tmp/wilted-trigger",
        "NERD_FONTS": "1",
        "WILTED_TRANSCRIBE_TIMEOUT_S": "90",
        "WILTED_TRANSCRIBE_MEM_LIMIT": "1234",
    }
    return env, capture, test_launcher


def test_runtime_launcher_limits_bws_and_wilted_environments(tmp_path: Path) -> None:
    env, capture, launcher = _runtime_environment(tmp_path)

    result = subprocess.run([str(launcher), "discover"], env=env, capture_output=True, text=True, check=False)

    assert result.returncode == 0, result.stderr
    assert (tmp_path / "bws-marker").read_text() == "test-runtime-token"
    received = capture.read_text()
    assert "BWS_ACCESS_TOKEN=" not in received
    assert "BWS_PROJECT_ID=" not in received
    assert "UNRELATED_SECRET=" not in received
    feed_lines = [line for line in received.splitlines() if line.startswith("WILTED_FEED_")]
    assert feed_lines == [
        "WILTED_FEED_NPR_PLUS_HOW_TO_DO_EVERYTHING=feed-a",
        "WILTED_FEED_NPR_PLUS_POP_CULTURE_HAPPY_HOUR=feed-b",
        "WILTED_FEED_NPR_PLUS_WAIT_WAIT=feed-c",
    ]
    for safe_value in (
        "TERM=xterm-256color",
        "LANG=en_US.UTF-8",
        "WILTED_DEBUG=1",
        "WILTED_WEATHER_TEST_TRIGGER=/tmp/wilted-trigger",
        "NERD_FONTS=1",
        "WILTED_TRANSCRIBE_TIMEOUT_S=90",
        "WILTED_TRANSCRIBE_MEM_LIMIT=1234",
    ):
        assert safe_value in received


def test_runtime_launcher_fails_without_keychain_token_without_leaking_value(tmp_path: Path) -> None:
    env, capture, launcher = _runtime_environment(tmp_path, security_fails=True)

    result = subprocess.run([str(launcher), "discover"], env=env, capture_output=True, text=True, check=False)

    assert result.returncode == 1
    assert "Keychain access token is unavailable" in result.stderr
    assert "inherited-token-must-not-reach-wilted" not in result.stderr
    assert not capture.exists()


def test_runtime_launcher_fails_when_bws_omits_required_feed_value(tmp_path: Path) -> None:
    env, capture, launcher = _runtime_environment(tmp_path, missing_secret=True)

    result = subprocess.run([str(launcher), "discover"], env=env, capture_output=True, text=True, check=False)

    assert result.returncode == 1
    assert "WILTED_FEED_NPR_PLUS_WAIT_WAIT" in result.stderr
    assert "not-for-wilted" not in result.stderr
    assert not capture.exists()


def test_runtime_launcher_rejects_bws_state_reaching_inner_process(tmp_path: Path) -> None:
    env, capture, launcher = _runtime_environment(tmp_path, bws_leaks_credentials=True)

    result = subprocess.run([str(launcher), "discover"], env=env, capture_output=True, text=True, check=False)

    assert result.returncode == 1
    assert "BWS access token unexpectedly reached runtime launcher" in result.stderr
    assert "test-runtime-token" not in result.stderr
    assert not capture.exists()


def test_runtime_launcher_cannot_select_an_arbitrary_command(tmp_path: Path) -> None:
    env, capture, launcher = _runtime_environment(tmp_path)

    result = subprocess.run(
        [str(launcher), "/bin/sh", "-c", "echo escaped"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert (tmp_path / "bws-marker").read_text() == "test-runtime-token"
    assert "escaped" not in result.stdout
    assert capture.with_suffix(".args").read_text().splitlines()[-3:] == ["/bin/sh", "-c", "echo escaped"]


def test_runtime_launcher_has_no_caller_controlled_binary_override() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    assert "WILTED_RUNTIME_BWS_BINARY" not in source
    assert "WILTED_RUNTIME_SECURITY_BINARY" not in source
    assert source.startswith("#!/bin/bash\n")
    assert 'readonly RUNTIME_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"' in source
