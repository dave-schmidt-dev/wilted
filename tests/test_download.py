"""Tests for wilted.download — podcast audio download with resume support."""

from __future__ import annotations

from io import BytesIO
from unittest.mock import MagicMock, patch

import pytest

from wilted import download as download_mod
from wilted.download import DownloadError, download_podcast, get_podcast_dir

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _patch_data_dir(tmp_path, monkeypatch):
    """Point download module's DATA_DIR at the isolated tmp directory."""
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(download_mod, "DATA_DIR", data_dir)


def _make_response(
    body: bytes,
    status: int = 200,
    content_type: str = "audio/mpeg",
    content_length: int | None = None,
    disposition: str | None = None,
    url: str = "https://example.com/feed/episode.mp3",
) -> MagicMock:
    """Build a fake HTTPResponse suitable for urllib.request.urlopen."""
    resp = MagicMock()
    resp.status = status
    resp.url = url

    # HTTPResponse.read() should yield chunks then b""
    stream = BytesIO(body)
    resp.read = stream.read

    headers = {}
    if content_type:
        headers["Content-Type"] = content_type
    if content_length is not None:
        headers["Content-Length"] = str(content_length)
    if disposition:
        headers["Content-Disposition"] = disposition

    resp.headers = MagicMock()
    resp.headers.get = lambda key, default="": headers.get(key, default)

    resp.close = MagicMock()
    return resp


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestGetPodcastDir:
    def test_returns_correct_path(self, tmp_path):
        data_dir = tmp_path / "data"
        expected = data_dir / "podcasts" / "42"
        assert get_podcast_dir(42) == expected

    def test_different_ids(self, tmp_path):
        data_dir = tmp_path / "data"
        assert get_podcast_dir(1) == data_dir / "podcasts" / "1"
        assert get_podcast_dir(999) == data_dir / "podcasts" / "999"


class TestDownloadPodcast:
    @patch("wilted.download.urllib.request.urlopen")
    def test_successful_download(self, mock_urlopen, tmp_path):
        """Full download writes correct content to expected path."""
        audio_data = b"\xff\xfb\x90\x00" * 1000  # fake MP3 data
        resp = _make_response(
            body=audio_data,
            content_length=len(audio_data),
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.return_value = resp

        result = download_podcast(1, "https://example.com/feed/episode.mp3")

        assert result.exists()
        assert result.name == "episode.mp3"
        assert result.read_bytes() == audio_data
        assert "podcasts" in str(result)
        assert "1" in str(result)

    @patch("wilted.download.urllib.request.urlopen")
    def test_resume_partial_download(self, mock_urlopen, tmp_path):
        """Resumes a partial file using Range header."""
        full_data = b"A" * 1000
        partial_data = b"A" * 400
        remaining_data = b"A" * 600

        # Pre-create partial file
        podcast_dir = get_podcast_dir(7)
        podcast_dir.mkdir(parents=True)
        partial_file = podcast_dir / "episode.mp3"
        partial_file.write_bytes(partial_data)

        # First urlopen → initial response with Content-Length
        first_resp = _make_response(
            body=b"",  # won't be read — gets closed for Range request
            content_length=len(full_data),
            url="https://example.com/feed/episode.mp3",
        )
        # Second urlopen → Range response with remaining data
        range_resp = _make_response(
            body=remaining_data,
            status=206,
            content_length=len(full_data),
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.side_effect = [first_resp, range_resp]

        result = download_podcast(7, "https://example.com/feed/episode.mp3")

        assert result.exists()
        assert result.read_bytes() == full_data
        # Verify Range header was sent on second request
        second_call_req = mock_urlopen.call_args_list[1][0][0]
        assert second_call_req.get_header("Range") == "bytes=400-"

    @patch("wilted.download.urllib.request.urlopen")
    def test_skip_complete_download(self, mock_urlopen, tmp_path):
        """Skips download when file already exists with matching size."""
        audio_data = b"\xff\xfb\x90\x00" * 500
        content_length = len(audio_data)

        # Pre-create complete file
        podcast_dir = get_podcast_dir(3)
        podcast_dir.mkdir(parents=True)
        complete_file = podcast_dir / "episode.mp3"
        complete_file.write_bytes(audio_data)

        resp = _make_response(
            body=b"",  # should not be read
            content_length=content_length,
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.return_value = resp

        result = download_podcast(3, "https://example.com/feed/episode.mp3")

        assert result == complete_file
        assert result.read_bytes() == audio_data
        # Only one urlopen call (no Range request)
        assert mock_urlopen.call_count == 1
        # Response was closed without streaming
        resp.close.assert_called_once()

    @patch("wilted.download.urllib.request.urlopen")
    def test_http_error_raises_download_error(self, mock_urlopen):
        """HTTP errors are wrapped in DownloadError."""
        from urllib.error import HTTPError

        mock_urlopen.side_effect = HTTPError(
            url="https://example.com/missing.mp3",
            code=404,
            msg="Not Found",
            hdrs=MagicMock(),
            fp=None,
        )

        with pytest.raises(DownloadError, match="HTTP 404"):
            download_podcast(99, "https://example.com/missing.mp3")

    @patch("wilted.download.urllib.request.urlopen")
    def test_url_error_raises_download_error(self, mock_urlopen):
        """URL errors (DNS, connection refused) become DownloadError."""
        from urllib.error import URLError

        mock_urlopen.side_effect = URLError("Name or service not known")

        with pytest.raises(DownloadError, match="URL error"):
            download_podcast(99, "https://nonexistent.example.com/ep.mp3")

    @patch("wilted.download.urllib.request.urlopen")
    def test_invalid_content_type_logs_warning_but_downloads(self, mock_urlopen, caplog):
        """Unexpected Content-Type triggers a warning but download proceeds."""
        audio_data = b"data" * 100
        resp = _make_response(
            body=audio_data,
            content_type="text/html",
            content_length=len(audio_data),
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.return_value = resp

        import logging

        with caplog.at_level(logging.WARNING, logger="wilted.download"):
            result = download_podcast(5, "https://example.com/feed/episode.mp3")

        assert result.exists()
        assert result.read_bytes() == audio_data
        assert any("Unexpected Content-Type" in msg for msg in caplog.messages)

    @patch("wilted.download.urllib.request.urlopen")
    def test_content_disposition_filename(self, mock_urlopen, tmp_path):
        """Filename is extracted from Content-Disposition header."""
        audio_data = b"audio" * 100
        resp = _make_response(
            body=audio_data,
            content_length=len(audio_data),
            disposition='attachment; filename="my-podcast-ep42.mp3"',
            url="https://cdn.example.com/abcdef123",
        )
        mock_urlopen.return_value = resp

        result = download_podcast(10, "https://cdn.example.com/abcdef123")

        assert result.exists()
        assert result.name == "my-podcast-ep42.mp3"
        assert result.read_bytes() == audio_data

    @patch("wilted.download.urllib.request.urlopen")
    def test_filename_from_redirect_url(self, mock_urlopen, tmp_path):
        """Filename extracted from final URL after redirect."""
        audio_data = b"audio" * 100
        resp = _make_response(
            body=audio_data,
            content_length=len(audio_data),
            url="https://cdn.example.com/media/interview-2026.mp3?token=abc",
        )
        mock_urlopen.return_value = resp

        result = download_podcast(
            20,
            "https://example.com/redirect/episode",
        )

        assert result.exists()
        # URL path extraction should get "interview-2026.mp3"
        assert result.name == "interview-2026.mp3"

    @patch("wilted.download.urllib.request.urlopen")
    def test_fallback_filename_when_url_has_no_extension(self, mock_urlopen, tmp_path):
        """Falls back to episode.mp3 when URL path has no extension."""
        audio_data = b"audio" * 50
        resp = _make_response(
            body=audio_data,
            content_length=len(audio_data),
            url="https://example.com/stream/12345",
        )
        mock_urlopen.return_value = resp

        result = download_podcast(30, "https://example.com/stream/12345")

        assert result.name == "episode.mp3"

    @patch("wilted.download.urllib.request.urlopen")
    def test_custom_dest_dir(self, mock_urlopen, tmp_path):
        """dest_dir override places file in specified directory."""
        custom_dir = tmp_path / "custom"
        audio_data = b"audio" * 50
        resp = _make_response(
            body=audio_data,
            content_length=len(audio_data),
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.return_value = resp

        result = download_podcast(40, "https://example.com/feed/episode.mp3", dest_dir=custom_dir)

        assert result.parent == custom_dir
        assert result.exists()

    @patch("wilted.download.urllib.request.urlopen")
    def test_application_octet_stream_accepted(self, mock_urlopen, caplog):
        """application/octet-stream is accepted without warning."""
        audio_data = b"audio" * 50
        resp = _make_response(
            body=audio_data,
            content_type="application/octet-stream",
            content_length=len(audio_data),
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.return_value = resp

        import logging

        with caplog.at_level(logging.WARNING, logger="wilted.download"):
            result = download_podcast(50, "https://example.com/feed/episode.mp3")

        assert result.exists()
        assert not any("Unexpected Content-Type" in msg for msg in caplog.messages)

    @patch("wilted.download.urllib.request.urlopen")
    def test_resume_server_no_range_support(self, mock_urlopen, tmp_path):
        """Falls back to full download when server ignores Range header."""
        full_data = b"B" * 1000
        partial_data = b"B" * 400

        # Pre-create partial file
        podcast_dir = get_podcast_dir(8)
        podcast_dir.mkdir(parents=True)
        partial_file = podcast_dir / "episode.mp3"
        partial_file.write_bytes(partial_data)

        # First response: normal GET with Content-Length
        first_resp = _make_response(
            body=b"",
            content_length=len(full_data),
            url="https://example.com/feed/episode.mp3",
        )
        # Second response: server ignores Range, sends full content with 200
        full_resp = _make_response(
            body=full_data,
            status=200,
            content_length=len(full_data),
            url="https://example.com/feed/episode.mp3",
        )
        mock_urlopen.side_effect = [first_resp, full_resp]

        result = download_podcast(8, "https://example.com/feed/episode.mp3")

        assert result.exists()
        assert result.read_bytes() == full_data
