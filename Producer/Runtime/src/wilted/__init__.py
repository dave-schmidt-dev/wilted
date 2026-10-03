"""Wilted — preparation runtime (ad removal, transcription, local LLM) for the native app."""

__version__ = "0.2.0"

import os
from pathlib import Path

# Allow override via env var; otherwise find the project root by looking for
# pyproject.toml upward from __file__ (works for both editable and regular installs).
if _env_root := os.environ.get("WILTED_PROJECT_ROOT"):
    PROJECT_ROOT = Path(_env_root)
else:
    _candidate = Path(__file__).resolve().parent
    while _candidate != _candidate.parent:
        if (_candidate / "pyproject.toml").exists():
            break
        _candidate = _candidate.parent
    else:
        # Fallback: assume original layout (src/wilted/__init__.py -> 3 parents up)
        _candidate = Path(__file__).resolve().parent.parent.parent
    PROJECT_ROOT = _candidate

DATA_DIR = PROJECT_ROOT / "data"
AUDIO_DIR = DATA_DIR / "audio"
