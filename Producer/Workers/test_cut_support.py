"""The labelled cut stage stands alone: its helpers and its imports.

The helpers in ``cut_support`` are unchanged copies of what the local ad
finder used to own. These tests pin their behaviour, and one test runs a whole
cut-stage request in a fresh interpreter in which the local finder's modules
cannot be imported at all.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import textwrap
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from wilted_worker import cue_timing, cut_support
from wilted_worker.reporting import WorkerError

WORKERS = Path(__file__).resolve().parent

CUT_STAGE_SCRIPT = textwrap.dedent(
    """
    import io, json, sys, tempfile
    from contextlib import redirect_stderr
    from dataclasses import dataclass
    from pathlib import Path
    from unittest import mock

    sys.path.insert(0, {workers!r})

    import wilted_pipeline
    from wilted_worker import cue_timing, labelled_outcome, labeller_cues, cut_support
    from wilted_worker import transcript_sources

    @dataclass
    class Segment:
        start_s: float
        end_s: float
        text: str

    segments = [
        Segment(0.0, 18.0, "programme opening"),
        Segment(20.0, 40.0, "sponsor read"),
        Segment(41.0, 50.0, "programme middle"),
        Segment(52.0, 57.0, "programme close"),
    ]
    digest = labeller_cues.serialize_labeller_cues(
        labeller_cues.build_labeller_cues(segments))[1]

    import re
    rendered = {{}}

    def render(command, **_kwargs):
        if "-filter_complex" not in command:
            return ""
        output = Path(command[-1])
        output.write_bytes(b"synthetic")
        filters = command[command.index("-filter_complex") + 1]
        points = [float(p) for p in re.search(r"asegment=timestamps=([0-9.|]+)", filters)[1].split("|")]
        bounds = [0.0, *points, 60.0]
        rendered[output.name] = sum(
            max(0.0, min(bounds[i + 1], 60.0) - bounds[i])
            for i in (int(found) for found in re.findall(r"\\[s(\\d+)\\]asetpts", filters))
        )

    def probe(path):
        return rendered.get(Path(path).name, 60.0)

    with tempfile.TemporaryDirectory() as directory:
        audio = Path(directory) / "source.mp3"
        audio.write_bytes(b"original audio")
        request = {{
            "protocolVersion": 2,
            "adStage": "cut",
            "audioPath": str(audio),
            "outputPath": str(Path(directory) / "prepared.mp3"),
            "removeAds": True,
            "labelledBreaks": [
                {{"start": 20.0, "end": 40.0, "kind": "sponsor",
                  "label": "must-cut", "advertisers": ["Acme"]}},
            ],
            "labellerCuesDigest": digest,
            "workDir": directory,
        }}
        with mock.patch.object(transcript_sources, "transcribe_with_daemon", return_value=segments), \\
                mock.patch.object(cue_timing, "probe_duration", side_effect=probe), \\
                mock.patch.object(cue_timing, "_run_render_with_progress", side_effect=render), \\
                mock.patch.object(cut_support.shutil, "which", return_value="/usr/bin/true"), \\
                redirect_stderr(io.StringIO()):
            result = wilted_pipeline.run(request)
    loaded = sorted(name for name in sys.modules if sys.modules[name] is not None
                    and name.startswith("wilted_worker."))
    print(json.dumps({{
        "ok": result["ok"],
        "stage": result["adStage"],
        "spans": [[s["startSeconds"], s["endSeconds"]] for s in result["adSegments"]],
        "engine": result["report"]["audit"]["adEngine"],
        "loaded": loaded,
    }}))
    """
)


class CutStageStandsAloneTests(unittest.TestCase):
    def test_a_cut_stage_request_runs_end_to_end_on_the_kept_modules(self):
        script = CUT_STAGE_SCRIPT.format(workers=str(WORKERS))
        completed = subprocess.run(
            [sys.executable, "-I", "-c", script],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr[-2000:])
        outcome = json.loads(completed.stdout.strip().splitlines()[-1])
        self.assertTrue(outcome["ok"])
        self.assertEqual(outcome["stage"], "cut")
        self.assertEqual(outcome["spans"], [[20.0, 40.0]])
        self.assertEqual(outcome["engine"], "labelled")
        on_disk = {f"wilted_worker.{p.stem}" for p in (WORKERS / "wilted_worker").glob("*.py")}
        self.assertLessEqual(set(outcome["loaded"]), on_disk | {"wilted_worker"})


class CutSupportTests(unittest.TestCase):
    def test_share_retirement_ledger_records_only_actual_over_ceiling_clears(self):
        for detection, total in (
            ([SimpleNamespace(start_s=0.0, end_s=29.0)], 50.0),
            ([SimpleNamespace(start_s=0.0, end_s=30.0)], 50.0),
        ):
            held, retired = [], []
            with redirect_stderr(io.StringIO()):
                self.assertIs(
                    cut_support.enforce_total_ad_share_ceiling(
                        detection,
                        total,
                        held,
                        retired_detections=retired,
                    ),
                    detection,
                )
            self.assertEqual(held, [])
            self.assertEqual(retired, [])

        over = [
            SimpleNamespace(start_s=0.0, end_s=31.0),
            SimpleNamespace(start_s=40.0, end_s=70.0),
        ]
        held, retired = [], []
        with redirect_stderr(io.StringIO()):
            self.assertEqual(
                cut_support.enforce_total_ad_share_ceiling(
                    over,
                    100.0,
                    held,
                    retired_detections=retired,
                ),
                [],
            )
        self.assertEqual(retired, over)
        self.assertEqual(
            [span.reason for span in held], ["total-share-ceiling"] * len(over)
        )

    def test_existing_total_share_ceiling_still_holds(self):
        held = []
        above = [
            SimpleNamespace(start_s=0.0, end_s=30.0),
            SimpleNamespace(start_s=30.0, end_s=31.0),
        ]
        with redirect_stderr(io.StringIO()):
            self.assertEqual(
                cut_support.enforce_total_ad_share_ceiling(above, 50.0, held), []
            )
        self.assertEqual([span.reason for span in held], ["total-share-ceiling"] * 2)

    def test_total_share_ceiling_counts_overlapping_union_once(self):
        detections = [
            SimpleNamespace(start_s=20.0, end_s=48.0),
            SimpleNamespace(start_s=60.0, end_s=87.0),
            SimpleNamespace(start_s=40.0, end_s=50.0),
        ]
        held = []
        self.assertEqual(
            cut_support.enforce_total_ad_share_ceiling(detections, 100.0, held),
            detections,
        )
        self.assertEqual(held, [])
        self.assertEqual(cut_support._union_ad_seconds(detections, 100.0), 57.0)

    def test_an_unreadable_detection_counts_as_unbounded_share(self):
        self.assertEqual(
            cut_support._union_ad_seconds(
                [SimpleNamespace(start_s=5.0, end_s=1.0)], 100.0
            ),
            float("inf"),
        )

    def test_a_held_span_is_recorded_and_reports_its_share(self):
        held = []
        stream = io.StringIO()
        with redirect_stderr(stream):
            cut_support.record_held_span(
                held, 10.0, 30.0, "boundary-review-unresolved", 100.0
            )
        self.assertEqual(
            held, [cut_support.HeldAdSpan(10.0, 30.0, "boundary-review-unresolved")]
        )
        self.assertIn("ads.detect.span.held", stream.getvalue())
        self.assertIn("20%", stream.getvalue())

    def test_effective_cut_selection_returns_every_overlapping_kind(self):
        paid = {
            "startSeconds": 0.0,
            "endSeconds": 10.0,
            "label": "sponsor_read",
            "kind": "paid advertising",
            "kinds": ["paid advertising"],
            "disposition": "must-cut",
            "confidence": 0.9,
        }
        house = {
            "startSeconds": 5.0,
            "endSeconds": 15.0,
            "label": "self_promo",
            "kind": "house promotion",
            "kinds": ["house promotion"],
            "disposition": "acceptable-cut",
            "confidence": 0.9,
        }
        keeps = cue_timing.build_keep_map([(15.0, 100.0)])

        both = cut_support.effective_ad_spans([paid, house], keeps, 100.0)
        self.assertEqual(len(both), 1)
        self.assertEqual(both[0]["label"], "sponsor_read")
        self.assertEqual(both[0]["kinds"], ["house promotion", "paid advertising"])
        self.assertEqual(both[0]["kind"], "paid advertising")
        self.assertEqual(both[0]["disposition"], "must-cut")

        only_house = cut_support.effective_ad_spans([house], keeps, 100.0)
        self.assertEqual(only_house[0]["kind"], "house promotion")
        self.assertEqual(only_house[0]["disposition"], "acceptable-cut")

        unmatched = cut_support.effective_ad_spans([], keeps, 100.0)
        self.assertEqual(unmatched[0]["label"], "advertisement")
        self.assertEqual(unmatched[0]["kind"], "paid advertising")

    def test_an_explicit_credits_kind_stays_credits_and_is_acceptable(self):
        fields = cut_support._ad_kind_fields(("credits",))
        self.assertEqual(
            fields,
            {"kind": "credits", "kinds": ["credits"], "disposition": "acceptable-cut"},
        )
        unknown = cut_support._ad_kind_fields(("something else",))
        self.assertEqual(unknown["kind"], "paid advertising")
        self.assertEqual(unknown["disposition"], "must-cut")

    def test_missing_cut_tools_fail_before_any_work(self):
        with mock.patch.object(cut_support.shutil, "which", return_value=None):
            with self.assertRaises(WorkerError) as raised:
                cut_support.preflight_cut_tools()
        self.assertEqual(raised.exception.code, "cut-tools-missing")


if __name__ == "__main__":
    unittest.main()
