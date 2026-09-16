"""Shared article ingestion — resolve URL or clipboard to text + metadata."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

from wilted.fetch import get_text_from_clipboard
from wilted.fetch_cascade import FetchBudget, resolve_article_text


@dataclass
class ArticleResult:
    """Resolved article with cleaned text and metadata."""

    text: str
    title: str | None
    source_url: str | None
    canonical_url: str | None


def resolve_article(
    url: str | None = None,
    *,
    clipboard_text: str | None = None,
    min_clipboard_len: int = 0,
    on_status: Callable[[str], None] | None = None,
) -> ArticleResult:
    """Resolve a URL or clipboard text to an ArticleResult.

    This is the shared ingest path for both CLI and TUI. It fetches the
    article text and extracts metadata (title, URLs) without enqueueing.

    Args:
        url: HTTP(S) URL to fetch. Mutually exclusive with clipboard_text.
        clipboard_text: Pre-read clipboard text. If None and url is None,
            reads from clipboard via pbpaste.
        min_clipboard_len: Minimum stripped clipboard length to accept.
            CLI uses 0 (no minimum), TUI uses 50.
        on_status: Optional callback for progress messages.

    Returns:
        ArticleResult with cleaned text and metadata.

    Raises:
        ValueError: If no usable text is found.
    """

    def _status(msg: str) -> None:
        if on_status:
            on_status(msg)

    if url and url.startswith(("http://", "https://")):
        return _resolve_from_url(url, _status)

    return _resolve_from_clipboard(clipboard_text, min_clipboard_len, _status)


def _resolve_from_url(
    url: str,
    status: Callable[[str], None],
) -> ArticleResult:
    """Fetch article text from a URL via the fetch/extract cascade.

    Delegates transport (trafilatura, escalating to a headed-browser
    fallback) and extraction (bare_extraction, escalating to a
    <main>-scoped retry on a consent wall) to
    :func:`wilted.fetch_cascade.resolve_article_text` at FULL budget — the
    interactive-ingest depth. A manual "add" legitimately keeps a
    headline-only result (the user asked for it), so both "ok" and
    "headline_only" outcomes return an ArticleResult; only "blocked" and
    "failed" raise.
    """
    source_url = url

    resolved = resolve_article_text(url, budget=FetchBudget.FULL, on_status=status)

    if resolved.outcome == "blocked":
        raise ValueError("Blocked (paywall or bot protection). Copy the article text, then add without a URL.")
    if resolved.outcome == "failed":
        raise ValueError("Could not extract article text. Try copying it and adding without a URL.")

    return ArticleResult(
        text=resolved.text,
        title=resolved.title,
        source_url=source_url,
        canonical_url=resolved.resolved_url,
    )


def _resolve_from_clipboard(
    clipboard_text: str | None,
    min_clipboard_len: int,
    status: Callable[[str], None],
) -> ArticleResult:
    """Resolve article from clipboard text."""
    from wilted.text import clean_text, extract_title_from_paste

    if clipboard_text is None:
        status("Reading clipboard...")
        clipboard_text = get_text_from_clipboard()

    if not clipboard_text or len(clipboard_text.strip()) < min_clipboard_len:
        if min_clipboard_len > 0:
            raise ValueError("Clipboard empty or too short")
        raise ValueError("Clipboard is empty.")

    # If clipboard is essentially just a URL (possibly prefixed by a shell
    # prompt character like ❯ or $), fetch it instead of storing verbatim.
    stripped = clipboard_text.strip()
    if "\n" not in stripped:
        url_match = re.search(r"https?://\S+", stripped)
        if url_match and len(url_match.group(0)) > len(stripped) * 0.5:
            status("URL detected in clipboard, fetching...")
            return _resolve_from_url(url_match.group(0), status)

    text = clean_text(clipboard_text)
    title = extract_title_from_paste(clipboard_text)

    # Check for Apple News URL in raw clipboard
    url_match = re.search(r"https://apple\.news/\S+", clipboard_text)
    source_url = url_match.group(0) if url_match else None

    return ArticleResult(
        text=text,
        title=title,
        source_url=source_url,
        canonical_url=None,
    )
