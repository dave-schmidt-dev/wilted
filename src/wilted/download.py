"""Podcast audio download — streams enclosure URLs to disk with resume support."""

from __future__ import annotations

import logging
import os
import re
import tempfile
import time
import urllib.request
from typing import TYPE_CHECKING
from urllib.error import HTTPError, URLError

from wilted import DATA_DIR

if TYPE_CHECKING:
    from http.client import HTTPResponse
    from pathlib import Path

logger = logging.getLogger(__name__)

CHUNK_SIZE = 65536  # 64 KB


class DownloadError(RuntimeError):
    """Raised when a podcast download fails."""


def get_podcast_dir(item_id: int) -> Path:
    """Return the directory for a podcast episode's audio file.

    Args:
        item_id: Database ID of the item.

    Returns:
        Path to ``DATA_DIR / "podcasts" / str(item_id)``.
    """
    return DATA_DIR / "podcasts" / str(item_id)


def _extract_filename(url: str, response: HTTPResponse) -> str:
    """Determine a filename from Content-Disposition or the URL path.

    Falls back to ``"episode.mp3"`` when neither source yields a usable name.

    Args:
        url: The original request URL.
        response: The HTTP response (may contain Content-Disposition).

    Returns:
        A sanitised filename string.
    """
    # Try Content-Disposition header first
    disposition = response.headers.get("Content-Disposition", "")
    if disposition:
        match = re.search(r'filename=["\']?([^"\';]+)', disposition)
        if match:
            name = match.group(1).strip()
            if name:
                return _sanitise_filename(name)

    # Fall back to URL path
    from urllib.parse import unquote, urlparse

    path = urlparse(url).path
    if path:
        name = unquote(path.rsplit("/", 1)[-1])
        # Strip query-string remnants that may leak through
        name = name.split("?")[0]
        if name and "." in name:
            return _sanitise_filename(name)

    return "episode.mp3"


def _sanitise_filename(name: str) -> str:
    """Remove characters that are unsafe in filenames."""
    # Keep alphanumeric, hyphens, underscores, dots
    safe = re.sub(r"[^\w.\-]", "_", name)
    return safe or "episode.mp3"


def download_podcast(
    item_id: int,
    url: str,
    dest_dir: Path | None = None,
) -> Path:
    """Download a podcast episode audio file, with resume support.

    Streams the response in 64 KB chunks so memory use stays constant regardless
    of episode length.  If a partial file already exists and the server reports a
    Content-Length, a Range request is used to resume.  A fully downloaded file
    (matching Content-Length) is returned immediately without a new request.

    Args:
        item_id: Database ID of the item (used for the directory name).
        url: Enclosure URL to download.
        dest_dir: Override the destination directory.  Defaults to
            ``get_podcast_dir(item_id)``.

    Returns:
        Absolute path to the downloaded audio file.

    Raises:
        DownloadError: On HTTP errors, timeouts, or other I/O failures.
    """
    if dest_dir is None:
        dest_dir = get_podcast_dir(item_id)
    dest_dir.mkdir(parents=True, exist_ok=True)

    logger.info("Starting podcast download: item_id=%d url=%s", item_id, url)
    start_time = time.monotonic()

    try:
        # Initial HEAD-like GET to learn filename and Content-Length.
        # We use a normal GET so we can reuse the connection for streaming.
        req = urllib.request.Request(url)

        # Check for existing partial file — need Content-Length first
        response: HTTPResponse = urllib.request.urlopen(req, timeout=60)  # noqa: S310
        content_length = _parse_content_length(response)
        content_type = response.headers.get("Content-Type", "")
        final_url = response.url  # after redirects

        filename = _extract_filename(final_url, response)
        dest_path = dest_dir / filename

        # Validate content type (warn only)
        _check_content_type(content_type, url)

        # If file exists and is already complete, skip download
        if dest_path.exists() and content_length is not None:
            existing_size = dest_path.stat().st_size
            if existing_size == content_length:
                response.close()
                logger.info(
                    "Download already complete: item_id=%d size=%d path=%s",
                    item_id,
                    existing_size,
                    dest_path,
                )
                return dest_path

        # Check for resumable partial download
        existing_size = dest_path.stat().st_size if dest_path.exists() else 0

        if existing_size > 0 and content_length is not None and existing_size < content_length:
            # Close the first response and make a Range request
            response.close()
            range_req = urllib.request.Request(url)
            range_req.add_header("Range", f"bytes={existing_size}-")
            response = urllib.request.urlopen(range_req, timeout=60)  # noqa: S310

            if response.status == 206:
                logger.info(
                    "Resuming download at byte %d: item_id=%d",
                    existing_size,
                    item_id,
                )
                _stream_to_file(response, dest_path, content_length, item_id, append=True, offset=existing_size)
            else:
                # Server doesn't support Range — re-download from scratch
                logger.info("Server does not support Range; restarting download: item_id=%d", item_id)
                _stream_to_file(response, dest_path, content_length, item_id, append=False, offset=0)
        else:
            # Fresh download (or no Content-Length to compare against)
            if existing_size > 0 and content_length is None:
                # Can't verify completeness without Content-Length; overwrite
                logger.debug("No Content-Length; overwriting existing file: item_id=%d", item_id)
            _stream_to_file(response, dest_path, content_length, item_id, append=False, offset=0)

        elapsed = time.monotonic() - start_time
        final_size = dest_path.stat().st_size
        logger.info(
            "Download complete: item_id=%d size=%d duration=%.1fs path=%s",
            item_id,
            final_size,
            elapsed,
            dest_path,
        )
        return dest_path

    except HTTPError as exc:
        raise DownloadError(f"HTTP {exc.code} downloading {url}: {exc.reason}") from exc
    except URLError as exc:
        raise DownloadError(f"URL error downloading {url}: {exc.reason}") from exc
    except OSError as exc:
        raise DownloadError(f"I/O error downloading {url}: {exc}") from exc


def _parse_content_length(response: HTTPResponse) -> int | None:
    """Parse Content-Length header, returning None if absent or invalid."""
    raw = response.headers.get("Content-Length")
    if raw is None:
        return None
    try:
        return int(raw)
    except (ValueError, TypeError):
        return None


def _check_content_type(content_type: str, url: str) -> None:
    """Log a warning if the Content-Type is unexpected for audio."""
    if not content_type:
        logger.warning("No Content-Type header for %s", url)
        return
    ct_lower = content_type.lower().split(";")[0].strip()
    if ct_lower.startswith("audio/") or ct_lower == "application/octet-stream":
        return
    logger.warning("Unexpected Content-Type %r for %s", content_type, url)


def _stream_to_file(
    response: HTTPResponse,
    dest_path: Path,
    content_length: int | None,
    item_id: int,
    *,
    append: bool,
    offset: int,
) -> None:
    """Stream response body to *dest_path* using atomic write (temp + replace).

    For appended (resumed) downloads the existing file is opened in append mode
    and written in place — atomic rename is not practical for appends.

    Args:
        response: Open HTTP response to read from.
        dest_path: Final destination path.
        content_length: Total expected file size (for progress logging).
        item_id: Item ID for log messages.
        append: If True, append to existing file instead of overwriting.
        offset: Bytes already on disk (for progress calculation).
    """
    bytes_written = offset
    last_progress = 0  # last reported 10% bucket

    try:
        if append:
            with open(dest_path, "ab") as f:
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    f.write(chunk)
                    bytes_written += len(chunk)
                    last_progress = _log_progress(bytes_written, content_length, item_id, last_progress)
        else:
            # Atomic write via tempfile + os.replace
            with tempfile.NamedTemporaryFile("wb", dir=dest_path.parent, suffix=".tmp", delete=False) as f:
                tmp_path = f.name
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    f.write(chunk)
                    bytes_written += len(chunk)
                    last_progress = _log_progress(bytes_written, content_length, item_id, last_progress)
            os.replace(tmp_path, dest_path)
    finally:
        response.close()


def _log_progress(
    bytes_written: int,
    content_length: int | None,
    item_id: int,
    last_bucket: int,
) -> int:
    """Log progress at 10% intervals.  Returns the last reported bucket."""
    if content_length is None or content_length == 0:
        return last_bucket
    pct = int(bytes_written * 100 / content_length)
    bucket = pct // 10
    if bucket > last_bucket:
        logger.info("Download progress: item_id=%d %d%%", item_id, bucket * 10)
        return bucket
    return last_bucket
