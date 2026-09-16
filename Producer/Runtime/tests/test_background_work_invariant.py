"""INV-10 gate — production modules may not call gated ML factories directly."""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

from tests.test_execution_capability import TestGatedFactories

pytestmark = pytest.mark.integration

_GATED_FACTORY_NAMES = frozenset(
    {
        "create_model_coordinator",
        "create_backend",
        "transcribe_audio",
    },
)

_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_SRC_ROOT = _PROJECT_ROOT / "src" / "wilted"


def _is_allowlisted(path: Path) -> bool:
    rel = path.relative_to(_SRC_ROOT)
    if rel.parts and rel.parts[0] == "handlers":
        return True
    return rel.name in {"pipeline_runner.py", "execution_capability.py"}


def _iter_production_modules() -> list[Path]:
    modules: list[Path] = []
    for path in sorted(_SRC_ROOT.rglob("*.py")):
        # NOTE: __init__.py files are intentionally NOT skipped — tui/__init__.py
        # hosts the article-cache drain and must be scanned by the INV-10 gate.
        if _is_allowlisted(path):
            continue
        modules.append(path)
    return modules


def _call_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Call):
        func = node.func
        if isinstance(func, ast.Name):
            return func.id
        if isinstance(func, ast.Attribute):
            return func.attr
    return None


def _find_forbidden_gated_calls(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    rel = path.relative_to(_PROJECT_ROOT)
    violations: list[str] = []
    for node in ast.walk(tree):
        name = _call_name(node)
        if name in _GATED_FACTORY_NAMES:
            violations.append(f"{rel}:{node.lineno} calls {name}()")
    return violations


class TestInv10BackgroundWorkInvariant:
    def test_inv10_documented_in_invariants(self) -> None:
        text = (_PROJECT_ROOT / "INVARIANTS.md").read_text(encoding="utf-8")
        assert "### INV-10" in text
        assert "tests/test_background_work_invariant.py" in text

    def test_inv10_born_covered_in_ledger(self) -> None:
        text = (_PROJECT_ROOT / "ledger.yaml").read_text(encoding="utf-8")
        assert "INV-10:" in text
        assert "gate_test_status: covered" in text.split("INV-10:", 1)[1].split("\n", 1)[0]

    @pytest.mark.parametrize("path", _iter_production_modules(), ids=lambda p: p.relative_to(_SRC_ROOT).as_posix())
    def test_production_modules_outside_allowlist_do_not_call_gated_factories(self, path: Path) -> None:
        violations = _find_forbidden_gated_calls(path)
        assert not violations, "INV-10 violations:\n" + "\n".join(violations)

    def test_runtime_capability_suite_still_gates_factories(self) -> None:
        """Runtime enforcement remains the primary authority; AST is secondary."""
        TestGatedFactories().test_create_backend_fails_without_capability()
        TestGatedFactories().test_create_model_coordinator_fails_without_capability()
