"""Authoritative registry of production orchestration surfaces (Task 1.2).

Characterizes every entrypoint that coordinates pipeline stages, chained
nightly work, TUI mount workers, or shell wrappers before refactoring them
to background-work runner submission.
"""

from __future__ import annotations

import ast
import inspect
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal

import wilted.cli as cli_module

if TYPE_CHECKING:
    from pathlib import Path

OrchestrationKind = Literal["direct_stage", "chained_pipeline", "mount_worker", "shell_wrapper"]

# Omission guard: bump only when intentionally adding/removing a surface.
EXPECTED_SURFACE_COUNT = 19


@dataclass(frozen=True, slots=True)
class OrchestrationSurface:
    """Static characterization of one production orchestration surface."""

    surface_id: str
    entrypoint: str
    orchestration_kind: OrchestrationKind
    constructs_model_coordinator: bool
    invokes_expensive_handler: bool


PRODUCTION_ORCHESTRATION_SURFACES: dict[str, OrchestrationSurface] = {
    "classify.run_classify": OrchestrationSurface(
        surface_id="classify.run_classify",
        entrypoint="wilted.classify.run_classify",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "classify.run_benchmark": OrchestrationSurface(
        surface_id="classify.run_benchmark",
        entrypoint="wilted.classify.run_benchmark",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "prepare.run_prepare": OrchestrationSurface(
        surface_id="prepare.run_prepare",
        entrypoint="wilted.prepare.run_prepare",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "discover.run_discover": OrchestrationSurface(
        surface_id="discover.run_discover",
        entrypoint="wilted.discover.run_discover",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "report.run_report": OrchestrationSurface(
        surface_id="report.run_report",
        entrypoint="wilted.report.run_report",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "queue.reading_list": OrchestrationSurface(
        surface_id="queue.reading_list",
        entrypoint="wilted.cli:cmd_add,cmd_play,cmd_next,cmd_direct",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=False,
        invokes_expensive_handler=True,
    ),
    "ingest.run_ingest": OrchestrationSurface(
        surface_id="ingest.run_ingest",
        entrypoint="wilted.onboard.run_ingest",
        orchestration_kind="chained_pipeline",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "onboarding.run_setup": OrchestrationSurface(
        surface_id="onboarding.run_setup",
        entrypoint="wilted.onboard.run_setup",
        orchestration_kind="chained_pipeline",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "cli.cmd_doctor": OrchestrationSurface(
        surface_id="cli.cmd_doctor",
        entrypoint="wilted.cli.cmd_doctor",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "cli.cmd_benchmark": OrchestrationSurface(
        surface_id="cli.cmd_benchmark",
        entrypoint="wilted.cli.cmd_benchmark",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "cli.cmd_discover": OrchestrationSurface(
        surface_id="cli.cmd_discover",
        entrypoint="wilted.cli.cmd_discover",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "cli.cmd_classify": OrchestrationSurface(
        surface_id="cli.cmd_classify",
        entrypoint="wilted.cli.cmd_classify",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "cli.cmd_report": OrchestrationSurface(
        surface_id="cli.cmd_report",
        entrypoint="wilted.cli.cmd_report",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "cli.cmd_prepare": OrchestrationSurface(
        surface_id="cli.cmd_prepare",
        entrypoint="wilted.cli.cmd_prepare",
        orchestration_kind="direct_stage",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "cli.cmd_ingest": OrchestrationSurface(
        surface_id="cli.cmd_ingest",
        entrypoint="wilted.cli.cmd_ingest",
        orchestration_kind="chained_pipeline",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
    "tui.briefing_on_mount": OrchestrationSurface(
        surface_id="tui.briefing_on_mount",
        entrypoint="wilted.tui.WiltedApp._adopt_owed_briefing_worker",
        orchestration_kind="mount_worker",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "tui.article_cache_generation": OrchestrationSurface(
        surface_id="tui.article_cache_generation",
        entrypoint="wilted.tui.WiltedApp._submit_article_cache_worker",
        orchestration_kind="mount_worker",
        constructs_model_coordinator=False,
        invokes_expensive_handler=True,
    ),
    "tui.report_check": OrchestrationSurface(
        surface_id="tui.report_check",
        entrypoint="wilted.tui.WiltedApp._check_unread_report_worker",
        orchestration_kind="mount_worker",
        constructs_model_coordinator=False,
        invokes_expensive_handler=False,
    ),
    "wrapper.wilted_nightly": OrchestrationSurface(
        surface_id="wrapper.wilted_nightly",
        entrypoint="scripts/wilted-nightly.sh",
        orchestration_kind="shell_wrapper",
        constructs_model_coordinator=True,
        invokes_expensive_handler=True,
    ),
}


# ---------------------------------------------------------------------------
# Source discovery for omission guard
# ---------------------------------------------------------------------------

_PIPELINE_STAGE_RUN_FUNCS = frozenset(
    {
        "wilted.classify.run_classify",
        "wilted.classify.run_benchmark",
        "wilted.prepare.run_prepare",
        "wilted.discover.run_discover",
        "wilted.report.run_report",
        "wilted.onboard.run_ingest",
        "wilted.onboard.run_setup",
    }
)

_CLI_PIPELINE_CMD_FUNCS = frozenset(
    {
        "wilted.cli.cmd_doctor",
        "wilted.cli.cmd_benchmark",
        "wilted.cli.cmd_discover",
        "wilted.cli.cmd_classify",
        "wilted.cli.cmd_report",
        "wilted.cli.cmd_prepare",
        "wilted.cli.cmd_ingest",
    }
)

_TUI_ORCHESTRATION_METHODS = frozenset(
    {
        "wilted.tui.WiltedApp._adopt_owed_briefing_worker",
        "wilted.tui.WiltedApp._submit_article_cache_worker",
        "wilted.tui.WiltedApp._check_unread_report_worker",
    }
)

_QUEUE_ENTRYPOINT = "wilted.cli:cmd_add,cmd_play,cmd_next,cmd_direct"
_NIGHTLY_SCRIPT = "scripts/wilted-nightly.sh"

_RUN_CLI_PIPELINE_SUBCOMMANDS = frozenset(
    {
        "doctor",
        "discover",
        "classify",
        "report",
        "benchmark",
        "prepare",
        "setup",
        "ingest",
    }
)


def _run_cli_dispatch_subcommands() -> frozenset[str]:
    """Return subcommand names dispatched by ``run_cli`` before argparse."""
    source = inspect.getsource(cli_module.run_cli)
    tree = ast.parse(source)
    found: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare):
            continue
        if not (
            isinstance(node.left, ast.Name)
            and node.left.id == "first"
            and len(node.ops) == 1
            and isinstance(node.ops[0], ast.Eq)
            and len(node.comparators) == 1
            and isinstance(node.comparators[0], ast.Constant)
            and isinstance(node.comparators[0].value, str)
        ):
            continue
        found.add(node.comparators[0].value)
    return frozenset(found)


def discover_orchestration_entrypoints() -> frozenset[str]:
    """Collect orchestration entrypoints from known production patterns."""
    discovered = set(_PIPELINE_STAGE_RUN_FUNCS)
    discovered.update(_CLI_PIPELINE_CMD_FUNCS)
    discovered.update(_TUI_ORCHESTRATION_METHODS)
    discovered.add(_QUEUE_ENTRYPOINT)
    discovered.add(_NIGHTLY_SCRIPT)
    return frozenset(discovered)


def registry_entrypoints() -> frozenset[str]:
    """Return the entrypoint strings recorded in the authoritative registry."""
    return frozenset(surface.entrypoint for surface in PRODUCTION_ORCHESTRATION_SURFACES.values())


def nightly_script_path(project_root: Path | None = None) -> Path:
    """Resolve ``scripts/wilted-nightly.sh`` from the project root."""
    if project_root is None:
        from wilted import PROJECT_ROOT

        project_root = PROJECT_ROOT
    return project_root / "scripts" / "wilted-nightly.sh"


def scheduler_script_path(project_root: Path | None = None) -> Path:
    """Resolve ``scripts/wilted-scheduler.sh`` from the project root."""
    if project_root is None:
        from wilted import PROJECT_ROOT

        project_root = PROJECT_ROOT
    return project_root / "scripts" / "wilted-scheduler.sh"
