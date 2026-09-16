"""Unified fetch/extract cascade for general-article text.

Phase 1 of the fetch-path consolidation (see
``.plans/wilted/fetch-path-consolidation-2026-07-23.md``). This module has
**zero callers** until Phase 2 cuts over ``fetch.get_text_from_url``,
``ingest._resolve_from_url``, and ``discover._fetch_article_text`` onto
:func:`resolve_article_text`. Building the cascade standalone first — with
its acceptance-gate predicate and suppression contract locked down by tests
— lets Phase 2 be a pure call-site swap with nothing new to get wrong.

Pure fetch/extract: no DB import, no ``DATA_DIR`` (INV-5).

Suppression contract (CR-9): ``suppress_subprocess_output`` wraps ONLY the
lazy ``import trafilatura`` + one-time timeout config — never the network
fetch. A subprocess-based spaCy model download on first trafilatura import
writes straight to fd 1/2 and corrupts the Textual TUI if left unguarded;
wrapping the *fetch* too (as the 2026-04-20 regression did — see
HISTORY.md:1368-1370) blinds the TUI for the whole HTTP round-trip instead of
just the one-time import. ``discover._fetch_article_text`` today fetches
*inside* the suppression scope (discover.py:177-180) — that CR-9 violation is
not reproduced here; T2.4 will delete the buggy original.
"""

from __future__ import annotations

import logging
import re
import urllib.request
from dataclasses import dataclass
from enum import Enum
from typing import TYPE_CHECKING, Literal

from wilted.fetch import fetch_url_with_browser, suppress_subprocess_output
from wilted.text import clean_text

if TYPE_CHECKING:
    from collections.abc import Callable

logger = logging.getLogger(__name__)

# Short Mac UA for plain urllib requests (Apple News link resolution only).
# The FULL-budget browser fallback (``fetch_url_with_browser``) keeps its own
# full desktop-Chrome UA in ``wilted.fetch`` — it stays the single Playwright
# implementation, so its UA is not duplicated here.
HTTP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

# trafilatura's per-attempt DOWNLOAD_TIMEOUT, wired via _configure_once().
# Matches trafilatura's own default (30s) — preserves today's per-attempt
# wall-clock behavior; see the Phase 1 timeout spike verdict in the plan.
FETCH_TIMEOUT_S = 30

_configured = False
_trafilatura_config = None


def _configure_once() -> None:
    """Idempotently bound trafilatura's per-attempt download timeout.

    trafilatura 2.0's urllib3-backed retry/pool is module-global state, not
    per-call — the Phase 1 spike confirmed that setting ``DOWNLOAD_TIMEOUT``
    on a config object (and threading it through every
    ``fetch_url(config=...)`` call) is what actually bounds a hung fetch.
    Per-call timeout kwargs don't exist on this API, and signal/thread-based
    wrappers are ruled out project-wide: the TUI runs ingest on a
    ``@work(thread=True)`` worker, where signal handlers can't install.

    Deliberately does NOT touch ``MAX_REDIRECTS`` — that governs real
    redirect-following (apple.news resolution, ordinary 301/302 chains) and
    is out of scope for this timeout fix.

    Guarded by ``_configured`` so the process-global mutation happens once
    per process. Must run inside ``suppress_subprocess_output`` alongside the
    lazy ``import trafilatura`` in :func:`resolve_article_text` — importing
    ``trafilatura.settings`` can trigger the same first-import subprocess
    output as ``trafilatura`` itself.
    """
    global _configured, _trafilatura_config
    if _configured:
        return
    from trafilatura.settings import use_config

    cfg = use_config()
    cfg.set("DEFAULT", "DOWNLOAD_TIMEOUT", str(FETCH_TIMEOUT_S))
    _trafilatura_config = cfg
    _configured = True


class FetchBudget(Enum):
    """How hard :func:`resolve_article_text` should try before giving up.

    CHEAP: trafilatura fetch only (no browser fallback); bare_extraction
        only (no ``<main>``-scoped retry). Matches the nightly discover path
        — cheap enough to run unattended across a whole feed batch.
    FULL: trafilatura fetch, escalating to a headless-Chrome fetch if that
        yields no HTML; bare_extraction, escalating to a ``<main>``-scoped
        retry if the result is missing or looks like a consent wall. Matches
        the interactive ingest path — a human is waiting, so it's worth
        spending the extra few seconds.
    """

    CHEAP = "cheap"
    FULL = "full"


@dataclass(frozen=True)
class ResolvedText:
    """Result of one fetch/extract cascade run.

    Attributes:
        text: Cleaned article text, or None if nothing usable was extracted.
        title: Extracted title, or None if unavailable or equal to the
            resolved URL (a URL-shaped "title" is not useful metadata, but
            per PM-7 it does not by itself downgrade ``outcome``).
        resolved_url: The input URL, or its Apple News resolution target.
        outcome: "ok" (usable article text), "headline_only" (text present
            but under ``min_words`` or consent-wall-shaped), "blocked" (no
            HTML at all), or "failed" (HTML fetched but no text extracted).
        tier_used: Deepest cascade tier actually exercised — "none",
            "trafilatura", "browser", or "main-scope" — for observability.
    """

    text: str | None
    title: str | None
    resolved_url: str
    outcome: Literal["ok", "headline_only", "blocked", "failed"]
    tier_used: str


def resolve_apple_news_url(url: str, on_status: Callable[[str], None] | None = None) -> str:
    """Extract the canonical article URL from an Apple News share link.

    Library code, not a CLI entry point: progress is reported via the
    optional ``on_status`` callback and a DEBUG log line, never ``print()``
    (the original in ``wilted.fetch`` prints directly and stays that way
    until its own caller cuts over in Phase 2). Never raises — degrades to
    returning the input URL unchanged on any failure.
    """
    req = urllib.request.Request(url, method="GET")
    req.add_header("User-Agent", HTTP_UA)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        match = re.search(r'redirectToUrl[^"]*"([^"]+)"', html)
        if match:
            canonical = match.group(1).split("?")[0]
            logger.debug("fetch_cascade: resolved Apple News URL to %s", canonical)
            if on_status:
                on_status(f"Resolved to: {canonical}")
            return canonical
    except Exception as e:
        logger.debug("fetch_cascade: could not resolve Apple News URL: %s", e)
        if on_status:
            on_status(f"Warning: could not resolve Apple News URL: {e}")
    return url


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
    the scoped extraction doesn't produce one. Never raises.
    """
    main_match = re.search(r"<main[^>]*>.*?</main>", html, re.DOTALL | re.IGNORECASE)
    if not main_match:
        return fallback_text, fallback_title

    scoped_html = f"<html><body>{main_match.group(0)}</body></html>"
    try:
        doc = trafilatura.bare_extraction(scoped_html, include_comments=False, include_tables=False)
    except Exception:
        logger.debug("fetch_cascade: <main>-scoped bare_extraction raised", exc_info=True)
        return fallback_text, fallback_title
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
            title = re.split(r"(?:\s[|\-]\s|[—–])", raw)[0].strip() or raw

    if text and not _looks_like_consent_wall(text):
        return text, title or fallback_title
    return fallback_text, fallback_title


def resolve_article_text(
    url: str,
    *,
    budget: FetchBudget,
    on_status: Callable[[str], None] | None = None,
    min_words: int = 25,
) -> ResolvedText:
    """Fetch and extract article text through a budgeted transport/extraction cascade.

    Transport cascade: trafilatura ``fetch_url`` first; on FULL budget only,
    escalate to :func:`wilted.fetch.fetch_url_with_browser` if that yields no
    HTML. Each tier runs in its own typed try/except and never raises.

    Extraction cascade: ``bare_extraction`` first; on FULL budget only,
    escalate to a ``<main>``-scoped retry (:func:`_extract_from_main`) when
    the result is missing or consent-wall-shaped. CHEAP budget stops at
    ``bare_extraction`` — this reproduces ``discover._fetch_article_text``'s
    current extraction depth exactly.

    Acceptance gate (first match wins):
        no HTML fetched                                    -> "blocked"
        HTML fetched, no text extracted (or text cleans
            down to empty/whitespace-only)                 -> "failed"
        text extracted, but < min_words or consent-wall     -> "headline_only"
        otherwise                                           -> "ok"
    A title equal to ``resolved_url`` is blanked (title=None) but never
    changes the outcome — a real >= min_words body still reaches "ok" even
    with a URL-shaped title (PM-7).

    Never raises for I/O failures; returns a ResolvedText describing the
    failure instead.
    """

    def _status(msg: str) -> None:
        if on_status:
            on_status(msg)

    resolved_url = url
    if "apple.news" in url:
        _status("Resolving Apple News link...")
        resolved_url = resolve_apple_news_url(url, on_status=on_status)

    def _on_wait() -> None:
        _status("Waiting for another download to finish...")

    # CR-9: suppress stdout/stderr for the import + one-time config only. A
    # subprocess-based spaCy model download on first trafilatura import
    # writes straight to fd 1/2 and corrupts the Textual TUI. The network
    # fetch and extraction below run unsuppressed so Textual keeps fd 1 and
    # can paint status updates throughout.
    with suppress_subprocess_output(on_wait=_on_wait):
        import trafilatura

        _configure_once()

    _status("Fetching article...")

    html = None
    tier_used = "none"

    logger.debug("fetch_cascade: trying trafilatura fetch for %s", resolved_url)
    try:
        html = trafilatura.fetch_url(resolved_url, config=_trafilatura_config)
    except Exception:
        logger.debug("fetch_cascade: trafilatura fetch raised", exc_info=True)
        html = None
    if html:
        tier_used = "trafilatura"

    if not html and budget is FetchBudget.FULL:
        logger.debug("fetch_cascade: trafilatura fetch empty, trying browser for %s", resolved_url)
        try:
            html = fetch_url_with_browser(resolved_url, on_status=on_status)
        except Exception:
            logger.debug("fetch_cascade: browser fetch raised", exc_info=True)
            html = None
        if html:
            tier_used = "browser"

    text: str | None = None
    title: str | None = None
    word_count = 0
    outcome: Literal["ok", "headline_only", "blocked", "failed"]

    if not html:
        outcome = "blocked"
    else:
        logger.debug("fetch_cascade: extracting via bare_extraction")
        try:
            doc = trafilatura.bare_extraction(html, include_comments=False, include_tables=False)
            text = getattr(doc, "text", None) if doc else None
            title = getattr(doc, "title", None) if doc else None
        except Exception:
            logger.debug("fetch_cascade: bare_extraction raised", exc_info=True)
            text = None
            title = None

        if budget is FetchBudget.FULL and (not text or _looks_like_consent_wall(text)):
            logger.debug("fetch_cascade: retrying extraction scoped to <main>")
            main_text, main_title = _extract_from_main(html, trafilatura, text, title)
            if main_text is not text:
                # _extract_from_main returns the exact fallback objects,
                # unchanged, whenever the <main>-scoped retry was a no-op (no
                # <main> element, extraction raised, or the scoped result was
                # itself rejected as a consent wall) — only bump tier_used
                # when it actually produced the text we go on to use.
                tier_used = "main-scope"
            text, title = main_text, main_title

        if not text:
            # Covers both "nothing extracted" (None) and "extracted an empty
            # string" — either way there's no usable text, so text must be
            # None per the "None if nothing usable" contract, not "".
            outcome = "failed"
            text = None
            title = None
        else:
            text = clean_text(text)
            if not text:
                # HTML fetched and something was extracted, but it cleaned
                # down to nothing usable (e.g. whitespace-only extraction) —
                # that's "failed", not "headline_only" with an empty string.
                outcome = "failed"
                text = None
                title = None
            else:
                word_count = len(text.split())
                consent_wall = _looks_like_consent_wall(text)
                outcome = "headline_only" if (word_count < min_words or consent_wall) else "ok"
                if title == resolved_url:
                    title = None

    logger.debug(
        "fetch_cascade: outcome=%s tier_used=%s words=%d url=%s",
        outcome,
        tier_used,
        word_count,
        resolved_url,
    )

    return ResolvedText(text=text, title=title, resolved_url=resolved_url, outcome=outcome, tier_used=tier_used)
