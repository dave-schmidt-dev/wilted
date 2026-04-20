"""Preference keyword management — CRUD for relevance scoring keywords.

Keywords influence how the classification LLM scores content relevance.
Higher-weighted keywords signal stronger interest in a topic.

Usage:
    from wilted.preferences import add_keyword, list_keywords, remove_keyword

    add_keyword("kubernetes", weight=1.5)
    keywords = list_keywords()
    remove_keyword("kubernetes")
"""

from __future__ import annotations

import logging

from peewee import IntegrityError

from wilted.db import Keyword
from wilted.db import ensure_db as _ensure_db
from wilted.db import now_utc as _now_utc

logger = logging.getLogger(__name__)


def add_keyword(keyword: str, *, weight: float = 1.0) -> Keyword:
    """Add a relevance keyword.

    Args:
        keyword: The keyword or phrase to track.
        weight: Relevance weight multiplier (default 1.0).

    Returns:
        The created Keyword instance.

    Raises:
        ValueError: If keyword already exists or is empty.
    """
    _ensure_db()

    keyword = keyword.strip()
    if not keyword:
        raise ValueError("Keyword cannot be empty")

    if weight <= 0:
        raise ValueError(f"Weight must be positive, got {weight}")

    try:
        kw = Keyword.create(
            keyword=keyword,
            weight=weight,
            created_at=_now_utc(),
        )
    except IntegrityError as e:
        raise ValueError(f"Keyword already exists: '{keyword}'") from e

    logger.info("Added keyword '%s' (weight=%.1f)", keyword, weight)
    return kw


def list_keywords() -> list[Keyword]:
    """Return all keywords ordered by weight (descending), then alphabetically."""
    _ensure_db()
    return list(Keyword.select().order_by(Keyword.weight.desc(), Keyword.keyword))


def remove_keyword(keyword: str) -> Keyword:
    """Remove a keyword by its text.

    Args:
        keyword: The keyword text to remove.

    Returns:
        The removed Keyword instance.

    Raises:
        ValueError: If no keyword matches.
    """
    _ensure_db()

    try:
        kw = Keyword.get(Keyword.keyword == keyword.strip())
    except Keyword.DoesNotExist:
        raise ValueError(f"Keyword not found: '{keyword}'") from None

    kw.delete_instance()
    logger.info("Removed keyword '%s'", keyword)
    return kw


def get_keywords_for_prompt() -> str:
    """Format keywords into a string suitable for LLM prompts.

    Returns a formatted list of keywords with weights for inclusion
    in classification/relevance scoring prompts. Returns empty string
    if no keywords are configured.
    """
    _ensure_db()

    keywords = list_keywords()
    if not keywords:
        return ""

    lines = ["User interest keywords (higher weight = stronger interest):"]
    for kw in keywords:
        lines.append(f"  - {kw.keyword} (weight: {kw.weight:.1f})")
    return "\n".join(lines)
