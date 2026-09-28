"""Shared worker test doubles."""
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
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources

@dataclass
class FakeLLM:
    """The previous project's GGUF backend, as far as the worker can see it.

    It loads lazily and refuses to answer until it has: that asymmetry is the
    whole TWiT 1098 regression, so the double reproduces it exactly.
    """

    answer: str = "[]"
    classifier_answer: str = '{"ads":[]}'
    loaded: bool = False
    closed: bool = False
    fail_load: Exception | None = None
    fail_generate: Exception | None = None
    boundary_content_start_id: int | None = None
    left_boundary_include: bool | None = None
    left_boundary_answer: str | None = None
    preroll_program_start_id: int | None = None
    adjacent_program_start_id: int | None = None
    adjacent_program_start_answer: str | None = None
    preroll_program_id: int | None = None
    boundary_starts_program: bool | None = None
    postroll_advertising_start_id: int | None = None
    rescan_evidence_id: int | None = None
    tail_carries_program: bool | None = None
    commercial_ad_ids: list[int] | None = None
    commercial_programme_ids: list[int] | None = None
    commercial_preservation_answer: str | None = None
    commercial_preservation_answers: list[str] = field(default_factory=list)
    commercial_conflict_answer: str | None = None
    commercial_conflict_answers: list[str] = field(default_factory=list)
    commercial_prefix_role_answer: str | None = None
    commercial_prefix_cue_answer: str | None = None
    preroll_continuation_id: int | None = None
    preroll_continuation_answer: str | None = None
    # The closing review asks the same confirmation twice when the first answer
    # moves the boundary, so the double has to be able to answer it differently.
    program_id_answers: list = field(default_factory=list)
    requests: list = field(default_factory=list)
    request_contents: list = field(default_factory=list)
    request_prompts: list = field(default_factory=list)

    def load(self):
        if self.fail_load is not None:
            raise self.fail_load
        self.loaded = True

    def generate(self, system_prompt, user_content, *, response_format=None):
        self.requests.append(response_format)
        self.request_contents.append(user_content)
        self.request_prompts.append(system_prompt)
        if not self.loaded:
            raise RuntimeError("Model not loaded. Call load() first.")
        if self.fail_generate is not None:
            raise self.fail_generate
        if system_prompt in {"archive ad classifier", "archive ad classifier correction"}:
            return self.classifier_answer, 1
        if system_prompt == wp.COMMERCIAL_PREFIX_ROLE_PROMPT:
            return self.commercial_prefix_role_answer or self.answer, 1
        if system_prompt == wp.COMMERCIAL_PREFIX_CUE_PROMPT:
            return self.commercial_prefix_cue_answer or self.answer, 1
        if system_prompt == wp.COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT:
            if self.commercial_conflict_answers:
                return self.commercial_conflict_answers.pop(0), 1
            if self.commercial_conflict_answer is not None:
                return self.commercial_conflict_answer, 1
            if self.commercial_programme_ids is not None:
                candidate_id = int(user_content.partition("Candidate ID to resolve: ")[2].split()[0])
                if candidate_id in self.commercial_programme_ids:
                    return json.dumps({"classification": "programme"}), 1
                return json.dumps({"classification": "commercial"}), 1
            return json.dumps({"classification": "commercial"}), 1
        if system_prompt == wp.AD_POD_CONTINUATION_PROMPT:
            if self.preroll_continuation_answer is not None:
                return self.preroll_continuation_answer, 1
            if self.preroll_continuation_id is not None:
                return json.dumps({"program_start_id": self.preroll_continuation_id}), 1
            if self.adjacent_program_start_answer is not None:
                return self.adjacent_program_start_answer, 1
            if self.adjacent_program_start_id is not None:
                return json.dumps({"program_start_id": self.adjacent_program_start_id}), 1
            return self.answer, 1
        # The boundary probe asks for free JSON like the coarse pass does, so the
        # system prompt is what tells them apart here as well as in the log.
        if "starts_program" in system_prompt:
            if self.boundary_starts_program is None:
                return self.answer, 1
            return json.dumps({"starts_program": self.boundary_starts_program}), 1
        if "carries_program" in system_prompt:
            if self.tail_carries_program is None:
                return self.answer, 1
            return json.dumps({"carries_program": self.tail_carries_program}), 1
        field_name = (response_format or {}).get("field")
        schema = (response_format or {}).get("schema", {})
        properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
        labels_schema = properties.get("labels")
        if isinstance(labels_schema, dict) and isinstance(labels_schema.get("properties"), dict):
            labelled_ids = [int(segment_id) for segment_id in labels_schema["properties"]]
            if self.commercial_preservation_answers:
                return self.commercial_preservation_answers.pop(0), 1
            if self.commercial_preservation_answer is not None:
                preservation_requests = sum(
                    content.startswith("IDs to classify:") for content in self.request_contents
                )
                # A follow-up asks about IDs the canned answer never named:
                # keep its labels and call the rest commercial.
                if preservation_requests > 1:
                    try:
                        supplied = json.loads(self.commercial_preservation_answer)["labels"]
                    except (json.JSONDecodeError, KeyError, TypeError):
                        supplied = None
                    if isinstance(supplied, dict) and all(
                        label in {"commercial", "programme", "mixed"}
                        for label in supplied.values()
                    ):
                        return json.dumps({"labels": {
                            str(segment_id): supplied.get(str(segment_id), "commercial")
                            for segment_id in labelled_ids
                        }}), 1
                return self.commercial_preservation_answer, 1
            programme = self.commercial_programme_ids
            proposed_ids = set(self.commercial_ad_ids or labelled_ids[1:-1])
            labels = {
                str(segment_id): (
                    "programme"
                    if (
                        segment_id in programme
                        if programme is not None else segment_id not in proposed_ids
                    )
                    else "commercial"
                )
                for segment_id in labelled_ids
            }
            return json.dumps({"labels": labels}), 1
        for commercial_field, configured in (("ad_ids", self.commercial_ad_ids),):
            if commercial_field not in properties:
                continue
            if configured is not None:
                return json.dumps({commercial_field: configured}), 1
            # Ordinary legacy tests do not exercise the new recovery.  When a
            # focused test does, make the conservative default visible: only
            # the outer supplied cues are programme, never an inferred cut.
            return json.dumps({commercial_field: []}), 1
        if field_name == "program_id" and self.program_id_answers:
            return json.dumps({"program_id": self.program_id_answers.pop(0)}), 1
        for name, answer in (("program_start_id", self.preroll_program_start_id),
                             ("advertising_start_id", self.postroll_advertising_start_id),
                             ("advertisement_evidence_id", self.rescan_evidence_id),
                             ("program_id", self.preroll_program_id)):
            if field_name == name:
                return (json.dumps({name: answer}) if answer is not None else self.answer), 1
        if response_format and (
            response_format.get("field") == "include" or "include" in properties
        ):
            candidate_id = int(user_content.partition("candidate=")[2])
            if "edge=left" in user_content:
                if self.left_boundary_answer is not None:
                    return self.left_boundary_answer, 1
                if self.left_boundary_include is not None:
                    return json.dumps({"include": self.left_boundary_include}), 1
            content_start_id = self.boundary_content_start_id
            return json.dumps({"include": content_start_id is not None and candidate_id < content_start_id}), 1
        return self.answer, 1

    def close(self):
        self.closed = True
