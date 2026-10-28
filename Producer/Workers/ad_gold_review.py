"""Ad gold review server for podcast ad break verification.

Provides a localhost-only HTTP server and REST API for inspecting,
verifying, and correcting proposed ad break ranges in podcast episodes
from a gold dataset corpus.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import mimetypes
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SLUG_PATTERN = re.compile(r"^[a-z0-9-]+$")
MAX_BODY_BYTES = 1024 * 1024  # 1 MB
MAX_PATTERN_CHARS = 2000

VALID_STATUSES = {"unreviewed", "in-progress", "confirmed", "needs-second-episode"}
VALID_KINDS = {"sponsor", "house-promo", "network-promo", "intro", "outro", "other"}
VALID_LABELS = {"must-cut", "acceptable-cut", "not-ad"}
VALID_DECISIONS = {"pending", "confirmed"}
VALID_ORIGINS = {"opus", "owner"}


def resolve_show_dir(root_dir: Path, slug: str) -> Path | None:
    """Validate slug and resolve existing child directory within root."""
    if not SLUG_PATTERN.match(slug):
        return None
    try:
        candidate = (root_dir / slug).resolve()
        if candidate.parent == root_dir.resolve() and candidate.is_dir():
            return candidate
    except (OSError, RuntimeError):
        return None
    return None


def derive_review_from_labels(labels_data: dict[str, Any]) -> dict[str, Any]:
    """Derive an unreviewed review payload from labels.opus.json data."""
    ranges = [
        {
            "id": str(r.get("id", "")),
            "start_s": float(r.get("start_s", 0.0)),
            "end_s": float(r.get("end_s", 0.0)),
            "kind": str(r.get("kind", "sponsor")),
            "label": str(r.get("label", "must-cut")),
            "decision": "pending",
            "origin": "opus",
            "opus": dict(r),
        }
        for r in labels_data.get("ranges", [])
    ]
    return {
        "version": 1,
        "pattern": str(labels_data.get("pattern", "")),
        "status": "unreviewed",
        "ranges": ranges,
    }


def validate_review_payload(
    data: Any, duration_seconds: float
) -> tuple[bool, str]:
    """Validate incoming review.json payload according to spec."""
    if not isinstance(data, dict):
        return False, "Payload must be a JSON object"
    if data.get("version") != 1:
        return False, "version must be 1"
    pattern = data.get("pattern")
    if not isinstance(pattern, str) or len(pattern) >= MAX_PATTERN_CHARS:
        return False, f"pattern must be a string under {MAX_PATTERN_CHARS} chars"
    if data.get("status") not in VALID_STATUSES:
        return False, f"Invalid status: {data.get('status')}"
    ranges = data.get("ranges")
    if not isinstance(ranges, list):
        return False, "ranges must be a list"

    seen_ids: set[str] = set()
    for r in ranges:
        if not isinstance(r, dict):
            return False, "Each range must be a JSON object"
        rid = r.get("id")
        if not isinstance(rid, str) or not rid or rid in seen_ids:
            return False, f"Invalid or duplicate range id: {rid}"
        seen_ids.add(rid)
        s, e = r.get("start_s"), r.get("end_s")
        if not isinstance(s, (int, float)) or not isinstance(e, (int, float)):
            return False, f"start_s and end_s must be numbers for range {rid}"
        if not (0 <= float(s) < float(e) <= duration_seconds + 1):
            return False, f"Range {rid} timing invalid: {s}..{e} (duration={duration_seconds})"
        if r.get("kind") not in VALID_KINDS:
            return False, f"Invalid kind: {r.get('kind')} in range {rid}"
        if r.get("label") not in VALID_LABELS:
            return False, f"Invalid label: {r.get('label')} in range {rid}"
        if r.get("decision") not in VALID_DECISIONS:
            return False, f"Invalid decision: {r.get('decision')} in range {rid}"
        if r.get("origin") not in VALID_ORIGINS:
            return False, f"Invalid origin: {r.get('origin')} in range {rid}"
        if r.get("opus") is not None and not isinstance(r.get("opus"), dict):
            return False, f"opus must be a dict or null in range {rid}"
    return True, ""


class AdGoldReviewHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the ad gold review tool."""

    server_version = "AdGoldReview/1.0"

    def log_message(self, format: str, *args: Any) -> None:
        """Log only error requests to avoid spamming the console."""
        if args and len(args) > 1:
            try:
                if int(args[1]) >= 400:
                    super().log_message(format, *args)
            except (ValueError, TypeError):
                pass

    @property
    def root_dir(self) -> Path:
        """Root directory containing gold show directories."""
        return self.server.root_dir  # type: ignore[attr-defined]

    def _verify_host(self) -> bool:
        """Enforce Host header validation to prevent DNS rebinding."""
        host = self.headers.get("Host", "").strip()
        port = self.server.server_port
        allowed = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if port == 80:
            allowed.update({"127.0.0.1", "localhost"})
        if host not in allowed:
            self.send_error(400, "Invalid Host header")
            return False
        return True

    def _send_json(self, status_code: int, data: Any) -> None:
        """Send JSON response with appropriate headers."""
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        """Handle GET requests."""
        if not self._verify_host():
            return
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self._serve_file("ad_gold_review.html", "text/html; charset=utf-8")
        elif path == "/ad_gold_review.js":
            self._serve_file("ad_gold_review.js", "application/javascript; charset=utf-8")
        elif path == "/api/shows":
            self._handle_get_shows()
        elif path.startswith("/api/shows/"):
            self._handle_get_show_detail(path[len("/api/shows/") :])
        elif path.startswith("/audio/"):
            self._handle_get_audio(path[len("/audio/") :])
        else:
            self.send_error(404, "Not Found")

    def do_PUT(self) -> None:
        """Handle PUT requests."""
        if not self._verify_host():
            return
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/api/shows/") and path.endswith("/review"):
            self._handle_put_review(path[len("/api/shows/") : -len("/review")])
        else:
            self.send_error(404, "Not Found")

    def _serve_file(self, filename: str, content_type: str) -> None:
        """Serve a static file located beside the script."""
        file_path = Path(__file__).parent / filename
        if not file_path.is_file():
            self.send_error(404, f"{filename} not found")
            return
        content = file_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _handle_get_shows(self) -> None:
        """Return show list sorted by label availability, status, and confidence."""
        shows: list[dict[str, Any]] = []
        if self.root_dir.is_dir():
            for child in self.root_dir.iterdir():
                if not child.is_dir() or not SLUG_PATTERN.match(child.name):
                    continue
                ep_file = child / "episode.json"
                if not ep_file.is_file():
                    continue
                try:
                    ep_data = json.loads(ep_file.read_text("utf-8"))
                except Exception:
                    continue
                labels_file = child / "labels.opus.json"
                has_labels = labels_file.is_file()
                review_file = child / "review.json"
                status, r_cnt, p_cnt, low_cnt = "unreviewed", 0, 0, 0
                if review_file.is_file():
                    try:
                        rd = json.loads(review_file.read_text("utf-8"))
                        status = rd.get("status", "unreviewed")
                        ranges = rd.get("ranges", [])
                        r_cnt = len(ranges)
                        p_cnt = sum(1 for r in ranges if r.get("decision") == "pending")
                        low_cnt = sum(
                            1 for r in ranges
                            if (r.get("confidence") or (r.get("opus") or {}).get("confidence")) == "low"
                        )
                    except Exception:
                        pass
                elif has_labels:
                    try:
                        ld = json.loads(labels_file.read_text("utf-8"))
                        ranges = ld.get("ranges", [])
                        r_cnt, p_cnt = len(ranges), len(ranges)
                        low_cnt = sum(1 for r in ranges if r.get("confidence") == "low")
                    except Exception:
                        pass
                else:
                    status = "awaiting labels"

                shows.append({
                    "slug": child.name,
                    "show": ep_data.get("show", child.name),
                    "title": ep_data.get("title", ""),
                    "durationSeconds": float(ep_data.get("durationSeconds", 0.0)),
                    "status": status,
                    "rangeCount": r_cnt,
                    "pendingCount": p_cnt,
                    "lowConfidenceCount": low_cnt,
                    "hasLabels": has_labels,
                })

        def sort_key(s: dict[str, Any]) -> tuple[int, int, int, str]:
            label_rank = 0 if s["hasLabels"] else 1
            st = s["status"]
            st_rank = 0 if st in ("unreviewed", "in-progress") else (1 if st in ("confirmed", "needs-second-episode") else 2)
            return (label_rank, st_rank, -s["lowConfidenceCount"], s["show"])

        shows.sort(key=sort_key)
        self._send_json(200, shows)

    def _handle_get_show_detail(self, slug: str) -> None:
        """Return episode metadata, review ranges, and transcript words."""
        show_dir = resolve_show_dir(self.root_dir, slug)
        if not show_dir or not (show_dir / "labels.opus.json").is_file():
            self.send_error(404, "Show not found or missing labels")
            return
        ep_path = show_dir / "episode.json"
        if not ep_path.is_file():
            self.send_error(404, "episode.json not found")
            return
        try:
            ep_data = json.loads(ep_path.read_text("utf-8"))
            labels_data = json.loads((show_dir / "labels.opus.json").read_text("utf-8"))
        except Exception:
            self.send_error(500, "Error reading metadata")
            return

        review_path = show_dir / "review.json"
        if review_path.is_file():
            try:
                review_data = json.loads(review_path.read_text("utf-8"))
            except Exception:
                review_data = derive_review_from_labels(labels_data)
        else:
            review_data = derive_review_from_labels(labels_data)

        words = []
        tx_path = show_dir / "transcript.json"
        if tx_path.is_file():
            try:
                words = json.loads(tx_path.read_text("utf-8")).get("words", [])
            except Exception:
                words = []
        gaps = labels_data.get("gaps", []) if isinstance(labels_data, dict) else []
        self._send_json(200, {"episode": ep_data, "review": review_data, "words": words, "gaps": gaps})

    def _handle_put_review(self, slug: str) -> None:
        """Validate and atomically persist review.json."""
        origin, port = self.headers.get("Origin"), self.server.server_port
        if origin is not None and origin not in {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}:
            self._send_json(403, {"error": "Cross-origin PUT forbidden"})
            return
        ct = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        if ct != "application/json":
            self._send_json(400, {"error": "Content-Type must be application/json"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": "Invalid Content-Length"})
            return
        if length > MAX_BODY_BYTES:
            self._send_json(400, {"error": "Body exceeds 1 MB"})
            return
        body = self.rfile.read(length)
        if len(body) > MAX_BODY_BYTES:
            self._send_json(400, {"error": "Body exceeds 1 MB"})
            return
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            self._send_json(400, {"error": "Invalid JSON payload"})
            return

        show_dir = resolve_show_dir(self.root_dir, slug)
        if not show_dir or not (show_dir / "episode.json").is_file():
            self.send_error(404, "Show not found")
            return
        try:
            ep_data = json.loads((show_dir / "episode.json").read_text("utf-8"))
            dur = float(ep_data.get("durationSeconds", 0.0))
        except Exception:
            self.send_error(500, "Error reading episode.json")
            return

        is_valid, err = validate_review_payload(data, dur)
        if not is_valid:
            self._send_json(400, {"error": err})
            return

        data["updatedAt"] = datetime.now(timezone.utc).isoformat()
        tmp_fd, tmp_path = tempfile.mkstemp(dir=show_dir, prefix="review_tmp_")
        try:
            with open(tmp_fd, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_path, show_dir / "review.json")
        except Exception as e:
            if os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            self._send_json(500, {"error": f"Failed to write review: {e}"})
            return
        self._send_json(200, {"ok": True, "updatedAt": data["updatedAt"]})

    def _handle_get_audio(self, slug: str) -> None:
        """Serve episode audio file with HTTP Range support."""
        show_dir = resolve_show_dir(self.root_dir, slug)
        if not show_dir or not (show_dir / "episode.json").is_file():
            self.send_error(404, "Show not found")
            return
        try:
            ep_data = json.loads((show_dir / "episode.json").read_text("utf-8"))
            audio_file = ep_data.get("audioFile", "")
        except Exception:
            self.send_error(500, "Error reading episode.json")
            return
        if not isinstance(audio_file, str) or not audio_file or os.path.basename(audio_file) != audio_file:
            self.send_error(404, "Invalid audioFile specification")
            return
        audio_path = (show_dir / audio_file).resolve()
        if audio_path.parent != show_dir or not audio_path.is_file():
            self.send_error(404, "Audio file not found")
            return
        try:
            file_size = audio_path.stat().st_size
        except OSError:
            self.send_error(500, "Error reading audio file stats")
            return

        mime_map = {".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4", ".ogg": "audio/ogg"}
        ct = mime_map.get(audio_path.suffix.lower()) or mimetypes.guess_type(str(audio_path))[0] or "application/octet-stream"

        range_hdr = self.headers.get("Range")
        if not range_hdr:
            self.send_response(200)
            self.send_header("Content-Type", ct)
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self._stream_file_range(audio_path, 0, file_size)
            return

        m = re.match(r"^bytes=(\d*)-(\d*)$", range_hdr.strip())
        if not m or (not m.group(1) and not m.group(2)):
            self._send_range_unsatisfiable(file_size)
            return
        raw_s, raw_e = m.groups()
        if raw_s and raw_e:
            start, end = int(raw_s), int(raw_e)
        elif raw_s:
            start, end = int(raw_s), file_size - 1
        else:
            start, end = max(0, file_size - int(raw_e)), file_size - 1

        if start >= file_size or start < 0 or end < start:
            self._send_range_unsatisfiable(file_size)
            return

        end = min(end, file_size - 1)
        length = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self._stream_file_range(audio_path, start, length)

    def _send_range_unsatisfiable(self, file_size: int) -> None:
        self.send_response(416)
        self.send_header("Content-Range", f"bytes */{file_size}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _stream_file_range(self, path: Path, start: int, length: int) -> None:
        chunk_size, remaining = 64 * 1024, length
        try:
            with open(path, "rb") as f:
                f.seek(start)
                while remaining > 0:
                    chunk = f.read(min(remaining, chunk_size))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


class GoldReviewServer(ThreadingHTTPServer):
    """Threaded HTTP server holding the root directory reference."""

    def __init__(
        self,
        server_address: tuple[str, int],
        RequestHandlerClass: type[BaseHTTPRequestHandler],
        root_dir: Path,
    ) -> None:
        self.root_dir = root_dir
        super().__init__(server_address, RequestHandlerClass)


def run_server(root_dir: Path, port: int = 8765) -> None:
    """Start the ad gold review server and serve until interrupted."""
    server = GoldReviewServer(("127.0.0.1", port), AdGoldReviewHandler, root_dir)
    print(f"ad gold review: http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main() -> None:
    """CLI entrypoint for ad gold review."""
    default_root = Path.home() / "Library" / "Application Support" / "Wilted" / "adcorpus-inputs" / "gold"
    parser = argparse.ArgumentParser(description="Ad gold set review web tool")
    parser.add_argument("--root", type=Path, default=default_root, help="Path to gold dataset root directory")
    parser.add_argument("--port", type=int, default=8765, help="Port to bind (default: 8765, 0 for any)")
    args = parser.parse_args()
    run_server(args.root, args.port)


if __name__ == "__main__":
    main()
