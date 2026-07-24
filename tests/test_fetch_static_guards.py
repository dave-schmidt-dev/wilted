"""Refactor-proof static/freeze guard tests for ``wilted.fetch_cascade`` (P3·T3.1/T3.2).

These are pure AST-scan (plus one subprocess) guards, not behavioral tests —
they don't call ``resolve_article_text`` at all. The point is to catch a
regression *structurally*, the moment the source shape changes, rather than
relying on a specific mocked call path happening to exercise the broken
branch. Companion behavioral coverage (mocking ``fetch_url_with_browser`` /
``_extract_from_main`` and asserting they weren't called for a *particular*
input) already lives in ``tests/test_fetch_cascade.py``; this file is the
"can this ever happen, for any input" version.

Mirrors the AST-scan pattern used at ``tests/test_tui.py:1938-1969``
(``ast.parse(inspect.getsource(...))`` + ``ast.walk``/manual traversal, not
substring matching) so a docstring or comment mentioning these names never
trips the assertions — only real code references count.

T3.1 (CV-6/R4/PM-3): CHEAP budget must never reach the browser fetch
escalation or the ``<main>``-scoped extraction retry.

T3.2 (CR-9/PM-1): the freeze-safety guards —
  (a) the transport fetch calls must never run inside the
      ``suppress_subprocess_output`` scope (the 2026-04-20 TUI-freeze
      regression at discover.py:177-180 / HISTORY.md:1368-1370).
  (b) trafilatura must never be imported at module top level, verified both
      statically (AST) and at runtime (a fresh subprocess must emit zero
      bytes on fd 1/2 while importing these modules).
"""

import ast
import inspect
import subprocess
import sys

import wilted.fetch_cascade as fc
from wilted.fetch_cascade import resolve_article_text


def _call_name(node: ast.expr | None) -> str | None:
    """Return the "leaf" name of a Call's func: ``foo`` or ``mod.foo`` -> ``foo``."""
    if not isinstance(node, ast.Call):
        return None
    func = node.func
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _is_budget_full_compare(node: ast.expr) -> bool:
    """True if ``node`` is exactly a ``budget is/== FetchBudget.FULL`` comparison.

    Accepts either operand order (``budget is FetchBudget.FULL`` or
    ``FetchBudget.FULL is budget``) and either ``is`` or ``==`` (both are
    legitimate, semantically equivalent ways to compare an Enum member) so a
    harmless stylistic rewrite doesn't spuriously trip the guard.
    """
    if not isinstance(node, ast.Compare) or len(node.ops) != 1:
        return False
    if not isinstance(node.ops[0], (ast.Is, ast.Eq)):
        return False
    operands = [node.left, node.comparators[0]]
    has_budget_name = any(isinstance(o, ast.Name) and o.id == "budget" for o in operands)
    has_full_attr = any(
        isinstance(o, ast.Attribute)
        and o.attr == "FULL"
        and isinstance(o.value, ast.Name)
        and o.value.id == "FetchBudget"
        for o in operands
    )
    return has_budget_name and has_full_attr


def _requires_full_budget(test: ast.expr) -> bool:
    """True if ``test`` can only evaluate truthy when budget is FetchBudget.FULL.

    Handles the direct comparison, an ``and`` chain where any single clause
    is the comparison (AND only narrows, so one FULL-only clause makes the
    whole expression FULL-only regardless of what else is ANDed in — this is
    exactly the shape both real guards use today), and conservatively
    requires an ``or`` chain's *every* clause to independently require FULL
    (an ``or`` with even one non-FULL-requiring clause could be true under
    CHEAP too).
    """
    if _is_budget_full_compare(test):
        return True
    if isinstance(test, ast.BoolOp):
        if isinstance(test.op, ast.And):
            return any(_requires_full_budget(v) for v in test.values)
        if isinstance(test.op, ast.Or):
            return all(_requires_full_budget(v) for v in test.values)
    return False


def _collect_gated_calls(node: ast.AST, gated: bool, results: list[tuple[str, bool]], target_names: set[str]) -> None:
    """Walk ``node``, recording ``(call_name, gated)`` for every Call whose leaf name is in ``target_names``.

    ``gated`` tracks whether every path reaching the current position
    requires ``budget is FetchBudget.FULL`` to be true. Entering the body of
    an ``if`` whose test requires FULL (or that is already inside such a
    body) sets ``gated=True`` for that body; the ``orelse`` branch inherits
    only the *outer* gating, since a false inner test doesn't itself imply
    anything about budget.
    """
    if isinstance(node, ast.Call):
        name = _call_name(node)
        if name in target_names:
            results.append((name, gated))
        # Fall through to the generic child walk below so a target call
        # nested inside another call's arguments is still found.

    if isinstance(node, ast.If):
        _collect_gated_calls(node.test, gated, results, target_names)
        body_gated = gated or _requires_full_budget(node.test)
        for stmt in node.body:
            _collect_gated_calls(stmt, body_gated, results, target_names)
        for stmt in node.orelse:
            _collect_gated_calls(stmt, gated, results, target_names)
        return

    for child in ast.iter_child_nodes(node):
        _collect_gated_calls(child, gated, results, target_names)


class TestCheapPathNeverReachesFullOnlyEscalation:
    """T3.1 (CV-6/R4/PM-3): CHEAP must never reach the browser fetch or <main> retry."""

    TARGET_CALLS = {"fetch_url_with_browser", "_extract_from_main"}

    def test_browser_and_main_retry_calls_are_lexically_gated_by_full_budget(self):
        """Refactor-proof guard: a future edit that lets the browser
        escalation or the ``<main>``-scoped retry run on CHEAP budget would
        silently change discover's byte-for-byte persisted text (discover
        runs CHEAP across a whole nightly feed batch). This fails the moment
        either call becomes reachable outside an
        ``if budget is FetchBudget.FULL:`` block — e.g. deleting the guard,
        widening it with an ``or`` that doesn't itself require FULL, or
        moving the call above/outside the ``if`` entirely.
        """
        source = inspect.getsource(resolve_article_text)
        tree = ast.parse(source)

        results: list[tuple[str, bool]] = []
        _collect_gated_calls(tree, False, results, self.TARGET_CALLS)

        found_names = {name for name, _gated in results}
        assert found_names == self.TARGET_CALLS, (
            f"expected calls to {sorted(self.TARGET_CALLS)} in resolve_article_text, "
            f"found {sorted(found_names)} instead — this test needs updating if these "
            "calls were renamed, or the regression they guard has already landed if one "
            "is simply missing"
        )

        ungated = [name for name, gated in results if not gated]
        assert not ungated, (
            f"{ungated} reachable without an `if budget is FetchBudget.FULL:` guard in "
            "resolve_article_text — CHEAP budget must never reach the browser fallback "
            "or the <main>-scoped extraction retry (CV-6/R4/PM-3)"
        )


class TestFreezeSafetyGuards:
    """T3.2 (CR-9/PM-1): the two freeze-class regressions this cascade must never reproduce."""

    FETCH_CALL_NAMES = {"fetch_url", "fetch_url_with_browser"}

    def test_transport_fetch_calls_never_run_inside_suppression_scope(self):
        """CR-9 static guard: ``trafilatura.fetch_url`` and
        ``fetch_url_with_browser`` must never be lexically nested inside a
        ``with suppress_subprocess_output(...):`` block in
        resolve_article_text. Fails the moment a future edit moves (or adds)
        a fetch call inside that scope — the exact shape of the
        2026-04-20 regression that lived at discover.py:177-180
        (HISTORY.md:1368-1370): wrapping the network fetch in the
        stdout/stderr-suppression context blinds the Textual TUI for the
        whole HTTP round-trip instead of just the one-time trafilatura
        import.
        """
        source = inspect.getsource(resolve_article_text)
        tree = ast.parse(source)

        suppress_with_nodes = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.With)
            and any(_call_name(item.context_expr) == "suppress_subprocess_output" for item in node.items)
        ]
        assert suppress_with_nodes, (
            "expected a `with suppress_subprocess_output(...):` block in "
            "resolve_article_text — this test needs updating if the suppression call "
            "site was renamed or restructured"
        )

        offending = [
            name
            for with_node in suppress_with_nodes
            for inner in ast.walk(with_node)
            if isinstance(inner, ast.Call) and (name := _call_name(inner)) in self.FETCH_CALL_NAMES
        ]
        assert not offending, (
            f"{offending} called inside `with suppress_subprocess_output(...)` in "
            "resolve_article_text — CR-9: only the lazy `import trafilatura` + one-time "
            "_configure_once() may run under suppression; wrapping the network fetch too "
            "freezes the Textual TUI for the whole HTTP round-trip"
        )

    def test_no_module_level_trafilatura_import_in_fetch_cascade(self):
        """PM-1 static guard: ``src/wilted/fetch_cascade.py`` must have no
        module-top ``import trafilatura`` / ``from trafilatura import ...``.
        Fails the moment a refactor hoists the lazy import out of
        ``resolve_article_text``'s suppression block to module scope — that
        would re-fire the spaCy-model-subprocess-download freeze on the mere
        ``import wilted.fetch_cascade``, before any suppression context
        exists to catch it.
        """
        source = inspect.getsource(fc)
        tree = ast.parse(source)
        for node in tree.body:  # module top-level only; the function-local import is fine
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
                assert not any(n.split(".")[0] == "trafilatura" for n in names), (
                    f"module-top `import` of trafilatura found in fetch_cascade.py: {names}"
                )
            elif isinstance(node, ast.ImportFrom) and node.module:
                assert node.module.split(".")[0] != "trafilatura", (
                    f"module-top `from {node.module} import ...` found in fetch_cascade.py"
                )

    def test_importing_fetch_cascade_and_ingest_emits_no_bytes_on_fd_1_or_2(self):
        """PM-1 runtime guard: importing ``wilted.fetch_cascade`` and
        ``wilted.ingest`` must be silent — no bytes on OS-level fd 1
        (stdout) or fd 2 (stderr).

        Runs in a genuinely fresh subprocess rather than reusing this test
        process: within one pytest session, some earlier test (or the
        ``stub_trafilatura_module`` fixture) may already have a `trafilatura`
        module resident in ``sys.modules``, which would make an in-process
        "is trafilatura imported yet" check a silent no-op regardless of
        what this module actually does. ``subprocess.run(capture_output=True)``
        captures real OS pipes wired to the child's fd 1/2, so it would catch
        a spaCy-model subprocess download's direct fd writes exactly like the
        Textual TUI is exposed to them — a ``sys.stdout`` monkeypatch would
        not.

        Fails the moment a refactor hoists the trafilatura import/config to
        module top (triggering the real, non-stubbed trafilatura import path
        in this bare subprocess) or otherwise causes either module import to
        emit subprocess output.
        """
        code = "import wilted.fetch_cascade\nimport wilted.ingest\n"
        result = subprocess.run(
            [sys.executable, "-c", code],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert result.returncode == 0, (
            f"fresh-process import of wilted.fetch_cascade/wilted.ingest failed "
            f"(rc={result.returncode}): stderr={result.stderr!r}"
        )
        assert result.stdout == "", f"unexpected bytes on fd 1 (stdout) during import: {result.stdout!r}"
        assert result.stderr == "", f"unexpected bytes on fd 2 (stderr) during import: {result.stderr!r}"
