"""Podcast worker tests."""
from __future__ import annotations
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from hashlib import sha256
from pathlib import Path
from wilted_worker import labeller_cues as _worker_labeller_cues
from wilted_worker.constants import ALIGNED_STT_CACHE_SCHEMA_VERSION
from worker_test_support import *
from worker_test_support import wp

class LabellerCueBackfillTests(unittest.TestCase):
    """The cue backfill exports stored transcripts without ever touching them."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wilted-labeller-backfill-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)

    def request(self, **overrides):
        request = {"operation": "labellerCues", "protocolVersion": 2, "workDir": str(self.work)}
        request.update(overrides)
        return request

    def cache_directory(self):
        return self.work / "wilted-pipeline" / "aligned-stt-cache"

    def export_directory(self):
        return self.work / "wilted-pipeline" / "labeller-backfill"

    def store(self, source_hash, model, segments):
        """Write one cache entry exactly where a completed preparation leaves it."""
        directory = self.cache_directory()
        directory.mkdir(parents=True, exist_ok=True)
        record = {
            "schemaVersion": ALIGNED_STT_CACHE_SCHEMA_VERSION,
            "sourceHash": source_hash,
            "model": model,
            "segments": [{"text": text, "start_s": start, "end_s": end} for text, start, end in segments],
        }
        path = wp._aligned_cache_path(directory, source_hash, model)  # noqa: SLF001 - places entries as the pipeline does
        path.write_text(json.dumps(record, separators=(",", ":")), encoding="utf-8")
        return path

    def run_export(self, request=None):
        with redirect_stderr(io.StringIO()) as progress:
            result = wp.run(request or self.request())
        return result, progress.getvalue()

    def test_exports_each_stored_entry_with_canonical_bytes(self):
        self.store("sha256:episode-one", wp.ALIGNED_STT_MODEL,
                   [("first words", 0.0, 1.5), ("second words", 2.0, 3.25)])
        self.store("sha256:episode-two", wp.ALIGNED_STT_MODEL, [("later words", 10.0, 12.5)])
        result, progress = self.run_export()

        self.assertTrue(result["ok"])
        self.assertEqual(result["operation"], "labellerCues")
        self.assertEqual(result["protocolVersion"], 2)
        self.assertEqual(result["exportDirectory"], str(self.export_directory()))
        self.assertEqual(result["skipped"], 0)
        self.assertEqual([entry["sourceHash"] for entry in result["exports"]],
                         ["sha256:episode-one", "sha256:episode-two"])

        expected = {
            "sha256:episode-one": [FakeSegment(0.0, 1.5, "first words"), FakeSegment(2.0, 3.25, "second words")],
            "sha256:episode-two": [FakeSegment(10.0, 12.5, "later words")],
        }
        for entry in result["exports"]:
            cue_bytes, digest = _worker_labeller_cues.serialize_labeller_cues(
                _worker_labeller_cues.build_labeller_cues(expected[entry["sourceHash"]])
            )
            destination = self.export_directory() / f"{sha256(entry['sourceHash'].encode()).hexdigest()}.json"
            self.assertEqual(entry["cuesPath"], str(destination))
            self.assertEqual(destination.read_bytes(), cue_bytes)
            self.assertEqual(entry["cuesDigest"], digest)
            self.assertEqual(entry["cueCount"], len(expected[entry["sourceHash"]]))
        self.assertEqual(result["exports"][0]["lastCueEnd"], 3.25)
        self.assertEqual(result["exports"][1]["lastCueEnd"], 12.5)
        self.assertIn("labeller.cues.export", progress)
        self.assertIn('"1/2"', progress)
        self.assertIn('"2/2"', progress)

    def test_an_entry_for_another_model_is_not_exported(self):
        self.store("sha256:other-model", "detector-v1", [("other model words", 0.0, 1.0)])
        self.store("sha256:current-model", wp.ALIGNED_STT_MODEL, [("current model words", 0.0, 1.0)])
        result, _ = self.run_export()
        self.assertEqual([entry["sourceHash"] for entry in result["exports"]], ["sha256:current-model"])
        self.assertEqual(sorted(path.name for path in self.export_directory().iterdir()),
                         [f"{sha256(b'sha256:current-model').hexdigest()}.json"])

    def test_corrupt_and_out_of_order_entries_are_skipped_and_left_untouched(self):
        directory = self.cache_directory()
        directory.mkdir(parents=True)
        corrupt = directory / "corrupt.json"
        corrupt.write_text("{not json", encoding="utf-8")
        self.store("sha256:shuffled", wp.ALIGNED_STT_MODEL, [("later", 5.0, 6.0), ("earlier", 1.0, 2.0)])
        before = {path.name: path.read_text() for path in directory.iterdir()}

        result, _ = self.run_export()

        self.assertEqual(result["exports"], [])
        self.assertEqual(result["skipped"], 2)
        self.assertEqual({path.name: path.read_text() for path in directory.iterdir()}, before)

    def test_an_entry_without_segments_is_skipped(self):
        self.store("sha256:empty", wp.ALIGNED_STT_MODEL, [])
        result, _ = self.run_export()
        self.assertEqual(result["exports"], [])
        self.assertEqual(result["skipped"], 1)
        self.assertEqual(list(self.export_directory().iterdir()), [])

    def test_the_cache_directory_is_untouched_by_the_export(self):
        self.store("sha256:kept", wp.ALIGNED_STT_MODEL, [("words", 0.0, 1.0)])
        (self.cache_directory() / "corrupt.json").write_text("{not json", encoding="utf-8")
        directory = self.cache_directory()
        before = sorted((path.name, path.stat().st_mtime_ns) for path in directory.iterdir())

        self.run_export()

        after = sorted((path.name, path.stat().st_mtime_ns) for path in directory.iterdir())
        self.assertEqual(after, before)

    def test_leftovers_in_the_export_directory_are_removed(self):
        export_directory = self.export_directory()
        export_directory.mkdir(parents=True)
        (export_directory / "interrupted.json").write_text("[]", encoding="utf-8")
        (export_directory / ".labeller-backfill-partial.tmp").write_text("[]", encoding="utf-8")
        self.store("sha256:kept", wp.ALIGNED_STT_MODEL, [("words", 0.0, 1.0)])

        result, _ = self.run_export()

        self.assertEqual(sorted(path.name for path in export_directory.iterdir()),
                         [f"{sha256(b'sha256:kept').hexdigest()}.json"])
        self.assertEqual(len(result["exports"]), 1)

    def test_a_missing_or_empty_work_dir_is_an_invalid_request(self):
        for request in ({"operation": "labellerCues", "protocolVersion": 2},
                        self.request(workDir=""),
                        self.request(workDir=None)):
            with self.subTest(request=request):
                with redirect_stderr(io.StringIO()):
                    with self.assertRaises(wp.WorkerError) as raised:
                        wp.run(request)
                self.assertEqual(raised.exception.code, "invalid-request")

    def test_a_missing_cache_directory_exports_nothing(self):
        result, _ = self.run_export()
        self.assertEqual(result["exports"], [])
        self.assertEqual(result["skipped"], 0)
        self.assertEqual(result["exportDirectory"], str(self.export_directory()))

    def test_the_shared_labeller_cues_file_is_never_written(self):
        self.store("sha256:kept", wp.ALIGNED_STT_MODEL, [("words", 0.0, 1.0)])
        self.run_export()
        self.assertFalse((self.work / "wilted-pipeline" / "labeller-cues.json").exists())

if __name__ == "__main__":
    unittest.main()
