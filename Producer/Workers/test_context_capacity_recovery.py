"""Tests for classifier context capacity overflow and recovery."""
from __future__ import annotations

import contextlib
import io
import json
import re
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import prompts as _worker_prompts
from wilted_worker.reporting import WorkerError
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, REPO_ROOT, install_fake_wilted, load_runtime_ads, wp


class CapacityScriptedBackend:
    """Backend answering classifications with simulated context capacity limits."""

    def __init__(
        self,
        label_map: dict[int, str],
        ads_module,
        *,
        max_ids: int | None = None,
        fail_ids: set[int] | None = None,
    ):
        self.label_map = label_map
        self.ads = ads_module
        self.max_ids = max_ids
        self.fail_ids = set(fail_ids or ())
        self.calls: list[tuple[str, str, dict | None]] = []

    def generate(self, system_prompt: str, content: str, *, response_format=None):
        self.calls.append((system_prompt, content, response_format))
        if system_prompt in (
            self.ads._AD_DETECT_SYSTEM_PROMPT,
            self.ads._AD_DETECT_CORRECTION_PROMPT,
            _worker_prompts.SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT,
            _worker_prompts.SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT,
        ):
            found_ids = [int(m) for m in re.findall(r"\[ID (\d+)\]", content)]
            if (self.max_ids is not None and len(found_ids) > self.max_ids) or any(
                i in self.fail_ids for i in found_ids
            ):
                raise ValueError("Requested tokens (4216) exceed context window of 4096")
            ads_list = [
                [seg_id, self.label_map[seg_id]]
                for seg_id in found_ids
                if seg_id in self.label_map and self.label_map[seg_id]
            ]
            return json.dumps({"ads": ads_list}), 1

        if response_format is not None:
            schema = response_format.get("schema", {})
            properties = schema.get("properties", {})
            if "include" in properties:
                return json.dumps({"include": False}), 1
            if "starts_program" in properties or "starts_program" in system_prompt:
                return json.dumps({"starts_program": False}), 1
            if "carries_program" in properties or "carries_program" in system_prompt:
                return json.dumps({"carries_program": False}), 1
            if "content_start_id" in properties:
                permitted = properties["content_start_id"].get("enum", [])
                return json.dumps({"content_start_id": permitted[0] if permitted else 0}), 1
            if "start_id" in properties:
                permitted = properties["start_id"].get("enum", [])
                return json.dumps({"start_id": permitted[-1] if permitted else 0}), 1
            if "program_start_id" in properties:
                permitted = properties["program_start_id"].get("enum", [])
                ans = 0 if 0 in permitted else (-1 if -1 in permitted else (permitted[0] if permitted else -1))
                return json.dumps({"program_start_id": ans}), 1
            if "advertising_start_id" in properties:
                permitted = properties["advertising_start_id"].get("enum", [])
                ans = -1 if -1 in permitted else (permitted[-1] if permitted else -1)
                return json.dumps({"advertising_start_id": ans}), 1
            if "labels" in properties:
                labels_dict = {str(k): "programme" for k in properties["labels"].get("properties", {})}
                return json.dumps({"labels": labels_dict}), 1
            if "classification" in properties:
                return json.dumps({"classification": "programme"}), 1
            if "ad_ids" in properties:
                return json.dumps({"ad_ids": []}), 1

        return json.dumps({}), 1


class ContextCapacityRecoveryTests(unittest.TestCase):
    """Tests verifying classifier capacity recovery and non-classifier latching."""

    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    def test_recovered_split_clears_capacity_error_and_preserves_detections(self):
        # Build 10 synthetic segments where the sponsor read sits at cues 2, 3, and 4.
        cues = [
            self.Segment(0.0, 10.0, "Welcome to the show today we discuss distributed systems architecture."),
            self.Segment(10.0, 20.0, "In this episode we will explore consensus algorithms and replication."),
            self.Segment(20.0, 30.0, "This episode is brought to you by Acme Cloud Services."),
            self.Segment(30.0, 40.0, "Acme Cloud Services provides reliable cloud servers worldwide."),
            self.Segment(40.0, 50.0, "Go to acme dot com slash podcast for twenty percent off today."),
            self.Segment(50.0, 60.0, "Now returning to consensus protocols and state machine replication."),
            self.Segment(60.0, 70.0, "Raft simplifies consensus by electing a distinguished leader."),
            self.Segment(70.0, 80.0, "The leader manages log replication across follower nodes in the cluster."),
            self.Segment(80.0, 90.0, "We will analyze safety and liveness properties in future discussions."),
            self.Segment(90.0, 100.0, "Thank you for listening to our discussion on systems architecture."),
        ]
        label_map = {2: "sponsor_read", 3: "sponsor_read", 4: "sponsor_read"}
        total_seconds = 100.0

        # Baseline: run with no capacity limit.
        backend_unlimited = CapacityScriptedBackend(label_map, self.ads)
        audit_unlimited = _worker_ad_audit.AuditingBackend(backend_unlimited, self.ads, len(cues))
        analysis_unlimited = _worker_ad_removal.analyze_ad_detections(
            self.ads, audit_unlimited, cues, total_seconds
        )

        # Limited backend: requests with more than 6 IDs overflow, but halve and fit.
        backend_limited = CapacityScriptedBackend(label_map, self.ads, max_ids=6)
        audit_limited = _worker_ad_audit.AuditingBackend(backend_limited, self.ads, len(cues))
        analysis_limited = _worker_ad_removal.analyze_ad_detections(
            self.ads, audit_limited, cues, total_seconds
        )

        self.assertTrue(analysis_unlimited.detections)
        self.assertEqual(analysis_limited.detections, analysis_unlimited.detections)
        self.assertIsNone(audit_limited.context_capacity_error)
        self.assertGreater(audit_limited.failures, 0)

    def test_unrecovered_split_for_specific_id_raises_classification_unresolved(self):
        # 40 cues with substantial length create multiple batches so the model overall
        # succeeds while the singleton request for ID 3 consistently overflows.
        cues = []
        t = 0.0
        for i in range(40):
            text = f"Content segment {i} " + ("synthetic text " * 150)
            cues.append(self.Segment(t, t + 10.0, text))
            t += 10.0

        backend = CapacityScriptedBackend({}, self.ads, fail_ids={3})
        audit_backend = _worker_ad_audit.AuditingBackend(backend, self.ads, len(cues))
        with self.assertRaises(WorkerError) as ctx:
            _worker_ad_removal.analyze_ad_detections(self.ads, audit_backend, cues, t)

        self.assertEqual(ctx.exception.code, "ads-classification-unresolved")
        self.assertIsNone(audit_backend.context_capacity_error)

    def test_non_classification_capacity_overflow_still_latches(self):
        class NonClassifierOverflowBackend:
            def generate(self, system_prompt, user_content, *, response_format=None):
                raise ValueError("Requested tokens (4216) exceed context window of 4096")

        inner = NonClassifierOverflowBackend()
        auditing_backend = _worker_ad_audit.AuditingBackend(inner, self.ads, 5)

        # Worker envelope verification prompt is not a classifier prompt and must latch.
        with self.assertRaises(ValueError):
            auditing_backend.generate(
                _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
                "Candidate ID to resolve: 1\n",
            )

        self.assertIsNotNone(auditing_backend.context_capacity_error)
        self.assertEqual(
            str(auditing_backend.context_capacity_error),
            "Requested tokens (4216) exceed context window of 4096",
        )

    def test_counting_backend_latches_capacity_error_from_any_prompt(self):
        capacity_error = ValueError("Requested tokens (4216) exceed context window of 4096")

        class AlwaysOverflowBackend:
            def generate(self, system_prompt, user_content, *, response_format=None):
                raise capacity_error

        # CountingBackend used directly without AuditingBackend latches any capacity failure.
        backend_classifier = _worker_ad_audit.CountingBackend(AlwaysOverflowBackend())
        with self.assertRaises(ValueError):
            backend_classifier.generate(self.ads._AD_DETECT_SYSTEM_PROMPT, "test synthetic content")
        self.assertIs(backend_classifier.context_capacity_error, capacity_error)

        backend_custom = _worker_ad_audit.CountingBackend(AlwaysOverflowBackend())
        with self.assertRaises(ValueError):
            backend_custom.generate("custom prompt", "test synthetic content")
        self.assertIs(backend_custom.context_capacity_error, capacity_error)

    def test_pipeline_run_recovers_from_classifier_overflow_and_renders(self):
        message = "Requested tokens (4216) exceed context window of 4096"
        audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
        segments = [
            FakeSegment(0.0, 5.0, "synthetic episode prelude"),
            FakeSegment(10.0, 20.0, "synthetic promotional setup"),
            FakeSegment(20.0, 30.0, "synthetic product details"),
            FakeSegment(30.0, 40.0, "visit example dot com slash discount today"),
            FakeSegment(50.0, 60.0, "synthetic discussion content"),
            FakeSegment(90.0, 100.0, "synthetic concluding thoughts"),
        ]

        install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: segments})
        llm = FakeLLM(preroll_program_id=-1, postroll_advertising_start_id=-1)
        ads = install_fake_ads(llm)
        original_generate = llm.generate
        failed = []

        def generate(prompt, content, *, response_format=None):
            if prompt == ads._AD_DETECT_SYSTEM_PROMPT and not failed:
                failed.append(prompt)
                raise ValueError(message)
            return original_generate(prompt, content, response_format=response_format)

        llm.generate = generate

        def detector(_segments, backend):
            # Initial request overflows, then retry at smaller halved batches succeeds.
            all_rendered = "\n".join(f"[ID {index}] {segment.text}" for index, segment in enumerate(segments))
            try:
                backend.generate(
                    ads._AD_DETECT_SYSTEM_PROMPT, all_rendered, response_format=ads._AD_DETECT_RESPONSE_FORMAT
                )
            except ValueError:
                pass
            half1 = "\n".join(f"[ID {index}] {segment.text}" for index, segment in enumerate(segments[:3]))
            half2 = "\n".join(f"[ID {index}] {segment.text}" for index, segment in enumerate(segments[3:], start=3))
            backend.generate(ads._AD_DETECT_SYSTEM_PROMPT, half1, response_format=ads._AD_DETECT_RESPONSE_FORMAT)
            backend.generate(ads._AD_DETECT_SYSTEM_PROMPT, half2, response_format=ads._AD_DETECT_RESPONSE_FORMAT)
            return [FakeAd(30, 40)]

        detector._covers_classifier = True
        ads.detect_ads = detector

        rendered_files: dict[str, float] = {}

        def fake_render(command, **_kwargs):
            out = Path(command[-1])
            out.write_bytes(b"synthetic cut audio")
            filters = command[command.index("-filter_complex") + 1]
            rendered_files[out.name] = sum(
                float(end) - float(start)
                for start, end in re.findall(r"atrim=start=([0-9.]+):end=([0-9.]+)", filters)
            )

        def fake_probe(path):
            return rendered_files.get(Path(path).name, 500.0)

        render_mock = mock.MagicMock(side_effect=fake_render)
        no_gpu = contextlib.nullcontext()

        with tempfile.TemporaryDirectory() as scratch:
            out_path = Path(scratch, "rendered-output.mp3")
            with redirect_stderr(io.StringIO()), \
                    mock.patch.object(_worker_ad_audit, "preflight_ad_removal"), \
                    mock.patch.object(_worker_cue_timing, "probe_duration", side_effect=fake_probe), \
                    mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", return_value=no_gpu), \
                    mock.patch.object(_worker_cue_timing, "_run_render_with_progress", render_mock):
                result = wp.run({
                    "protocolVersion": 2,
                    "audioPath": str(audio),
                    "outputPath": str(out_path),
                    "removeAds": True,
                    "readableTranscript": False,
                })

        self.assertEqual(len(failed), 1)
        self.assertNotEqual(result["report"]["outcome"], "uncertain")
        self.assertEqual(result["report"]["outcome"], "cut")
        self.assertNotIn("original audio includes ads", result.get("warning") or "")
        render_mock.assert_called_once()


if __name__ == "__main__":
    unittest.main()
