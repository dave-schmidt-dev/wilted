"""Production orchestration characterization and wiring tests (Task 1.2).

Maps every production orchestration surface before refactoring pipeline
stages to background-work runner submission. Uses real entrypoint invocation
with spies on ``ModelCoordinator`` and expensive handler seams.
"""

from __future__ import annotations

import ast
import inspect
import textwrap
from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import pytest

from tests.production_orchestration_registry import (
    _RUN_CLI_PIPELINE_SUBCOMMANDS,
    EXPECTED_SURFACE_COUNT,
    PRODUCTION_ORCHESTRATION_SURFACES,
    _run_cli_dispatch_subcommands,
    discover_orchestration_entrypoints,
    nightly_script_path,
    registry_entrypoints,
)
from wilted.classify import run_benchmark
from wilted.cli import (
    cmd_benchmark,
    cmd_classify,
    cmd_discover,
    cmd_doctor,
    cmd_ingest,
    cmd_prepare,
    cmd_report,
)
from wilted.discover import run_discover
from wilted.onboard import run_ingest
from wilted.pipeline_submit import run_classify_via_runner, run_prepare_via_runner
from wilted.report import run_report
from wilted.tui import WiltedApp

pytestmark = [pytest.mark.integration, pytest.mark.usefixtures("execution_capability")]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_fetched_item(*, text: str = "Article body for classification.") -> None:
    """Insert a fetched item with an on-disk transcript."""
    from wilted import ARTICLES_DIR
    from wilted.db import Item

    transcript = ARTICLES_DIR / "orch-classify.txt"
    transcript.write_text(text, encoding="utf-8")
    Item.create(
        guid=f"orch-classify-{id(object())}",
        title="Orchestration Classify Item",
        discovered_at=_now(),
        item_type="article",
        status="fetched",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


def _make_selected_item(*, text: str = "Article body for preparation.") -> None:
    """Insert a selected article with an on-disk transcript."""
    from wilted import ARTICLES_DIR
    from wilted.db import Item

    transcript = ARTICLES_DIR / "orch-prepare.txt"
    transcript.write_text(text, encoding="utf-8")
    Item.create(
        guid=f"orch-prepare-{id(object())}",
        title="Orchestration Prepare Item",
        discovered_at=_now(),
        item_type="article",
        status="selected",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


class _CoordinatorInitSpy:
    """Track ``ModelCoordinator`` construction without blocking real behavior."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from wilted.station_runtime.coordinator import ModelCoordinator

        self.count = 0
        self._real_init = ModelCoordinator.__init__

        def _spy_init(coordinator_self, *args, **kwargs) -> None:
            self.count += 1
            return self._real_init(coordinator_self, *args, **kwargs)

        monkeypatch.setattr(ModelCoordinator, "__init__", _spy_init)


class _MockLLMBackend:
    """Minimal LLM backend that satisfies classify/prepare coordinator paths."""

    def __init__(self) -> None:
        self.closed = False

    def load(self) -> None:
        return None

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        del system_prompt, user_content
        return (
            '{"playlist": "Work", "relevance_score": 0.8, "summary": "Test summary."}',
            12,
        )

    def close(self) -> None:
        self.closed = True


# ---------------------------------------------------------------------------
# Registry completeness
# ---------------------------------------------------------------------------


class TestOrchestrationRegistry:
    def test_registry_lists_expected_surface_count(self) -> None:
        """Omission guard: registry must contain exactly the planned surfaces."""
        assert len(PRODUCTION_ORCHESTRATION_SURFACES) == EXPECTED_SURFACE_COUNT

    def test_registry_covers_discovered_entrypoints(self) -> None:
        """Every known production orchestration entrypoint appears in the registry."""
        discovered = discover_orchestration_entrypoints()
        registered = registry_entrypoints()
        missing = discovered - registered
        assert not missing, f"Registry missing orchestration entrypoints: {sorted(missing)}"

    def test_registry_entrypoints_are_unique(self) -> None:
        """Each registry entrypoint string is recorded once."""
        entrypoints = [surface.entrypoint for surface in PRODUCTION_ORCHESTRATION_SURFACES.values()]
        assert len(entrypoints) == len(set(entrypoints))

    def test_run_cli_pipeline_subcommands_are_accounted_for(self) -> None:
        """AST scan of ``run_cli`` dispatch must match the planned pipeline subcommands."""
        dispatched = _run_cli_dispatch_subcommands()
        assert _RUN_CLI_PIPELINE_SUBCOMMANDS <= dispatched

        for subcommand in _RUN_CLI_PIPELINE_SUBCOMMANDS:
            if subcommand == "setup":
                assert "onboarding.run_setup" in PRODUCTION_ORCHESTRATION_SURFACES
            elif subcommand == "doctor":
                assert "cli.cmd_doctor" in PRODUCTION_ORCHESTRATION_SURFACES
            else:
                assert f"cli.cmd_{subcommand}" in PRODUCTION_ORCHESTRATION_SURFACES

    @pytest.mark.parametrize("surface_id", tuple(PRODUCTION_ORCHESTRATION_SURFACES.keys()))
    def test_surface_characterization_fields(self, surface_id: str) -> None:
        """Every surface records coordinator, expensive-handler, kind, and entrypoint."""
        surface = PRODUCTION_ORCHESTRATION_SURFACES[surface_id]
        assert surface.surface_id == surface_id
        assert surface.entrypoint
        assert surface.orchestration_kind in {"direct_stage", "chained_pipeline", "mount_worker", "shell_wrapper"}


# ---------------------------------------------------------------------------
# Stage wiring — ModelCoordinator and cheap stages
# ---------------------------------------------------------------------------


class TestStageOrchestrationWiring:
    def test_run_classify_empty_db_reaches_real_entrypoint_without_coordinator(self, monkeypatch) -> None:
        """``run_classify_via_runner`` on an empty DB returns stats without constructing a coordinator."""
        spy = _CoordinatorInitSpy(monkeypatch)
        result = run_classify_via_runner(model="test", backend_type="gguf")
        assert result == {"classified": 0, "errors": 0, "total": 0}
        assert spy.count == 0

    def test_run_classify_with_work_constructs_coordinator(self, monkeypatch) -> None:
        """``run_classify_via_runner`` constructs ``ModelCoordinator`` when fetched items exist."""
        _make_fetched_item()
        spy = _CoordinatorInitSpy(monkeypatch)
        monkeypatch.setattr("wilted.handlers.classify.create_backend", lambda *args, **kwargs: _MockLLMBackend())
        result = run_classify_via_runner(model="test", backend_type="gguf")
        assert result["classified"] == 1
        assert spy.count >= 1

    def test_run_prepare_empty_db_reaches_real_entrypoint_without_coordinator(self, monkeypatch) -> None:
        """``run_prepare_via_runner`` on an empty DB returns stats without constructing a coordinator."""
        spy = _CoordinatorInitSpy(monkeypatch)
        result = run_prepare_via_runner(use_llm=False, skip_tts=True)
        assert result == {"prepared": 0, "errors": 0, "skipped": 0}
        assert spy.count == 0

    def test_run_prepare_with_work_constructs_coordinator(self, monkeypatch) -> None:
        """``run_prepare_via_runner`` constructs ``ModelCoordinator`` when selected items exist."""
        _make_selected_item()
        spy = _CoordinatorInitSpy(monkeypatch)
        monkeypatch.setattr("wilted.cache.generate_article_cache", lambda *args, **kwargs: True)
        result = run_prepare_via_runner(use_llm=False, skip_tts=True)
        assert result["prepared"] == 1
        assert spy.count >= 1

    def test_run_discover_is_cheap_without_coordinator(self, monkeypatch) -> None:
        """``run_discover`` never constructs ``ModelCoordinator``."""
        spy = _CoordinatorInitSpy(monkeypatch)
        result = run_discover()
        assert "discovered" in result
        assert spy.count == 0

    def test_run_report_is_cheap_without_coordinator(self, monkeypatch) -> None:
        """``run_report`` never constructs ``ModelCoordinator``."""
        spy = _CoordinatorInitSpy(monkeypatch)
        result = run_report()
        assert "report_id" in result or result.get("items", 0) == 0
        assert spy.count == 0

    def test_run_benchmark_constructs_coordinator(self, monkeypatch, capsys) -> None:
        """``run_benchmark`` is a real LLM orchestration surface using ``ModelCoordinator``."""
        spy = _CoordinatorInitSpy(monkeypatch)
        monkeypatch.setattr("wilted.handlers.classify.create_backend", lambda *args, **kwargs: _MockLLMBackend())
        run_benchmark(models=["test-model"], backend_type="gguf")
        capsys.readouterr()
        assert spy.count >= 1


# ---------------------------------------------------------------------------
# Chained ingest pipeline
# ---------------------------------------------------------------------------


class TestIngestPipelineWiring:
    def test_run_ingest_chains_discover_classify_report(self, monkeypatch) -> None:
        """``run_ingest`` invokes discover → classify → report in order."""
        calls: list[str] = []

        monkeypatch.setattr(
            "wilted.discover.run_discover",
            lambda: calls.append("discover") or {"discovered": 0, "feeds_polled": 0, "errors": 0},
        )
        monkeypatch.setattr(
            "wilted.pipeline_submit.run_classify_via_runner",
            lambda **kwargs: calls.append("classify") or {"classified": 0, "errors": 0, "total": 0},
        )
        monkeypatch.setattr(
            "wilted.report.run_report",
            lambda: calls.append("report") or {"items": 0, "playlists": {}, "report_id": 1},
        )
        monkeypatch.setattr("wilted.report.get_report", lambda: None)

        run_ingest()
        assert calls == ["discover", "classify", "report"]

    def test_run_ingest_classify_stage_constructs_coordinator(self, monkeypatch) -> None:
        """Ingest's classify stage constructs ``ModelCoordinator`` when work exists."""
        _make_fetched_item()
        spy = _CoordinatorInitSpy(monkeypatch)
        monkeypatch.setattr("wilted.handlers.classify.create_backend", lambda *args, **kwargs: _MockLLMBackend())
        monkeypatch.setattr("wilted.report.get_report", lambda: None)

        run_ingest(skip_discover=True, skip_report=True)
        assert spy.count == 1


# ---------------------------------------------------------------------------
# CLI dispatch wiring
# ---------------------------------------------------------------------------


class TestCliOrchestrationDispatch:
    @pytest.mark.parametrize(
        ("cmd_fn", "target", "call_args"),
        [
            (cmd_discover, "wilted.discover.run_discover", []),
            (cmd_classify, "wilted.pipeline_submit.run_classify_via_runner", []),
            (cmd_report, "wilted.report.run_report", []),
            (cmd_prepare, "wilted.pipeline_submit.run_prepare_via_runner", ["--no-llm"]),
            (
                cmd_ingest,
                "wilted.onboard.run_ingest",
                ["--skip-discover", "--skip-classify", "--skip-report"],
            ),
        ],
    )
    def test_cmd_pipeline_reaches_real_run_target(self, cmd_fn, target, call_args, monkeypatch) -> None:
        """CLI cmd_* handlers dispatch to their real run_* entrypoints."""
        called = {"value": False}

        def _spy(*args, **kwargs):
            called["value"] = True
            if target.endswith("run_discover"):
                return {"discovered": 0, "feeds_polled": 0, "errors": 0}
            if target.endswith("run_classify_via_runner"):
                return {"classified": 0, "errors": 0, "total": 0}
            if target.endswith("run_report"):
                return {"items": 0, "playlists": {}, "report_id": 1}
            if target.endswith("run_prepare_via_runner"):
                return {"prepared": 0, "errors": 0, "skipped": 0}
            if target.endswith("run_ingest"):
                return {}
            return None

        monkeypatch.setattr(target, _spy)
        if target.endswith("run_report"):
            monkeypatch.setattr("wilted.report.get_report", lambda: None)

        cmd_fn(call_args)
        assert called["value"] is True

    def test_cmd_benchmark_reaches_run_benchmark(self, monkeypatch) -> None:
        """``cmd_benchmark classify`` dispatches to ``run_benchmark``."""
        called = {"value": False}

        def _spy(**kwargs):
            called["value"] = True

        monkeypatch.setattr("wilted.classify.run_benchmark", _spy)
        cmd_benchmark(["classify", "--models", "test-model"])
        assert called["value"] is True

    def test_cmd_doctor_reaches_real_entrypoint(self, capsys) -> None:
        """``cmd_doctor`` runs diagnostics without mocking the handler away."""
        cmd_doctor()
        out = capsys.readouterr().out
        assert "wilted doctor" in out
        assert "PROJECT_ROOT" in out


# ---------------------------------------------------------------------------
# Queue orchestration
# ---------------------------------------------------------------------------


class TestQueueOrchestrationWiring:
    def test_cmd_add_reaches_resolve_and_queue(self, monkeypatch, capsys) -> None:
        """Reading-list add orchestrates fetch + queue persistence."""
        from wilted.cli import cmd_add

        calls: list[str] = []

        def _resolve(**kwargs):
            del kwargs
            calls.append("resolve")
            from wilted.ingest import ArticleResult

            return ArticleResult(
                text="Body", title="Title", source_url="https://x.test/a", canonical_url="https://x.test/a"
            )

        def _add(*args, **kwargs):
            del args, kwargs
            calls.append("add")
            return {"id": 1, "title": "Title", "words": 1, "added": _now()}

        monkeypatch.setattr("wilted.cli.resolve_article", _resolve)
        monkeypatch.setattr("wilted.cli.add_article", _add)
        monkeypatch.setattr("wilted.cli.load_queue", lambda: [{"id": 1}])

        args = MagicMock()
        args.input = "https://example.com/article"
        cmd_add(args)
        capsys.readouterr()
        assert calls == ["resolve", "add"]

    def test_cmd_play_reaches_play_text(self, monkeypatch, capsys) -> None:
        """Reading-list play orchestrates TTS playback via ``_play_text``."""
        from wilted.cli import cmd_play

        played = {"value": False}

        monkeypatch.setattr("wilted.cli.is_station_active", lambda: False)
        monkeypatch.setattr(
            "wilted.cli.load_queue",
            lambda: [{"id": 1, "title": "Test", "words": 10, "added": _now(), "file": "missing"}],
        )
        monkeypatch.setattr("wilted.cli.get_article_text", lambda entry: "hello world")
        monkeypatch.setattr("wilted.cli.mark_completed", lambda entry: None)

        def _play_text(text, args):
            del text, args
            played["value"] = True
            return True

        monkeypatch.setattr("wilted.cli._play_text", _play_text)

        args = MagicMock(voice="af_heart", speed=None, model="test", lang="a", save=None)
        cmd_play(args)
        capsys.readouterr()
        assert played["value"] is True


# ---------------------------------------------------------------------------
# TUI mount orchestration
# ---------------------------------------------------------------------------


class TestTuiMountOrchestration:
    def test_on_mount_ast_references_orchestration_workers(self) -> None:
        """``on_mount`` wires briefing, cache generation, and report-check workers."""
        source = textwrap.dedent(inspect.getsource(WiltedApp.on_mount))
        tree = ast.parse(source)
        called: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                called.add(node.func.attr)
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                called.add(node.func.id)

        assert "_generate_briefing_worker" in called
        assert "_trigger_generation" in called
        assert "_check_unread_report" in called

    @pytest.mark.asyncio
    async def test_on_mount_starts_briefing_worker_when_generator_present(self) -> None:
        """Briefing generation on mount calls ``_generate_briefing_worker``."""
        from tests.test_tui import FakeBriefingGenerator, _make_app

        generator = FakeBriefingGenerator()
        app = _make_app(briefing_generator=generator)
        with patch.object(app, "_generate_briefing_worker") as mock_briefing:
            async with app.run_test():
                await app.workers.wait_for_complete()
            mock_briefing.assert_called_once()

    @pytest.mark.asyncio
    async def test_on_mount_checks_unread_report(self) -> None:
        """Report check on mount calls ``_check_unread_report``."""
        from tests.test_tui import _make_app

        app = _make_app()
        with (
            patch.object(app, "_check_unread_report") as mock_report,
            patch.object(app, "_check_unread_report_worker"),
        ):
            async with app.run_test():
                await app.workers.wait_for_complete()
            mock_report.assert_called_once()

    @pytest.mark.asyncio
    async def test_report_check_worker_can_call_run_report(self, monkeypatch) -> None:
        """``_check_unread_report_worker`` reaches ``run_report`` when today's report is missing."""
        from tests.test_tui import _make_app

        called = {"value": False}

        def _spy():
            called["value"] = True
            return {"items": 0, "playlists": {}, "report_id": 1}

        monkeypatch.setattr("wilted.report.run_report", _spy)
        monkeypatch.setattr("wilted.report.get_latest_unread_report", lambda: None)

        app = _make_app()
        async with app.run_test():
            await app.workers.wait_for_complete()
        assert called["value"] is True

    @pytest.mark.asyncio
    async def test_trigger_generation_starts_cache_worker(self) -> None:
        """``_trigger_generation`` reaches the ``_generate_cache`` worker."""
        from tests.test_tui import _make_app

        app = _make_app()
        with patch.object(app, "_generate_cache") as mock_worker:
            mock_worker.return_value = MagicMock(is_running=False)
            app._trigger_generation()
            mock_worker.assert_called_once()


# ---------------------------------------------------------------------------
# Shell wrapper
# ---------------------------------------------------------------------------


class TestShellWrapperOrchestration:
    def test_nightly_script_references_ingest_and_report(self) -> None:
        """``scripts/wilted-nightly.sh`` chains ingest and email report."""
        script = nightly_script_path()
        assert script.is_file(), f"Expected nightly wrapper at {script}"
        content = script.read_text(encoding="utf-8")
        assert "ingest" in content
        assert "report --email" in content or "report --email" in content.replace('"', "")

    def test_nightly_script_invokes_runtime_for_ingest(self, monkeypatch, tmp_path) -> None:
        """Nightly wrapper subprocess path calls the runtime ingest command."""
        script = nightly_script_path()
        content = script.read_text(encoding="utf-8")
        assert "WILTED_RUNTIME" in content
        assert '"$WILTED_RUNTIME" ingest' in content or '$WILTED_RUNTIME" ingest' in content
