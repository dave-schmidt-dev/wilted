"""Live worker response privacy and feed-profile status contracts."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker.feed_profiles import profile_envelope, validate_observation
from worker_test_fake_ads import install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, REPO_ROOT, install_fake_wilted, wp


class FeedProfilePipelineTests(unittest.TestCase):
    """Profile observations stay private to the top-level response."""

    def test_observation_is_top_level_and_wrong_feed_is_rejected(self):
        source_hash = "a" * 64
        segments = [FakeSegment(0, 1, "programme")]
        profile = profile_envelope({
            "schemaVersion": 1, "feedID": "feed-exact-1", "revision": 1,
            "sampleCount": 1, "slots": [{
                "position": "pre", "startBasisPoints": 0, "endBasisPoints": 10_000,
                "entryPhrases": ["previous sampled sponsor"], "returnPhrases": [],
            }],
        })
        with tempfile.TemporaryDirectory(prefix="feed-profile-pipeline-") as directory:
            audio = REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py"
            request = {
                "protocolVersion": 2, "audioPath": str(audio),
                "workDir": directory,
                "outputPath": str(Path(directory) / "profile-observation.mp3"),
                "removeAds": True, "alignedTranscriptModel": wp.ALIGNED_STT_MODEL,
                "feedID": "feed-exact-1", "episodeID": "episode-exact-1",
                "sourceHash": "sha256:" + source_hash, "adProfile": profile,
            }
            result = self._run(request, segments)
            cache = Path(directory) / "wilted-pipeline" / "aligned-stt-cache"
            self.assertTrue(list(cache.glob("*.json")), "fixture cache must be owned by its temporary directory")
            self.assertEqual(result["adProfileStatus"], "applied")
            self.assertEqual(result["adProfileRequestedDigest"], profile["digest"])
            self.assertEqual(result["adProfileAppliedDigest"], profile["digest"])
            self.assertIsNotNone(validate_observation(
                result["adProfileObservation"], "feed-exact-1", "episode-exact-1", source_hash,
            ))
            self.assertNotIn("adProfileObservation", result["report"]["audit"])
            self.assertNotIn("previous sampled sponsor", json.dumps(result["report"]))
            self.assertGreater(result["report"]["audit"]["adProfileRequests"], 0)
            self.assertGreaterEqual(
                result["report"]["audit"]["modelRequests"],
                result["report"]["audit"]["adProfileRequests"],
            )

            wrong_feed = dict(
                request, feedID="other-exact-feed",
                outputPath=str(Path(directory) / "wrong-feed.mp3"),
            )
            result = self._run(wrong_feed, segments)
        self.assertEqual(result["adProfileStatus"], "invalid")
        self.assertEqual(result["adProfileRequestedDigest"], profile["digest"])
        self.assertIsNone(result["adProfileAppliedDigest"])
        self.assertIsNone(result["report"]["audit"]["adProfileAppliedDigest"])

    @staticmethod
    def _run(request, segments):
        install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: segments})
        install_fake_ads(FakeLLM())
        with mock.patch.object(_worker_ad_audit, "preflight_ad_removal"), \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock",
                                  return_value=wp.contextlib.nullcontext()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=10.0), \
                redirect_stderr(io.StringIO()):
            return wp.run(request)
