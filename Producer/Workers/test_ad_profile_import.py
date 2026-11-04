"""End-to-end tests for the private feed profile catalog importer."""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import ad_profile_import as importer
from wilted_worker import feed_profiles

FIXTURE_PATH = Path(__file__).parent / "tests" / "fixtures" / "feed_profile_v1.json"
FIXTURE = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def envelope(feed_id: str) -> dict[str, str]:
    payload = dict(FIXTURE["validPayload"], feedID=feed_id)
    return feed_profiles.profile_envelope(payload)


def observation(feed_id: str, episode_id: str, source_hash: str) -> dict:
    return dict(FIXTURE["validObservation"], feedID=feed_id, episodeID=episode_id, sourceHash=source_hash)


def make_library(path: Path, rows: list[tuple]) -> None:
    if path.exists():
        path.unlink()
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE ZPODCASTSUBSCRIPTIONRECORD (ZFEEDID TEXT, ZSUBSCRIBEDAT TIMESTAMP, ZENABLED INTEGER)")
        db.executemany("INSERT INTO ZPODCASTSUBSCRIPTIONRECORD VALUES (?, ?, ?)", rows)


def store_record(feed_id: str, epoch: float, *, profile=None, imported=None, observations=None) -> dict:
    return {"feedID": feed_id, "subscriptionEpoch": epoch, "profile": profile,
            "importedProfile": imported, "observations": observations or []}


class ProfileImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wilted-profile-import-")
        self.root = Path(self.tmp.name)
        self.db = self.root / "library.sqlite"
        self.profiles = self.root / "profiles.json"
        self.store = self.root / "ad-placement-profiles.json"

    def tearDown(self):
        self.tmp.cleanup()

    def run_import(self, entries, rows, **kwargs):
        make_library(self.db, rows)
        self.profiles.write_text(json.dumps({"profiles": entries}), encoding="utf-8")
        return importer.import_profiles(self.db, self.profiles, self.store, **kwargs)

    def test_bootstraps_active_and_disabled_unknown_records(self):
        result = self.run_import([envelope("feed1")], [("feed1", 1000.0, 1), ("feed2", 2000.0, 0)])
        self.assertEqual((result["imported"], result["feeds"], result["active"]), (1, 2, 2))
        rows = {row["feedID"]: row for row in json.loads(self.store.read_text())["feeds"]}
        self.assertEqual(rows["feed1"]["importedProfile"], envelope("feed1"))
        self.assertIsNone(rows["feed1"]["profile"])
        self.assertEqual(rows["feed2"]["observations"], [])
        self.assertIsNone(rows["feed2"]["importedProfile"])
        self.assertEqual(rows["feed1"]["subscriptionEpoch"], 978308200.0)

    def test_partial_import_preserves_other_import_and_learning(self):
        make_library(self.db, [("feed1", 1000.0, 1), ("feed2", 2000.0, 1)])
        previous = {
            "schemaVersion": 1,
            "feeds": [
                store_record("feed1", 978308200.0, profile=envelope("feed1"),
                             imported=envelope("feed1"),
                             observations=[observation("feed1", "ep-one", FIXTURE["sourceHash"])]),
                store_record("feed2", 978309200.0, imported=envelope("feed2")),
            ],
        }
        self.store.write_text(json.dumps(previous), encoding="utf-8")
        self.profiles.write_text(json.dumps({"profiles": [envelope("feed1")]}), encoding="utf-8")
        importer.import_profiles(self.db, self.profiles, self.store)
        rows = {row["feedID"]: row for row in json.loads(self.store.read_text())["feeds"]}
        self.assertEqual(rows["feed1"]["profile"], previous["feeds"][0]["profile"])
        self.assertEqual(rows["feed1"]["observations"], previous["feeds"][0]["observations"])
        self.assertEqual(rows["feed2"]["importedProfile"], previous["feeds"][1]["importedProfile"])

    def test_subscription_epoch_exactly_resets_old_generation(self):
        make_library(self.db, [("feed1", 1000.0, 1)])
        self.store.write_text(json.dumps({"schemaVersion": 1, "feeds": [store_record(
            "feed1", 978308200.0, profile=envelope("feed1"), imported=envelope("feed1"),
            observations=[observation("feed1", "ep-one", FIXTURE["sourceHash"])])]}))
        make_library(self.db, [("feed1", 1000.01, 1)])  # less than one second, still a new feed generation
        self.profiles.write_text(json.dumps({"profiles": []}))
        result = importer.import_profiles(self.db, self.profiles, self.store)
        self.assertEqual(result["reset"], 1)
        row = json.loads(self.store.read_text())["feeds"][0]
        self.assertEqual(row["subscriptionEpoch"], 978308200.01)
        self.assertIsNone(row["profile"])
        self.assertIsNone(row["importedProfile"])
        self.assertEqual(row["observations"], [])

    def test_valid_empty_reviewed_profile_and_unknown_profile(self):
        result = self.run_import([envelope("feed1")], [("feed1", 1.0, 1), ("feed2", 2.0, 1)])
        self.assertEqual(result["feeds"], 2)
        self.assertIsNotNone(json.loads(self.store.read_text())["feeds"][0])

    def test_invalid_profile_rejected_before_any_store_change(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        bad = envelope("feed1") | {"digest": "0" * 64}
        self.profiles.write_text(json.dumps({"profiles": [bad]}))
        original = b"keep prior file unchanged"
        self.store.write_bytes(original)
        with self.assertRaises(ValueError):
            importer.import_profiles(self.db, self.profiles, self.store)
        self.assertEqual(self.store.read_bytes(), original)

    def test_rejects_envelope_external_feed_id_and_extra_keys(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        valid = envelope("feed1")
        self.profiles.write_text(json.dumps({"profiles": [valid | {"feedID": "feed1"}]}))
        with self.assertRaises(ValueError):
            importer.import_profiles(self.db, self.profiles, self.store)
        self.profiles.write_text(json.dumps({"profiles": [valid], "extra": []}))
        with self.assertRaises(ValueError):
            importer.import_profiles(self.db, self.profiles, self.store)

    def test_rejects_unsubscribed_and_duplicate_import(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        for rows in ([envelope("ghost")], [envelope("feed1"), envelope("feed1")]):
            self.profiles.write_text(json.dumps({"profiles": rows}))
            with self.assertRaises(ValueError):
                importer.import_profiles(self.db, self.profiles, self.store)
        self.assertFalse(self.store.exists())

    def test_profile_revision_must_fit_swift_integer(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        payload = dict(FIXTURE["validPayload"], feedID="feed1", revision=2**63)
        self.profiles.write_text(json.dumps({"profiles": [feed_profiles.profile_envelope(payload)]}))
        with self.assertRaises(ValueError):
            importer.import_profiles(self.db, self.profiles, self.store)

    def test_rejects_invalid_database_identity_epoch_and_duplicates(self):
        invalid_rows = [
            [(None, 1.0, 1)], [("bad id", 1.0, 1)], [("feed1", None, 1)],
            [("feed1", float("inf"), 1)], [("feed1", 1.0, 1), ("feed1", 2.0, 1)],
        ]
        for rows in invalid_rows:
            make_library(self.db, rows)
            with self.assertRaises(ValueError):
                importer.read_subscriptions(self.db)

    def test_corrupt_store_is_never_overwritten(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        self.profiles.write_text(json.dumps({"profiles": []}))
        self.store.write_text("corrupt")
        with self.assertRaises(ValueError):
            importer.import_profiles(self.db, self.profiles, self.store)
        self.assertEqual(self.store.read_text(), "corrupt")

    def test_duplicate_json_keys_and_bool_epoch_rejected(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        self.profiles.write_text('{"profiles":[],"profiles":[]}')
        with self.assertRaises(ValueError):
            importer.import_profiles(self.db, self.profiles, self.store)
        self.store.write_text(json.dumps({"schemaVersion": 1, "feeds": [store_record("feed1", True)]}))
        with self.assertRaises(ValueError):
            importer.load_store(self.store)

    def test_store_rejects_duplicate_episode_or_source_observation(self):
        row = observation("feed1", "ep-one", FIXTURE["sourceHash"])
        document = {"schemaVersion": 1, "feeds": [store_record(
            "feed1", 1.0, observations=[row, row]) ]}
        self.store.write_text(json.dumps(document))
        with self.assertRaises(ValueError):
            importer.load_store(self.store)

    def test_store_reconciliation_prunes_only_removed_feeds(self):
        subs = {"feed1": 1.0, "feed2": 2.0}
        prior = {"schemaVersion": 1, "feeds": [
            store_record("feed1", 1.0, imported=envelope("feed1")),
            store_record("removed", 3.0, imported=envelope("removed")),
        ]}
        data, stats = importer.reconcile(subs, prior, {})
        self.assertEqual(stats["removed"], 1)
        self.assertEqual([x["feedID"] for x in data["feeds"]], ["feed1", "feed2"])
        self.assertEqual(data["feeds"][0]["importedProfile"], envelope("feed1"))
        self.assertIsNone(data["feeds"][1]["importedProfile"])

    def test_rejects_symlink_inputs_store_and_lock(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        self.profiles.write_text(json.dumps({"profiles": []}))
        for name, target in (("lib-link", self.db), ("profiles-link", self.profiles)):
            link = self.root / name
            link.symlink_to(target)
            with self.assertRaises((OSError, ValueError)):
                importer.import_profiles(link if name == "lib-link" else self.db,
                                         link if name == "profiles-link" else self.profiles, self.store)
            link.unlink()
        self.store.symlink_to(self.root / "target")
        with self.assertRaises((OSError, ValueError)):
            importer.import_profiles(self.db, self.profiles, self.store)
        self.store.unlink()
        lock = self.root / "ad-placement-profiles.json.lock"
        lock.symlink_to(self.root / "target")
        with self.assertRaises((OSError, ValueError)):
            importer.import_profiles(self.db, self.profiles, self.store)

    def test_lock_timeout_is_bounded_and_does_not_write(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        self.profiles.write_text(json.dumps({"profiles": []}))
        lock = self.root / "ad-placement-profiles.json.lock"
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            with self.assertRaises(TimeoutError):
                importer.import_profiles(self.db, self.profiles, self.store, lock_timeout=0.01)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        self.assertFalse(self.store.exists())

    def test_dry_run_has_no_filesystem_writes(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        self.profiles.write_text(json.dumps({"profiles": [envelope("feed1")]}))
        result = importer.import_profiles(self.db, self.profiles, self.store, dry_run=True)
        self.assertEqual(result["imported"], 1)
        self.assertFalse(self.store.exists())
        self.assertFalse((self.root / "ad-placement-profiles.json.lock").exists())

    def test_failed_atomic_replace_preserves_store_and_cleans_temp(self):
        make_library(self.db, [("feed1", 1.0, 1)])
        self.profiles.write_text(json.dumps({"profiles": []}))
        original = b'{"schemaVersion":1,"feeds":[]}'
        self.store.write_bytes(original)
        with patch.object(importer.os, "replace", side_effect=OSError("simulated")):
            with self.assertRaises(OSError):
                importer.import_profiles(self.db, self.profiles, self.store)
        self.assertEqual(self.store.read_bytes(), original)
        self.assertEqual(list(self.root.glob(".ad-placement-profiles.json.*.tmp")), [])

    def test_bad_lock_timeouts_rejected(self):
        for value in (-1, float("nan"), float("inf"), 60.01):
            with self.assertRaises(ValueError):
                importer.import_profiles(self.db, self.profiles, self.store, lock_timeout=value)


if __name__ == "__main__":
    unittest.main()
