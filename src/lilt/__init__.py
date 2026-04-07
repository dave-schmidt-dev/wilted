"""Lilt — local TTS article reader for Apple Silicon."""

__version__ = "0.2.0"

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
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
