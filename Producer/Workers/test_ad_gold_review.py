"""Unit tests for ad_gold_review HTTP server and endpoints."""

from __future__ import annotations

import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
import wave

try:
    from ad_gold_review import (
        AdGoldReviewHandler,
        GoldReviewServer,
    )
except ImportError:
    from Producer.Workers.ad_gold_review import (
        AdGoldReviewHandler,
        GoldReviewServer,
    )


def create_dummy_wav(path: Path, duration_s: float = 20.0, sample_rate: int = 16000) -> bytes:
    """Generate a valid mono 16-bit PCM WAV file."""
    frames = int(duration_s * sample_rate)
    data = b"\x00\x00" * frames
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(data)
    return path.read_bytes()


class TestAdGoldReview(unittest.TestCase):
    """Test suite covering ad gold review server endpoints and security rules."""

    def setUp(self) -> None:
        """Create temporary test fixtures and launch server thread."""
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)

        # Show A: has labels, unreviewed, 1 low confidence
        self.show_a = self.root / "show-a"
        self.show_a.mkdir()
        (self.show_a / "episode.json").write_text(
            json.dumps({
                "show": "Show A",
                "slug": "show-a",
                "title": "Episode A",
                "audioFile": "audio.wav",
                "durationSeconds": 20.0,
            }),
            "utf-8",
        )
        self.wav_bytes = create_dummy_wav(self.show_a / "audio.wav", duration_s=20.0)
        (self.show_a / "labels.opus.json").write_text(
            json.dumps({
                "pattern": "sponsor at 5s",
                "ranges": [{
                    "id": "r1",
                    "start_s": 5.0,
                    "end_s": 10.0,
                    "kind": "sponsor",
                    "label": "must-cut",
                    "confidence": "low",
                    "sponsor": "Acme",
                    "note": "Opus note",
                }],
                "gaps": [[11.0, 20.0]],
            }),
            "utf-8",
        )
        (self.show_a / "transcript.json").write_text(
            json.dumps({
                "model": "test",
                "segments": [{"start_s": 0.0, "end_s": 20.0, "text": "hello test"}],
                "words": [
                    [4.0, 5.0, "hello"],
                    [5.0, 6.0, "sponsor"],
                    [9.0, 10.0, "thanks"],
                    [10.0, 11.0, "all"],
                ],
            }),
            "utf-8",
        )

        # Show B: awaiting labels
        self.show_b = self.root / "show-b"
        self.show_b.mkdir()
        (self.show_b / "episode.json").write_text(
            json.dumps({
                "show": "Show B",
                "slug": "show-b",
                "title": "Episode B",
                "audioFile": "audio.wav",
                "durationSeconds": 20.0,
            }),
            "utf-8",
        )
        create_dummy_wav(self.show_b / "audio.wav", duration_s=20.0)

        # Show C: has labels & confirmed review, 0 low confidence
        self.show_c = self.root / "show-c"
        self.show_c.mkdir()
        (self.show_c / "episode.json").write_text(
            json.dumps({
                "show": "Show C",
                "slug": "show-c",
                "title": "Episode C",
                "audioFile": "audio.wav",
                "durationSeconds": 20.0,
            }),
            "utf-8",
        )
        create_dummy_wav(self.show_c / "audio.wav", duration_s=20.0)
        (self.show_c / "labels.opus.json").write_text(
            json.dumps({
                "pattern": "",
                "ranges": [{
                    "id": "r2",
                    "start_s": 1.0,
                    "end_s": 4.0,
                    "kind": "intro",
                    "label": "acceptable-cut",
                    "confidence": "high",
                    "sponsor": None,
                    "note": "",
                }],
            }),
            "utf-8",
        )
        (self.show_c / "review.json").write_text(
            json.dumps({
                "version": 1,
                "pattern": "",
                "status": "confirmed",
                "ranges": [{
                    "id": "r2",
                    "start_s": 1.0,
                    "end_s": 4.0,
                    "kind": "intro",
                    "label": "acceptable-cut",
                    "decision": "confirmed",
                    "origin": "opus",
                    "opus": {},
                }],
                "updatedAt": "2026-01-01T00:00:00Z",
            }),
            "utf-8",
        )

        self.server = GoldReviewServer(("127.0.0.1", 0), AdGoldReviewHandler, self.root)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def tearDown(self) -> None:
        """Shutdown server and clean up temporary directory."""
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2.0)
        self.temp_dir.cleanup()

    def _conn(self) -> http.client.HTTPConnection:
        return http.client.HTTPConnection("127.0.0.1", self.port)

    def test_show_list_sort_and_counts(self) -> None:
        """Verify show sorting order and metadata counts."""
        conn = self._conn()
        conn.request("GET", "/api/shows")
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        shows = json.loads(resp.read().decode("utf-8"))

        # Order expected:
        # 1. Shows with labels (Show A, Show C) before Show B (awaiting labels)
        # 2. unreviewed/in-progress (Show A) before confirmed (Show C)
        # 3. lowConfidenceCount descending
        slugs = [s["slug"] for s in shows]
        self.assertEqual(slugs, ["show-a", "show-c", "show-b"])

        show_a = shows[0]
        self.assertEqual(show_a["hasLabels"], True)
        self.assertEqual(show_a["status"], "unreviewed")
        self.assertEqual(show_a["rangeCount"], 1)
        self.assertEqual(show_a["pendingCount"], 1)
        self.assertEqual(show_a["lowConfidenceCount"], 1)

        show_b = shows[2]
        self.assertEqual(show_b["hasLabels"], False)
        self.assertEqual(show_b["status"], "awaiting labels")
        self.assertEqual(show_b["rangeCount"], 0)

    def test_derived_review_when_review_json_absent(self) -> None:
        """Verify derived review payload when review.json does not yet exist."""
        conn = self._conn()
        conn.request("GET", "/api/shows/show-a")
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        data = json.loads(resp.read().decode("utf-8"))

        self.assertIn("episode", data)
        self.assertIn("review", data)
        self.assertIn("words", data)
        self.assertEqual(data["gaps"], [[11.0, 20.0]])

        review = data["review"]
        self.assertEqual(review["version"], 1)
        self.assertEqual(review["status"], "unreviewed")
        self.assertEqual(review["pattern"], "sponsor at 5s")
        self.assertEqual(len(review["ranges"]), 1)

        r = review["ranges"][0]
        self.assertEqual(r["id"], "r1")
        self.assertEqual(r["decision"], "pending")
        self.assertEqual(r["origin"], "opus")
        self.assertIsInstance(r["opus"], dict)
        self.assertEqual(r["opus"]["sponsor"], "Acme")

    def test_valid_put_persists_and_roundtrips(self) -> None:
        """Verify valid review PUT saves atomically and round-trips."""
        conn = self._conn()
        payload = {
            "version": 1,
            "pattern": "updated pattern",
            "status": "in-progress",
            "ranges": [{
                "id": "r1",
                "start_s": 5.5,
                "end_s": 10.5,
                "kind": "sponsor",
                "label": "must-cut",
                "decision": "confirmed",
                "origin": "opus",
                "opus": None,
            }],
        }
        conn.request(
            "PUT",
            "/api/shows/show-a/review",
            body=json.dumps(payload),
            headers={
                "Content-Type": "application/json",
                "Origin": f"http://127.0.0.1:{self.port}",
            },
        )
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        res_data = json.loads(resp.read().decode("utf-8"))
        self.assertTrue(res_data["ok"])
        self.assertIn("updatedAt", res_data)

        # Confirm persisted on disk
        review_file = self.show_a / "review.json"
        self.assertTrue(review_file.is_file())
        disk_data = json.loads(review_file.read_text("utf-8"))
        self.assertEqual(disk_data["pattern"], "updated pattern")
        self.assertEqual(disk_data["status"], "in-progress")

        # GET roundtrip
        conn.request("GET", "/api/shows/show-a")
        get_resp = conn.getresponse()
        roundtrip = json.loads(get_resp.read().decode("utf-8"))["review"]
        self.assertEqual(roundtrip["pattern"], "updated pattern")
        self.assertEqual(roundtrip["ranges"][0]["start_s"], 5.5)

    def test_invalid_put_returns_400_and_leaves_file_unchanged(self) -> None:
        """Verify invalid PUT payloads return 400 without modifying review file."""
        # Initial review state
        init_file = self.show_a / "review.json"
        self.assertFalse(init_file.exists())

        conn = self._conn()
        headers = {
            "Content-Type": "application/json",
            "Origin": f"http://127.0.0.1:{self.port}",
        }

        # Case 1: Bad enum
        bad_enum = {
            "version": 1,
            "pattern": "",
            "status": "invalid-status",
            "ranges": [],
        }
        conn.request("PUT", "/api/shows/show-a/review", body=json.dumps(bad_enum), headers=headers)
        resp = conn.getresponse()
        self.assertEqual(resp.status, 400)
        resp.read()

        # Case 2: End beyond duration + 1 (duration is 20.0s)
        end_beyond = {
            "version": 1,
            "pattern": "",
            "status": "unreviewed",
            "ranges": [{
                "id": "r1",
                "start_s": 5.0,
                "end_s": 25.0,
                "kind": "sponsor",
                "label": "must-cut",
                "decision": "pending",
                "origin": "owner",
                "opus": None,
            }],
        }
        conn.request("PUT", "/api/shows/show-a/review", body=json.dumps(end_beyond), headers=headers)
        resp = conn.getresponse()
        self.assertEqual(resp.status, 400)
        resp.read()

        # Case 3: Start >= End
        start_ge_end = {
            "version": 1,
            "pattern": "",
            "status": "unreviewed",
            "ranges": [{
                "id": "r1",
                "start_s": 10.0,
                "end_s": 5.0,
                "kind": "sponsor",
                "label": "must-cut",
                "decision": "pending",
                "origin": "owner",
                "opus": None,
            }],
        }
        conn.request("PUT", "/api/shows/show-a/review", body=json.dumps(start_ge_end), headers=headers)
        resp = conn.getresponse()
        self.assertEqual(resp.status, 400)
        resp.read()

        self.assertFalse(init_file.exists())

    def test_cross_origin_put_is_403(self) -> None:
        """Verify cross-origin PUT requests are rejected with 403."""
        conn = self._conn()
        conn.request(
            "PUT",
            "/api/shows/show-a/review",
            body=b"{}",
            headers={
                "Content-Type": "application/json",
                "Origin": "http://evil.com",
            },
        )
        resp = conn.getresponse()
        self.assertEqual(resp.status, 403)
        resp.read()

    def test_bad_host_is_rejected(self) -> None:
        """Verify requests with unauthorized Host headers are rejected."""
        conn = self._conn()
        conn.request("GET", "/api/shows", headers={"Host": "evil.com"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 400)
        resp.read()

    def test_slug_traversal_is_404(self) -> None:
        """Verify traversal or invalid slug patterns return 404."""
        conn = self._conn()
        for bad_slug in ["..", "%2e%2e", "Show-A", "show_a", "unknown"]:
            conn.request("GET", f"/api/shows/{bad_slug}")
            resp = conn.getresponse()
            self.assertEqual(resp.status, 404)
            resp.read()

    def test_range_request_and_unsatisfiable_range(self) -> None:
        """Verify HTTP 206 Range responses and 416 for unsatisfiable ranges."""
        conn = self._conn()
        total_len = len(self.wav_bytes)

        # Valid range: 0-99 (100 bytes)
        conn.request("GET", "/audio/show-a", headers={"Range": "bytes=0-99"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 206)
        self.assertEqual(resp.getheader("Content-Range"), f"bytes 0-99/{total_len}")
        chunk = resp.read()
        self.assertEqual(len(chunk), 100)
        self.assertEqual(chunk, self.wav_bytes[:100])

        # Unsatisfiable range
        conn.request(
            "GET",
            "/audio/show-a",
            headers={"Range": f"bytes={total_len + 100}-{total_len + 200}"},
        )
        resp = conn.getresponse()
        self.assertEqual(resp.status, 416)
        self.assertEqual(resp.getheader("Content-Range"), f"bytes */{total_len}")
        resp.read()


if __name__ == "__main__":
    unittest.main()
