"""Shared article ingestion — resolve URL or clipboard to text + metadata."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

from wilted.fetch import (
    fetch_url_with_browser,
    get_text_from_clipboard,
    resolve_apple_news_url,
    suppress_subprocess_output,
)

# Phrases that appear at the start of consent/cookie walls, not article text.
_CONSENT_MARKERS = (
    "tracker preferences",
    "manage your tracker",
    "cookie consent",
    "we use cookies",
    "privacy choices",
)


def _looks_like_consent_wall(text: str) -> bool:
    """Return True if the extracted text looks like a cookie/consent overlay."""
    probe = text[:300].lower()
    return any(marker in probe for marker in _CONSENT_MARKERS)


def _extract_from_main(html: str, trafilatura, fallback_text, fallback_title):
    """Re-run trafilatura against the <main> element only.

    Many modern CMS/SPA sites (Axios, The Atlantic, etc.) put the article
    inside <main> and the consent overlay outside it. Scoping the extraction
    to <main> avoids picking up the overlay boilerplate.

    Returns (text, title), falling back to the supplied values if extraction
    yields nothing useful. Title is pulled from the full HTML <title> tag when
    the scoped extraction doesn't produce one.
    """
    main_match = re.search(r"<main[^>]*>.*?</main>", html, re.DOTALL | re.IGNORECASE)
    if not main_match:
        return fallback_text, fallback_title

    scoped_html = f"<html><body>{main_match.group(0)}</body></html>"
    doc = trafilatura.bare_extraction(scoped_html, include_comments=False, include_tables=False)
    text = getattr(doc, "text", None) if doc else None
    title = getattr(doc, "title", None) if doc else None

    if not title:
        # <title> lives outside <main>; grab it from the full HTML.
        t = re.search(r"<title[^>]*>([^<]+)</title>", html, re.IGNORECASE)
        if t:
            raw = t.group(1).strip()
            # Strip trailing " - Site Name" / " | Site" suffixes.
            # Require at least one space before ASCII pipe/hyphen so we don't
            # split hyphenated words like "self-made". Em/en-dashes are always
            # title separators regardless of surrounding whitespace.
            title = re.split(r"(?:\s[|\-]\s|[\u2014\u2013])", raw)[0].strip() or raw

    if text and not _looks_like_consent_wall(text):
        return text, title or fallback_title
    return fallback_text, fallback_title


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
    """Fetch article from a URL, extracting title from trafilatura metadata.

    Falls back to a headed browser fetch (via playwright + system Chrome) when
    trafilatura is blocked by Cloudflare or other bot-protection challenges.
    If the browser fetch succeeds but trafilatura still picks up a cookie/consent
    overlay, retries extraction scoped to the <main> element.
    """
    from wilted.text import clean_text

    source_url = url
    canonical_url = url

    if "apple.news" in url:
        status("Resolving Apple News link...")
        canonical_url = resolve_apple_news_url(url)
        url = canonical_url

    status("Fetching article...")

    # Suppress stdout/stderr during trafilatura import — spacy model
    # downloads via pip subprocess corrupt the Textual TUI.  Only the
    # import itself is guarded; the network fetch runs unsuppressed so
    # Textual's renderer keeps fd 1 and can paint status updates.
    with suppress_subprocess_output():
        import trafilatura

    html = trafilatura.fetch_url(url)

    if not html:
        # Trafilatura blocked (Cloudflare, bot protection, etc.) — try browser.
        html = fetch_url_with_browser(url, on_status=status)

    if not html:
        raise ValueError("Blocked (paywall or bot protection). Copy the article text, then add without a URL.")

    # Use bare_extraction to get text + title in one pass (no double HTTP fetch).
    # trafilatura >=2.0 returns a Document object; older versions return a dict.
    doc = trafilatura.bare_extraction(html, include_comments=False, include_tables=False)
    doc_text = getattr(doc, "text", None) if doc else None
    title = getattr(doc, "title", None)

    # If trafilatura picked up a cookie/consent overlay instead of the article,
    # retry against just the <main> element (which contains only the article body
    # on most modern CMS/SPA sites like Axios, The Atlantic, etc.).
    if not doc_text or _looks_like_consent_wall(doc_text):
        doc_text, title = _extract_from_main(html, trafilatura, doc_text, title)

    if not doc_text:
        raise ValueError("Could not extract article text. Try copying it and adding without a URL.")

    text = clean_text(doc_text)

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
