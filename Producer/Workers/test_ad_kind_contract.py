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

class AdKindContractTests(unittest.TestCase):
    """Paid advertising, house promotion, and credits, as the contract's kinds.

    The detector's four labels say how a read was delivered, not who paid for
    it: `self_promo` is the show promoting itself, which David decided on
    2026-09-17 is not advertising. The worker republishes every span with a
    kind while leaving the label in place, carries every overlapping
    nomination's kind through a merge and through effective-cut selection, and
    reports `acceptable-cut` for anything that is not paid advertising.
    """

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.request = {"audioPath": str(self.audio), "outputPath": "/tmp/never-written.mp3"}
        self.segments = [
            FakeSegment(index * 10.0, index * 10.0 + 10.0, f"segment {index}")
            for index in range(10)
        ]

    def cut(self, detections, total=100.0):
        llm = FakeLLM()
        install_fake_ads(llm, detections=list(detections))
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=total):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        return spans

    def test_each_detector_label_keeps_its_value_and_gains_a_kind(self):
        spans = self.cut([
            FakeAd(0.0, 5.0, label="sponsor_read"),
            FakeAd(20.0, 25.0, label="self_promo"),
            FakeAd(40.0, 45.0, label="ad_break"),
            FakeAd(60.0, 65.0, label="newsletter_pitch"),
        ])
        by_label = {span["label"]: span for span in spans}
        self.assertEqual(
            set(by_label),
            {"sponsor_read", "self_promo", "ad_break", "newsletter_pitch"},
            "the label is added beside the kind, not replaced",
        )
        self.assertEqual(by_label["sponsor_read"]["kind"], "paid advertising")
        self.assertEqual(by_label["sponsor_read"]["disposition"], "must-cut")
        self.assertEqual(by_label["ad_break"]["kind"], "paid advertising")
        self.assertEqual(by_label["self_promo"]["kind"], "house promotion")
        self.assertEqual(by_label["self_promo"]["disposition"], "acceptable-cut")
        self.assertEqual(by_label["newsletter_pitch"]["kind"], "house promotion")
        self.assertEqual(by_label["newsletter_pitch"]["disposition"], "acceptable-cut")
        for span in spans:
            self.assertIn(span["kind"], {"paid advertising", "house promotion", "credits"})
            self.assertEqual(span["kinds"], [span["kind"]], "a single nomination carries one kind")

    def test_an_unpaid_house_promotion_is_acceptable_cut_and_keeps_its_boundaries(self):
        spans = self.cut([FakeAd(0.0, 5.0, label="self_promo")])
        # The cut span set is exactly what it was before the kinds landed.
        self.assertEqual(
            [(span["startSeconds"], span["endSeconds"], span["label"]) for span in spans],
            [(0.0, 5.0, "self_promo")],
        )
        self.assertEqual(spans[0]["kind"], "house promotion")
        self.assertEqual(spans[0]["disposition"], "acceptable-cut")

    def test_an_adjacent_pair_with_different_labels_merges_with_both_kinds(self):
        # Merging keeps the earlier label for the run, as it always has; the
        # kinds are a set, so the survivor cannot silently claim the whole run.
        ads = install_fake_ads(FakeLLM())
        merged = ads._merge_adjacent([
            FakeAd(0.0, 10.0, label="sponsor_read"),
            FakeAd(11.0, 20.0, label="self_promo"),
        ])
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0].label, "sponsor_read")
        self.assertEqual(list(merged[0].kinds), ["house promotion", "paid advertising"])

    def test_effective_cut_selection_returns_every_overlapping_kind(self):
        ads = install_fake_ads(FakeLLM())
        paid = {
            "startSeconds": 0.0, "endSeconds": 10.0, "label": "sponsor_read",
            "kind": "paid advertising", "kinds": ["paid advertising"],
            "disposition": "must-cut", "confidence": 0.9,
        }
        house = {
            "startSeconds": 5.0, "endSeconds": 15.0, "label": "self_promo",
            "kind": "house promotion", "kinds": ["house promotion"],
            "disposition": "acceptable-cut", "confidence": 0.9,
        }
        keeps = wp.build_keep_map([(15.0, 100.0)])

        both = wp.effective_ad_spans(ads, [paid, house], keeps, 100.0)
        self.assertEqual(len(both), 1)
        self.assertEqual(both[0]["label"], "sponsor_read")
        self.assertEqual(both[0]["kinds"], ["house promotion", "paid advertising"],
                         "each overlapping nomination's kind survives selection")
        self.assertEqual(both[0]["kind"], "paid advertising")
        self.assertEqual(both[0]["disposition"], "must-cut",
                         "a cut holding paid advertising is required, whatever else it holds")

        only_house = wp.effective_ad_spans(ads, [house], keeps, 100.0)
        self.assertEqual(only_house[0]["kind"], "house promotion")
        self.assertEqual(only_house[0]["disposition"], "acceptable-cut")

        unmatched = wp.effective_ad_spans(ads, [], keeps, 100.0)
        self.assertEqual(unmatched[0]["label"], "advertisement")
        self.assertEqual(unmatched[0]["kind"], "paid advertising",
                         "an interval no nomination explains is the conservative reading")

    def test_an_explicit_credits_kind_stays_credits_on_a_paid_label(self):
        # The kind is what the span is, the label is how the detector found
        # it. A span the worker positively established as credits must not be
        # re-attributed to paid advertising just because its detector label
        # maps there by default.
        spans = self.cut([FakeAd(40.0, 45.0, label="ad_break", kinds=("credits",))])
        self.assertEqual(len(spans), 1)
        self.assertEqual(spans[0]["label"], "ad_break")
        self.assertEqual(spans[0]["kind"], "credits")
        self.assertEqual(spans[0]["kinds"], ["credits"])
        self.assertEqual(spans[0]["disposition"], "acceptable-cut")

    def test_both_unpaid_house_labels_report_house_promotion_without_moving_the_cut(self):
        for label in ("self_promo", "newsletter_pitch"):
            with self.subTest(label=label):
                spans = self.cut([FakeAd(0.0, 5.0, label=label)])
                self.assertEqual(
                    [(span["startSeconds"], span["endSeconds"], span["label"]) for span in spans],
                    [(0.0, 5.0, label)],
                )
                self.assertEqual(spans[0]["kind"], "house promotion")
                self.assertEqual(spans[0]["disposition"], "acceptable-cut")

    def test_a_merged_paid_and_house_pair_publishes_both_kinds(self):
        # The archive's own merge fuses an adjacent paid read and a house
        # promotion into one run; the publication path has to carry both
        # kinds from that run, not the earlier label's kind alone.
        llm = FakeLLM()
        ads = install_fake_ads(llm)
        merged = ads._merge_adjacent([
            FakeAd(0.0, 10.0, label="sponsor_read"),
            FakeAd(10.5, 20.0, label="self_promo"),
        ])
        self.assertEqual(len(merged), 1)
        install_fake_ads(llm, detections=merged)
        with redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=100.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], self.segments)
        self.assertEqual(len(spans), 1)
        self.assertEqual(
            (spans[0]["startSeconds"], spans[0]["endSeconds"]), (0.0, 20.0)
        )
        self.assertEqual(spans[0]["label"], "sponsor_read")
        self.assertEqual(spans[0]["kinds"], ["house promotion", "paid advertising"])
        self.assertEqual(spans[0]["kind"], "paid advertising")
        self.assertEqual(spans[0]["disposition"], "must-cut")

    def test_a_closing_credits_span_reports_credits_and_stays_acceptable(self):
        # The closing review is the one pass that positively established this
        # run as the sign-off/credits/music-bed shape, so it is where `credits`
        # is attached; the contract carries it with an acceptable disposition.
        llm = FakeLLM(postroll_advertising_start_id=19, tail_carries_program=False,
                      preroll_program_id=-1)
        install_fake_ads(llm)
        segments = [
            FakeSegment(index * 40.0, index * 40.0 + 40.0, f"segment {index}")
            for index in range(20)
        ]
        stream = io.StringIO()
        with redirect_stderr(stream), mock.patch.object(_worker_cue_timing, "probe_duration", return_value=810.0):
            _path, spans, _keeps = wp.detect_and_cut(self.request, self.audio, [], segments)
        credits = [span for span in spans if span["kind"] == "credits"]
        self.assertEqual(len(credits), 1)
        self.assertEqual(
            (credits[0]["startSeconds"], credits[0]["endSeconds"], credits[0]["label"]),
            (760.0, 810.0, "ad_break"),
        )
        self.assertEqual(credits[0]["disposition"], "acceptable-cut")

    def test_the_test_taxonomy_matches_the_vendored_module(self):
        # The real module cannot be imported in this gate -- it imports the
        # model bindings -- so its taxonomy is read out of its source and
        # compared with the fake the rest of these tests run against.
        source = (
            Path(REPO_ROOT) / "Producer" / "Runtime" / "src" / "wilted" / "ads.py"
        ).read_text(encoding="utf-8")
        constants = {}
        mapping = None
        for node in ast.parse(source).body:
            if not isinstance(node, ast.Assign) or len(node.targets) != 1:
                continue
            target = node.targets[0]
            if not isinstance(target, ast.Name) or not target.id.startswith("AD_KIND_"):
                continue
            if target.id == "AD_KIND_BY_LABEL":
                mapping = {
                    key.value: constants[value.id]
                    for key, value in zip(node.value.keys, node.value.values)
                }
            else:
                constants[target.id] = ast.literal_eval(node.value)
        self.assertEqual(constants, {
            "AD_KIND_PAID": "paid advertising",
            "AD_KIND_HOUSE": "house promotion",
            "AD_KIND_CREDITS": "credits",
        })
        self.assertEqual(mapping, AD_KIND_BY_LABEL)
