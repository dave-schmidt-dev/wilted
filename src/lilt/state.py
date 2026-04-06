"""Resume state — track playback position per article."""

import json
import os
import tempfile
from datetime import datetime

from lilt import STATE_FILE, ensure_data_dirs


def load_state() -> dict:
    """Load resume state from disk."""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, ValueError):
            return {}
    return {}


def save_state(state: dict) -> None:
    """Save resume state atomically."""
    ensure_data_dirs()
    with tempfile.NamedTemporaryFile(
        "w", dir=STATE_FILE.parent, suffix=".tmp", delete=False
    ) as f:
        json.dump(state, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, STATE_FILE)


def get_article_state(article_id: int) -> dict | None:
    """Get resume position for an article, or None if not saved."""
    state = load_state()
    return state.get(str(article_id))


def set_article_state(
    article_id: int, paragraph_idx: int, segment_in_paragraph: int = 0
) -> None:
    """Save resume position for an article."""
    state = load_state()
    state[str(article_id)] = {
        "paragraph_idx": paragraph_idx,
        "segment_in_paragraph": segment_in_paragraph,
        "updated": datetime.now().isoformat(timespec="seconds"),
    }
    save_state(state)


def clear_article_state(article_id: int) -> None:
    """Remove resume position for an article."""
    state = load_state()
    state.pop(str(article_id), None)
    save_state(state)
