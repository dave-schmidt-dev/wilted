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

LEGACY_SPONSOR_OPENING_COMPATIBILITY_PATTERN = (
    r"\bbrought\s+to\s+you(?:\s+(?:today|this\s+week))?\s+by\b"
)

MISSING_SUPPORT_SPONSOR_COMPATIBILITY_PATTERN = (
    r"^\s*for\s+(?:the|this)\s+show\s+comes\s+from(?=\s+[a-z0-9])"
)

EXPLICIT_SUPPORT_OPENING_COMPATIBILITY_PATTERN = (
    r"(?:\bsupport\s+for\s+(?:the|this)\s+show\s+comes\s+from\b|"
    rf"{MISSING_SUPPORT_SPONSOR_COMPATIBILITY_PATTERN}\b)"
)

PARTNER_SPONSOR_OPENING_COMPATIBILITY_PATTERN = (
    r"\bour\s+partners?\s+(?:at\s+)?(?=[a-z0-9])"
)

PRODUCED_DISCLAIMER_CUE_PATTERN = (
    r"\b(?:"
    r"subject\s+to\s+credit\s+approval|"
    r"member\s+(?:of\s+)?fdic|"
    r"cards?\s+issued\s+by|"
    r"eligibility\s+varies|"
    r"cancel\s+any\s?time|"
    r"terms\s+and\s+conditions\s+apply|"
    r"(?:offer|eligibility)\s+restrictions\s+apply|"
    r"void\s+where\s+prohibited|"
    r"rates\s+and\s+fees"
    r")\b"
)

PUBLISHED_TRANSCRIPT_GAP_FLOOR_S = 45.0

PUBLISHED_TRANSCRIPT_GAP_FRACTION = 0.005

PREROLL_RECOVERY_MAX_SECONDS = 300.0

PREROLL_RECOVERY_MAX_SEGMENTS = 96

PREROLL_ALREADY_CLAIMED_SECONDS = 1.0

PREROLL_RECOVERY_MINIMUM_SECONDS = 10.0

PREROLL_COLD_OPEN_MAX_ID = 1

OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS = 96

AD_POD_CONTINUATION_MAX_GAP_SECONDS = 3.0

AD_POD_CONTINUATION_MAX_SEGMENTS = 12

AD_POD_CONTINUATION_MAX_SECONDS = 90.0

POSTROLL_RECOVERY_MAX_SECONDS = 300.0

POSTROLL_RECOVERY_MAX_SEGMENTS = 96

POSTROLL_ALREADY_CLAIMED_SECONDS = 1.0

POSTROLL_RECOVERY_MINIMUM_SECONDS = 10.0

POSTROLL_CLEAN_BREAK_SECONDS = 2.0

POSTROLL_LEADER_MAX_SECONDS = 15.0

EXPLICIT_SPONSOR_RECOVERY_MAX_SEGMENTS = 64

EXPLICIT_SPONSOR_RECOVERY_MAX_SECONDS = 10 * 60

EXPLICIT_SPONSOR_RESUMPTION_TAIL_SEGMENTS = 32

COMMERCIAL_RECOVERY_CONTEXT_IDS = 64

COMMERCIAL_RECOVERY_CONTEXT_CHARS = 12_000

COMMERCIAL_RECOVERY_MAX_CANDIDATE_SECONDS = 600.0

COMMERCIAL_RECOVERY_MAX_CANDIDATE_SHARE = 0.15

COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_IDS = 3

COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_SECONDS = 90.0

COMMERCIAL_RECOVERY_MAX_CANDIDATES = 4

COMMERCIAL_RECOVERY_MAX_ADDITIONAL_CALLS = 16

COMMERCIAL_SPARSE_MAX_SECONDS = 30.0

COMMERCIAL_SPARSE_GAP_MIN_SECONDS = 4.0

COMMERCIAL_SPARSE_MAX_ENVELOPE_SECONDS = 180.0

COMMERCIAL_SPARSE_CONTEXT_FLANK_IDS = 6

COMMERCIAL_SPARSE_TRANSITION_MAX_SECONDS = 0.5

COMMERCIAL_SPARSE_TRANSITION_MAX_CHARS = 6

COMMERCIAL_SPARSE_PREFIX_MAX_IDS = 12

COMMERCIAL_SPARSE_PREFIX_MAX_SECONDS = 90.0

STRADDLING_TAIL_MAX_PROBES = 8

EXPLICIT_SPONSOR_PREROLL_ANCHOR_MAX_SECONDS = 60.0

EXPLICIT_SPONSOR_PREROLL_LEFT_GAP_MAX_SECONDS = 15.0

EXPLICIT_SPONSOR_CTA_RE = re.compile(
    r"\b(?:learn|find\s+out|hear)\s+more\b|\bget\s+started\b|"
    r"\b(?:go\s+)?check\s+(?:it|them|us|these|those|that|him|her)\s+out\b|"
    r"\bgo\s+(?:check|see|read|grab|watch)\b|\bhead\s+(?:on\s+)?(?:over\s+)?to\b|"
    r"\bsign\s+up\b|\bsubscribe\b|\bfree\s+trial\b|\border\s+(?:now|today)\b|"
    r"\b(?:directly\s+)?support\s+(?:us|them|the\s+show|at)\b|\bavailable\s+(?:now\s+)?(?:at|on)\b|"
    r"\bdownload\b|\bjoin\b|\bvisit\b|\bgo\s+to\b",
    re.IGNORECASE,
)

EXPLICIT_SPONSOR_TOP_LEVEL_DOMAINS = (
    r"com|net|org|edu|gov|co|io|ai|app|dev|tv|fm|gg|me|us|uk|ca|de|shop|store|"
    r"club|live|life|news|blog|page|site|town|studio|media|games|show|xyz|link"
)

EXPLICIT_SPONSOR_DOT_DOMAIN_RE = re.compile(
    rf"\bdot\s+(?:{EXPLICIT_SPONSOR_TOP_LEVEL_DOMAINS})\b", re.IGNORECASE
)

EXPLICIT_SPONSOR_URL_RE = re.compile(r"\bhttps?\b|\bwww\b", re.IGNORECASE)

EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE = re.compile(
    rf"\b(?:[a-z0-9](?:[a-z0-9-]{{0,61}}[a-z0-9])?\.)+(?:{EXPLICIT_SPONSOR_TOP_LEVEL_DOMAINS})\b",
    re.IGNORECASE,
)

EXPLICIT_SPONSOR_SPOKEN_PATH_RE = re.compile(
    r"\b(?:patreon|youtube|instagram|twitter|facebook|tiktok|twitch|reddit|"
    r"linktree|discord|substack|bandcamp|kickstarter)\s+slash\b",
    re.IGNORECASE,
)

EXPLICIT_SPONSOR_OFFER_CODE_RE = re.compile(
    r"\b(?:promo|offer|coupon|discount)\s+code\b|\buse\s+(?:the\s+)?code\b|"
    r"\bcode\s+[a-z0-9]{3,}\s+at\s+checkout\b",
    re.IGNORECASE,
)

COMMERCIAL_PRESERVATION_FLANK_IDS = 2

COMMERCIAL_PRESERVATION_FLANK_STEPS = 3

EXPLICIT_SPONSOR_NAME_MAX_WORDS = 4

EXPLICIT_SPONSOR_NAME_MINIMUM_CHARACTERS = 6

EXPLICIT_SPONSOR_NAME_MINIMUM_REPEATS = 3

EXPLICIT_SPONSOR_NAME_WINDOW_SECONDS = 90.0

EXPLICIT_SPONSOR_NAME_WORD_RE = re.compile(r"[a-z0-9][a-z0-9'’]*", re.IGNORECASE)

EXPLICIT_SPONSOR_NAME_LEADING_FILLER = frozenset(
    {"the", "a", "an", "our", "my", "your", "this", "today", "todays", "good", "folks", "fine", "great"}
)

ALIGNED_STT_MODEL = "mlx-community/parakeet-tdt-1.1b"

ALIGNED_STT_CACHE_SCHEMA_VERSION = 1

ALIGNED_STT_CACHE_MAXIMUM_ENTRIES = 32

ALIGNED_TIMING_TAIL_ALLOWANCE_S = 3.0

RENDER_DURATION_TOLERANCE_S = 0.35

RENDER_PROGRESS_INTERVAL_S = 1.0

RENDER_TIMEOUT_S = 7_200.0

STT_EVICTION_BARRIER_TIMEOUT_S = 10.0

MAXIMUM_SINGLE_AD_SHARE = 0.5

MAXIMUM_TOTAL_AD_SHARE = 0.6

MAXIMUM_UNCONFIRMED_AD_SHARE = 0.5

MINIMUM_PROGRAMME_SHARE = 0.3

NOMINATED_SECONDS_FLOOR = 15.0

NOMINATED_SHARE_FLOOR = 0.005

RECOVERED_CONFIDENCE_FLOOR = 0.5

RECOVERED_CONFIDENCE_CEILING = 0.9

FORWARDED_WARNING_LIMIT = 20

TIMED_MEDIA_TYPES = {
    "text/vtt": "vtt",
    "application/x-subrip": "srt",
    "application/srt": "srt",
    "text/srt": "srt",
    "application/json": "podcast-json",
}
