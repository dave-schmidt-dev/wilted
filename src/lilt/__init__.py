"""Lilt — local TTS article reader for Apple Silicon."""

__version__ = "0.2.0"

import os
from pathlib import Path

# Allow override via env var; otherwise find the project root by looking for
# pyproject.toml upward from __file__ (works for both editable and regular installs).
if _env_root := os.environ.get("LILT_PROJECT_ROOT"):
    PROJECT_ROOT = Path(_env_root)
else:
    _candidate = Path(__file__).resolve().parent
    while _candidate != _candidate.parent:
        if (_candidate / "pyproject.toml").exists():
            break
        _candidate = _candidate.parent
    else:
        # Fallback: assume original layout (src/lilt/__init__.py -> 3 parents up)
        _candidate = Path(__file__).resolve().parent.parent.parent
    PROJECT_ROOT = _candidate

DATA_DIR = PROJECT_ROOT / "data"
QUEUE_FILE = DATA_DIR / "queue.json"
ARTICLES_DIR = DATA_DIR / "articles"
STATE_FILE = DATA_DIR / "state.json"


VOICES = {
    "af_heart": {"name": "Heart", "gender": "F", "accent": "American"},
    "af_bella": {"name": "Bella", "gender": "F", "accent": "American"},
    "af_nova": {"name": "Nova", "gender": "F", "accent": "American"},
    "af_sky": {"name": "Sky", "gender": "F", "accent": "American"},
    "am_adam": {"name": "Adam", "gender": "M", "accent": "American"},
    "am_echo": {"name": "Echo", "gender": "M", "accent": "American"},
    "bf_alice": {"name": "Alice", "gender": "F", "accent": "British"},
    "bf_emma": {"name": "Emma", "gender": "F", "accent": "British"},
    "bm_daniel": {"name": "Daniel", "gender": "M", "accent": "British"},
    "bm_george": {"name": "George", "gender": "M", "accent": "British"},
    "jf_alpha": {"name": "Alpha", "gender": "F", "accent": "Japanese"},
    "jm_kumo": {"name": "Kumo", "gender": "M", "accent": "Japanese"},
    "zf_xiaobei": {"name": "Xiaobei", "gender": "F", "accent": "Chinese"},
    "zm_yunxi": {"name": "Yunxi", "gender": "M", "accent": "Chinese"},
}

WPM_ESTIMATE = 150  # Approximate words-per-minute for TTS time estimates

LANGUAGES = {
    "a": "American English",
    "b": "British English",
    "j": "Japanese",
    "z": "Chinese",
}


def ensure_data_dirs():
    """Create data directories if they don't exist."""
    ARTICLES_DIR.mkdir(parents=True, exist_ok=True)
