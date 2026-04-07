"""Reading list queue — load, save, add, remove, clear."""

import json
import os
import re
import tempfile
from datetime import datetime

from lilt import ARTICLES_DIR, QUEUE_FILE, ensure_data_dirs


def load_queue() -> list[dict]:
    """Load the reading list queue from disk."""
    if QUEUE_FILE.exists():
        try:
            with open(QUEUE_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, ValueError):
            return []
    return []


def save_queue(queue: list[dict]) -> None:
    """Save the reading list queue atomically."""
    ensure_data_dirs()
    with tempfile.NamedTemporaryFile("w", dir=QUEUE_FILE.parent, suffix=".tmp", delete=False) as f:
        json.dump(queue, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, QUEUE_FILE)


def _slugify(text: str, max_len: int = 50) -> str:
    """Convert text to a filesystem-safe slug."""
    slug = re.sub(r"[^\w\s-]", "", text.lower())
    slug = re.sub(r"[\s_]+", "-", slug).strip("-")
    return slug[:max_len]


def add_article(
    text: str,
    title: str | None = None,
    source_url: str | None = None,
    canonical_url: str | None = None,
) -> dict:
    """Save article text and add to the reading list. Returns the new entry."""
    ensure_data_dirs()
    queue = load_queue()
    next_id = max((e["id"] for e in queue), default=0) + 1

    word_count = len(text.split())

    if not title:
        first_line = text.split("\n")[0][:80]
        title = first_line

    slug = _slugify(title)
    filename = f"{next_id}_{slug}.txt"
    article_path = ARTICLES_DIR / filename
    with open(article_path, "w") as f:
        f.write(text)

    entry = {
        "id": next_id,
        "title": title,
        "words": word_count,
        "source_url": source_url,
        "canonical_url": canonical_url,
        "file": filename,
        "added": datetime.now().isoformat(timespec="seconds"),
    }
    queue.append(entry)
    save_queue(queue)
    return entry


def remove_article(index: int) -> dict:
    """Remove article at 0-based index. Returns the removed entry.

    Raises IndexError if index is out of range.
    """
    queue = load_queue()
    if index < 0 or index >= len(queue):
        raise IndexError(f"Invalid index {index}. Queue has {len(queue)} article(s).")

    entry = queue.pop(index)
    article_path = ARTICLES_DIR / entry["file"]
    if article_path.exists():
        article_path.unlink()

    save_queue(queue)
    return entry


def clear_queue() -> int:
    """Clear all articles. Returns the number removed."""
    queue = load_queue()
    if not queue:
        return 0

    count = len(queue)
    for entry in queue:
        article_path = ARTICLES_DIR / entry["file"]
        if article_path.exists():
            article_path.unlink()

    save_queue([])
    return count


def get_article_text(entry: dict) -> str | None:
    """Read cached article text for a queue entry."""
    article_path = ARTICLES_DIR / entry["file"]
    if not article_path.exists():
        return None
    with open(article_path) as f:
        return f.read()


def mark_completed(entry: dict) -> None:
    """Remove a completed article from the queue and delete its cached file."""
    queue = load_queue()
    queue = [e for e in queue if e["id"] != entry["id"]]
    save_queue(queue)
    article_path = ARTICLES_DIR / entry["file"]
    if article_path.exists():
        article_path.unlink()
