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
class FakeAd:
    start_s: float
    end_s: float
    label: str = "sponsor"
    confidence: float = 0.9
    kinds: tuple = ()

AD_KIND_BY_LABEL = {
    "sponsor_read": "paid advertising",
    "ad_break": "paid advertising",
    "self_promo": "house promotion",
    "newsletter_pitch": "house promotion",
}

def attach_ad_kind_taxonomy(ads):
    """Give a fake archive module the shared kind vocabulary.

    `AdSegment`, `_merge_adjacent` and the serializer all need the same answer
    to "what is this span?", so the worker reads it from the module it was
    handed rather than keeping a second copy of the mapping.
    """
    ads.AD_KIND_PAID = "paid advertising"
    ads.AD_KIND_HOUSE = "house promotion"
    ads.AD_KIND_CREDITS = "credits"
    ads.AD_KIND_BY_LABEL = dict(AD_KIND_BY_LABEL)

    def ad_segment_kinds(segment):
        explicit = tuple(getattr(segment, "kinds", ()) or ())
        if explicit:
            return tuple(sorted(set(explicit)))
        return (ads.AD_KIND_BY_LABEL.get(segment.label, ads.AD_KIND_PAID),)

    ads.ad_segment_kinds = ad_segment_kinds
    return ads

def install_fake_ads(llm: FakeLLM, detections=()):
    """Stand in for `wilted.ads` and `wilted.llm` with the real detector's manners.

    The real detector asks the backend once per batch and treats any exception
    as a malformed completion: it swallows it and classifies the batch as
    content. This double asks once per segment and does the same.
    """
    host = sys.modules.get("speech_stack.daemon.host")
    if "speech_stack.client" not in sys.modules or host is None or not host.state_dir().is_dir():
        install_fake_speech_stack()
    class FakeAdsModule(types.ModuleType):
        def __setattr__(self, name, value):
            if name == "detect_ads" and callable(value) and not getattr(value, "_covers_classifier", False):
                raw_detector = value

                def detector_with_classifier_coverage(segments, backend):
                    ids = list(range(len(segments)))
                    rendered = "\n".join(
                        f"[ID {segment_id}] [{segment.start_s:.3f}s - {segment.end_s:.3f}s] {segment.text}"
                        for segment_id, segment in enumerate(segments)
                    )
                    for prompt in (self._AD_DETECT_SYSTEM_PROMPT, self._AD_DETECT_CORRECTION_PROMPT):
                        try:
                            response, _ = backend.generate(
                                prompt, rendered, response_format=self._AD_DETECT_RESPONSE_FORMAT
                            )
                            self._parse_ad_response(response, ids)
                            break
                        except Exception:  # noqa: BLE001 - archive retries malformed classifier responses
                            continue
                    return raw_detector(segments, backend)

                detector_with_classifier_coverage._covers_classifier = True
                value = detector_with_classifier_coverage
            super().__setattr__(name, value)

    ads = FakeAdsModule("wilted.ads")
    ads._AD_DETECT_SYSTEM_PROMPT = "archive ad classifier"
    ads._AD_DETECT_CORRECTION_PROMPT = "archive ad classifier correction"
    ads._AD_DETECT_RESPONSE_FORMAT = {
        "type": "json_object",
        "schema": {
            "type": "object",
            "properties": {"ads": {"type": "array"}},
            "required": ["ads"],
            "additionalProperties": False,
        },
    }

    def parse_ad_response(response, expected_ids):
        parsed = json.loads(response)
        if not isinstance(parsed, dict) or set(parsed) != {"ads"} or not isinstance(parsed["ads"], list):
            raise ValueError("invalid ads response")
        positions = {segment_id: index for index, segment_id in enumerate(expected_ids)}
        labels = {}
        for item in parsed["ads"]:
            if (not isinstance(item, list) or len(item) != 2 or isinstance(item[0], bool)
                    or not isinstance(item[0], int) or item[0] not in positions
                    or item[0] in labels or item[1] not in {
                        "sponsor_read", "self_promo", "ad_break", "newsletter_pitch"
                    }):
                raise ValueError("invalid ad entry")
            labels[item[0]] = item[1]
        if list(labels) != sorted(labels, key=positions.__getitem__):
            raise ValueError("ads are out of order")
        return [(segment_id, segment_id in labels, labels.get(segment_id)) for segment_id in expected_ids]

    ads._parse_ad_response = parse_ad_response
    ads._SPONSOR_OPENING_RE = re.compile(  # noqa: SLF001 - matches the legacy module seam
        r"\b(?:this|the)\s+episode\s+is\s+(?:brought\s+to\s+you\s+by|sponsored\s+by)\b"
        r"|\bthis\s+message\s+is\s+brought\s+to\s+you\s+by\b"
        r"|\bpaid\s+for\s+by\b|\bpaid\s+ad\b",
        re.IGNORECASE,
    )
    ads._EXPLICIT_HOST_READ_OPENING_RE = re.compile(  # noqa: SLF001 - legacy module seam
        r"\b(?:"
        r"(?:this|the)\s+(?:episode|show)(?:\s+of\s+[^.!?]{1,80}?)?\s+(?:is\s+)?brought\s+to\s+you"
        r"(?:\s+today)?\s+by|"
        r"today(?:'s|’s|\s+is\s+our)\s+sponsor(?:\s+is)?|"
        r"our\s+sponsor\s+for\s+this\s+(?:section|segment|episode|show)"
        r")\b",
        re.IGNORECASE,
    )
    ads._SPARSE_PROMO_CUES = (  # noqa: SLF001 - mirrors the legacy module seam
        re.compile(r"\b(?:brought to you by|paid for by|sponsor(?:ed|ship)?)\b", re.IGNORECASE),
        re.compile(r"\b[a-z0-9-]+\.(?:com|net|org|io)\b|\bdot[ -]?com\b", re.IGNORECASE),
        re.compile(r"\b(?:(?:promo|offer|discount) code|use code)\b", re.IGNORECASE),
        re.compile(
            r"\$\s*\d|\b\d+(?:\.\d+)?\s*(?:%|percent)\s+off\b"
            r"|\b(?:price|priced|pricing|discount|free trial)\b",
            re.IGNORECASE,
        ),
        re.compile(r"\blimited[- ]time sale\b", re.IGNORECASE),
    )
    attach_ad_kind_taxonomy(ads)
    ads.AdSegment = lambda start_s, end_s, confidence, label, kinds=(): FakeAd(  # noqa: E731
        start_s, end_s, label, confidence, kinds
    )
    ads._refine_ad_start_from_tokens = lambda segment, _pattern: segment.start_s  # noqa: SLF001

    def merge_adjacent(items):
        merged = []
        for item in sorted(items, key=lambda ad: ad.start_s):
            if merged and item.start_s <= merged[-1].end_s + 2.0:
                previous = merged[-1]
                merged[-1] = FakeAd(
                    previous.start_s,
                    max(previous.end_s, item.end_s),
                    previous.label,
                    max(previous.confidence, item.confidence),
                    tuple(sorted({*ads.ad_segment_kinds(previous), *ads.ad_segment_kinds(item)})),
                )
            else:
                merged.append(item)
        return merged

    ads._merge_adjacent = merge_adjacent  # noqa: SLF001
    ads._SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT = "find verified content resumption"

    def render_segments_bounded(context_ids, segments, headers=()):
        return "\n".join([*headers, *(f"[{index}] {segments[index].text}" for index in context_ids)])

    ads._render_segments_bounded = render_segments_bounded  # noqa: SLF001
    attach_archive_render_helpers(ads, lambda index, _segment: f"[{index}] ")
    ads._id_response_format = lambda field, ids: {"field": field, "ids": list(ids)}  # noqa: SLF001
    ads._generate_constrained_response = (  # noqa: SLF001
        lambda backend, system, transcript, response_format: backend.generate(
            system, transcript, response_format=response_format
        )
    )

    def parse_content_response(response, minimum_id, window_max):
        parsed = json.loads(response)
        if set(parsed) != {"content_start_id"}:
            raise ValueError("invalid content response")
        content_id = parsed["content_start_id"]
        if isinstance(content_id, bool) or not isinstance(content_id, int):
            raise ValueError("invalid content id")
        if not minimum_id <= content_id <= window_max:
            raise ValueError("content id outside context")
        return content_id

    ads._parse_preroll_content_response = parse_content_response  # noqa: SLF001
    ads._last_meaningful_ad_end = (  # noqa: SLF001
        lambda content_id, _minimum_id, segments: segments[content_id - 1].end_s
    )

    def probe_boundary(candidate_id, _adjacent_id, edge, _segments, backend):
        response, _tokens = backend.generate(
            "verify immediate boundary",
            f"edge={edge};candidate={candidate_id}",
            response_format={"field": "include", "candidate": candidate_id},
        )
        try:
            parsed = json.loads(response)
            if set(parsed) != {"include"} or not isinstance(parsed["include"], bool):
                raise ValueError("invalid boundary response")
            return parsed["include"]
        except (TypeError, ValueError):
            return None

    ads._probe_boundary_candidate = probe_boundary  # noqa: SLF001
    attach_archive_overlap_resolver(ads)

    def detect_ads(segments, backend):
        return list(detections)

    ads.detect_ads = detect_ads
    ads._compute_keep_segments = lambda total, ads_found, pad: []  # noqa: SLF001
    llm_module = types.ModuleType("wilted.llm")
    llm_module.DEFAULT_GGUF_MODEL = "/models/default.gguf"
    llm_module.create_backend = lambda kind, model: llm
    package = sys.modules.get("wilted") or types.ModuleType("wilted")
    package.ads = ads
    package.llm = llm_module
    sys.modules["wilted"] = package
    sys.modules["wilted.ads"] = ads
    sys.modules["wilted.llm"] = llm_module
    return ads

ARCHIVE_TRUNCATION_MARKER = " \u2026[TRUNCATED]\u2026 "

def attach_archive_render_helpers(ads, segment_prefix):
    """Give a fake archive module the render helpers the worker's install needs.

    The worker builds its replacement renderer out of the archive's own prefix,
    truncation and cap, so a fake that omits them would silently skip the
    install and leave the budget arithmetic untested. The truncation is the
    archive's, copied rather than imported for the same reason the rest of this
    module fakes `wilted.ads`: the gate never loads the archive.
    """
    ads._TRUNCATION_MARKER = ARCHIVE_TRUNCATION_MARKER  # noqa: SLF001
    ads._MAX_CLASSIFICATION_BATCH_CHARS = 12_000  # noqa: SLF001
    ads._segment_prefix = segment_prefix  # noqa: SLF001

    def truncate_head_tail(text, max_chars):
        if len(text) <= max_chars:
            return text
        if max_chars <= len(ARCHIVE_TRUNCATION_MARKER):
            return ARCHIVE_TRUNCATION_MARKER[:max_chars]
        remaining = max_chars - len(ARCHIVE_TRUNCATION_MARKER)
        tail_chars = remaining // 2
        return (
            text[: (remaining + 1) // 2]
            + ARCHIVE_TRUNCATION_MARKER
            + (text[-tail_chars:] if tail_chars else "")
        )

    ads._truncate_head_tail = truncate_head_tail  # noqa: SLF001

def attach_archive_overlap_resolver(ads):
    """Give a fake archive its content-on-tie overlap resolver."""
    @dataclass(frozen=True)
    class CoarseRun:
        start_id: int
        end_id: int
        confidence: float
        label: str

    def resolve_overlaps(raw_classifications, segments):
        votes = [[] for _ in segments]
        for chunk in raw_classifications:
            for segment_id, is_ad, label in chunk:
                votes[segment_id].append((is_ad, label))
        decisions = []
        for segment_votes in votes:
            positive = [(is_ad, label) for is_ad, label in segment_votes if is_ad]
            ratio = len(positive) / len(segment_votes) if segment_votes else 0.0
            is_ad = bool(segment_votes) and len(positive) > len(segment_votes) - len(positive)
            labels = [label for _is_ad, label in positive if label is not None]
            dominant = max(sorted(set(labels)), key=labels.count) if labels else "ad_break"
            decisions.append((is_ad, ratio, dominant))
        runs = []
        index = 0
        while index < len(segments):
            if not decisions[index][0]:
                index += 1
                continue
            start_id, confidences, labels = index, [], []
            while index < len(segments) and decisions[index][0]:
                confidences.append(decisions[index][1])
                labels.extend(
                    label for is_ad, label in votes[index] if is_ad and label is not None
                )
                index += 1
            runs.append(
                CoarseRun(
                    start_id,
                    index - 1,
                    sum(confidences) / len(confidences),
                    max(sorted(set(labels)), key=labels.count),
                )
            )
        return runs

    ads._resolve_overlaps = resolve_overlaps  # noqa: SLF001 - archive seam under test
    ads._verify_sparse_content_start = (  # noqa: SLF001 - archive seam under test
        lambda coarse_run, _confirmed_start_id, _segments, _backend: coarse_run.end_id + 1
    )
