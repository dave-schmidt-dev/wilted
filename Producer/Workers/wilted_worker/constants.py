"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import contextlib
import difflib
import errno
import fcntl
import html
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

PROTOCOL_VERSION = 2

CUT_TOOLS = ("ffmpeg", "ffprobe")

PUBLISHED_TRANSCRIPT_GAP_FLOOR_S = 45.0

PUBLISHED_TRANSCRIPT_GAP_FRACTION = 0.005

ALIGNED_STT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"

# The model an app built before engine v13 still names in its removal requests.
# The app runs this checkout's worker, so it meets the new model before it is
# rebuilt; its requests are served with ALIGNED_STT_MODEL rather than refused.
ALIGNED_STT_PREVIOUS_MODEL = "mlx-community/parakeet-tdt-1.1b"

# Version 6 transcripts reconcile microgaps with complete-cue alignment evidence.
ALIGNED_STT_CACHE_SCHEMA_VERSION = 6

# Parakeet computes a token's end as its start plus its duration, and the next
# token's start from its own frame step, so two adjacent tokens can disagree by
# a few ulps. A word fragment is still contiguous with the token before it when
# it starts this much earlier; a real overlapping chunk stitch is far larger.
SPLIT_WORD_CONTIGUITY_TOLERANCE_S = 0.001

ALIGNED_STT_CACHE_MAXIMUM_ENTRIES = 32

ALIGNED_TIMING_TAIL_ALLOWANCE_S = 3.0

RENDER_DURATION_TOLERANCE_S = 0.35

RENDER_PROGRESS_INTERVAL_S = 1.0

RENDER_TIMEOUT_S = 7_200.0

# Silence trimming. Audio at or below this level counts as silence. Speech and
# produced room tone sit far above it, so a noisy recording finds no silence
# and is left alone, which is the safe direction. On a 98-minute episode
# (measured 2026-10-20, ffmpeg 9.0) -50 dB found 600 pauses of 0.5 s or more
# and trimmed 202 s; -35 dB and -60 dB found 782 and 492, so the count changes
# smoothly with the floor and this choice is not on an edge.
SILENCE_NOISE_FLOOR_DB = -50

# Every pause longer than this is shortened to it, half on each side.
SILENCE_KEPT_PAUSE_S = 0.5

# The shortest silence the detector reports: half the kept pause, so the two
# halves of a pause that an ad cut joins together are both seen.
SILENCE_DETECT_MIN_S = 0.25

# Silence this close to the start or end of the prepared audio, or to the next
# silence, is treated as touching it.
SILENCE_EDGE_TOLERANCE_S = 0.05

# A kept piece shorter than this is dropped rather than kept as a sliver, by
# pause trimming and by the ad cut map alike.
SILENCE_MIN_KEEP_S = 0.01

# The Mac stores at most 512 kept intervals per preparation; trimming stops
# below that, taking the longest pauses first.
SILENCE_MAX_KEEP_INTERVALS = 500

# The detection pass decodes the whole episode once: 8.4 s for the same
# 98-minute MP3 (2026-10-20). The bound only stops a wedged decoder.
SILENCE_DETECT_TIMEOUT_S = 900.0

FFPROBE_TIMEOUT_S = 60

STT_EVICTION_BARRIER_TIMEOUT_S = 10.0

MAXIMUM_TOTAL_AD_SHARE = 0.6

NOMINATED_SECONDS_FLOOR = 15.0

NOMINATED_SHARE_FLOOR = 0.005

FORWARDED_WARNING_LIMIT = 20

TIMED_MEDIA_TYPES = {
    "text/vtt": "vtt",
    "application/x-subrip": "srt",
    "application/srt": "srt",
    "text/srt": "srt",
    "application/json": "podcast-json",
}
