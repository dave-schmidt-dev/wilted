"""Unit tests for wilted_worker.feed_profiles pure schema validators."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest

_WORKERS_DIR = str(Path(__file__).resolve().parent)
if _WORKERS_DIR not in sys.path:
    sys.path.insert(0, _WORKERS_DIR)

from wilted_worker import feed_profiles


class FeedProfilesTests(unittest.TestCase):
    """Test suite for feed profile envelopes, payloads, observations, and strict constraints."""

    @classmethod
    def setUpClass(cls) -> None:
        fixture_path = Path(__file__).parent / "tests" / "fixtures" / "feed_profile_v1.json"
        with fixture_path.open("r", encoding="utf-8") as f:
            cls.fixture = json.load(f)

    def test_shared_fixture_valid_profile(self) -> None:
        """Shared synthetic fixture envelope validates cleanly for its feedID."""
        envelope = self.fixture["validEnvelope"]
        feed_id = self.fixture["feedID"]
        payload = feed_profiles.validate_profile(envelope, feed_id)
        self.assertIsNotNone(payload)
        self.assertEqual(payload, self.fixture["validPayload"])

    def test_profile_envelope_constructor(self) -> None:
        """profile_envelope constructs matching payload string and lowercase sha256 digest."""
        payload_dict = self.fixture["validPayload"]
        constructed = feed_profiles.profile_envelope(payload_dict)
        self.assertIn("payload", constructed)
        self.assertIn("digest", constructed)
        self.assertEqual(len(constructed["digest"]), 64)
        self.assertTrue(constructed["digest"].islower())
        computed = hashlib.sha256(constructed["payload"].encode("utf-8")).hexdigest()
        self.assertEqual(constructed["digest"], computed)

        # Roundtrip validation
        validated = feed_profiles.validate_profile(constructed, self.fixture["feedID"])
        self.assertEqual(validated, payload_dict)

    def test_shared_fixture_valid_observation(self) -> None:
        """Shared synthetic fixture observation validates cleanly."""
        obs = self.fixture["validObservation"]
        validated = feed_profiles.validate_observation(
            obs,
            self.fixture["feedID"],
            self.fixture["episodeID"],
            self.fixture["sourceHash"],
        )
        self.assertIsNotNone(validated)
        self.assertEqual(validated, obs)

    def test_observation_as_json_string(self) -> None:
        """Observation passed as a JSON string also validates successfully."""
        obs_str = json.dumps(self.fixture["validObservation"])
        validated = feed_profiles.validate_observation(
            obs_str,
            self.fixture["feedID"],
            self.fixture["episodeID"],
            self.fixture["sourceHash"],
        )
        self.assertIsNotNone(validated)
        self.assertEqual(validated, self.fixture["validObservation"])

    def test_empty_slots_valid_unknown_observation(self) -> None:
        """Empty slots array is valid for an unknown observation."""
        obs = self.fixture["validEmptySlotsObservation"]
        validated = feed_profiles.validate_observation(
            obs,
            self.fixture["feedID"],
            self.fixture["episodeID"],
            self.fixture["sourceHash"],
        )
        self.assertIsNotNone(validated)
        self.assertEqual(validated["slots"], [])

    # Schema & unknown field tests

    def test_unknown_fields_in_envelope_rejected(self) -> None:
        """Extra unknown fields in envelope are rejected."""
        envelope = dict(self.fixture["validEnvelope"])
        envelope["extraField"] = "unknown"
        self.assertIsNone(feed_profiles.validate_profile(envelope, self.fixture["feedID"]))

    def test_missing_fields_in_envelope_rejected(self) -> None:
        """Missing required fields in envelope are rejected."""
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": "{}"}, self.fixture["feedID"])
        )
        self.assertIsNone(
            feed_profiles.validate_profile({"digest": "abc"}, self.fixture["feedID"])
        )

    def test_unknown_fields_in_payload_rejected(self) -> None:
        """Unknown fields in payload dictionary are rejected."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["unknownKey"] = 123
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # In envelope payload string
        serialized = json.dumps(payload)
        digest = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": serialized, "digest": digest}, self.fixture["feedID"])
        )

    def test_unknown_fields_in_slot_rejected(self) -> None:
        """Unknown fields inside a slot are rejected."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["extraSlotField"] = True
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_unknown_fields_in_observation_rejected(self) -> None:
        """Unknown fields in observation (including sampleCount/revision) are rejected."""
        obs = copy.deepcopy(self.fixture["validObservation"])
        obs["sampleCount"] = 5
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs, self.fixture["feedID"], self.fixture["episodeID"], self.fixture["sourceHash"]
            )
        )
        obs2 = copy.deepcopy(self.fixture["validObservation"])
        obs2["revision"] = 1
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs2, self.fixture["feedID"], self.fixture["episodeID"], self.fixture["sourceHash"]
            )
        )
        obs3 = copy.deepcopy(self.fixture["validObservation"])
        obs3["unexpectedField"] = "foo"
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs3, self.fixture["feedID"], self.fixture["episodeID"], self.fixture["sourceHash"]
            )
        )

    # Type tests: bool not integer, floats, strings

    def test_bool_not_integer_in_payload_schema_version(self) -> None:
        """schemaVersion cannot be a boolean."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["schemaVersion"] = True
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_bool_not_integer_in_payload_revision(self) -> None:
        """revision cannot be a boolean."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["revision"] = True
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_bool_not_integer_in_payload_sample_count(self) -> None:
        """sampleCount cannot be a boolean."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["sampleCount"] = True
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_bool_not_integer_in_slot_basis_points(self) -> None:
        """Basis points cannot be booleans."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["startBasisPoints"] = False
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        payload2 = copy.deepcopy(self.fixture["validPayload"])
        payload2["slots"][0]["endBasisPoints"] = True
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload2)

    def test_bool_not_integer_in_observation_schema_version(self) -> None:
        """schemaVersion in observation cannot be a boolean."""
        obs = copy.deepcopy(self.fixture["validObservation"])
        obs["schemaVersion"] = True
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs, self.fixture["feedID"], self.fixture["episodeID"], self.fixture["sourceHash"]
            )
        )

    def test_floats_and_strings_in_int_fields_rejected(self) -> None:
        """Floats and numeric strings are rejected in integer fields."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["revision"] = 1.0
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        payload2 = copy.deepcopy(self.fixture["validPayload"])
        payload2["sampleCount"] = "5"
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload2)

        payload3 = copy.deepcopy(self.fixture["validPayload"])
        payload3["slots"][0]["startBasisPoints"] = 0.0
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload3)

    # Finite bounded data tests

    def test_feed_id_bounds(self) -> None:
        """feedID must be between 1 and 256 characters."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["feedID"] = ""
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        payload["feedID"] = "a" * 256
        envelope = feed_profiles.profile_envelope(payload)
        self.assertIsNotNone(feed_profiles.validate_profile(envelope, "a" * 256))

        payload["feedID"] = "a" * 257
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_revision_bounds(self) -> None:
        """revision must be integer >= 1."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["revision"] = 0
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)
        payload["revision"] = -1
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_sample_count_bounds(self) -> None:
        """sampleCount must be 1..20."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["sampleCount"] = 0
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        payload["sampleCount"] = 1
        self.assertIsNotNone(feed_profiles.profile_envelope(payload))

        payload["sampleCount"] = 20
        self.assertIsNotNone(feed_profiles.profile_envelope(payload))

        payload["sampleCount"] = 21
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_slots_maximum_12(self) -> None:
        """slots array can have at most 12 items."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        slot_template = payload["slots"][0]
        # 12 slots is valid
        payload["slots"] = [copy.deepcopy(slot_template) for _ in range(12)]
        self.assertIsNotNone(feed_profiles.profile_envelope(payload))

        # 13 slots is rejected
        payload["slots"] = [copy.deepcopy(slot_template) for _ in range(13)]
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_slot_positions(self) -> None:
        """Slot position must be strictly 'pre', 'mid', or 'post'."""
        for invalid_pos in ("preroll", "midroll", "postroll", "PRE", "start", "", "other"):
            payload = copy.deepcopy(self.fixture["validPayload"])
            payload["slots"][0]["position"] = invalid_pos
            with self.assertRaises(ValueError):
                feed_profiles.profile_envelope(payload)

    def test_basis_points_bounds_and_ordering(self) -> None:
        """Basis points must be in 0..10000 and start < end."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        # start < 0
        payload["slots"][0]["startBasisPoints"] = -1
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # end > 10000
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["endBasisPoints"] = 10001
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # start == end
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["startBasisPoints"] = 500
        payload["slots"][0]["endBasisPoints"] = 500
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # start > end
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["startBasisPoints"] = 600
        payload["slots"][0]["endBasisPoints"] = 500
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    def test_phrases_bounds_and_limits(self) -> None:
        """Phrases list max 8, phrase string non-empty and <= 120 chars."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        # 8 phrases is valid
        payload["slots"][0]["entryPhrases"] = [f"phrase {i}" for i in range(8)]
        self.assertIsNotNone(feed_profiles.profile_envelope(payload))

        # 9 phrases is rejected
        payload["slots"][0]["entryPhrases"] = [f"phrase {i}" for i in range(9)]
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # phrase length 120 is valid
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["entryPhrases"] = ["a" * 120]
        self.assertIsNotNone(feed_profiles.profile_envelope(payload))

        # phrase length 121 is rejected
        payload["slots"][0]["entryPhrases"] = ["a" * 121]
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # empty phrase is rejected
        payload["slots"][0]["entryPhrases"] = [""]
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        # whitespace only is rejected
        payload["slots"][0]["entryPhrases"] = ["   "]
        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

    # Literal marker data: no addresses or control characters

    def test_literal_phrase_disallowed_content(self) -> None:
        """Disallowed content in phrases is rejected."""
        disallowed = [
            "visit https://example.com for 20% off",
            "http://sponsor.org",
            "go to www.brand.com",
            "bad\tmarker",
            "bad\x00marker",
            "bad\ud800marker",
            "multi\nline phrase",
            "multi\rline phrase",
        ]
        for phrase in disallowed:
            payload = copy.deepcopy(self.fixture["validPayload"])
            payload["slots"][0]["entryPhrases"] = [phrase]
            with self.assertRaises(ValueError, msg=f"Should reject phrase: {phrase!r}"):
                feed_profiles.profile_envelope(payload)

    def test_semantic_marker_words_remain_literal_data(self):
        payload = copy.deepcopy(self.fixture["validPayload"])
        payload["slots"][0]["entryPhrases"] = ["terms of service apply", "Episode 42", "literal .* marker"]
        self.assertIsNotNone(feed_profiles.profile_envelope(payload))

    def test_invalid_unicode_envelope_returns_none(self):
        self.assertIsNone(feed_profiles.validate_profile(
            {"payload": "\ud800", "digest": "0" * 64}, self.fixture["feedID"]))
        self.assertIsNone(feed_profiles.validate_observation(
            "\ud800", self.fixture["feedID"], self.fixture["episodeID"], self.fixture["sourceHash"]))

    # UTF8 byte limit tests (<= 8192 bytes)

    def test_utf8_byte_limit_envelope_and_payload(self) -> None:
        """Payload exceeding 8192 UTF-8 bytes is rejected."""
        payload = copy.deepcopy(self.fixture["validPayload"])
        # Fill slots and phrases with long valid text until exceeding 8192 bytes
        payload["slots"] = [
            {
                "position": "mid",
                "startBasisPoints": i * 800,
                "endBasisPoints": i * 800 + 400,
                "entryPhrases": ["Valid long literal phrase for slot testing " + "x" * 60] * 8,
                "returnPhrases": ["Valid long return phrase for slot testing " + "y" * 60] * 8,
            }
            for i in range(12)
        ]
        serialized = json.dumps(payload)
        self.assertGreater(len(serialized.encode("utf-8")), 8192)

        with self.assertRaises(ValueError):
            feed_profiles.profile_envelope(payload)

        digest = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": serialized, "digest": digest}, self.fixture["feedID"])
        )

    # Digest tests: lowercase sha256 hex without prefix

    def test_digest_validation(self) -> None:
        """Digest must be exact matching 64 lowercase hex characters."""
        envelope = dict(self.fixture["validEnvelope"])

        # Mismatched digest
        bad_digest = "0" * 64
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": envelope["payload"], "digest": bad_digest}, self.fixture["feedID"])
        )

        # Uppercase hex rejected
        upper_digest = envelope["digest"].upper()
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": envelope["payload"], "digest": upper_digest}, self.fixture["feedID"])
        )

        # Prefixed digest rejected
        prefixed = f"sha256:{envelope['digest']}"
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": envelope["payload"], "digest": prefixed}, self.fixture["feedID"])
        )

        # Short digest rejected
        self.assertIsNone(
            feed_profiles.validate_profile({"payload": envelope["payload"], "digest": envelope["digest"][:63]}, self.fixture["feedID"])
        )

    # Identity mismatch tests

    def test_identity_mismatch_profile(self) -> None:
        """Profile feedID mismatch returns None."""
        envelope = self.fixture["validEnvelope"]
        self.assertIsNone(feed_profiles.validate_profile(envelope, "different-feed-id"))

    def test_identity_mismatch_observation(self) -> None:
        """Observation identity mismatches return None."""
        obs = self.fixture["validObservation"]
        # Mismatched feedID
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs, "wrong-feed", self.fixture["episodeID"], self.fixture["sourceHash"]
            )
        )
        # Mismatched episodeID
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs, self.fixture["feedID"], "wrong-ep", self.fixture["sourceHash"]
            )
        )
        # Mismatched sourceHash
        self.assertIsNone(
            feed_profiles.validate_observation(
                obs, self.fixture["feedID"], self.fixture["episodeID"], "f" * 64
            )
        )


if __name__ == "__main__":
    unittest.main()
