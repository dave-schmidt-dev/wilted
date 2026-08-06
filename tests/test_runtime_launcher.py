"""Behavioral tests for the least-privilege Wilted runtime launcher."""

from __future__ import annotations

import os
import re
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
        'printf \'%s\' "${BWS_ACCESS_TOKEN:-missing}" > "$BWS_MARKER"\n'
        '[[ "$1" == run && "$2" == -- ]]\n'
        "shift 2\n"
        "export WILTED_FEED_NPR_PLUS_HOW_TO_DO_EVERYTHING='feed-a'\n"
        "export WILTED_FEED_NPR_PLUS_POP_CULTURE_HAPPY_HOUR='feed-b'\n"
        + missing_export
        + "export BWS_PROJECT_ID='not-for-wilted'\n"
        + "export UNRELATED_SECRET='not-for-wilted'\n"
        + remove_bws_state
        + 'exec "$@"\n',
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
        'env | sort > "$TMPDIR/capture"\n'
        'printf \'%s\\n\' "$@" > "$TMPDIR/capture.args"\n',
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
        "TERM_PROGRAM": "iTerm.app",
        "LC_TERMINAL": "iTerm2",
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
        "TERM_PROGRAM=iTerm.app",
        "LC_TERMINAL=iTerm2",
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


def test_runtime_launcher_uv_invocation_never_resolves_dependencies() -> None:
    """A background tick must reuse the provisioned venv/lockfile as-is.

    Regression: without ``--no-sync --frozen``, a tick launched under launchd's
    clean environment can stall indefinitely in uv's dependency resolve/sync
    stage (no network timeout, no python process ever spawns).
    """
    source = SCRIPT.read_text(encoding="utf-8")
    match = re.search(r'"\$UV_BINARY" run\b[^\n]*', source)
    assert match, "expected a uv run invocation in wilted-runtime.sh"
    uv_line = match.group(0)
    assert "--no-sync" in uv_line
    assert "--frozen" in uv_line


def test_runtime_launcher_run_clean_wilted_execs_env_dash_i() -> None:
    """``run_clean_wilted`` must replace the process, not fork and return.

    Regression: an edit briefly dropped ``exec /usr/bin/env -i``, which broke
    process replacement — the function forked, returned to ``main()``, which
    fell through to the ``bws`` re-exec, producing an infinite loop — and
    silently dropped clean-environment isolation. The subprocess-based tests
    above already demonstrate no infinite loop by completing at all; this test
    locks in the source-level invariant so the bug can't be reintroduced.
    """
    source = SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"run_clean_wilted\(\) \{\n(.*?)\n\}\n", source, re.DOTALL)
    assert match, "expected a run_clean_wilted() function definition"
    body = match.group(1)

    # Join backslash-continued lines into single logical statements.
    logical_lines = [line for line in re.sub(r"\\\n\s*", " ", body).splitlines() if line.strip()]
    exec_lines = [line for line in logical_lines if re.match(r"\s*exec\s", line)]

    assert exec_lines, "run_clean_wilted must exec, not fork+return, to replace the process"
    assert len(exec_lines) == 1, f"expected exactly one exec statement, found {len(exec_lines)}"
    assert exec_lines[0].strip().startswith("exec /usr/bin/env -i"), exec_lines[0]
    # The exec must be the function's terminal statement — nothing may follow it.
    assert logical_lines[-1] == exec_lines[0]


def test_runtime_launcher_passes_terminal_identity_through_for_mouse_input(tmp_path: Path) -> None:
    """The env -i allowlist must carry TERM_PROGRAM/LC_TERMINAL through (BUG-7).

    Textual derives ``IS_ITERM`` from exactly these two variables and uses it to skip
    an iTerm2 code path its own source calls buggy. Strip them and Textual cannot tell
    it is on iTerm2, so it enables in-band window resize and with it SGR-pixel mouse
    mode (``\x1b[?1016h``); iTerm2 then reports mouse position in pixels while Textual
    reads them as cells, and every click lands outside the grid. The symptom is a
    totally dead mouse with a working keyboard, which is what BUG-7 was.

    Asserted at the launcher rather than in a TUI test because the defect lives in the
    environment handoff — the app itself was always correct, and every headless test
    passed throughout.
    """
    env, capture, launcher = _runtime_environment(tmp_path)

    result = subprocess.run([str(launcher), "discover"], env=env, capture_output=True, text=True, check=False)

    assert result.returncode == 0, result.stderr
    received = capture.read_text().splitlines()
    assert "TERM_PROGRAM=iTerm.app" in received, (
        "TERM_PROGRAM was stripped by the env -i allowlist; Textual will enable "
        "pixel mouse mode on iTerm2 and the mouse will be dead"
    )
    assert "LC_TERMINAL=iTerm2" in received, (
        "LC_TERMINAL was stripped by the env -i allowlist; it is the other half of "
        "Textual's IS_ITERM check"
    )
    # The allowlist must stay an allowlist: unrelated inherited vars still must not pass.
    assert not any(line.startswith("UNRELATED_SECRET=") for line in received)
    assert not any(line.startswith("BWS_ACCESS_TOKEN=") for line in received)
