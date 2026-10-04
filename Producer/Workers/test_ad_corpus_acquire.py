"""Tests for `ad_corpus_acquire`: no output path may reach the owner's library."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import ad_corpus
import ad_corpus_acquire as acquire


class TempRoots(unittest.TestCase):
    """A fake library tree and a fake preparation cache inside a private temp dir."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(os.path.realpath(self._tmp.name))
        self.library = self.base / "Application Support" / "Wilted"
        self.cache = self.library / "media" / "preparation" / "wilted-pipeline" / "aligned-stt-cache"
        self.cache.mkdir(parents=True)
        self.outside = self.base / "elsewhere"
        self.outside.mkdir()
        self.roots = [self.library, self.cache]


class RefusalTests(TempRoots):
    def test_library_and_preparation_cache_paths_are_refused(self):
        for path in (self.library, self.library / "library.sqlite", self.library / "media" / "x.mp3",
                     self.cache, self.cache / "new-entry.json", self.library / "adcorpus-inputs" / "a.json"):
            with self.assertRaises(acquire.RefusedOutputPath, msg=str(path)):
                acquire.check_output_path(path, roots=self.roots)

    def test_the_real_defaults_protect_the_owner_tree(self):
        home = Path(os.path.realpath(Path.home()))
        for path in (home / "Library" / "Application Support" / "Wilted" / "library.sqlite",
                     ad_corpus.DEFAULT_ALIGNED_CACHE / "entry.json",
                     ad_corpus.DEFAULT_AD_CORPUS_INPUTS / "pinned.json"):
            with self.assertRaises(acquire.RefusedOutputPath, msg=str(path)):
                acquire.check_output_path(path)

    def test_parent_traversal_cannot_reach_a_protected_root(self):
        sneaky = self.outside / ".." / "Application Support" / "Wilted" / "media" / "out.json"
        with self.assertRaises(acquire.RefusedOutputPath):
            acquire.check_output_path(sneaky, roots=self.roots)
        dotdot_from_inside = self.library / "media" / ".." / "library.sqlite"
        with self.assertRaises(acquire.RefusedOutputPath):
            acquire.check_output_path(dotdot_from_inside, roots=self.roots)

    def test_a_symlink_into_a_protected_root_is_followed_and_refused(self):
        link = self.outside / "innocent"
        link.symlink_to(self.cache, target_is_directory=True)
        with self.assertRaises(acquire.RefusedOutputPath):
            acquire.check_output_path(link / "entry.json", roots=self.roots)
        deeper = self.outside / "deeper"
        deeper.symlink_to(self.library / "media", target_is_directory=True)
        with self.assertRaises(acquire.RefusedOutputPath):
            acquire.check_output_path(deeper / "preparation" / "not-yet-created" / "x", roots=self.roots)

    def test_a_case_variant_of_a_protected_root_is_refused(self):
        variant = Path(str(self.library).upper()) / "library.sqlite"
        with self.assertRaises(acquire.RefusedOutputPath):
            acquire.check_output_path(variant, roots=self.roots)

    def test_a_sibling_with_a_shared_name_prefix_is_not_refused(self):
        sibling = self.library.parent / "Wilted-other" / "x.json"
        self.assertEqual(acquire.check_output_path(sibling, roots=self.roots), sibling)

    def test_a_scratch_path_is_accepted(self):
        with acquire.scratch_directory(roots=self.roots) as scratch:
            self.assertTrue(scratch.is_dir())
            self.assertEqual(acquire.check_output_path(scratch / "audio.bin", roots=self.roots),
                             Path(os.path.realpath(scratch)) / "audio.bin")
        self.assertEqual(acquire.check_output_path(self.outside / "snapshot", roots=self.roots),
                         self.outside / "snapshot")

    def test_scratch_inside_a_protected_root_is_refused_and_still_removed(self):
        tmp = Path(os.path.realpath(tempfile.gettempdir()))
        created: list[Path] = []
        real_mkdtemp = tempfile.mkdtemp
        with mock.patch.object(acquire.tempfile, "mkdtemp",
                               side_effect=lambda **kw: created.append(Path(real_mkdtemp(**kw))) or created[-1]):
            with self.assertRaises(acquire.RefusedOutputPath):
                with acquire.scratch_directory(roots=[tmp]):
                    self.fail("scratch under a protected root must not be entered")
        self.assertFalse(created[0].exists())


class ScratchLifecycleTests(TempRoots):
    def _scratch_spy(self):
        seen: list[Path] = []
        real = acquire.scratch_directory

        def spy(*args, **kwargs):
            manager = real(*args, **kwargs)

            @acquire.contextlib.contextmanager
            def wrapper():
                with manager as path:
                    seen.append(path)
                    yield path
            return wrapper()
        return seen, spy

    def test_scratch_is_removed_when_the_download_fails(self):
        seen, spy = self._scratch_spy()

        def failing_fetch(url, destination):
            destination.write_bytes(b"partial")
            raise OSError("network down")

        with mock.patch.object(acquire, "scratch_directory", spy), self.assertRaises(OSError):
            acquire.acquire("https://example.invalid/a.mp3", self.outside / "snap",
                            fetch=failing_fetch, roots=self.roots)
        self.assertEqual(len(seen), 1)
        self.assertFalse(seen[0].exists())
        self.assertFalse((self.outside / "snap").exists())

    def test_scratch_is_removed_on_interrupt(self):
        seen, spy = self._scratch_spy()

        def interrupted(url, destination):
            raise KeyboardInterrupt

        with mock.patch.object(acquire, "scratch_directory", spy), self.assertRaises(KeyboardInterrupt):
            acquire.acquire("https://example.invalid/a.mp3", self.outside / "snap",
                            fetch=interrupted, roots=self.roots)
        self.assertFalse(seen[0].exists())

    def test_a_protected_snapshot_directory_is_refused_before_any_download(self):
        fetch = mock.Mock()
        with self.assertRaises(acquire.RefusedOutputPath):
            acquire.acquire("https://example.invalid/a.mp3", self.cache, fetch=fetch, roots=self.roots)
        fetch.assert_not_called()

    def test_success_copies_exactly_one_entry_and_leaves_no_scratch(self):
        seen, spy = self._scratch_spy()
        source_hash = "sha256:" + "ab" * 32

        def fetch(url, destination):
            destination.write_bytes(b"audio")
            return {"sourceHash": source_hash, "byteCount": 5}

        def transcribe(audio, hash_, scratch):
            entry = scratch / "cache" / "entry.json"
            entry.parent.mkdir()
            entry.write_text(json.dumps({"sourceHash": hash_, "segments": [{"text": "x"}]}))
            return {"durationSeconds": 12.5, "segmentCount": 1, "model": "m",
                    "transcriptEndSeconds": 12.0, "entry": entry}

        with mock.patch.object(acquire, "scratch_directory", spy):
            record = acquire.acquire("https://example.invalid/a.mp3", self.outside / "snap",
                                     fetch=fetch, transcribe=transcribe, roots=self.roots)
        self.assertFalse(seen[0].exists())
        self.assertEqual([p.name for p in (self.outside / "snap").iterdir()], ["entry.json"])
        self.assertEqual(record["sourceHash"], source_hash)
        self.assertEqual(record["durationSeconds"], 12.5)
        # The record is hashes and counts only: no transcript text.
        self.assertNotIn('"text"', json.dumps(record))


class FeedTests(unittest.TestCase):
    FEED = b"""<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
      <item><title>Alpha story</title><guid>a</guid><pubDate>Fri, 02 Oct 2026</pubDate>
        <itunes:duration>9:23</itunes:duration><enclosure url="https://example.invalid/a.mp3"/></item>
      <item><title>Beta story</title><guid>b</guid><itunes:duration>421</itunes:duration>
        <enclosure url="https://example.invalid/b.mp3"/></item>
      <item><title>No audio</title></item></channel></rss>"""

    def test_episodes_without_an_enclosure_are_skipped_and_durations_parsed(self):
        episodes = acquire.feed_episodes(self.FEED)
        self.assertEqual([e["title"] for e in episodes], ["Alpha story", "Beta story"])
        self.assertEqual([e["declaredDurationSeconds"] for e in episodes], [563.0, 421.0])

    def test_selection_by_title_and_by_duration(self):
        episodes = acquire.feed_episodes(self.FEED)
        self.assertEqual(acquire.select_episode(episodes, title="beta")["guid"], "b")
        self.assertEqual(acquire.select_episode(episodes, duration_near=563)["guid"], "a")
        with self.assertRaises(LookupError):
            acquire.select_episode(episodes, duration_near=100)


class AdoptCompatibilityTests(TempRoots):
    """The snapshot this module writes is exactly what `ad_corpus.adopt` reads."""

    def _write_entry(self, directory: Path, source_hash: str) -> None:
        from wilted_worker import transcript_sources as ts
        from wilted_worker.constants import ALIGNED_STT_MODEL
        segment = ts.CachedAlignedSegment(text="placeholder", start_s=0.0, end_s=1.0)
        request = {"sourceHash": source_hash, "alignedTranscriptModel": ALIGNED_STT_MODEL,
                   "workDir": str(directory)}
        ts._store_cached_aligned_segments(request, source_hash, ALIGNED_STT_MODEL, [segment])

    def test_adopt_pins_registered_case_hashes_only(self):
        registered, unregistered = "sha256:" + "11" * 32, "sha256:" + "22" * 32
        scratch = self.outside / "scratch"
        self._write_entry(scratch, registered)
        self._write_entry(scratch, unregistered)
        snapshot = self.outside / "snapshot"
        snapshot.mkdir()
        for entry in (scratch / "wilted-pipeline" / "aligned-stt-cache").glob("*.json"):
            (snapshot / entry.name).write_bytes(entry.read_bytes())
        manifest = self.outside / "manifest.json"
        manifest.write_text(json.dumps({"cases": [{"id": "c", "sourceHash": registered}], "gaps": [
            {"id": "g", "sourceHash": unregistered}]}))
        store = self.outside / "store"
        adopted, unsatisfied = ad_corpus.adopt(snapshot, store=store, manifest=manifest)
        self.assertEqual([case for case, _ in adopted], ["c"])
        self.assertEqual(unsatisfied, [])
        # A gap entry's hash is not a case's: adopt() never reads `gaps`.
        self.assertEqual(len(list(store.glob("*.json"))), 1)


if __name__ == "__main__":
    unittest.main()
