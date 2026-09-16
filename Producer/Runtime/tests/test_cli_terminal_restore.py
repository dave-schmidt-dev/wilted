"""Regression tests for the terminal-restore safety net (cli._launch_tui).

Context: closing a terminal tab sends SIGHUP, and Textual's driver leaves
SIGHUP/SIGTERM at their POSIX default (immediate terminate) — so the process
dies before any Textual teardown runs, leaving the shell with mouse/focus
reporting still on (every mouse move spews escape codes) and the cursor hidden.
That was the "Wilted is broken and I can't escape the terminal" wedge.

The fix emits the DEC private-mode resets with a single raw ``os.write`` to a
file descriptor captured before Textual takes over — NOT buffered
``sys.stdout.write``, which can deadlock a signal handler against Textual's
writer thread on the stream lock (that was the original failed attempt: all
restore bytes silently dropped). These tests lock the raw-write behavior and
the completeness of the restore sequence.
"""

from __future__ import annotations

import os

import pytest

from wilted import cli


class TestTerminalRestoreSequence:
    """The escape sequence must undo every terminal mode a TUI driver sets."""

    def test_sequence_clears_all_mouse_reporting_encodings(self):
        seq = cli._TERMINAL_RESTORE_SEQ
        # Every mouse-reporting mode + encoding the driver may have enabled.
        for mode in (b"\x1b[?1000l", b"\x1b[?1002l", b"\x1b[?1003l", b"\x1b[?1006l", b"\x1b[?1015l"):
            assert mode in seq, f"restore sequence missing mouse reset {mode!r}"

    def test_sequence_clears_focus_bracketed_paste_and_shows_cursor(self):
        seq = cli._TERMINAL_RESTORE_SEQ
        assert b"\x1b[?1004l" in seq  # focus reporting off
        assert b"\x1b[?2004l" in seq  # bracketed paste off
        assert b"\x1b[?25h" in seq  # cursor visible again

    def test_sequence_leaves_the_alternate_screen(self):
        # Without this the shell is left staring at the TUI's alt-screen buffer.
        assert b"\x1b[?1049l" in cli._TERMINAL_RESTORE_SEQ


class TestEmitTerminalRestore:
    """``_emit_terminal_restore`` is the async-signal-safe raw-write primitive."""

    def test_writes_full_sequence_to_fd(self):
        read_fd, write_fd = os.pipe()
        try:
            cli._emit_terminal_restore(write_fd)
        finally:
            os.close(write_fd)  # close so the read side sees EOF
        try:
            got = os.read(read_fd, 65536)
        finally:
            os.close(read_fd)
        # The raw os.write path must deliver the EXACT bytes — this is the
        # regression: buffered sys.stdout.write dropped them from a handler.
        assert got == cli._TERMINAL_RESTORE_SEQ

    def test_none_fd_is_a_silent_noop(self):
        # No terminal to restore (piped output / cron): must not raise.
        cli._emit_terminal_restore(None)

    def test_closed_fd_is_swallowed_not_raised(self):
        # A restore that races a closing terminal must never propagate an
        # OSError up into the exit/signal path.
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        os.close(write_fd)
        cli._emit_terminal_restore(write_fd)  # writing to a closed fd: swallowed


class TestTerminalFd:
    """``_terminal_fd`` resolves a controlling-terminal fd, or None when absent."""

    def test_returns_int_or_none(self):
        fd = cli._terminal_fd()
        assert fd is None or isinstance(fd, int)

    def test_prefers_a_real_tty_stream(self, monkeypatch):
        class _FakeTTY:
            def isatty(self):
                return True

            def fileno(self):
                return 4242

        monkeypatch.setattr(cli.sys, "__stdout__", _FakeTTY())
        assert cli._terminal_fd() == 4242


@pytest.mark.parametrize(
    "fname", ["_TERMINAL_RESTORE_SEQ", "_terminal_fd", "_emit_terminal_restore", "_restore_terminal"]
)
def test_restore_api_surface_exists(fname):
    """Guard against the restore helpers being renamed/removed without updating callers."""
    assert hasattr(cli, fname)
