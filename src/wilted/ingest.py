"""Shared article ingestion — resolve URL or clipboard to text + metadata."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

from wilted.fetch import get_text_from_clipboard, resolve_apple_news_url, suppress_subprocess_output


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
    """Fetch article from a URL, extracting title from trafilatura metadata."""
    from wilted.text import clean_text

    source_url = url
    canonical_url = url

    if "apple.news" in url:
        status("Resolving Apple News link...")
        canonical_url = resolve_apple_news_url(url)
        url = canonical_url

    status("Fetching article...")

    # Suppress stdout/stderr during trafilatura import — spacy model
    # downloads via pip subprocess corrupt the Textual TUI.
    with suppress_subprocess_output():
        import trafilatura

        html = trafilatura.fetch_url(url)

    if not html:
        raise ValueError("Could not fetch article text (paywall?). Copy the text, then run: wilted --add")

    # Use bare_extraction to get text + title in one pass (no double HTTP fetch).
    # trafilatura >=2.0 returns a Document object; older versions return a dict.
    doc = trafilatura.bare_extraction(html, include_comments=False, include_tables=False)
    doc_text = getattr(doc, "text", None) if doc else None
    if not doc_text:
        raise ValueError("Could not extract article text (paywall?). Copy the text, then run: wilted --add")

    text = clean_text(doc_text)
    title = getattr(doc, "title", None)

    return ArticleResult(
        text=text,
        title=title,
        source_url=source_url,
        canonical_url=canonical_url,
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
