"""Podcast worker tests."""
from __future__ import annotations
import ast
import importlib.util
import inspect
import io
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import dataclass, field
from pathlib import Path
from unittest import mock
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import commercial_recovery as _worker_commercial_recovery
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import edge_recovery as _worker_edge_recovery
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import span_bounds as _worker_span_bounds
from wilted_worker import tail_recovery as _worker_tail_recovery
from wilted_worker import transcript_sources as _worker_transcript_sources
from worker_test_support import *
from worker_test_fake_llm import *
from worker_test_fake_ads import *
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources

class WorkerSplitRailTests(unittest.TestCase):
    @staticmethod
    def _dotted_name(node):
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.Attribute):
            parent = WorkerSplitRailTests._dotted_name(node.value)
            return f"{parent}.{node.attr}" if parent else None
        return None

    @staticmethod
    def _top_level_definitions(path):
        definitions = set()
        for node in ast.parse(path.read_text(encoding="utf-8")).body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                definitions.add(node.name)
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else (node.target,)
                definitions.update(
                    target.id for target in targets if isinstance(target, ast.Name)
                )
        return definitions

    @staticmethod
    def _module_level_prompt_values():
        prompts = set()
        for path in WORKER_SOURCES:
            for node in ast.parse(path.read_text(encoding="utf-8")).body:
                if not isinstance(node, (ast.Assign, ast.AnnAssign)) or not isinstance(node.value, ast.Constant):
                    continue
                targets = node.targets if isinstance(node, ast.Assign) else (node.target,)
                if isinstance(node.value.value, str) and any(
                    isinstance(target, ast.Name) and target.id.endswith("_PROMPT") for target in targets
                ):
                    prompts.add(node.value.value)
        return prompts

    @staticmethod
    def _ad_corpus_worker_names():
        tree = ast.parse((WORKER_PATH.with_name("ad_corpus.py")).read_text(encoding="utf-8"))
        return {
            node.attr for node in ast.walk(tree)
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "wp"
        }

    def test_worker_owned_prompts_cover_every_prompt_constant(self):
        self.assertEqual(_worker_owned_prompts(), self._module_level_prompt_values())

    def test_patch_targets_are_defined_where_patched(self):
        definitions = {path: self._top_level_definitions(path) for path in WORKER_SOURCES}
        allowed = self._ad_corpus_worker_names()
        module_paths = {"wilted_pipeline": WORKER_PATH}
        for path in WORKER_SOURCES[1:]:
            relative = path.relative_to(WORKER_PACKAGE_PATH).with_suffix("")
            parts = relative.parts[:-1] if relative.name == "__init__" else relative.parts
            module_paths["wilted_worker" + ("." + ".".join(parts) if parts else "")] = path

        failures = []
        for test_path in sorted((REPO_ROOT / "Producer" / "Workers").glob("test_*.py")):
            tree = ast.parse(test_path.read_text(encoding="utf-8"))
            bindings = {"wp": WORKER_PATH}
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        if alias.name in module_paths:
                            bindings[alias.asname or alias.name.split(".")[0]] = module_paths[alias.name]
                elif isinstance(node, ast.ImportFrom) and node.module:
                    for alias in node.names:
                        module_name = f"{node.module}.{alias.name}"
                        if module_name in module_paths:
                            bindings[alias.asname or alias.name] = module_paths[module_name]

            for node in ast.walk(tree):
                target_path = None
                name = None
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == "object" and isinstance(node.func.value, ast.Attribute)
                        and node.func.value.attr == "patch" and len(node.args) >= 2
                        and isinstance(node.args[1], ast.Constant)
                        and isinstance(node.args[1].value, str)):
                    target_name = self._dotted_name(node.args[0])
                    target_path = bindings.get(target_name) or module_paths.get(target_name)
                    name = node.args[1].value
                elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == "patch" and isinstance(node.func.value, ast.Name)
                        and node.func.value.id == "self" and node.args
                        and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
                    target_path = WORKER_PATH
                    name = node.args[0].value
                if target_path and name not in definitions[target_path] and name not in allowed:
                    failures.append(f"{test_path.name}:{node.lineno} patches undefined {name}")
        self.assertEqual(failures, [])

class WorkerPromptContractTests(unittest.TestCase):
    """Every prompt this worker sends must survive its own audit backend.

    `AuditingBackend.generate` flags an unrecognized prompt that *looks* like an
    archived classifier request. The shape test is a word search over prose, so
    for a long time the only thing keeping a worker prompt out of that branch
    was not happening to use the word "classification" in a sentence.
    `OVERSIZED_SPAN_RESCAN_PROMPT` eventually did, which made every oversized
    span fail its whole preparation with `ads-audit-contract-unavailable` --
    invisibly, because the rescan's own `except` swallowed the raise while the
    recorded contract error still aborted the run downstream. No existing test
    could see it: they all hand a raw fake backend to the detector functions and
    never construct an `AuditingBackend` at all.
    """

    def backend(self, inner=None):
        ads = types.ModuleType("wilted.ads")
        ads._AD_DETECT_SYSTEM_PROMPT = "classify"
        ads._AD_DETECT_CORRECTION_PROMPT = "correct"
        ads._AD_DETECT_RESPONSE_FORMAT = {"type": "json_object"}
        ads._parse_ad_response = lambda *a, **k: []

        class Inner:
            def generate(inner, prompt, content, *, response_format=None):
                return "{}", 1

        return wp.AuditingBackend(inner or Inner(), ads)

    def worker_prompts(self):
        return sorted(
            (name, value) for name, value in worker_namespaces().items()
            if name.endswith("_PROMPT") and isinstance(value, str) and value
        )

    def test_no_worker_prompt_trips_its_own_contract_guard(self):
        content = "[ID 0] first\n[ID 1] second\n[ID 2] third\n"
        self.assertGreater(len(self.worker_prompts()), 1)
        for name, prompt in self.worker_prompts():
            with self.subTest(prompt=name):
                backend = self.backend()
                try:
                    backend.generate(prompt, content, response_format=None)
                except wp.WorkerError as error:  # pragma: no cover - the failure we are locking out
                    self.fail(f"{name} tripped the audit contract guard: {error}")
                except Exception:
                    pass  # unrelated stub plumbing; only the contract matters here
                self.assertEqual(
                    backend.contract_errors, [],
                    f"{name} recorded a contract error, which aborts the whole preparation",
                )

    def test_the_rescan_prompt_reaches_the_model_under_the_contract_guard(self):
        # The exemption has to let the prompt through to the model, not merely
        # avoid recording an error: the rescan's own `except` swallows a raise,
        # so an exemption that only skipped the failure would still be caught
        # by the recorded contract error downstream.
        reached = []

        class Inner:
            def generate(inner, prompt, content, *, response_format=None):
                reached.append(prompt)
                return '{"advertisement_evidence_id": 1}', 1

        backend = self.backend(Inner())
        backend.generate(
            wp.OVERSIZED_SPAN_RESCAN_PROMPT,
            "[ID 0] first\n[ID 1] second\n",
            response_format=None,
        )
        self.assertEqual(reached, [wp.OVERSIZED_SPAN_RESCAN_PROMPT])
        self.assertEqual(backend.contract_errors, [])

    def test_an_unknown_classification_shaped_prompt_is_still_refused(self):
        for word in ("classify", "classification", "classifier"):
            with self.subTest(word=word):
                backend = self.backend()
                with self.assertRaises(wp.WorkerError):
                    backend.generate(
                        f"Please use the {word} of each of the segments below.",
                        "[ID 0] first\n[ID 1] second\n",
                        response_format=None,
                    )
                self.assertEqual(
                    backend.contract_errors, ["unknown classification-shaped prompt"]
                )
