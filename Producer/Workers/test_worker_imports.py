"""Every module left in wilted_worker/ imports cleanly and imports only modules that exist.

The local ad finder's modules are gone. A stale import of one of them inside a
function body would not fail at import time, so this scans the source of every
remaining module, at module and function level, for imports of a module that
is not on disk.
"""
from __future__ import annotations

import ast
import importlib
import importlib.util
import unittest
from pathlib import Path

WORKERS = Path(__file__).resolve().parent
PACKAGE = WORKERS / "wilted_worker"
MODULES = sorted(p.stem for p in PACKAGE.glob("*.py") if p.stem != "__init__")
REMOVED_RUNTIME_MODULE = "wilted." + "ads"


def _imported_modules(tree: ast.AST, package: str):
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield alias.name, node.lineno
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                base = package.split(".")[: len(package.split(".")) - node.level + 1]
                prefix = ".".join(base)
                if node.module:
                    yield f"{prefix}.{node.module}", node.lineno
                else:
                    for alias in node.names:
                        yield f"{prefix}.{alias.name}", node.lineno
            elif node.module:
                yield node.module, node.lineno
                # `from wilted_worker import ad_removal` names the module in the alias.
                for alias in node.names:
                    yield f"{node.module}.{alias.name}", node.lineno


def _missing_imports(tree: ast.AST, origin: str) -> list[str]:
    missing = []
    for target, line in _imported_modules(tree, "wilted_worker"):
        if target.startswith("wilted_worker."):
            leaf = target.split(".")[1]
            if leaf not in MODULES:
                missing.append(f"{origin}:{line} imports {target}")
        elif target == REMOVED_RUNTIME_MODULE or target.startswith(REMOVED_RUNTIME_MODULE + "."):
            missing.append(f"{origin}:{line} imports {target}")
    return missing


class WorkerImportTests(unittest.TestCase):
    def test_every_remaining_worker_module_imports(self):
        for name in MODULES:
            with self.subTest(module=name):
                importlib.import_module(f"wilted_worker.{name}")

    def test_no_module_or_function_imports_a_module_that_no_longer_exists(self):
        missing = []
        for name in MODULES:
            path = PACKAGE / f"{name}.py"
            tree = ast.parse(path.read_text(encoding="utf-8"))
            missing.extend(_missing_imports(tree, path.name))
        self.assertEqual(missing, [])

    def test_the_scan_sees_every_import_form_inside_a_function(self):
        removed = "ad_" + "removal"
        source = "\n".join([
            "def late():",
            f"    from wilted_worker import {removed}",
            f"    from wilted_worker.{removed} import detect_and_cut",
            f"    from . import {removed}",
            f"    from .{removed} import detect_and_cut",
            f"    import wilted_worker.{removed}",
            "    from wilted import ads",
            "    import wilted.ads",
            "    from wilted_worker import cue_timing",
            "    from wilted_worker.cue_timing import probe_duration",
        ])
        missing = _missing_imports(ast.parse(source), "sample.py")
        self.assertEqual(sorted({int(entry.split(":")[1].split()[0]) for entry in missing}), [2, 3, 4, 5, 6, 7, 8])


if __name__ == "__main__":
    unittest.main()
