"""Article fetching — URL resolution, text extraction, clipboard."""

import re
import subprocess
import sys
import urllib.request


def get_text_from_clipboard() -> str:
    """Read text from macOS clipboard via pbpaste."""
    result = subprocess.run(["pbpaste"], capture_output=True, text=True)
    return result.stdout.strip()


def resolve_apple_news_url(url: str) -> str:
    """Extract canonical URL from Apple News share link."""
    req = urllib.request.Request(url, method="GET")
    req.add_header(
        "User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
    )
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
        req.add_header(
            "User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
        )
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


def get_text_from_url(url: str) -> tuple[str | None, str]:
    """Fetch and extract article text from a URL.

    Returns (text, resolved_url). The URL may differ from input if an
    Apple News link was resolved.
    """
    import trafilatura

    if "apple.news" in url:
        url = resolve_apple_news_url(url)
    html = trafilatura.fetch_url(url)
    if html:
        text = trafilatura.extract(
            html, include_comments=False, include_tables=False
        )
        return text, url
    return None, url
