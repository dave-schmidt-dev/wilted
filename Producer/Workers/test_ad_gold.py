"""Tests for the ad gold set's fetch, label-snapping and finish steps."""

from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

import ad_gold_fetch as fetch
import ad_gold_finish as finish
import ad_gold_label as label
import ad_gold_recover as recover


@dataclass
class Token:
    text: str
    start_s: float
    end_s: float


@dataclass
class Segment:
    text: str
    start_s: float
    end_s: float
    tokens: tuple | None = None


WORDS = [
    [0.0, 0.4, "This"],
    [0.4, 0.8, "episode"],
    [0.8, 1.0, "is"],
    [1.0, 1.4, "brought"],
    [1.4, 1.6, "to"],
    [1.6, 1.8, "you"],
    [1.8, 2.0, "by"],
    [2.0, 2.6, "Acme."],
    [2.6, 3.0, "Visit"],
    [3.0, 6.0, "acme.com."],
    [6.0, 6.4, "Welcome"],
    [6.4, 6.8, "back"],
    [6.8, 7.2, "to"],
    [7.2, 7.6, "the"],
    [7.6, 8.0, "show."],
]


class FetchTests(unittest.TestCase):
    def test_slug_is_lowercase_hyphenated_ascii(self):
        self.assertEqual(
            fetch.slug("Wait Wait... Don't Tell Me!"), "wait-wait-dont-tell-me"
        )
        self.assertEqual(fetch.slug("99% Invisible"), "99-invisible")

    def test_audio_extension_prefers_the_path_then_the_media_type(self):
        self.assertEqual(
            fetch.audio_extension("https://x/ep.M4A?id=1", "audio/mpeg"), "m4a"
        )
        self.assertEqual(
            fetch.audio_extension("https://x/redirect", "audio/x-m4a"), "m4a"
        )
        self.assertEqual(fetch.audio_extension("https://x/redirect", None), "mp3")

    def test_words_join_continuation_tokens_and_spread_untokenized_text(self):
        tokened = Segment(
            "Hello there",
            0.0,
            1.0,
            (Token(" Hel", 0.0, 0.2), Token("lo", 0.2, 0.4), Token(" there", 0.5, 1.0)),
        )
        plain = Segment("two words", 2.0, 3.0)
        self.assertEqual(
            fetch.words_from_segments([tokened, plain]),
            [
                [0.0, 0.4, "Hello"],
                [0.5, 1.0, "there"],
                [2.0, 2.5, "two"],
                [2.5, 3.0, "words"],
            ],
        )

    def test_latest_episodes_picks_the_newest_long_episode_of_enabled_feeds(self):
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / "library.sqlite"
            with sqlite3.connect(library) as connection:
                connection.executescript("""
                    create table ZPODCASTSUBSCRIPTIONRECORD (ZENABLED, ZFEEDID, ZDISPLAYNAME);
                    create table ZPODCASTFEEDRECORD (ZID, ZTITLE);
                    create table ZPODCASTEPISODERECORD (ZFEEDID, ZID, ZTITLE, ZDURATIONSECONDS, ZENCLOSUREURL,
                                                        ZENCLOSUREMEDIATYPE, ZPUBLISHEDTIME);
                    insert into ZPODCASTSUBSCRIPTIONRECORD values (1, 'f1', null), (0, 'f2', 'Off');
                    insert into ZPODCASTFEEDRECORD values ('f1', 'Show One'), ('f2', 'Show Two');
                    insert into ZPODCASTEPISODERECORD values
                      ('f1', 'old', 'Old', 3600, 'https://x/old.mp3', 'audio/mpeg', 100),
                      ('f1', 'short', 'Trailer', 60, 'https://x/short.mp3', 'audio/mpeg', 300),
                      ('f1', 'new', 'New', 1800, 'https://x/new.mp3', 'audio/mpeg', 200),
                      ('f2', 'off', 'Off', 1800, 'https://x/off.mp3', 'audio/mpeg', 200);
                """)
            episodes = fetch.latest_episodes(library)
        self.assertEqual(
            [(e["slug"], e["episodeID"]) for e in episodes], [("show-one", "new")]
        )


class LabelTests(unittest.TestCase):
    def raw(self, **overrides):
        item = {
            "start_s": 0.0,
            "end_s": 2.6,
            "first_words": "This episode is brought",
            "last_words": "Visit acme.com.",
            "kind": "sponsor",
            "label": "must-cut",
            "confidence": "high",
            "sponsor": "Acme",
            "note": "",
        }
        return {**item, **overrides}

    def test_edges_snap_to_the_quoted_words_and_trim_a_stretched_last_word(self):
        snapped = label.snap_range(self.raw(), WORDS, 1)
        self.assertEqual((snapped["start_s"], snapped["end_s"]), (0.0, 4.2))
        self.assertEqual(snapped["confidence"], "high")

    def test_unfound_words_keep_the_time_at_a_word_boundary_and_are_flagged(self):
        snapped = label.snap_range(
            self.raw(start_s=0.5, last_words="nothing like this"), WORDS, 1
        )
        self.assertEqual(snapped["start_s"], 0.0)
        self.assertEqual(snapped["end_s"], 2.6)
        self.assertEqual(snapped["confidence"], "low")
        self.assertIn("[check end", snapped["note"])

    def test_gaps_list_untranscribed_stretches_including_the_ends(self):
        words = [[10.0, 10.5, "a"], [10.5, 30.0, "stretched"], [40.0, 40.4, "b"]]
        self.assertEqual(label.untranscribed_gaps(words, 60.0), [[0.0, 10.0], [11.7, 40.0], [40.4, 60.0]])

    def test_review_lists_long_gaps_and_gaps_beside_a_break(self):
        gaps = [[0.0, 10.0], [105.0, 115.0], [200.0, 230.0]]
        ranges = [{"start_s": 40.0, "end_s": 70.0}]
        self.assertEqual(label.review_gaps(gaps, ranges), [[0.0, 10.0], [200.0, 230.0]])

    def test_bad_enum_is_rejected(self):
        with self.assertRaises(label.LabelError):
            label.snap_range(self.raw(kind="banner"), WORDS, 1)

    def test_snap_show_writes_sorted_labels(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "transcript.json").write_text(json.dumps({"words": WORDS}))
            later = self.raw(
                start_s=6.0,
                end_s=8.0,
                first_words="Welcome back",
                last_words="the show.",
                kind="outro",
                label="acceptable-cut",
            )
            (folder / "labels.opus.raw.json").write_text(
                json.dumps({"pattern": " p ", "ranges": [later, self.raw()]})
            )
            labels = label.snap_show(folder)
            self.assertEqual(
                json.loads((folder / "labels.opus.json").read_text()), labels
            )
        self.assertEqual(labels["pattern"], "p")
        self.assertEqual(
            [item["kind"] for item in labels["ranges"]], ["sponsor", "outro"]
        )


class FinishTests(unittest.TestCase):
    def test_windows_pad_merge_and_skip_rejected_ranges(self):
        ranges = [
            {"start_s": 10, "end_s": 40, "label": "must-cut"},
            {"start_s": 100, "end_s": 130, "label": "must-cut"},
            {"start_s": 900, "end_s": 930, "label": "not-ad"},
            {"start_s": 1000, "end_s": 1020, "label": "acceptable-cut"},
        ]
        self.assertEqual(
            finish.clip_windows(ranges, 1050, padding=60),
            [(0.0, 190.0), (940.0, 1050.0)],
        )

    def test_only_a_confirmed_show_with_nothing_pending_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            review = {
                "status": "confirmed",
                "ranges": [{"decision": "confirmed"}, {"decision": "pending"}],
            }
            (folder / "review.json").write_text(json.dumps(review))
            self.assertIsNone(finish.confirmed_review(folder))
            review["ranges"][1]["decision"] = "confirmed"
            (folder / "review.json").write_text(json.dumps(review))
            self.assertIsNotNone(finish.confirmed_review(folder))

    def test_apply_clips_trashes_the_download_and_exports_labels_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root, trash = Path(directory) / "gold", Path(directory) / "Trash"
            folder = root / "show-one"
            folder.mkdir(parents=True)
            trash.mkdir()
            (folder / "audio.mp3").write_bytes(b"audio")
            (folder / "episode.json").write_text(
                json.dumps(
                    {
                        "show": "Show One",
                        "episodeID": "e1",
                        "audioFile": "audio.mp3",
                        "audioSha256": "ab",
                        "durationSeconds": 600.0,
                    }
                )
            )
            (folder / "review.json").write_text(
                json.dumps(
                    {
                        "status": "confirmed",
                        "pattern": "pre-roll",
                        "ranges": [
                            {
                                "start_s": 0.0,
                                "end_s": 30.0,
                                "kind": "sponsor",
                                "label": "must-cut",
                                "decision": "confirmed",
                                "origin": "opus",
                                "opus": {"note": "transcript words"},
                            }
                        ],
                    }
                )
            )
            export = Path(directory) / "gold.json"
            with (
                mock.patch.object(finish, "TRASH", trash),
                mock.patch.object(
                    finish, "cut_clips", return_value=[{"file": "clip-01.opus"}]
                ) as cut,
            ):
                finish.main(["--root", str(root), "--export", str(export), "--apply"])
            self.assertEqual(cut.call_args.args[2], [(0.0, 150.0)])
            self.assertFalse((folder / "audio.mp3").exists())
            self.assertTrue((trash / "wilted-gold-show-one-audio.mp3").exists())
            shows = json.loads(export.read_text())["shows"]
        self.assertEqual(shows[0]["audioSha256"], "sha256:ab")
        self.assertEqual(
            shows[0]["ranges"],
            [
                {
                    "start_s": 0.0,
                    "end_s": 30.0,
                    "kind": "sponsor",
                    "label": "must-cut",
                    "origin": "opus",
                }
            ],
        )
        self.assertNotIn("transcript words", json.dumps(shows))


class RecoverTests(unittest.TestCase):
    PREVIOUS = [[0.0, 0.5, "a"], [40.0, 40.5, "b"]]
    RECOVERED = ["This", "episode", "is", "brought", "to", "you"]
    NOW = PREVIOUS[:1] + [[10.0 + i, 10.5 + i, w] for i, w in enumerate(RECOVERED)] + PREVIOUS[1:]

    def test_stretches_are_new_words_inside_old_gaps(self):
        self.assertEqual(recover.recovered_stretches(self.PREVIOUS, self.NOW, 41.0), [[10.0, 15.5]])
        self.assertEqual(recover.recovered_stretches(self.PREVIOUS, self.PREVIOUS, 41.0), [])

    def test_merge_adds_pending_ranges_and_reopens_a_confirmed_show(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "transcript.json").write_text(json.dumps({"words": self.NOW}))
            (folder / "episode.json").write_text(json.dumps({"durationSeconds": 41.0}))
            kept = {"id": "r1", "start_s": 40.0, "end_s": 40.5, "kind": "outro", "label": "acceptable-cut"}
            (folder / "labels.opus.json").write_text(json.dumps({"pattern": "p", "ranges": [kept], "gaps": []}))
            decided = {**kept, "decision": "confirmed", "origin": "opus", "opus": kept}
            (folder / "review.json").write_text(json.dumps({"version": 1, "status": "confirmed", "ranges": [decided]}))
            item = {"start_s": 10.0, "end_s": 15.0, "first_words": "This episode is", "last_words": "to you",
                    "kind": "sponsor", "label": "must-cut", "confidence": "high", "sponsor": None, "note": ""}
            (folder / "labels.recovered.raw.json").write_text(json.dumps({"ranges": [item, item]}))
            self.assertEqual(recover.merge_show(folder), 1)
            review = json.loads((folder / "review.json").read_text())
            labels = json.loads((folder / "labels.opus.json").read_text())
        self.assertEqual(review["status"], "in-progress")
        self.assertEqual([(r["id"], r["decision"]) for r in review["ranges"]], [("x1", "pending"), ("r1", "confirmed")])
        self.assertEqual((review["ranges"][0]["start_s"], review["ranges"][0]["end_s"]), (10.0, 15.5))
        self.assertEqual([r["id"] for r in labels["ranges"]], ["x1", "r1"])
        self.assertEqual(labels["gaps"], [[0.5, 10.0], [15.5, 40.0]])


if __name__ == "__main__":
    unittest.main()
