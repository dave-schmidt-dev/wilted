"""Bounded local-summary retries when the model reaches its output limit."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock
from uuid import uuid4

from test_transcript_summary import MeasuredFakeLLM
from worker_test_support import install_fake_wilted, recording_model_lock, wp
from wilted_worker import gpu_admission


class TruncationAwareFakeLLM(MeasuredFakeLLM):
    def generate_summary(self, prepared):
        prefix = getattr(self, "truncate_prefix", None)
        remaining = getattr(self, "truncations_remaining", 0)
        should_truncate = self.truncated or (
            remaining > 0 and (prefix is None or prepared.content.startswith(prefix))
        )
        if should_truncate:
            self.generated_prepared = getattr(self, "generated_prepared", []) + [prepared]
            self.truncated_attempts.append(prepared.content)
            if not self.truncated:
                self.truncations_remaining -= 1
            raise self.truncation_error("completion finish_reason length")
        return super().generate_summary(prepared)


class TranscriptSummaryTruncationTests(unittest.TestCase):
    def setUp(self):
        self.modules = mock.patch.dict(sys.modules)
        self.modules.start()
        self.addCleanup(self.modules.stop)
        install_fake_wilted()
        self.directory = tempfile.TemporaryDirectory(prefix="wilted-summary-truncation-")
        self.addCleanup(self.directory.cleanup)
        self.model = (Path(self.directory.name) / "synthetic-local.gguf").resolve()
        self.model.write_bytes(b"synthetic; never loaded by a real backend")
        self.backend = TruncationAwareFakeLLM(answer="The gardener explains watering and soil care.")
        self.backend.truncation_error = sys.modules["wilted.gguf_summary"].SummaryOutputTruncated
        self.backend.truncated_attempts = []
        self.factory = mock.Mock(return_value=self.backend)
        llm = types.ModuleType("wilted.llm")
        llm.DEFAULT_GGUF_MODEL = str(self.model)
        llm.create_backend = self.factory
        sys.modules["wilted.llm"] = llm
        sys.modules["wilted"].llm = llm
        self.lock_events = []
        self.gpu = mock.patch.object(
            gpu_admission, "prepare_ad_model_lock",
            side_effect=lambda *_args, **_kwargs: recording_model_lock(self.lock_events),
        )
        self.gpu.start()
        self.addCleanup(self.gpu.stop)

    def request(self, transcript):
        return {"protocolVersion": 2, "operation": "summary", "requestID": str(uuid4()),
                "transcriptText": transcript, "llmModel": str(self.model)}

    def accepted_summary(self, request):
        with redirect_stderr(io.StringIO()):
            result = wp.run(request)
        self.assertTrue(result["ok"])
        self.assertEqual(result["coverage"], "whole")
        self.assertEqual(result["inputCharacters"], len(request["transcriptText"]))
        ranges = result["coverageRanges"]
        self.assertEqual(ranges[0][0], 0)
        self.assertEqual(ranges[-1][1], len(request["transcriptText"]))
        self.assertTrue(all(left[1] == right[0] for left, right in zip(ranges, ranges[1:])))
        self.assertTrue(self.backend.closed)
        self.assertEqual(self.lock_events, ["lock.enter", "lock.exit"])
        return result

    def test_truncated_map_passage_is_split_and_full_coverage_is_returned(self):
        self.backend.context_size = 1200
        self.backend.truncations_remaining = 1
        transcript = "START " + ("soil café 水 🌱 roots. " * 90) + "END SENTINEL"
        result = self.accepted_summary(self.request(transcript))
        first_attempt = self.backend.truncated_attempts[0][len("Transcript:\n"):]
        first_success = self.backend.generated_prepared[1].content[len("Transcript:\n"):]
        self.assertLess(len(first_success), len(first_attempt))
        self.assertEqual(transcript[:len(first_success)], first_success)
        self.assertEqual(result["coverageRanges"][0], [0, len(first_success)])
        self.assertEqual("".join(transcript[a:b] for a, b in result["coverageRanges"]), transcript)

    def test_truncated_reduce_batch_is_halved_and_counts_only_complete_calls(self):
        self.backend.truncations_remaining = 1
        self.backend.truncate_prefix = "Summaries:\n"
        transcript = "Beginning " + ("soil holds water; roots need air. " * 420) + "END SENTINEL"
        result = self.accepted_summary(self.request(transcript))
        failed_children = json.loads(self.backend.truncated_attempts[0][len("Summaries:\n"):])
        completed_reductions = [
            json.loads(content[len("Summaries:\n"):])
            for content in self.backend.request_contents if content.startswith("Summaries:\n")
        ]
        self.assertGreater(len(failed_children), 2)
        self.assertLess(len(completed_reductions[0]), len(failed_children))
        self.assertEqual(result["completionTokens"], len(self.backend.request_contents))
        self.assertGreater(result["reductionLevels"], 0)

    def test_repeated_map_truncation_is_bounded_and_never_returns_partial_text(self):
        from wilted_worker.transcript_summary import MAX_MAP_TRUNCATION_RETRIES

        self.backend.truncated = True
        request = self.request("A substantial transcript passage. " * 80)
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run(request)
        self.assertEqual(raised.exception.code, "summary-generation-failed")
        self.assertLessEqual(len(self.backend.truncated_attempts), MAX_MAP_TRUNCATION_RETRIES + 1)
        self.assertTrue(self.backend.closed)
        self.assertEqual(self.lock_events, ["lock.enter", "lock.exit"])

    def test_truncated_two_summary_reduction_fails_without_partial_text(self):
        self.backend.truncations_remaining = 100
        self.backend.truncate_prefix = "Summaries:\n"
        request = self.request("Beginning " + ("soil holds water; roots need air. " * 420) + "END SENTINEL")
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run(request)
        self.assertEqual(raised.exception.code, "summary-generation-failed")
        self.assertEqual(len(self.backend.truncated_attempts), 2)
        last_children = json.loads(self.backend.truncated_attempts[-1][len("Summaries:\n"):])
        self.assertEqual(len(last_children), 2)
        self.assertTrue(self.backend.closed)
        self.assertEqual(self.lock_events, ["lock.enter", "lock.exit"])
