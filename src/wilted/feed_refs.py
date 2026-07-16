"""Safe storage and resolution for public and BWS-backed feed URLs."""

from __future__ import annotations

import hashlib
import os
import re
from urllib.parse import urlsplit

import feedparser

_BWS_REFERENCE = re.compile(r"^bws:([A-Z][A-Z0-9_]*)$")
_BWS_ITEM_REFERENCE = re.compile(r"^bws-feed-item:([A-Z][A-Z0-9_]*):([a-f0-9]{64})$")
_BWS_GUID_REFERENCE = re.compile(r"^bws-guid:([a-f0-9]{64})$")


class FeedReferenceError(ValueError):
    """A stored feed or enclosure reference cannot be used safely."""


def _is_http_url(value: str) -> bool:
    """Return whether value is an absolute HTTP(S) URL without whitespace."""
    if not value or value != value.strip() or any(character.isspace() for character in value):
        return False
    try:
        parsed = urlsplit(value)
    except ValueError:
        return False
    return (
        parsed.scheme in {"http", "https"}
        and bool(parsed.netloc)
        and parsed.hostname is not None
        and parsed.username is None
        and parsed.password is None
    )


def bws_secret_name(feed_reference: str) -> str | None:
    """Return the BWS environment variable named by a feed reference, if any."""
    match = _BWS_REFERENCE.fullmatch(feed_reference)
    return match.group(1) if match else None


def validate_feed_reference(feed_reference: str) -> str:
    """Validate a persistable public URL or ``bws:UPPERCASE_SNAKE_CASE`` ref."""
    if bws_secret_name(feed_reference) or _is_http_url(feed_reference):
        return feed_reference
    raise FeedReferenceError("Feed URL must be an http(s) URL or bws:UPPERCASE_SNAKE_CASE reference")


def resolve_feed_url(feed_reference: str) -> str:
    """Resolve a feed reference using only the runtime launcher's environment."""
    validate_feed_reference(feed_reference)
    secret_name = bws_secret_name(feed_reference)
    if secret_name is None:
        return feed_reference
    resolved_url = os.environ.get(secret_name)
    if not resolved_url:
        raise FeedReferenceError(
            f"BWS feed reference {feed_reference} is unavailable; launch Wilted through wilted-runtime.sh"
        )
    if not _is_http_url(resolved_url):
        raise FeedReferenceError(f"BWS feed reference {feed_reference} does not contain a valid http(s) URL")
    return resolved_url


def display_feed_reference(feed_reference: str) -> str:
    """Return the persisted non-secret reference suitable for CLI output and logs."""
    validate_feed_reference(feed_reference)
    return feed_reference


def make_bws_enclosure_reference(feed_reference: str, entry_guid: str) -> str:
    """Create an opaque persisted enclosure reference for a BWS-backed feed."""
    secret_name = bws_secret_name(feed_reference)
    if secret_name is None or not entry_guid:
        raise FeedReferenceError("BWS enclosure references require a BWS feed reference and entry GUID")
    identity_digest = hashlib.sha256(entry_guid.encode("utf-8")).hexdigest()
    return f"bws-feed-item:{secret_name}:{identity_digest}"


def make_bws_guid(entry_guid: str) -> str:
    """Create the opaque persisted identity used to deduplicate BWS episodes."""
    return f"bws-guid:{hashlib.sha256(entry_guid.encode('utf-8')).hexdigest()}"


def is_bws_guid(value: str | None) -> bool:
    """Return whether value is an opaque persisted BWS episode identity."""
    return bool(value and _BWS_GUID_REFERENCE.fullmatch(value))


def guid_matches_reference(candidate_guid: str, stored_guid: str) -> bool:
    """Match raw XML GUID against either a public or opaque stored identity."""
    match = _BWS_GUID_REFERENCE.fullmatch(stored_guid)
    if match:
        return hashlib.sha256(candidate_guid.strip().encode("utf-8")).hexdigest() == match.group(1)
    return candidate_guid.strip() == stored_guid


def is_bws_enclosure_reference(value: str | None) -> bool:
    """Return whether value is an opaque BWS-backed enclosure reference."""
    return bool(value and _BWS_ITEM_REFERENCE.fullmatch(value))


def _parse_bws_enclosure_reference(value: str) -> tuple[str, str]:
    """Return secret name and one-way entry identity digest from a reference."""
    match = _BWS_ITEM_REFERENCE.fullmatch(value)
    if not match:
        raise FeedReferenceError("Invalid BWS enclosure reference")
    return match.group(1), match.group(2)


def _entry_enclosure_url(entry) -> str | None:
    """Extract the first audio enclosure URL from a feedparser entry."""
    for enclosure in entry.get("enclosures", []):
        href = enclosure.get("href") or enclosure.get("url")
        content_type = enclosure.get("type", "")
        if href and ("audio" in content_type or href.endswith((".mp3", ".m4a", ".ogg", ".wav"))):
            return str(href)
    for link in entry.get("links", []):
        if link.get("type", "").startswith("audio/") and link.get("href"):
            return str(link["href"])
    return None


def resolve_enclosure_url(enclosure_reference: str, feed_reference: str) -> str:
    """Resolve an opaque enclosure by re-reading its BWS-backed RSS feed."""
    if not is_bws_enclosure_reference(enclosure_reference):
        return enclosure_reference
    secret_name, identity_digest = _parse_bws_enclosure_reference(enclosure_reference)
    if bws_secret_name(feed_reference) != secret_name:
        raise FeedReferenceError("BWS enclosure reference does not match its feed reference")
    try:
        parsed = feedparser.parse(resolve_feed_url(feed_reference))
    except Exception as exc:
        # Suppress the chained exception: network/parser exceptions may embed
        # the resolved credential-bearing URL in their message.
        raise FeedReferenceError(f"Could not refresh BWS feed {feed_reference}: {type(exc).__name__}") from None
    for entry in parsed.entries:
        candidate_guid = entry.get("id")
        candidate_digest = None
        if candidate_guid:
            candidate_digest = hashlib.sha256(str(candidate_guid).strip().encode("utf-8")).hexdigest()
        if candidate_digest == identity_digest:
            enclosure_url = _entry_enclosure_url(entry)
            if enclosure_url and _is_http_url(enclosure_url):
                return enclosure_url
            break
    raise FeedReferenceError(f"Could not resolve enclosure for BWS feed {feed_reference}")
