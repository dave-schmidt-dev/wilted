"""INV-11 gate: user-facing blocking CLI paths surface live progress; the daemon
path stays silent on every surface; and the model-download progress bar can't be
silently suppressed.

Charter contract (AGENTS.md "Progress Visibility (No Silent Waits)"): a
perceptible blocking op (feed polling, LLM classification, ad/promo detection +
audio) on an interactive surface must emit live progress to a *side channel*
(stderr), never read as a hang, and never pollute the stdout data stream. The
same channel is bidirectional: the nightly daemon (``on_status=None``) must stay
byte-silent on stdout/stderr — its detail belongs in the file log, and a
regression that spammed the daemon's stderr is equally a violation.

Layers gated here:
  1. ``drain_runner`` fires a heartbeat *between* batches (emission during the op),
     and is byte-silent when no sink is supplied (daemon path).
  2. The wrapper (``run_*_via_runner``) names the wait before the drain.
  3. The interactive CLI commands each forward a real (non-None) stderr sink —
     enumerated so a future 5th pipeline command that forgets to forward is caught
     structurally, not just for today's four.
  4. Static guard: output suppression stays confined to the fetch cascade, so a
     future refactor can't wrap a model load/download and swallow the
     huggingface_hub tqdm bar (the multi-GB silent-download regression class).
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

import wilted.pipeline_submit as ps
from wilted.cli import cmd_classify, cmd_discover, cmd_prepare, cmd_report

_SRC = Path(__file__).resolve().parent.parent / "src" / "wilted"


def _batch(submitted: int = 1, failed: int = 0, reason: str = "completed") -> SimpleNamespace:
    """A stand-in for one ``PipelineRunner.run()`` result the drain loop reads."""
    stats = SimpleNamespace(submitted_handled=submitted, failed=failed, cancelled=0, deferred_yield=0)
    return SimpleNamespace(stats=stats, exit_reason=SimpleNamespace(value=reason))


def _fake_runner_factory(results: list[SimpleNamespace]):
    """Build a PipelineRunner stand-in whose ``run()`` returns ``results`` in order."""
    seq = iter(results)

    class _FakeRunner:
        def __init__(self, **_kwargs):
            pass

        def run(self, **_kwargs):
            return next(seq)

    return _FakeRunner


class TestDrainRunnerProgress:
    """drain_runner is the submit->blocking-work seam that forwards progress."""

    def _patch_drain(self, has_jobs: list[bool], batches: list[SimpleNamespace]):
        """Context managers that let drain_runner run its real loop hermetically."""
        return (
            patch.object(ps, "_has_runnable_jobs", side_effect=has_jobs),
            patch.object(ps, "runnable_cohort_requires_speech", return_value=False),
            patch.object(ps, "PipelineRunner", _fake_runner_factory(batches)),
        )

    def test_heartbeat_fires_between_batches(self):
        """A multi-batch drain emits a running tally *during* the work, not only after."""
        seen: list[str] = []
        # guard=True, then two loop passes run a batch, third check ends the loop.
        p1, p2, p3 = self._patch_drain(
            has_jobs=[True, True, True, False],
            batches=[_batch(), _batch()],
        )
        with p1, p2, p3:
            stats = ps.drain_runner(kind=None, on_status=seen.append)

        assert stats.submitted_handled == 2
        # A heartbeat fires after each productive batch, so the running tally
        # advances visibly during a multi-batch drain (after batch 1, then batch 2)
        # rather than the user staring at a silent wait until the final summary.
        assert len(seen) == 2, f"expected a heartbeat after each batch, got {seen!r}"
        assert "1 processed" in seen[0] and "2 processed" in seen[1]

    def test_none_sink_is_byte_silent(self, capsys):
        """The daemon path (on_status=None) writes nothing to stdout or stderr."""
        p1, p2, p3 = self._patch_drain(
            has_jobs=[True, True, True, False],
            batches=[_batch(), _batch()],
        )
        with p1, p2, p3:
            ps.drain_runner(kind=None, on_status=None)

        captured = capsys.readouterr()
        assert captured.out == "", f"daemon drain polluted stdout: {captured.out!r}"
        assert captured.err == "", f"daemon drain polluted stderr: {captured.err!r}"


class TestWrapperNamesTheWait:
    """Each run_*_via_runner names its wait before entering the drain."""

    def test_report_wrapper_names_the_wait(self):
        seen: list[str] = []
        with (
            patch.object(ps, "submit_report"),
            patch.object(ps, "drain_runner"),
            patch("wilted.report.assemble_report", return_value={}),
            patch("wilted.report._local_date_str", return_value="2026-07-24"),
        ):
            ps.run_report_via_runner(on_status=seen.append)

        assert seen, "report wrapper emitted no opener"
        assert "report" in seen[0].lower()

    def test_wrapper_forwards_sink_into_drain(self):
        """The sink reaches drain_runner, not just the opener — the during-op path."""
        seen: list[str] = []
        captured_kwargs: dict = {}

        def _capture_drain(**kwargs):
            captured_kwargs.update(kwargs)
            return ps.RunStats()

        with (
            patch.object(ps, "submit_report"),
            patch.object(ps, "drain_runner", side_effect=_capture_drain),
            patch("wilted.report.assemble_report", return_value={}),
            patch("wilted.report._local_date_str", return_value="2026-07-24"),
        ):
            ps.run_report_via_runner(on_status=seen.append)

        assert captured_kwargs.get("on_status") is not None, "wrapper dropped the sink at the drain"


class TestCliCommandsForwardStderrSink:
    """The interactive commands forward a real stderr sink to their wrapper.

    Enumerated (not one-off): a future pipeline command that drains the runner
    without forwarding a sink is a silent-wait regression this must catch.
    """

    # (command, module attribute patched inside the command, stub return value)
    _CASES = [
        (cmd_discover, "run_discover_via_runner", {"discovered": 0, "feeds_polled": 0, "errors": 0, "unknown": 0}),
        (cmd_classify, "run_classify_via_runner", {"classified": 0, "errors": 0, "total": 0}),
        (cmd_prepare, "run_prepare_via_runner", {"prepared": 0, "errors": 0, "skipped": 0}),
    ]

    @pytest.mark.parametrize("command, target, stub_return", _CASES)
    def test_command_passes_callable_on_status(self, command, target, stub_return):
        captured: dict = {}

        def _stub(**kwargs):
            captured.update(kwargs)
            return stub_return

        with patch.object(ps, target, _stub):
            command([])

        sink = captured.get("on_status")
        assert callable(sink), f"{command.__name__} did not forward a callable on_status sink"

    def test_report_command_passes_callable_on_status(self):
        captured: dict = {}

        def _stub(**kwargs):
            captured.update(kwargs)
            return {}

        # cmd_report reads get_report() after the drain; keep it hermetic.
        with (
            patch.object(ps, "run_report_via_runner", _stub),
            patch("wilted.report.get_report", return_value=None),
        ):
            cmd_report([])

        assert callable(captured.get("on_status")), "cmd_report did not forward a callable on_status sink"


class TestChannelHygiene:
    """Progress goes to stderr; the command's data/summary stays on stdout."""

    def test_discover_progress_on_stderr_not_stdout(self, capsys):
        def _stub(**kwargs):
            # The real wrapper emits progress through this sink during the drain.
            kwargs["on_status"]("Polling 3 feed(s) and fetching new articles...")
            return {"discovered": 5, "feeds_polled": 3, "errors": 0, "unknown": 0}

        with patch.object(ps, "run_discover_via_runner", _stub):
            cmd_discover([])

        captured = capsys.readouterr()
        assert "Polling 3 feed(s)" in captured.err, "progress did not reach stderr"
        assert "Polling 3 feed(s)" not in captured.out, "progress leaked onto the stdout stream"
        assert "Discovery complete" in captured.out, "summary should stay on stdout"


class TestModelDownloadStaysVisible:
    """Static guards locking the already-conforming model-download progress path.

    The huggingface_hub tqdm bar reaches stderr only because output suppression is
    confined to the fetch cascade and the bar is never disabled. Both are load
    bearing for the multi-GB first-run download; guard them structurally so a
    future refactor can't silently reintroduce a silent wait.
    """

    # fetch.py DEFINES suppress_subprocess_output; fetch_cascade.py is its one
    # legitimate user (trafilatura import only, never the network fetch — CR-9).
    _SUPPRESSION_ALLOWED = {"fetch.py", "fetch_cascade.py"}

    def test_output_suppression_confined_to_fetch_cascade(self):
        offenders = [
            str(p.relative_to(_SRC))
            for p in _SRC.rglob("*.py")
            if p.name not in self._SUPPRESSION_ALLOWED and "suppress_subprocess_output" in p.read_text()
        ]
        assert not offenders, (
            "suppress_subprocess_output escaped the fetch cascade: "
            f"{offenders}. Wrapping a model load/download in it would swallow the "
            "huggingface_hub download bar (silent multi-GB wait)."
        )

    def test_hf_download_progress_bar_never_disabled(self):
        offenders = [
            str(p.relative_to(_SRC))
            for p in _SRC.rglob("*.py")
            if "disable_progress_bars" in p.read_text() or "HF_HUB_DISABLE_PROGRESS_BARS" in p.read_text()
        ]
        assert not offenders, f"model-download progress bar disabled in: {offenders}"
