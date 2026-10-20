"""Tests for the one-pass ffmpeg graph that renders a keep map."""
from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path

from wilted_worker.cue_timing import KeepInterval, build_keep_map
from wilted_worker.render_graph import keep_segment_graph
from wilted_worker.reporting import WorkerError

REPO_ROOT = Path(__file__).resolve().parents[2]


def _atrim_reference_graph(keeps) -> str:
    """The per-keep ``atrim`` graph the split graph replaced, kept as the oracle."""
    filters = [
        f"[0:a]atrim=start={keep.start_s:.6f}:end={keep.end_s:.6f},asetpts=PTS-STARTPTS[k{index}]"
        for index, keep in enumerate(keeps)
    ]
    filters.append("".join(f"[k{index}]" for index in range(len(keeps))) + f"concat=n={len(keeps)}:v=0:a=1[outc]")
    filters.append("[outc]aresample[outa]")
    return ";".join(filters)


class KeepSegmentGraphTests(unittest.TestCase):
    def test_splits_once_and_keeps_only_the_listed_pieces(self):
        graph = keep_segment_graph(build_keep_map([(0.0, 10.0), (20.0, 30.0)]))
        self.assertEqual(
            graph,
            "[0:a]asegment=timestamps=10.000000|20.000000|30.000000[s0][s1][s2][s3];"
            "[s0]asetpts=PTS-STARTPTS[k0];[s1]anullsink;[s2]asetpts=PTS-STARTPTS[k2];[s3]anullsink;"
            "[k0][k2]concat=n=2:v=0:a=1[outc];[outc]aresample[outa]",
        )

    def test_a_late_first_keep_drains_the_leading_piece(self):
        graph = keep_segment_graph(build_keep_map([(5.0, 10.0)]))
        self.assertTrue(graph.startswith("[0:a]asegment=timestamps=5.000000|10.000000[s0][s1][s2];"))
        self.assertIn("[s0]anullsink;[s1]asetpts=PTS-STARTPTS[k1];[s2]anullsink;", graph)
        self.assertIn("[k1]concat=n=1:v=0:a=1[outc]", graph)

    def test_touching_keeps_share_one_split_point(self):
        graph = keep_segment_graph(build_keep_map([(0.0, 4.0), (4.0, 9.0)]))
        self.assertIn("asegment=timestamps=4.000000|9.000000[s0][s1][s2]", graph)
        self.assertIn("[k0][k1]concat=n=2", graph)

    def test_a_keep_too_short_to_express_is_dropped(self):
        keeps = [KeepInterval(0.0, 3.0, 0.0), KeepInterval(3.0, 3.0000001, 3.0), KeepInterval(5.0, 6.0, 3.0)]
        graph = keep_segment_graph(keeps)
        self.assertIn("asegment=timestamps=3.000000|5.000000|6.000000", graph)
        self.assertIn("concat=n=2", graph)

    def test_unsafe_maps_are_refused(self):
        cases = {
            "empty interval": [KeepInterval(2.0, 2.0, 0.0)],
            "negative start": [KeepInterval(-1.0, 2.0, 0.0)],
            "overlap": [KeepInterval(0.0, 5.0, 0.0), KeepInterval(4.0, 8.0, 5.0)],
            "out of order": [KeepInterval(6.0, 8.0, 0.0), KeepInterval(0.0, 2.0, 2.0)],
            "nothing kept": [],
            "only inexpressible keeps": [KeepInterval(1.0, 1.0000001, 0.0)],
        }
        for name, keeps in cases.items():
            with self.subTest(name), self.assertRaises(WorkerError) as raised:
                keep_segment_graph(keeps)
            self.assertEqual(raised.exception.code, "cut-unsafe")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is not installed")
    def test_decoded_audio_matches_the_atrim_graph_sample_for_sample(self):
        scratch = REPO_ROOT / ".verify-tmp" / f"render-graph-{os.getpid()}"
        scratch.mkdir(parents=True, exist_ok=True)
        self.addCleanup(shutil.rmtree, scratch, ignore_errors=True)
        # A zero start, a gap, touching keeps, an off-frame boundary and a
        # keep that runs past the end of the 12-second stream.
        keeps = build_keep_map([(0.0, 2.3), (4.1, 6.05), (6.05, 8.0), (9.123457, 10.5), (11.5, 13.0)])
        for suffix in (".wav", ".mp3", ".m4a"):
            source = scratch / f"source{suffix}"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                 "-i", "aevalsrc=sin(2*PI*(200+40*t)*t):s=44100:d=12", str(source)],
                check=True, capture_output=True,
            )
            decoded = {}
            for name, graph in (("split", keep_segment_graph(keeps)), ("atrim", _atrim_reference_graph(keeps))):
                output = scratch / f"{name}{suffix}.pcm"
                subprocess.run(
                    ["ffmpeg", "-y", "-v", "error", "-i", str(source), "-filter_complex", graph,
                     "-map", "[outa]", "-f", "s16le", "-acodec", "pcm_s16le", str(output)],
                    check=True, capture_output=True,
                )
                decoded[name] = output.read_bytes()
            with self.subTest(suffix):
                self.assertGreater(len(decoded["atrim"]), 0)
                self.assertEqual(decoded["split"], decoded["atrim"])


if __name__ == "__main__":
    unittest.main()
