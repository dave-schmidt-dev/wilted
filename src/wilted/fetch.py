"""Article fetching — URL resolution, text extraction, clipboard."""

import logging
import os
import re
import subprocess
import sys
import threading
import urllib.request
from contextlib import contextmanager

logger = logging.getLogger(__name__)

# Serializes all OS-level FD manipulation. os.dup2 modifies the process-wide
# FD table with no thread awareness; concurrent calls from multiple Textual
# worker threads corrupt each other's saved/restored FDs.
_suppress_lock = threading.Lock()


@contextmanager
def suppress_subprocess_output(on_wait=None):
    """Redirect OS-level file descriptors 1 & 2 to /dev/null.

    Python's contextlib.redirect_stdout only catches sys.stdout writes.
    Subprocess output (e.g. pip installing spacy models) goes straight to
    fd 1/2, which corrupts the Textual TUI. This redirects at the OS level.

    Thread-safe: a module-level lock serialises concurrent calls so FD saves
    and restores never interleave. Gracefully skips any FD that is already
    invalid (e.g. because Playwright's async teardown recycled it).

    Args:
        on_wait: Optional zero-argument callable invoked when the lock is
            already held by another thread. Use to show a "waiting…" status
            in the UI before blocking.
    """
    if not _suppress_lock.acquire(blocking=False):
        if on_wait:
            on_wait()
        _suppress_lock.acquire(blocking=True)

    try:
        try:
            devnull_fd = os.open(os.devnull, os.O_WRONLY)
        except OSError:
            yield
            return

        saved: dict[int, int] = {}
        for fd in (1, 2):
            try:
                saved[fd] = os.dup(fd)
                os.dup2(devnull_fd, fd)
            except OSError:
                pass  # FD invalid (e.g. closed by async teardown); skip it

        try:
            yield
        finally:
            for fd, saved_fd in saved.items():
                try:
                    os.dup2(saved_fd, fd)
                except OSError:
                    pass
                try:
                    os.close(saved_fd)
                except OSError:
                    pass
            try:
                os.close(devnull_fd)
            except OSError:
                pass
    finally:
        _suppress_lock.release()


def get_text_from_clipboard() -> str:
    """Read text from macOS clipboard via pbpaste."""
    result = subprocess.run(["pbpaste"], capture_output=True, text=True)
    return result.stdout.strip()


def resolve_apple_news_url(url: str) -> str:
    """Extract canonical URL from Apple News share link."""
    req = urllib.request.Request(url, method="GET")
    req.add_header("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        match = re.search(r'redirectToUrl[^"]*"([^"]+)"', html)
        if match:
            canonical = match.group(1).split("?")[0]
            print(f"  Resolved to: {canonical}")
            return canonical
    except Exception as e:
        print(
            f"  Warning: could not resolve Apple News URL: {e}",
            file=sys.stderr,
        )
    return url


def extract_title_from_url(url: str) -> str | None:
    """Try to extract article title from the URL's HTML."""
    try:
        req = urllib.request.Request(url)
        req.add_header("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        match = re.search(r"<title[^>]*>([^<]+)</title>", html, re.IGNORECASE)
        if match:
            title = match.group(1).strip()
            # Strip common suffixes like " - The Atlantic" or " | The New Yorker"
            title = re.split(
                r"\s*[|\-\u2014\u2013]\s*(?:The\s+)?(?:Atlantic|New Yorker|Reason|NYT|Washington Post).*$",
                title,
                flags=re.IGNORECASE,
            )[0]
            return title.strip()
    except Exception:
        pass
    return None


# Common cookie/consent button selectors across major consent frameworks
# (OneTrust, Quantcast, Funding Choices, custom implementations).
_CONSENT_SELECTORS = [
    "#onetrust-accept-btn-handler",
    "button:has-text('Accept all')",
    "button:has-text('Accept All')",
    "button:has-text('Accept cookies')",
    "button:has-text('Accept')",
    "button:has-text('I Accept')",
    "button:has-text('Agree')",
    "button:has-text('Agree and close')",
    "[aria-label='Accept cookies']",
    ".fc-button-label",  # Funding Choices
]


def _dismiss_cookie_consent(page) -> None:
    """Click the first visible consent button found, if any."""
    for sel in _CONSENT_SELECTORS:
        try:
            btn = page.locator(sel).first
            if btn.is_visible(timeout=300):
                btn.click()
                page.wait_for_timeout(500)
                return
        except Exception:
            continue


def fetch_url_with_browser(url: str, on_status=None) -> str | None:
    """Fetch URL using headless system Chrome to handle bot challenges.

    Launches headless Chrome via Playwright, waits for any JS challenge and
    cookie consent dialogs to resolve, then returns the page HTML. Falls back
    gracefully if playwright is not installed or Chrome is not found.

    Args:
        url: The URL to fetch.
        on_status: Optional callback for progress strings.

    Returns:
        Raw HTML string, or None if unavailable.
    """
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        logger.warning("Playwright not installed — browser fallback unavailable")
        return None

    def _status(msg: str) -> None:
        if on_status:
            on_status(msg)

    _status("Opening browser to bypass bot protection...")
    try:
        pw_ctx = sync_playwright().start()
        try:
            browser = pw_ctx.chromium.launch(
                channel="chrome",
                headless=True,
                args=["--disable-blink-features=AutomationControlled"],
            )
            context = browser.new_context(
                user_agent=(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/131.0.0.0 Safari/537.36"
                ),
            )
            page = context.new_page()
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                # Wait up to 10s for Cloudflare JS challenge to resolve
                for _ in range(10):
                    title = page.title()
                    if "just a moment" not in title.lower() and "checking" not in title.lower():
                        break
                    _status("Waiting for browser challenge...")
                    page.wait_for_timeout(1_000)
                # Let JS-rendered content settle, then dismiss any consent dialog
                try:
                    page.wait_for_load_state("networkidle", timeout=5_000)
                except Exception:
                    pass
                _dismiss_cookie_consent(page)
                return page.content()
            finally:
                browser.close()
        finally:
            pw_ctx.stop()
    except Exception:
        logger.warning("Browser fetch failed for %s", url, exc_info=True)
        return None


def get_text_from_url(url: str) -> tuple[str | None, str]:
    """Fetch and extract article text from a URL.

    Returns (text, resolved_url). The URL may differ from input if an
    Apple News link was resolved.
    """
    if "apple.news" in url:
        url = resolve_apple_news_url(url)

    # Suppress stdout/stderr during trafilatura import — spacy model
    # downloads via pip subprocess corrupt the Textual TUI.  Only the
    # import is guarded; the network fetch runs unsuppressed so Textual
    # keeps fd 1 and can paint status updates.
    with suppress_subprocess_output():
        import trafilatura

    html = trafilatura.fetch_url(url)

    if html:
        text = trafilatura.extract(html, include_comments=False, include_tables=False)
        return text, url
    return None, url
