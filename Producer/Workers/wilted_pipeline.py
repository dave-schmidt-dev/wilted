#!/usr/bin/env python3
"""Prepare one downloaded podcast episode: transcript, ad detection, ad removal.

This is the bridge to the previous Python Wilted. The valuable, hard to
reproduce part of that codebase is `wilted.ads` -- roughly 1,500 lines of tuned
prompts and boundary verification -- and the transcript parsers beside it. None
of that is reimplemented here; this module is the process boundary the native
app talks to.

Protocol, deliberately narrow:

  stdin   one JSON request object, then EOF
  stderr  newline-delimited JSON progress records, one per line
  stdout  one JSON response object

The worker performs no network access. Every document it needs -- the published
transcript, the episode page -- is fetched by the caller and passed in as text,
so the transport policy (HTTPS only, size caps, redirect rules) stays in one
place on the Swift side and no credentialed feed URL ever reaches this process.

Run it with the previous project's virtualenv and source tree on the path:

    PYTHONPATH=<wilted-old>/src <wilted-old>/.venv/bin/python wilted_pipeline.py
"""

from __future__ import annotations

import contextlib
import difflib
import errno
import fcntl
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

PROTOCOL_VERSION = 1

# Tools the audio cut shells out to. Checked before any work starts: a GUI app
# launched from Finder inherits a PATH without Homebrew, and finding that out
# after twelve minutes of speech-to-text is the wrong time.
CUT_TOOLS = ("ffmpeg", "ffprobe")

# The archived detector's existing positive-seed and content-resumption gates
# protect this generic explicit "brought to you ... by" fallback phrase.
LEGACY_SPONSOR_OPENING_COMPATIBILITY_PATTERN = (
    r"\bbrought\s+to\s+you(?:\s+(?:today|this\s+week))?\s+by\b"
)

# How much longer than its transcript a downloaded file may be before the
# transcript is treated as describing a different rendering of the episode.
#
# Podcast hosts insert advertising when the file is requested, so the same
# episode is served at different lengths to different listeners, while the
# published transcript describes whatever rendering the publisher transcribed.
# Timing taken from the wrong rendering is wrong for every second after the
# first insertion: the reading position drifts, and the ad cut is aimed at
# ordinary conversation.
#
# The floor is what a long outro of untranscribed music can legitimately add.
# The fraction keeps that proportionate on a three-hour show. An inserted ad
# pod is larger than either.
PUBLISHED_TRANSCRIPT_GAP_FLOOR_S = 45.0
PUBLISHED_TRANSCRIPT_GAP_FRACTION = 0.005

# A produced pre-roll runs before the programme's own opening: an inserted
# commercial, a trailer for another show, a network promo. It carries none of
# the evidence the explicit host-read recovery below looks for -- no "brought
# to you by", no sponsor domain, no call to action -- because nobody on the
# show reads it, and the coarse classifier does not reliably call it an ad
# either. Giant Bombcast 955 opened with fifty-two seconds of game commercial
# that every stage of the detector called content.
#
# The window is bounded on both time and count so the question stays one
# request, and a show that simply opens with a long cold open cannot be
# swallowed by a runaway answer.
PREROLL_RECOVERY_MAX_SECONDS = 300.0
PREROLL_RECOVERY_MAX_SEGMENTS = 96
# How far past the transcript's own first second a detection may begin and
# still count as having claimed the opening. Anything later leaves
# advertising in front of it.
PREROLL_ALREADY_CLAIMED_SECONDS = 1.0
# Below this a positive answer is more likely to be the model splitting a
# sentence than an advertisement worth cutting.
PREROLL_RECOVERY_MINIMUM_SECONDS = 10.0

PREROLL_PROGRAM_START_PROMPT = """\
The excerpt is the beginning of a podcast episode. Advertising is sometimes inserted before the
program starts: a produced commercial, a trailer for another show, or a promotional spot voiced by
someone who does not appear on this program. Find the first ID at which the program itself begins.
The program's own opening, its title, its host introductions, and unstructured banter all count as
program. Return 0 when the program begins immediately and nothing precedes it. Use only a supplied ID.
Return only the strict JSON object {"program_start_id": ID}, with no prose or Markdown."""

PREROLL_CONFIRM_PROMPT = """\
The excerpt is the opening of a podcast episode, believed to be entirely advertising or promotion
carried before the program starts. Find the first ID that belongs to the program itself rather than
to advertising or promotion. Host introductions, the show title, and unstructured banter belong to
the program. Return -1 when no supplied ID belongs to the program. Use only a supplied ID or -1.
Return only the strict JSON object {"program_id": ID}, with no prose or Markdown."""

# How much of the span a resize review may read. The same bound as the opening
# review: enough to find the boundary, not enough to become a second detector.
OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS = 96

# A cut lands on a segment edge, so a segment holding an advertisement's last
# words and the program's first words cannot be taken without taking the program
# with it. TechCrunch segment 9 is five seconds of Plaud call to action followed
# by "apple debuts its most powerful chip ever i'm imran shake and your daily
# crunch starts right now" and the first story, and the boundary question
# nominated the segment after it, which would have cut the episode title and the
# host introduction out of the file. Saying so in the boundary prompt did not
# change its answer, and saying it in the confirm prompt made that answer worse:
# the model started calling a pure sponsor read program. So it is asked
# separately, about one segment, which it answers correctly and repeatably.
BOUNDARY_SEGMENT_PROMPT = """\
The excerpt is one passage from a podcast episode, taken from inside a stretch of advertising.
Answer whether the program itself starts somewhere inside this passage. The program is the show's
own content: its title, its host introductions, its reporting or discussion. A passage that is
advertising from beginning to end does not start the program, even if the advertisement ends in it.
Return only the strict JSON object {"starts_program": true} or {"starts_program": false}, with no
prose or Markdown."""

OVERSIZED_SPAN_PROGRAM_START_PROMPT = """\
The excerpt is a passage from a podcast episode that a detector classified entirely as advertising,
and it is too long for that to be true. Find the first ID at which the program itself resumes. The
program's own reporting, discussion, interviews, host introductions, and unstructured banter all
count as program; read advertisements, sponsor messages, promotional spots for other shows, and
their calls to action do not. Return the first supplied ID when the passage is advertising
throughout. Use only a supplied ID.
Return only the strict JSON object {"program_start_id": ID}, with no prose or Markdown."""

OVERSIZED_SPAN_CONFIRM_PROMPT = """\
The excerpt is a passage from the middle of a podcast episode, believed to be entirely advertising
or promotion. Find the first ID that belongs to the program itself rather than to advertising or
promotion. The program's own reporting, discussion, interviews, host introductions, and unstructured
banter belong to the program. Return -1 when no supplied ID belongs to the program. Use only a
supplied ID or -1.
Return only the strict JSON object {"program_id": ID}, with no prose or Markdown."""

# How far back from the end a closing review may read, and the smallest thing it
# is allowed to cut. The same shape as the opening review's bounds, because it is
# the same question asked at the other edge of the file.
POSTROLL_RECOVERY_MAX_SECONDS = 300.0
POSTROLL_RECOVERY_MAX_SEGMENTS = 96
POSTROLL_ALREADY_CLAIMED_SECONDS = 1.0
POSTROLL_RECOVERY_MINIMUM_SECONDS = 10.0
# How much of the silence before a produced spot the cut may claim. The seam
# between the sign-off and the spot is the spot's own leader, and leaving it
# behind leaves the advertisement in: TechCrunch's is 6.3 seconds, The Daily's
# 4.2. The bound is there because a long silence might be untranscribed program
# audio rather than a leader, and the only thing at risk is the silence itself.
# The gap is never evidence, only a boundary. The two largest seams in The Daily
# are 9.9 seconds each and both fall between news stories.
POSTROLL_LEADER_MAX_SECONDS = 15.0

POSTROLL_PROGRAM_END_PROMPT = """\
The excerpt is the end of a podcast episode. Advertising is sometimes appended after the program
finishes: a produced commercial, or a promotional spot for a different show, voiced by someone who
does not appear on this program. Find the first ID at which the program has finished and appended
advertising runs from there to the end. The program's own sign-off, its credits, its thanks and
corrections, a teaser for its own next episode, and a request to subscribe to this show all count as
program. Return -1 when the program runs all the way to the end and nothing is appended. Use only a
supplied ID or -1.
Return only the strict JSON object {"advertising_start_id": ID}, with no prose or Markdown."""

POSTROLL_CONFIRM_PROMPT = """\
The excerpt is the end of a podcast episode, believed to be a commercial, or a promotion for a
different program, appended after this program finished. Find the first ID that belongs to this
program itself. Only this program's own voice counts: its reporting or discussion, its sign-off,
its credits, its thanks and corrections, or a teaser for its own next episode. A passage that
promotes a different show is advertising even when it asks the listener to subscribe, and a passage
selling a product is advertising however it ends. Most of the time nothing here belongs to the
program, and -1 is the expected answer. Use only a supplied ID or -1.
Return only the strict JSON object {"program_id": ID}, with no prose or Markdown."""

BOUNDARY_SEGMENT_TAIL_PROMPT = """\
The excerpt is one passage from the end of a podcast episode, taken from inside a stretch of
advertising. Answer whether the program itself is still running somewhere inside this passage. The
program is the show's own content: its reporting or discussion, its sign-off, its credits, its
thanks. A passage that is advertising from beginning to end does not carry the program, even if the
program ended just before it.
Return only the strict JSON object {"carries_program": true} or {"carries_program": false}, with no
prose or Markdown."""

EXPLICIT_SPONSOR_RECOVERY_MAX_SEGMENTS = 64
EXPLICIT_SPONSOR_RECOVERY_MAX_SECONDS = 10 * 60
EXPLICIT_SPONSOR_RESUMPTION_TAIL_SEGMENTS = 32
# What a host read tells the listener to do. "check it out" was here and
# "check them out" was not, which is the difference between a sponsor and a
# person, and hosts say both.
EXPLICIT_SPONSOR_CTA_RE = re.compile(
    r"\b(?:learn|find\s+out|hear)\s+more\b|\bget\s+started\b|"
    r"\b(?:go\s+)?check\s+(?:it|them|us|these|those|that|him|her)\s+out\b|"
    r"\bgo\s+(?:check|see|read|grab|watch)\b|\bhead\s+(?:on\s+)?(?:over\s+)?to\b|"
    r"\bsign\s+up\b|\bsubscribe\b|\bfree\s+trial\b|\border\s+(?:now|today)\b|"
    r"\b(?:directly\s+)?support\s+(?:us|them|the\s+show|at)\b|\bavailable\s+(?:now\s+)?(?:at|on)\b|"
    r"\bdownload\b|\bjoin\b|\bvisit\b|\bgo\s+to\b",
    re.IGNORECASE,
)
# Where a host read sends the listener. The detector reads an unpunctuated
# transcript, so the spoken form carries most of these; the written form is
# here for a published transcript, which does have orthography.
#
# The top-level domain lists were com/ai/org/net and com/co/io/net/org/tv/ai,
# which is a 2005 view of the namespace. Giant Bombcast 955 sends listeners to
# videogame.town, and neither list had ever heard of it.
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
# A spoken web address on a platform the sponsor does not own. "patreon slash
# videogametown" is an address; "writer slash producer" is a figure of speech,
# so only the platforms are accepted, never a bare slash.
EXPLICIT_SPONSOR_SPOKEN_PATH_RE = re.compile(
    r"\b(?:patreon|youtube|instagram|twitter|facebook|tiktok|twitch|reddit|"
    r"linktree|discord|substack|bandcamp|kickstarter)\s+slash\b",
    re.IGNORECASE,
)
# An offer code is a place to act even when no address is spoken.
EXPLICIT_SPONSOR_OFFER_CODE_RE = re.compile(
    r"\b(?:promo|offer|coupon|discount)\s+code\b|\buse\s+(?:the\s+)?code\b|"
    r"\bcode\s+[a-z0-9]{3,}\s+at\s+checkout\b",
    re.IGNORECASE,
)
# How often the sponsor's own name has to come back before recurrence counts
# as advertising copy rather than a subject someone happens to be discussing.
EXPLICIT_SPONSOR_NAME_MAX_WORDS = 4
EXPLICIT_SPONSOR_NAME_MINIMUM_CHARACTERS = 6
EXPLICIT_SPONSOR_NAME_MINIMUM_REPEATS = 3
# Recurrence only counts while it is dense. A ten-minute window is long enough
# for a topic to be named this often honestly; ninety seconds of it is a read.
EXPLICIT_SPONSOR_NAME_WINDOW_SECONDS = 90.0
EXPLICIT_SPONSOR_NAME_WORD_RE = re.compile(r"[a-z0-9][a-z0-9'’]*", re.IGNORECASE)
# Words a host read starts with before it reaches the sponsor, which must not
# become the phrase whose recurrence is counted.
EXPLICIT_SPONSOR_NAME_LEADING_FILLER = frozenset(
    {"the", "a", "an", "our", "my", "your", "this", "today", "todays", "good", "folks", "fine", "great"}
)
STT_EVICTION_BARRIER_POLL_INTERVAL_S = 0.1
GPU_LOCK_PROGRESS_INTERVAL_S = 1.0
ALIGNED_STT_MODEL = "mlx-community/parakeet-tdt-1.1b"
ALIGNED_STT_CACHE_SCHEMA_VERSION = 1
ALIGNED_STT_CACHE_MAXIMUM_ENTRIES = 32

# The broker acknowledges EVICT before its inference thread actually releases
# a resident model. A following FIFO selftest is the completion barrier; keep
# it bounded so a wedged daemon produces an actionable worker failure.
STT_EVICTION_BARRIER_TIMEOUT_S = 10.0

# How long to wait for a shared GPU inference lock somebody else is holding.
# The eviction barrier above was doing double duty as this bound, and the two
# measure different things: ten seconds is long for a daemon that has stopped
# answering and absurdly short for a peer that legitimately holds the GPU for
# the length of a detect run. Three episodes downloaded at once cost two whole
# preparations to that conflation, each failing with `ads-model-wait-failed`
# ten seconds into a wait that was going to be fine. Waiting is the correct
# behaviour, and `ads.model.wait` reports it every second while it happens.
GPU_LOCK_ACQUISITION_TIMEOUT_S = 30 * 60.0

# A detected span that covers most of the episode is not an advertisement, it is
# a detection failure, and size alone tells the two apart. The archived detector
# brackets an ad that goes out and comes back as one pod, bounded at ten minutes
# and 128 segments -- bounds written for a two-hour show. On a nine-minute one
# they reach across the whole programme: TechCrunch Daily was cut from 9:23 to
# 1:52 by a single `sponsor_read` running 0:07 to 7:37, which held the two real
# reads at either end and every news item between them. Uncut audio is
# recoverable and over-cut audio is not, because preparation writes over the
# download, so a span this size is dropped and said out loud rather than obeyed.
MAXIMUM_SINGLE_AD_SHARE = 0.5
MAXIMUM_TOTAL_AD_SHARE = 0.6

# How many of the previous project's warnings are relayed verbatim before the
# rest are counted. The ad detector logs one warning per failed batch and
# halves down to singletons, so a dead backend produces thousands.
FORWARDED_WARNING_LIMIT = 20

# Media types whose timing the publisher states. Mirrors
# WiltedDomain.PodcastTranscriptSource.timedMediaTypes; the two must agree,
# because the Swift side decides what to send based on its copy and this side
# decides what to parse based on this one.
TIMED_MEDIA_TYPES = {
    "text/vtt": "vtt",
    "application/x-subrip": "srt",
    "application/srt": "srt",
    "text/srt": "srt",
    "application/json": "podcast-json",
}

# Below this, an extracted web page is show notes rather than a transcript.
# Carried over from the previous pipeline's own threshold.
MINIMUM_PROSE_WORDS = 500


class WorkerError(RuntimeError):
    """A failure that should be reported as a structured result, not a crash."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------


def progress(stage: str, detail: str = "", fraction: float | None = None) -> None:
    """Emit one progress record on stderr.

    Every stage below is minutes long on a real episode. A caller with no
    feedback channel cannot tell a working transcription from a hung one, so
    this is part of the contract rather than logging.
    """
    record = {"stage": stage, "detail": detail}
    if fraction is not None:
        record["fraction"] = round(max(0.0, min(1.0, fraction)), 4)
    sys.stderr.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stderr.flush()


class ForwardedWarnings(logging.Handler):
    """Relay WARNING+ log records from every library in this process as progress.

    The previous project reports trouble through `logging`. With no handler
    installed, Python's last-resort handler printed those lines to raw stderr,
    where the Swift collector discards anything that is not a JSON record --
    so the thousands of "Model not loaded" warnings that explained the TWiT
    1098 false negative were thrown away. Each relayed record gets its own
    numbered stage because the journal keeps one row per stage.
    """

    def __init__(self, limit: int = FORWARDED_WARNING_LIMIT):
        super().__init__(level=logging.WARNING)
        self.limit = limit
        self.forwarded = 0
        self.suppressed = 0

    def emit(self, record: logging.LogRecord) -> None:
        if self.forwarded >= self.limit:
            self.suppressed += 1
            return
        self.forwarded += 1
        try:
            progress(f"log.{record.levelname.lower()}.{self.forwarded}", f"{record.name}: {record.getMessage()}")
        except Exception:  # noqa: BLE001 - a handler must never unwind its caller
            self.handleError(record)

    def summarize(self) -> None:
        if self.suppressed:
            progress("log.suppressed", f"{self.suppressed} further warnings not relayed")


# How many discarded runs to name before reporting only the count.
DISCARDED_RUN_REPORT_LIMIT = 12


class DiscardedRuns(logging.Handler):
    """Collect the archived detector's own notices about runs it threw away.

    The detector flags a span, fails to evidence it, and drops it with a line
    at INFO -- which the WARNING+ forwarder above never sees. That left a real
    question unanswerable: The Daily's closing Chase Sapphire spot was missing
    from the output and nothing in the journal said whether it had been flagged
    and then dropped for lacking a price or an address, or never flagged at
    all. Those two want different fixes, so the difference is worth one line.
    """

    def __init__(self, segments, limit: int = DISCARDED_RUN_REPORT_LIMIT):
        super().__init__(level=logging.INFO)
        self.segments = segments
        self.limit = limit
        self.notices: list[str] = []
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        try:
            message = record.getMessage()
            if not message.startswith("Discarding"):
                return
            self.count += 1
            if len(self.notices) < self.limit:
                self.notices.append(self._with_times(message))
        except Exception:  # noqa: BLE001 - a handler must never unwind its caller
            self.handleError(record)

    def _with_times(self, message: str) -> str:
        """Add the run's clock times, because a segment ID means nothing later."""
        found = re.search(r"\b(\d+)-(\d+)\b", message)
        if not found:
            return message
        first, last = int(found.group(1)), int(found.group(2))
        if not 0 <= first <= last < len(self.segments):
            return message
        span = f"{float(self.segments[first].start_s):.1f}-{float(self.segments[last].end_s):.1f}s"
        return f"{message} ({span})"

    def summarize(self) -> None:
        if not self.count:
            return
        detail = "; ".join(self.notices)
        if self.count > len(self.notices):
            detail += f"; and {self.count - len(self.notices)} more"
        progress("ads.detect.discarded", f"{self.count} flagged runs dropped: {detail}")


# ---------------------------------------------------------------------------
# Cue timing
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class KeepInterval:
    """One span of the original audio that survives the cut."""

    start_s: float
    end_s: float
    output_start_s: float

    @property
    def duration_s(self) -> float:
        return self.end_s - self.start_s


@dataclass(frozen=True)
class CachedAlignedSegment:
    """The detector-compatible shape reconstructed from an aligned STT cache."""

    text: str
    start_s: float
    end_s: float


def build_keep_map(keep_segments: list[tuple[float, float]]) -> list[KeepInterval]:
    """Turn ffmpeg's keep spans into a map from original time to output time."""
    intervals: list[KeepInterval] = []
    output = 0.0
    for start, end in keep_segments:
        if end <= start:
            continue
        intervals.append(KeepInterval(start_s=start, end_s=end, output_start_s=output))
        output += end - start
    return intervals


def serialize_keep_map(keeps: list[KeepInterval]) -> list[dict]:
    """Round one self-consistent original-to-output map for the Swift contract."""
    serialized: list[dict] = []
    output = 0.0
    for keep in keeps:
        start, end = round(keep.start_s, 3), round(keep.end_s, 3)
        serialized.append({
            "startSeconds": start,
            "endSeconds": end,
            "outputStartSeconds": round(output, 3),
        })
        output += end - start
    return serialized


def remap_cues(cues: list[dict], keeps: list[KeepInterval]) -> list[dict]:
    """Move cue timing onto the cut audio's clock.

    Cutting ads shifts every timestamp after the first cut, so a transcript
    that was synchronised with the download is wrong the moment the file is
    rewritten. The previous pipeline never did this -- its transcript was read,
    not followed -- which is why this is new code rather than a port.

    A cue landing entirely inside a removed span is dropped. A cue straddling a
    boundary keeps its whole text and is bracketed by the surviving audio: the
    text may then include a few words that were cut, which is a smaller error
    than dropping a line of real content or leaving the timing pointing at
    audio that no longer exists.
    """
    if not keeps:
        return []
    remapped: list[dict] = []
    for cue in cues:
        start, end = float(cue["startSeconds"]), float(cue["endSeconds"])
        covered = [k for k in keeps if k.end_s > start and k.start_s < end]
        if not covered:
            continue
        first, last = covered[0], covered[-1]
        new_start = first.output_start_s + max(0.0, start - first.start_s)
        new_end = last.output_start_s + min(last.duration_s, max(0.0, end - last.start_s))
        if new_end < new_start:
            new_end = new_start
        remapped.append({
            "startSeconds": round(new_start, 3),
            "endSeconds": round(new_end, 3),
            "text": cue["text"],
        })
    # Cutting can pull two cues onto the same instant. Order is a contract
    # invariant on the Swift side, so it is restored here rather than there.
    remapped.sort(key=lambda c: c["startSeconds"])
    return remapped


def in_time_order(segments):
    """Return the segments in the order every consumer already assumes.

    Speech-to-text runs in 120-second GPU windows with 15 seconds of overlap,
    and stitching those windows can emit a segment that starts before the one
    ahead of it. The display cues never showed it because `segments_to_cues`
    sorts, but the detector is handed this list unsorted and reads it by
    position: which segments fall in a classification window, where a coarse
    run begins and ends, and which segment the opening review calls first all
    depend on the order being time order. The aligned cache is the only thing
    that ever objected, and it objects by declining to save, so every episode
    paid for speech-to-text twice and nothing said why.
    """
    # A tier that found nothing returns None, and "nothing, in order" is still
    # nothing; sorting is not the place to turn that into an empty list.
    if not segments:
        return segments
    return sorted(segments, key=lambda segment: (float(segment.start_s), float(segment.end_s)))


def segments_to_cues(segments) -> list[dict]:
    """Project the previous pipeline's segments onto the cue contract.

    Token-level timing is dropped on purpose: it is input to ad-boundary
    refinement, not durable state, and keeping it would multiply the stored
    transcript several times over for no reading benefit.
    """
    cues: list[dict] = []
    for segment in segments:
        text = (segment.text or "").strip()
        if not text:
            continue
        start = max(0.0, float(segment.start_s))
        end = max(start, float(segment.end_s))
        cues.append({"startSeconds": round(start, 3), "endSeconds": round(end, 3), "text": text})
    cues.sort(key=lambda c: c["startSeconds"])
    return cues


def cues_to_text(cues: list[dict]) -> str:
    return " ".join(cue["text"] for cue in cues).strip()


# ---------------------------------------------------------------------------
# Show-notes glossary
# ---------------------------------------------------------------------------
#
# Speech-to-text writes every name the way it sounds, in lower case, and the
# feed's notes spell the same hosts, guests, products, and sponsors correctly.
# There is no way to hand parakeet a vocabulary, and an LLM rewrite of a
# three-hour transcript measured at seven tokens a second, so the notes are
# applied afterwards, deterministically: exact lower-case hits take the notes'
# casing, and near-misses ("the rot" for "Thurrott") take the spelling when
# the letters are close enough and the target is not an ordinary word.

SYSTEM_DICTIONARY = Path("/usr/share/dict/words")
GLOSSARY_STOPWORDS = frozenset("""
a an and are as at be but by for from he her his how i if in is it its of on or our she so
that the their them they this to us was we what when where which who why will with you your
new big go join today download subscribe support host hosts guest guests sponsor sponsors
podcast podcasts episode episodes show shows club ad free audio video feed feeds discord
content members exclusive
""".split())
GLOSSARY_MINIMUM_SIMILARITY = 0.8
GLOSSARY_MINIMUM_FUZZY_LETTERS = 6
GLOSSARY_MAXIMUM_TERMS = 200
# Letters in any script, not [A-Za-z]: "Söderberg" is one word, not "S" and
# "derberg". [^\W_] is Unicode-aware alphanumerics without the underscore.
_WORD = re.compile(r"[^\W_][^\W_'&.-]*(?:['&.-][^\W_]+)*")
_LABEL = re.compile(r"\s*(?:[-*\u2022]\s*)?[A-Za-z][A-Za-z ]{0,24}:\s+")
_MARKS = ".,;:?!\"'()[]\u201c\u201d\u2018\u2019"
_EDGE_MARKS = re.compile(r"^[\"'(\[\u201c\u2018]*")
_TRAILING_MARKS = re.compile(r"[.,;:?!\"')\]\u201d\u2019]*$")
_URL = re.compile(r"(?:https?://)?(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?:/[^\s)]*)?", re.IGNORECASE)


# The system word list predates the web; these are the ordinary words that
# tech headlines capitalize and it does not know.
DICTIONARY_SUPPLEMENT = frozenset("""
online offline tech email internet website websites smartphone smartphones startup startups
chatbot chatbots crypto blockchain cloud streaming laptop laptops wifi bluetooth software hardware
gaming gamer gamers robotaxi robotaxis rideshare tablet tablets browser browsers spyware malware
ransomware hacker hackers hack hacks login logins password passwords upload uploads download downloads
subscription subscriptions app apps ebook ebooks podcast podcasts livestream vlog blog blogs meme memes
selfie selfies emoji emojis texting tweet tweets
""".split())


def _load_dictionary() -> frozenset[str]:
    try:
        words = SYSTEM_DICTIONARY.read_text().splitlines()
    except OSError:
        words = []
    return frozenset(w.strip().lower() for w in words if w.strip()) | DICTIONARY_SUPPLEMENT


def _is_capitalized(token: str) -> bool:
    return token[:1].isupper() and any(c.islower() for c in token[1:]) or (token.isupper() and len(token) >= 2)


def _in_dictionary(word: str, dictionary: frozenset[str]) -> bool:
    """Whether `word` or its plain inflection is an ordinary word.

    The system word list carries base forms only, so "platforms", "seems",
    and "conceding" all miss it without this.
    """
    word = word.lower()
    if word in dictionary:
        return True
    stems = []
    for suffix in ("'s", "s", "es", "ed", "ing"):
        if word.endswith(suffix) and len(word) - len(suffix) >= 3:
            stems.append(word[: -len(suffix)])
            if suffix in ("ed", "ing"):
                stems.append(word[: -len(suffix)] + "e")
    return any(stem in dictionary for stem in stems)


def _clean_token(token: str) -> str:
    """A notes token as a name: no possessive, no acronym dots, no edge marks."""
    token = token.strip("'&.-")
    if token.lower().endswith("'s"):
        token = token[:-2]
    if re.fullmatch(r"(?:[A-Za-z]\.)+[A-Za-z]?", token):
        token = token.replace(".", "")
    return token.strip("'&.-")


def build_glossary(notes: str, title: str = "", dictionary: frozenset[str] | None = None) -> list[str]:
    """Names, products, and sites the notes spell out, longest first.

    A phrase is a run of capitalized tokens inside a sentence. Headline lines
    (most tokens capitalized) contribute only tokens outside the dictionary,
    because "Will Force Online Platforms" is not anyone's name. A single token
    qualifies when it is never written in lower case anywhere in the notes and
    is not a stopword; a dictionary word ("apple", "flock") also has to appear
    capitalized more than once so a sentence-initial "Police" does not count.
    """
    dictionary = _load_dictionary() if dictionary is None else dictionary
    text = f"{title}\n{notes or ''}"
    lowercase_seen = {t.lower() for t in _WORD.findall(text) if t[:1].islower()}
    capitalized_count: dict[str, int] = {}
    phrases: dict[str, str] = {}
    singles: dict[str, str] = {}
    domains: dict[str, str] = {}

    for match in _URL.finditer(text):
        host = match.group(1).lower()
        if "." in host:
            domains[host] = host

    for line in text.splitlines():
        # "Host: Leo Laporte" and "Guests: A, B and C" are lists of names,
        # however capitalized; the label itself is not one.
        labelled = _LABEL.match(line)
        if labelled:
            line = line[labelled.end():]
        tokens = [_clean_token(t) for t in _WORD.findall(_URL.sub(" ", line))]
        tokens = [t for t in tokens if t]
        if not tokens:
            continue
        capitalized = [_is_capitalized(t) for t in tokens]
        headline = not labelled and len(tokens) >= 4 and sum(capitalized) / len(tokens) > 0.6
        for token, is_cap in zip(tokens, capitalized):
            if is_cap:
                capitalized_count[token] = capitalized_count.get(token, 0) + 1
        if headline:
            # "Will Force Online Platforms" is a headline, not a name; only
            # what no dictionary knows ("Waymo", "NVIDIA", "DMA") survives.
            for token, is_cap in zip(tokens, capitalized):
                if not is_cap or _in_dictionary(token, dictionary) or token.lower() in GLOSSARY_STOPWORDS:
                    continue
                if len(token) >= 4 or (token.isupper() and len(token) >= 3):
                    singles.setdefault(token.lower(), token)
            continue
        run: list[str] = []
        # Sentence-initial tokens are capitalized for grammar, not identity.
        for index, (token, is_cap) in enumerate(zip(tokens, capitalized)):
            starts_sentence = index == 0
            if is_cap and not (starts_sentence and token.lower() in GLOSSARY_STOPWORDS):
                run.append(token)
            else:
                _close_run(run, phrases, singles, starts_sentence=index - len(run) == 0)
                run = []
        _close_run(run, phrases, singles, starts_sentence=len(run) == len(tokens))

    # "Meta" and "Apple" are ordinary words that open sentences and headlines;
    # written capitalized three times and never otherwise, they are names.
    for token, count in capitalized_count.items():
        if count >= 3:
            singles.setdefault(token.lower(), token)

    terms: dict[str, str] = {}
    for key, value in phrases.items():
        if not all(t.lower() in GLOSSARY_STOPWORDS for t in value.split()):
            terms[key] = value
    for key, value in singles.items():
        if key in GLOSSARY_STOPWORDS or key in lowercase_seen or len(key) < 3:
            continue
        if _in_dictionary(key, dictionary):
            # A dictionary word earns its casing by repetition, and "US" or
            # "AI" would silence every "us" and "ai" spoken as a word.
            if capitalized_count.get(value, 0) < 3 or (value.isupper() and len(value) < 3):
                continue
        terms.setdefault(key, value)
    for key, value in domains.items():
        terms.setdefault(key, value)
    ordered = sorted(terms.values(), key=lambda t: (-len(t.split()), -len(t), t.lower()))
    return ordered[:GLOSSARY_MAXIMUM_TERMS]


def _close_run(run: list[str], phrases: dict[str, str], singles: dict[str, str], *, starts_sentence: bool) -> None:
    if not run:
        return
    while run and run[0].lower() in GLOSSARY_STOPWORDS:
        run = run[1:]
    while run and run[-1].lower() in GLOSSARY_STOPWORDS:
        run = run[:-1]
    if len(run) >= 2:
        phrases.setdefault(" ".join(run).lower(), " ".join(run))
        for token in run:
            singles.setdefault(token.lower(), token)
    elif len(run) == 1 and not starts_sentence:
        singles.setdefault(run[0].lower(), run[0])


def _spoken(term: str) -> list[str]:
    """The words speech-to-text would write for a term: a site is said "dot"."""
    return [w for w in re.split(r"[\s]+", term.lower().replace(".", " dot ")) if w]


def _fold(text: str) -> str:
    """Lower case with diacritics removed: "Söderberg" and "soderberg" agree,
    which is how speech-to-text tends to write a name it has not seen."""
    decomposed = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in decomposed if not unicodedata.combining(c))


def _squash(words: list[str]) -> str:
    return re.sub(r"[^a-z0-9]", "", _fold("".join(words)))


def apply_glossary(
    cues: list[dict], glossary: list[str], dictionary: frozenset[str] | None = None,
    on_progress=None,
) -> tuple[list[dict], int]:
    """Rewrite cue text with the glossary; returns the cues and the edit count.

    Exact lower-case hits take the notes' casing. A near-miss is replaced only
    when the squashed letters are at least 80% similar, the window is not
    itself made of dictionary words spelled correctly, and the term is not a
    plain dictionary word -- misreading "flock" into every "block" would be
    worse than the lower case it fixes.

    Cost is cues x terms, and a notes-dense episode reaches 200 terms over
    1,300 cues, so each cue's word forms are computed once and a term is
    tried at a word only when that word could begin it. `on_progress(done,
    total)` is called every few hundred cues; the caller owns the surface.
    """
    if not cues or not glossary:
        return cues, 0
    dictionary = _load_dictionary() if dictionary is None else dictionary
    entries = []
    for term in glossary:
        spoken = _spoken(term)
        squashed = _squash(spoken)
        fuzzy = (
            len(squashed) >= GLOSSARY_MINIMUM_FUZZY_LETTERS
            and not (len(spoken) == 1 and _in_dictionary(spoken[0], dictionary))
        )
        entries.append((spoken, term, fuzzy, squashed, squashed[:1]))
    edits = 0
    rewritten: list[dict] = []
    total = len(cues)
    for done, cue in enumerate(cues):
        if on_progress and done and done % 250 == 0:
            on_progress(done, total)
        words = cue["text"].split()
        forms = [_WordForm.of(w) for w in words]
        # A replaced span is final: "Leo Laporte" must not be re-read as a
        # near-miss of "Laporte" by the next, shorter term.
        locked = [False] * len(words)
        changed = False
        for spoken, term, fuzzy, squashed, initial in entries:
            first = spoken[0]
            index = 0
            while index < len(words):
                if locked[index]:
                    index += 1
                    continue
                form = forms[index]
                # An exact hit starts with the term's first word; a near-miss
                # starts with its first letter. Anything else cannot match.
                if form.stem != first and not (fuzzy and form.squashed[:1] == initial):
                    index += 1
                    continue
                hit = _glossary_window(words, forms, index, spoken, term, fuzzy, squashed, dictionary)
                if hit and not any(locked[index:index + hit[0]]):
                    size, replacement = hit
                    words[index:index + size] = [replacement]
                    forms[index:index + size] = [_WordForm.of(replacement)]
                    locked[index:index + size] = [True]
                    changed = True
                    edits += 1
                index += 1
        if changed:
            cue = dict(cue, text=" ".join(words))
        rewritten.append(cue)
    return rewritten, edits


@dataclass(frozen=True)
class _WordForm:
    """One transcript word, with the marks around it and its comparable forms
    worked out once rather than per glossary term."""

    raw: str
    lead: str
    trail: str
    bare: str
    lower: str
    stem: str  # lower without a trailing possessive: "meta's" begins "Meta"
    squashed: str

    @classmethod
    def of(cls, raw: str) -> "_WordForm":
        bare = raw.strip(_MARKS)
        lower = bare.lower()
        stem = lower[:-2] if lower.endswith("'s") and len(lower) > 2 else lower
        return cls(
            raw=raw,
            lead=_EDGE_MARKS.match(raw).group(0),
            trail=_TRAILING_MARKS.search(raw).group(0),
            bare=bare,
            lower=lower,
            stem=stem,
            squashed=_squash([bare]),
        )


def _glossary_window(
    words: list[str], forms: list[_WordForm], index: int, spoken: list[str], term: str,
    fuzzy: bool, squashed: str, dictionary: frozenset[str],
) -> tuple[int, str] | None:
    """The words at `index` that say `term`, as (count, replacement), or None.

    The spoken form may split differently from the written one ("air tag",
    "adaptive security dot com"), so every window up to one word longer than
    the term is tried and the closest wins. A trailing possessive survives.
    """
    best: tuple[float, int, str] | None = None
    for size in range(1, len(spoken) + 2):
        raw = words[index:index + size]
        if len(raw) < size:
            break
        window = forms[index:index + size]
        # A punctuating transcript writes "Abuelsamid." and "(Waymo)"; the
        # marks around the name go back around the corrected one.
        lead = window[0].lead
        trail = window[-1].trail
        if not all(form.bare for form in window):
            continue
        last = window[-1].bare
        possessive = last.lower().endswith("'s") and len(last) > 2
        lowered = [form.lower for form in window]
        bare = [form.bare for form in window]
        if possessive:
            lowered[-1] = lowered[-1][:-2]
            bare[-1] = last[:-2]
        replacement = lead + term + ("'s" if possessive else "") + trail
        if lowered == spoken:
            if " ".join(raw) == replacement:
                return None
            return size, replacement
        if not fuzzy:
            continue
        if lowered[0] in GLOSSARY_STOPWORDS or lowered[-1] in GLOSSARY_STOPWORDS:
            continue
        candidate = _squash(bare) if possessive else "".join(form.squashed for form in window)
        if not candidate or abs(len(candidate) - len(squashed)) > 3 or candidate[0] != squashed[0]:
            continue
        if candidate == squashed:
            return size, replacement
        # One spoken word is never a whole multi-word name: "laporte" is
        # close to "Leo Laporte", and putting "Leo" in the mouth is a lie.
        if size == 1 and len(spoken) > 1:
            continue
        # Real words that happen to sound like a name are still those words:
        # "using" is not "Usain", and "plate for" is not "Platforms".
        if all(_in_dictionary(w, dictionary) for w in bare):
            continue
        matcher = difflib.SequenceMatcher(None, candidate, squashed)
        if matcher.quick_ratio() < GLOSSARY_MINIMUM_SIMILARITY:
            continue
        ratio = matcher.ratio()
        if ratio >= GLOSSARY_MINIMUM_SIMILARITY and (best is None or ratio > best[0]):
            best = (ratio, size, replacement)
    return (best[1], best[2]) if best else None


def polish_with_notes(request: dict, cues: list[dict]) -> list[dict]:
    """The glossary stage: never fatal, always reported."""
    notes = request.get("episodeNotes") or ""
    title = request.get("episodeTitle") or ""
    if not cues or not (notes or title):
        return cues
    try:
        glossary = build_glossary(notes, title)
        progress("transcript.glossary.terms", f"{len(glossary)} terms from the show notes")
        if not glossary:
            return cues
        cues, edits = apply_glossary(
            cues, glossary,
            on_progress=lambda done, total: progress("transcript.glossary.progress", f"{done} of {total} cues"),
        )
        progress("transcript.glossary.complete", f"{edits} corrections")
        return cues
    except Exception as error:  # noqa: BLE001 - a polish failure must not cost the transcript
        progress("transcript.glossary.failed", f"{type(error).__name__}: {error}")
        return cues


# ---------------------------------------------------------------------------
# Transcript sourcing
# ---------------------------------------------------------------------------


def parse_published_transcript(body: str, media_type: str, url: str):
    """Parse a transcript the feed published, or return None if unusable."""
    from wilted import transcribe

    parsers = {
        "vtt": transcribe.parse_vtt,
        "srt": transcribe.parse_srt,
        "podcast-json": transcribe.parse_podcast_json,
    }
    kind = TIMED_MEDIA_TYPES.get(media_type.strip().lower())
    if kind is None:
        # The type attribute is advisory and publishers get it wrong. Falling
        # back to the extension recovers a real transcript that would
        # otherwise be thrown away for a typo.
        lowered = url.lower()
        for extension, guess in ((".vtt", "vtt"), (".srt", "srt"), (".json", "podcast-json")):
            if lowered.endswith(extension):
                kind = guess
                break
    if kind is None:
        return None
    try:
        return parsers[kind](body) or None
    except Exception as error:  # noqa: BLE001 - a bad transcript is not a failed episode
        progress("transcript.published.unparseable", f"{kind}: {error}")
        return None


def published_transcript_matches_audio(segments, audio_path: Path) -> bool:
    """Return whether a published transcript's timing describes this audio.

    The measurement is emitted either way. A single accepted episode says
    nothing about where the threshold belongs, so every preparation records
    what it saw and the journal becomes the evidence a later adjustment needs.
    """
    try:
        audio_seconds = probe_duration(audio_path)
    except Exception as error:  # noqa: BLE001 - the guard checks the transcript, not the episode
        # A transcript that cannot be checked is still the best timing there
        # is. Failing the episode because ffprobe was unavailable would trade
        # a possible misalignment for a certain loss.
        progress("transcript.published.unverified", f"{type(error).__name__}: {error}")
        return True
    transcript_seconds = max((float(segment.end_s) for segment in segments), default=0.0)
    gap = audio_seconds - transcript_seconds
    tolerance = max(PUBLISHED_TRANSCRIPT_GAP_FLOOR_S, PUBLISHED_TRANSCRIPT_GAP_FRACTION * audio_seconds)
    detail = (f"audio {audio_seconds:.1f}s, transcript ends {transcript_seconds:.1f}s, "
              f"gap {gap:.1f}s, tolerance {tolerance:.1f}s")
    if gap > tolerance:
        progress("transcript.published.misaligned", detail)
        return False
    progress("transcript.published.aligned", detail)
    return True


def extract_prose(html: str) -> str | None:
    """Pull readable prose out of an episode page, or None if it is show notes.

    The result carries no timing and is never presented as if it did. The
    previous pipeline estimated timestamps here at 150 words per minute; that
    number is a guess about a page, not a measurement of audio, and it cannot
    drive a reading position or an audio cut.
    """
    import trafilatura

    try:
        text = trafilatura.extract(html)
    except Exception:  # noqa: BLE001
        return None
    if not text:
        return None
    return text if len(text.split()) >= MINIMUM_PROSE_WORDS else None


def _aligned_cache_directory(request: dict) -> Path | None:
    """Return this request's private aligned-STT cache directory, when keyed."""
    source_hash = request.get("sourceHash")
    model = request.get("alignedTranscriptModel")
    if not isinstance(source_hash, str) or not source_hash or not isinstance(model, str) or not model:
        return None
    return Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline" / "aligned-stt-cache"


def _aligned_cache_path(cache_directory: Path, source_hash: str, model: str) -> Path:
    """Give one opaque, filesystem-safe path to a source hash/model pair."""
    digest = sha256(f"{ALIGNED_STT_CACHE_SCHEMA_VERSION}\0{source_hash}\0{model}".encode()).hexdigest()
    return cache_directory / f"{digest}.json"


def _discard_aligned_cache_entry(path: Path) -> None:
    """Best-effort cleanup for one cache artifact, including an interrupted directory."""
    try:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
    except OSError:
        pass


def _decode_cached_aligned_segments(payload: object, *, source_hash: str | None = None,
                                    model: str | None = None) -> list[CachedAlignedSegment]:
    """Validate a cache record and rebuild precisely the attributes ads needs."""
    if not isinstance(payload, dict) or payload.get("schemaVersion") != ALIGNED_STT_CACHE_SCHEMA_VERSION:
        raise ValueError("unsupported cache schema")
    if not isinstance(payload.get("sourceHash"), str) or not payload["sourceHash"]:
        raise ValueError("missing source hash")
    if not isinstance(payload.get("model"), str) or not payload["model"]:
        raise ValueError("missing model")
    if source_hash is not None and payload["sourceHash"] != source_hash:
        raise ValueError("source hash does not match cache key")
    if model is not None and payload["model"] != model:
        raise ValueError("model does not match cache key")
    raw_segments = payload.get("segments")
    if not isinstance(raw_segments, list):
        raise ValueError("missing segments")
    segments: list[CachedAlignedSegment] = []
    previous_start = -1.0
    for raw in raw_segments:
        if not isinstance(raw, dict) or not isinstance(raw.get("text"), str) or not raw["text"].strip():
            raise ValueError("invalid cached segment text")
        start, end = raw.get("start_s"), raw.get("end_s")
        if type(start) not in (int, float) or type(end) not in (int, float):
            raise ValueError("invalid cached segment timing")
        start, end = float(start), float(end)
        if not start >= 0 or not start < end or not start < float("inf") or not end < float("inf"):
            raise ValueError("invalid cached segment timing")
        if start < previous_start:
            raise ValueError("out-of-order cached segments")
        segments.append(CachedAlignedSegment(text=raw["text"], start_s=start, end_s=end))
        previous_start = start
    return segments


def _cache_record(segments, source_hash: str, model: str) -> dict:
    """Serialize only the stable detector contract, never parser/model internals."""
    record_segments = []
    for segment in segments:
        text = getattr(segment, "text", None)
        start, end = getattr(segment, "start_s", None), getattr(segment, "end_s", None)
        if not isinstance(text, str) or not text.strip() or type(start) not in (int, float) or type(end) not in (int, float):
            raise ValueError("invalid aligned STT segment")
        start, end = float(start), float(end)
        if not start >= 0 or not start < end or not start < float("inf") or not end < float("inf"):
            raise ValueError("invalid aligned STT segment")
        if record_segments and start < record_segments[-1]["start_s"]:
            raise ValueError("out-of-order aligned STT segments")
        record_segments.append({"text": text, "start_s": start, "end_s": end})
    return {
        "schemaVersion": ALIGNED_STT_CACHE_SCHEMA_VERSION,
        "sourceHash": source_hash,
        "model": model,
        "segments": record_segments,
    }


def _prune_aligned_stt_cache(cache_directory: Path) -> None:
    """Remove temporary/corrupt entries and retain the 32 most-recent valid ones."""
    try:
        entries = list(cache_directory.iterdir())
    except OSError:
        return
    valid: list[Path] = []
    for entry in entries:
        if not entry.is_file() or entry.suffix != ".json":
            _discard_aligned_cache_entry(entry)
            continue
        try:
            payload = json.loads(entry.read_text(encoding="utf-8"))
            _decode_cached_aligned_segments(payload)
            if entry != _aligned_cache_path(cache_directory, payload["sourceHash"], payload["model"]):
                raise ValueError("cache file does not match its key")
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            _discard_aligned_cache_entry(entry)
            continue
        valid.append(entry)
    valid.sort(key=lambda entry: entry.stat().st_mtime_ns, reverse=True)
    for entry in valid[ALIGNED_STT_CACHE_MAXIMUM_ENTRIES:]:
        _discard_aligned_cache_entry(entry)


def _load_cached_aligned_segments(request: dict, source_hash: str, model: str) -> list[CachedAlignedSegment] | None:
    """Load a matching cache entry, deleting it before a fresh STT retry if bad."""
    cache_directory = _aligned_cache_directory(request)
    if cache_directory is None:
        return None
    path = _aligned_cache_path(cache_directory, source_hash, model)
    try:
        segments = _decode_cached_aligned_segments(
            json.loads(path.read_text(encoding="utf-8")), source_hash=source_hash, model=model
        )
    except FileNotFoundError:
        return None
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        _discard_aligned_cache_entry(path)
        _prune_aligned_stt_cache(cache_directory)
        progress("transcript.stt.cache.invalid", "discarded malformed aligned transcript")
        return None
    try:
        os.utime(path, None)
    except OSError:
        _discard_aligned_cache_entry(path)
        _prune_aligned_stt_cache(cache_directory)
        progress("transcript.stt.cache.invalid", "could not refresh aligned transcript recency")
        return None
    _prune_aligned_stt_cache(cache_directory)
    progress("transcript.stt.cache.hit", f"{len(segments)} segments")
    return segments


def _store_cached_aligned_segments(request: dict, source_hash: str, model: str, segments) -> None:
    """Atomically persist a completed detector transcript before ad detection."""
    cache_directory = _aligned_cache_directory(request)
    if cache_directory is None:
        return
    temporary_path: Path | None = None
    try:
        record = _cache_record(segments, source_hash, model)
        cache_directory.mkdir(parents=True, exist_ok=True)
        destination = _aligned_cache_path(cache_directory, source_hash, model)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cache_directory,
                                         prefix=".aligned-stt-", suffix=".tmp", delete=False) as temporary:
            json.dump(record, temporary, separators=(",", ":"), allow_nan=False)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, destination)
        with contextlib.suppress(OSError):
            directory_fd = os.open(cache_directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        _prune_aligned_stt_cache(cache_directory)
        progress("transcript.stt.cache.saved", f"{len(record['segments'])} segments")
    except (OSError, ValueError, TypeError) as error:
        # A cache is an optimization. It must never turn a completed STT pass
        # into a failed episode, and an interrupted temporary is never retained.
        if temporary_path is not None:
            _discard_aligned_cache_entry(temporary_path)
        _prune_aligned_stt_cache(cache_directory)
        progress("transcript.stt.cache.failed", f"{type(error).__name__}: {error}")


def transcribe_with_daemon(audio_path: Path, model: str = ALIGNED_STT_MODEL):
    """Tier three: our own speech-to-text, aligned against this exact audio."""
    from wilted import transcribe

    progress("transcript.stt.start", str(audio_path.name))
    segments = in_time_order(transcribe.transcribe_audio(audio_path, model_name=model))
    progress("transcript.stt.complete", f"{len(segments)} segments")
    return segments


# The detector was tuned on parakeet-tdt-1.1b, which writes no punctuation
# and no capitals; a run on the 0.6b-v3 output moved and split the cuts on the
# same episode. So the 1.1b transcript stays the detector's input and v3, at
# about four minutes for a two-and-a-half-hour episode, is transcribed again
# for the listener. An LLM rewrite of the 1.1b text was the alternative, and
# measured at seven tokens a second it would take longer than the episode.
READABLE_STT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
# The readable pass replaces the display transcript only when it heard about
# as much as the detector's pass did; a truncated or empty result keeps the
# plain one rather than losing lines.
READABLE_MINIMUM_WORD_RATIO = 0.8


def transcribe_readable(request: dict, audio_path: Path, plain_cues: list[dict]) -> list[dict]:
    """A second pass with a punctuating model, for reading rather than cutting."""
    from wilted import transcribe

    model = request.get("readableTranscriptModel") or READABLE_STT_MODEL
    progress("transcript.stt.readable.start", model.rsplit("/", 1)[-1])
    try:
        segments = transcribe.transcribe_audio(audio_path, model_name=model)
    except Exception as error:  # noqa: BLE001 - the plain transcript is still a transcript
        progress("transcript.stt.readable.failed", f"{type(error).__name__}: {error}")
        return plain_cues
    cues = segments_to_cues(segments)
    plain_words = len(cues_to_text(plain_cues).split())
    readable_words = len(cues_to_text(cues).split())
    if not cues or readable_words < plain_words * READABLE_MINIMUM_WORD_RATIO:
        progress("transcript.stt.readable.rejected", f"{readable_words} words against {plain_words}")
        return plain_cues
    progress("transcript.stt.readable.complete", f"{len(cues)} cues")
    return cues


# ---------------------------------------------------------------------------
# Ad removal
# ---------------------------------------------------------------------------


class CountingBackend:
    """Wrap the classifier's backend so a run that never reached the model is
    distinguishable from one that ran and found nothing.

    The detector treats every backend exception as a malformed response: it
    retries, halves the batch, and finally labels each segment as content. That
    is the right call for one bad completion and the wrong one for a backend
    that cannot answer at all, which it cannot tell apart. This can.
    """

    def __init__(self, backend):
        self._backend = backend
        self.calls = 0
        self.failures = 0
        self.last_error: Exception | None = None

    def generate(self, system_prompt: str, user_content: str, *, response_format=None):
        self.calls += 1
        try:
            return self._backend.generate(system_prompt, user_content, response_format=response_format)
        except Exception as error:
            self.failures += 1
            self.last_error = error
            raise

    @property
    def mostly_failed(self) -> bool:
        """True when the backend, not the completions, is what is broken.

        A healthy backend raises essentially never: the accepted four-podcast
        trial made 207 calls with no malformed responses, and a malformed
        response is the detector's parse error rather than a backend exception
        anyway. A majority of raised calls is an environment fault, and one
        lucky singleton must not disarm the check.
        """
        return self.calls > 0 and self.failures * 2 > self.calls


def preflight_ad_removal(request: dict) -> None:
    """Fail before any work if the cut cannot possibly succeed.

    Both checks are cheap, and both failures were silent before: the model
    reached the detector unloaded and every batch was quietly classified as
    content, and the missing `ffprobe` surfaced only as a skipped duration
    probe on the way out. A run that skips ad removal skips this too.
    """
    from wilted import llm as llm_module

    missing = [tool for tool in CUT_TOOLS if shutil.which(tool) is None]
    if missing:
        raise WorkerError(
            "cut-tools-missing",
            f"{', '.join(missing)} not on PATH ({os.environ.get('PATH', '')}); install ffmpeg",
        )
    model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
    # An `hf:<repo>/<file>` spec is resolved by the previous project's cache
    # at load time; only a literal path can be checked here.
    if not model.startswith("hf:") and not Path(model).is_file():
        raise WorkerError("ads-model-missing", f"no ad-detection model at {model}")


def install_legacy_sponsor_opening_compatibility(ads_module) -> None:
    """Add the bounded host-read wording to the legacy detector's anchors."""
    for attribute in ("_SPONSOR_OPENING_RE", "_EXPLICIT_HOST_READ_OPENING_RE"):
        existing = getattr(ads_module, attribute)
        if LEGACY_SPONSOR_OPENING_COMPATIBILITY_PATTERN in existing.pattern:
            continue
        setattr(
            ads_module,
            attribute,
            re.compile(
                f"(?:{existing.pattern})|{LEGACY_SPONSOR_OPENING_COMPATIBILITY_PATTERN}",
                existing.flags,
            ),
        )


def _remaining_admission_budget(deadline: float) -> float:
    """Return the remaining shared lock/RPC budget or fail at its one deadline."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("timed out waiting for exclusive GPU model admission")
    return remaining


def _speech_rpc_with_progress(operation, deadline: float, detail: str):
    """Run one bounded synchronous daemon RPC with periodic progress."""
    outcome = {}
    done = threading.Event()

    def invoke():
        try:
            outcome["result"] = operation(_remaining_admission_budget(deadline))
        except BaseException as error:  # noqa: BLE001 - re-raised on the caller thread
            outcome["error"] = error
        finally:
            done.set()

    threading.Thread(target=invoke, daemon=True, name="wilted-speech-rpc").start()
    next_heartbeat = time.monotonic() + GPU_LOCK_PROGRESS_INTERVAL_S
    while not done.is_set():
        remaining = _remaining_admission_budget(deadline)
        if done.wait(min(STT_EVICTION_BARRIER_POLL_INTERVAL_S, remaining)):
            break
        now = time.monotonic()
        if now >= next_heartbeat:
            progress("ads.model.wait", f"{detail}; {remaining:.1f}s remain")
            next_heartbeat = now + GPU_LOCK_PROGRESS_INTERVAL_S
    if "error" in outcome:
        raise outcome["error"]
    return outcome.get("result")


@contextlib.contextmanager
def _canonical_gpu_flock(deadline: float):
    """Acquire speech-stack's canonical flock without a silent blocking wait."""
    from speech_stack.daemon import host as speech_host

    lock_path = speech_host.state_dir() / "gpu.lock"
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    next_heartbeat = time.monotonic()
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
            remaining = _remaining_admission_budget(deadline)
            now = time.monotonic()
            if now >= next_heartbeat:
                progress("ads.model.wait", f"waiting for shared GPU inference lock; {remaining:.1f}s remain")
                next_heartbeat = now + GPU_LOCK_PROGRESS_INTERVAL_S
            time.sleep(min(STT_EVICTION_BARRIER_POLL_INTERVAL_S, remaining))
        try:
            yield
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _validate_daemon_admission_snapshot(snapshot) -> tuple[int, int]:
    """Validate the broker counters used while the canonical flock is held."""
    resident_models = snapshot.get("resident_models") if isinstance(snapshot, dict) else None
    in_flight = snapshot.get("in_flight") if isinstance(snapshot, dict) else None
    if type(resident_models) is not int or resident_models < 0:
        raise RuntimeError(f"invalid speech daemon status: {snapshot!r}")
    if type(in_flight) is not int or in_flight < 1:
        raise RuntimeError(f"invalid speech daemon status: {snapshot!r}")
    return resident_models, in_flight


@contextlib.contextmanager
def prepare_ad_model_lock(_model: str, *, aligned_stt: bool):
    """Hold the canonical GPU flock after broker residency and work drain."""
    from speech_stack import client as speech_client

    # Two budgets, because they bound two different failures. Acquiring the
    # lock waits on a peer and is allowed to take as long as that peer's work;
    # everything after it talks to the daemon and must fail fast if the daemon
    # has stopped answering. The barrier budget starts when the lock is first
    # held, not at entry, so a long wait does not spend it before the first RPC.
    lock_deadline = time.monotonic() + GPU_LOCK_ACQUISITION_TIMEOUT_S
    barrier_deadline = None
    source = "aligned STT" if aligned_stt else "published transcript"
    progress("ads.model.wait", f"waiting for exclusive GPU admission after {source}")
    lock_stack = None
    try:
        while True:
            lock_stack = contextlib.ExitStack()
            try:
                lock_stack.enter_context(_canonical_gpu_flock(lock_deadline))
                if barrier_deadline is None:
                    barrier_deadline = time.monotonic() + STT_EVICTION_BARRIER_TIMEOUT_S
                snapshot = _speech_rpc_with_progress(
                    lambda timeout: speech_client.status(timeout=timeout),
                    barrier_deadline,
                    "waiting for speech daemon status",
                )
                resident_models, in_flight = _validate_daemon_admission_snapshot(snapshot)
            except speech_client.DaemonUnavailable:
                progress("ads.model.wait", "speech daemon unavailable; canonical GPU lock is exclusive")
                break
            except Exception:
                lock_stack.close()
                raise

            if resident_models == 0 and in_flight == 1:
                progress("ads.model.wait", "GPU admission is exclusive")
                break

            progress(
                "ads.model.release",
                f"releasing GPU lock to drain {resident_models} resident models and {in_flight - 1} other requests",
            )
            lock_stack.close()
            progress("ads.model.drain", "evicting resident speech models and waiting on FIFO barrier")
            try:
                if resident_models:
                    for task in ("stt", "tts"):
                        _speech_rpc_with_progress(
                            lambda timeout, task=task: speech_client.evict(task, timeout=timeout),
                            barrier_deadline,
                            f"waiting to evict resident {task} model",
                        )
                _speech_rpc_with_progress(
                    lambda timeout: speech_client.selftest(
                        "echo",
                        timeout=timeout,
                        barrier="wilted-gpu-drained",
                    ),
                    barrier_deadline,
                    "waiting for speech daemon FIFO drain",
                )
            except speech_client.DaemonUnavailable:
                progress("ads.model.drain", "speech daemon stopped during drain; retrying canonical lock")
            progress("ads.model.retry", "retrying exclusive GPU admission")
    except WorkerError:
        raise
    except Exception as error:  # noqa: BLE001 - never load GGUF without proving exclusive admission
        raise WorkerError(
            "ads-model-wait-failed",
            f"exclusive GPU admission failed: {type(error).__name__}: {error}",
        ) from error
    assert lock_stack is not None
    with lock_stack:
        yield


def explicit_sponsor_name_phrases(text, opening_pattern):
    """The names a host read might be repeating, longest first.

    A read says its sponsor over and over; a conversation that happens to open
    like one says it once. Counting that recurrence is the evidence that
    survives a transcript with no punctuation, and no punctuation is what the
    detector is handed: `videogame.town` reaches it as three ordinary words
    with no dot anywhere in them.

    Which words are the name is not knowable from the text alone, because
    nothing marks where it ends -- "brought to you by Video Game Town Video
    Game Town is an independent" runs the name straight into the next
    sentence. So return every prefix instead and let recurrence pick: only the
    real name comes back again.
    """
    match = opening_pattern.search(text)
    if match is None:
        return []
    words = [word.lower() for word in EXPLICIT_SPONSOR_NAME_WORD_RE.findall(text[match.end():])]
    while words and words[0] in EXPLICIT_SPONSOR_NAME_LEADING_FILLER:
        words.pop(0)
    phrases = []
    for length in range(min(len(words), EXPLICIT_SPONSOR_NAME_MAX_WORDS), 0, -1):
        phrase = " ".join(words[:length])
        # Short enough to be a common word is short enough to recur honestly.
        if len(phrase.replace(" ", "")) >= EXPLICIT_SPONSOR_NAME_MINIMUM_CHARACTERS:
            phrases.append(phrase)
    return phrases


def sponsor_name_recurrence_text(text, opening_pattern):
    """The part of the anchor segment where a name could come *back*.

    The anchor names its sponsor once by definition -- that is what "brought to
    you by" is followed by -- so counting that naming would give every anchor a
    free mention. Skip past the opening and the longest name it could have
    introduced, and count only what follows.
    """
    match = opening_pattern.search(text)
    if match is None:
        return text
    trailing = text[match.end():]
    words = list(EXPLICIT_SPONSOR_NAME_WORD_RE.finditer(trailing))
    if len(words) <= EXPLICIT_SPONSOR_NAME_MAX_WORDS:
        return ""
    return trailing[words[EXPLICIT_SPONSOR_NAME_MAX_WORDS - 1].end():]


def count_sponsor_name_mentions(text, phrases, counts):
    """Add this segment's mentions of each candidate name to the running count."""
    lowered = text.lower()
    for phrase in phrases:
        start = 0
        while True:
            found = lowered.find(phrase, start)
            if found < 0:
                break
            counts[phrase] = counts.get(phrase, 0) + 1
            start = found + len(phrase)


def recover_unclaimed_explicit_sponsor_reads(ads_module, backend, segments, detections):
    """Recover or extend explicit host reads through verified content return."""
    recovered = []
    opening_pattern = ads_module._EXPLICIT_HOST_READ_OPENING_RE  # noqa: SLF001
    for anchor_id, anchor in enumerate(segments):
        if opening_pattern.search(anchor.text) is None:
            continue
        claimed = [*detections, *recovered]
        overlapping = [
            ad for ad in claimed if ad.start_s < anchor.end_s and ad.end_s > anchor.start_s
        ]

        context_ids = [anchor_id]
        for segment_id in range(anchor_id + 1, len(segments)):
            if (
                len(context_ids) >= EXPLICIT_SPONSOR_RECOVERY_MAX_SEGMENTS
                or segments[segment_id].start_s - anchor.start_s > EXPLICIT_SPONSOR_RECOVERY_MAX_SECONDS
            ):
                break
            context_ids.append(segment_id)
        if len(context_ids) < 2:
            progress(
                "ads.detect.recovery.skipped",
                f"explicit sponsor anchor at {anchor.start_s:.3f} had no following content boundary",
            )
            continue

        # Two independent signals, as before, but the second one no longer has
        # to be an address. A sponsor whose domain is spoken as ordinary words
        # is invisible to every address pattern there is, and Giant Bombcast
        # 955's ninety-second read was skipped for exactly that: no dot, no
        # http, and a `.town` top-level domain no list had. Its own name came
        # back thirteen times, which is what a read is.
        name_phrases = explicit_sponsor_name_phrases(anchor.text, opening_pattern)
        name_counts = {}
        domain_seen = False
        cta_seen = False
        evidence_id = None
        for segment_id in context_ids:
            text = segments[segment_id].text
            domain_seen = domain_seen or any(
                pattern.search(text) is not None
                for pattern in (
                    EXPLICIT_SPONSOR_DOT_DOMAIN_RE,
                    EXPLICIT_SPONSOR_URL_RE,
                    EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE,
                    EXPLICIT_SPONSOR_SPOKEN_PATH_RE,
                    EXPLICIT_SPONSOR_OFFER_CODE_RE,
                )
            )
            cta_seen = cta_seen or EXPLICIT_SPONSOR_CTA_RE.search(text) is not None
            if (
                name_phrases
                and segments[segment_id].start_s - anchor.start_s <= EXPLICIT_SPONSOR_NAME_WINDOW_SECONDS
            ):
                count_sponsor_name_mentions(
                    text if segment_id != anchor_id else sponsor_name_recurrence_text(text, opening_pattern),
                    name_phrases,
                    name_counts,
                )
            name_repeated = any(
                count >= EXPLICIT_SPONSOR_NAME_MINIMUM_REPEATS for count in name_counts.values()
            )
            if cta_seen and (domain_seen or name_repeated):
                evidence_id = segment_id
                break

        if evidence_id is None:
            progress(
                "ads.detect.recovery.skipped",
                f"unclaimed explicit sponsor anchor at {anchor.start_s:.3f} had no bounded CTA/domain evidence",
            )
            continue
        evidence_end = segments[evidence_id].end_s
        verified_end_id = evidence_id
        content_start_id = None
        verifier_end = min(
            context_ids[-1],
            evidence_id + EXPLICIT_SPONSOR_RESUMPTION_TAIL_SEGMENTS,
        )
        try:
            for candidate_id in range(evidence_id + 1, verifier_end + 1):
                include = ads_module._probe_boundary_candidate(  # noqa: SLF001
                    candidate_id,
                    verified_end_id,
                    "right",
                    segments,
                    backend,
                )
                if include is True:
                    verified_end_id = candidate_id
                    continue
                if include is False:
                    content_start_id = candidate_id
                break
        except Exception as error:  # noqa: BLE001 - uncertain fallback boundaries never cut audio
            progress(
                "ads.detect.recovery.skipped",
                f"explicit sponsor verifier failed at {anchor.start_s:.3f}: {type(error).__name__}: {error}",
            )
            continue
        if content_start_id is None:
            progress(
                "ads.detect.recovery.skipped",
                f"explicit sponsor verifier found no content return after {evidence_id}",
            )
            continue
        recovered_end = ads_module._last_meaningful_ad_end(  # noqa: SLF001
            content_start_id,
            anchor_id,
            segments,
        )
        if overlapping and recovered_end <= max(ad.end_s for ad in overlapping):
            continue
        recovered.append(
            ads_module.AdSegment(  # noqa: SLF001 - preserve legacy detection result type
                # The fallback's proof is the full explicit host-read cue. Its
                # natural sponsor lead-in can precede the regex phrase, so do
                # not retain it by token-refining this worker-only recovery.
                anchor.start_s,
                recovered_end,
                1.0,
                "sponsor_read",
            )
        )

    if not recovered:
        return detections
    merged = ads_module._merge_adjacent(  # noqa: SLF001 - retain legacy overlap semantics
        sorted([*detections, *recovered], key=lambda ad: ad.start_s)
    )
    evidence = ", ".join(f"{ad.start_s:.3f}-{ad.end_s:.3f}" for ad in recovered)
    progress("ads.detect.recovered", f"{len(recovered)} spans: {evidence}")
    return merged


def _constrained_id(ads_module, backend, prompt, field, window_ids, permitted, segments):
    """Ask one bounded ID question and return a validated supplied ID."""
    response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
        backend,
        prompt,
        ads_module._render_segments_bounded(window_ids, segments),  # noqa: SLF001
        ads_module._id_response_format(field, permitted),  # noqa: SLF001
    )
    parsed = json.loads(response)
    if not isinstance(parsed, dict) or set(parsed) != {field}:
        raise ValueError(f"{field} response must contain exactly {field}")
    value = parsed[field]
    if isinstance(value, bool) or not isinstance(value, int) or value not in permitted:
        raise ValueError(f"{field} response must be one of the supplied IDs, got {value!r}")
    return value


def recover_transcript_start_preroll(ads_module, backend, segments, detections):
    """Recover a produced advertisement carried before the program starts.

    Two questions rather than one, and the second is not the first asked
    again: it is handed only the passage the first answer nominated and asked
    to find program content inside it. A cold open wrongly nominated has its
    hosts talking in that passage, so the second question finds them and the
    cut never happens.
    """
    if not segments:
        return detections
    # Only an opening already claimed from its first second is left alone. A
    # detection that begins a few seconds in is the case this exists for: the
    # advertisement's opening sentences were not recognised as advertising, so
    # what survives the cut is a commercial, and it is the first thing the
    # listener hears. Giant Bombcast 955 kept thirteen seconds of an insurance
    # spot that way, with the detector's own span starting at 13.0.
    if any(ad.start_s <= segments[0].start_s + PREROLL_ALREADY_CLAIMED_SECONDS for ad in detections):
        return detections
    window_ids = [0]
    for segment_id in range(1, len(segments)):
        if (len(window_ids) >= PREROLL_RECOVERY_MAX_SEGMENTS
                or segments[segment_id].start_s > PREROLL_RECOVERY_MAX_SECONDS):
            break
        window_ids.append(segment_id)
    if len(window_ids) < 2:
        return detections

    try:
        program_start_id = _constrained_id(
            ads_module, backend, PREROLL_PROGRAM_START_PROMPT, "program_start_id",
            window_ids, window_ids, segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        progress("ads.detect.preroll.skipped", f"opening review failed: {type(error).__name__}: {error}")
        return detections
    if program_start_id == 0:
        progress("ads.detect.preroll.skipped", "the program starts at the first segment")
        return detections

    # The cut runs to where the program begins rather than to the last
    # advertising cue, because the insertion gap between them is the spot's
    # own music bed and leaving it behind is leaving the advertisement in.
    end_s = float(segments[program_start_id].start_s)
    if end_s < PREROLL_RECOVERY_MINIMUM_SECONDS:
        progress("ads.detect.preroll.skipped", f"the opening is only {end_s:.1f}s long")
        return detections

    opening_ids = list(range(program_start_id))
    try:
        program_id = _constrained_id(
            ads_module, backend, PREROLL_CONFIRM_PROMPT, "program_id",
            opening_ids, [-1, *opening_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        progress("ads.detect.preroll.skipped", f"opening confirmation failed: {type(error).__name__}: {error}")
        return detections
    if program_id != -1:
        progress("ads.detect.preroll.skipped", f"the opening holds program content at {program_id}")
        return detections

    preroll = ads_module.AdSegment(0.0, end_s, 1.0, "ad_break")  # noqa: SLF001 - legacy result type
    progress("ads.detect.preroll", f"0.000-{end_s:.3f} before program ID {program_start_id}")
    return ads_module._merge_adjacent(  # noqa: SLF001 - retain legacy overlap semantics
        sorted([preroll, *detections], key=lambda ad: ad.start_s)
    )


def _program_starts_inside(ads_module, backend, segments, segment_id):
    """Answer whether the program begins inside one segment, so a cut can stop short of it.

    Returns True when it does, and True as well when the question cannot be
    answered: an unreadable answer must not license taking a segment that might
    hold the program.
    """
    try:
        response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
            backend,
            BOUNDARY_SEGMENT_PROMPT,
            ads_module._render_segments_bounded([segment_id], segments),  # noqa: SLF001
            {"type": "json_object"},
        )
        parsed = json.loads(response)
        if set(parsed) != {"starts_program"} or not isinstance(parsed["starts_program"], bool):
            raise ValueError("starts_program response must contain exactly one boolean")
        return parsed["starts_program"]
    except Exception as error:  # noqa: BLE001 - an unanswered question keeps the segment
        progress("ads.detect.boundary.unanswered", f"{type(error).__name__}: {error}")
        return True


def _tail_carries_program(ads_module, backend, segments, segment_id):
    """Answer whether the program is still running inside one segment.

    True when it is, and True when the question cannot be answered: the mirror
    of the opening probe, and fail-closed for the same reason.
    """
    try:
        response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
            backend,
            BOUNDARY_SEGMENT_TAIL_PROMPT,
            ads_module._render_segments_bounded([segment_id], segments),  # noqa: SLF001
            {"type": "json_object"},
        )
        parsed = json.loads(response)
        if set(parsed) != {"carries_program"} or not isinstance(parsed["carries_program"], bool):
            raise ValueError("carries_program response must contain exactly one boolean")
        return parsed["carries_program"]
    except Exception as error:  # noqa: BLE001 - an unanswered question keeps the segment
        progress("ads.detect.boundary.unanswered", f"{type(error).__name__}: {error}")
        return True


def recover_transcript_end_postroll(ads_module, backend, segments, detections, total_seconds):
    """Recover a produced advertisement appended after the program signs off.

    The opening review's mirror, and it exists for the same reason: a produced
    spot carries none of the evidence the anchor recovery needs. Nobody on the
    show reads it, it names no domain the sparse-evidence filter would see, and
    a network cross-promotion for a different podcast asks you to subscribe
    somewhere else rather than to buy anything. Two episodes reported on the
    same day ended this way -- The Daily on a Chase Sapphire spot, TechCrunch
    Daily on a Motley Fool one -- and the detector found neither.

    The cut runs to the end of the file rather than to the last advertising
    cue, because what is between them is the spot's own music bed.
    """
    if not segments or total_seconds <= 0:
        return detections
    end_s = float(segments[-1].end_s)
    if any(float(ad.end_s) >= end_s - POSTROLL_ALREADY_CLAIMED_SECONDS for ad in detections):
        progress("ads.detect.postroll.skipped", "the ending is already claimed")
        return detections

    floor_s = end_s - POSTROLL_RECOVERY_MAX_SECONDS
    window_ids = [
        segment_id for segment_id, segment in enumerate(segments)
        if float(segment.end_s) > floor_s
        and not any(float(ad.end_s) > float(segment.start_s) for ad in detections)
    ][-POSTROLL_RECOVERY_MAX_SEGMENTS:]
    if len(window_ids) < 2:
        return detections

    try:
        advertising_start_id = _constrained_id(
            ads_module, backend, POSTROLL_PROGRAM_END_PROMPT, "advertising_start_id",
            window_ids, [-1, *window_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        progress("ads.detect.postroll.skipped", f"closing review failed: {type(error).__name__}: {error}")
        return detections
    if advertising_start_id == -1:
        progress("ads.detect.postroll.skipped", "the program runs to the end")
        return detections

    boundary_carries_program = advertising_start_id < window_ids[-1] and _tail_carries_program(
        ads_module, backend, segments, advertising_start_id
    )
    if boundary_carries_program:
        # The sign-off and the spot's first words share a segment, so the cut
        # starts after it. One step only, for the same reason as the opening.
        progress(
            "ads.detect.boundary.shortened",
            f"the program is still running inside segment {advertising_start_id}, "
            "so the cut starts after it",
        )
        advertising_start_id += 1
        boundary_carries_program = False

    start_s = float(segments[advertising_start_id].start_s)
    if advertising_start_id > 0:
        start_s = max(
            float(segments[advertising_start_id - 1].end_s),
            start_s - POSTROLL_LEADER_MAX_SECONDS,
        )
    if total_seconds - start_s < POSTROLL_RECOVERY_MINIMUM_SECONDS:
        progress("ads.detect.postroll.skipped", "the ending is too short to be a produced spot")
        return detections
    share = (total_seconds - start_s) / total_seconds
    if share > MAXIMUM_SINGLE_AD_SHARE:
        progress("ads.detect.postroll.skipped", f"the ending would be {share:.0%} of the episode")
        return detections

    tail_ids = [segment_id for segment_id in window_ids if segment_id >= advertising_start_id]
    try:
        program_id = _constrained_id(
            ads_module, backend, POSTROLL_CONFIRM_PROMPT, "program_id",
            tail_ids, [-1, *tail_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        progress("ads.detect.postroll.skipped", f"closing confirmation failed: {type(error).__name__}: {error}")
        return detections
    if program_id == advertising_start_id and not boundary_carries_program:
        # Two questions disagreeing about one segment, and the one asked about
        # that segment alone wins. TechCrunch Daily ends on a promotion for
        # another podcast that describes its own content the way a show
        # describes itself, and the confirmation read the first segment of it as
        # this program; the single-segment probe, handed nothing else to weigh,
        # said there was no program in it. Believing the confirmation here costs
        # two thirds of the spot for no reason anyone could name.
        progress(
            "ads.detect.postroll.contested",
            f"the confirmation puts the program at {program_id} and the segment itself carries none; "
            "keeping the boundary",
        )
        program_id = -1

    if program_id != -1:
        # One shrink, then the answer stands. The realistic disagreement is the
        # first question overshooting by a segment or two -- The Daily's closing
        # promo for another NYT show reads as advertising and its sign-off comes
        # after it -- so the passage is narrowed to what the confirmation left
        # and asked once more. A second disagreement is not a boundary dispute,
        # it is the review being wrong about the whole ending.
        shrunk_ids = [segment_id for segment_id in tail_ids if segment_id > program_id]
        start_s = (
            max(float(segments[shrunk_ids[0] - 1].end_s),
                float(segments[shrunk_ids[0]].start_s) - POSTROLL_LEADER_MAX_SECONDS)
            if shrunk_ids else 0.0
        )
        if not shrunk_ids or total_seconds - start_s < POSTROLL_RECOVERY_MINIMUM_SECONDS:
            progress("ads.detect.postroll.skipped", f"the ending holds program content at {program_id}")
            return detections
        progress(
            "ads.detect.postroll.shrunk",
            f"program content at {program_id}, so the ending is narrowed to {shrunk_ids[0]}",
        )
        advertising_start_id = shrunk_ids[0]
        try:
            program_id = _constrained_id(
                ads_module, backend, POSTROLL_CONFIRM_PROMPT, "program_id",
                shrunk_ids, [-1, *shrunk_ids], segments,
            )
        except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
            progress("ads.detect.postroll.skipped", f"closing confirmation failed: {type(error).__name__}: {error}")
            return detections
        if program_id != -1:
            progress("ads.detect.postroll.skipped", f"the ending still holds program content at {program_id}")
            return detections

    progress(
        "ads.detect.postroll",
        f"{start_s:.3f}-{total_seconds:.3f} after program ID {advertising_start_id}",
    )
    return ads_module._merge_adjacent([  # noqa: SLF001
        *detections,
        ads_module.AdSegment(start_s, total_seconds, 1.0, "ad_break"),
    ])


def _resize_one_oversized_span(ads_module, backend, segments, ad, total_seconds):
    """Trim one too-large span back to where the program resumes, or decline.

    Two questions in the shape the opening review established: the first
    nominates a boundary, the second is handed only the shortened span and
    asked to find program content inside it. A boundary in the wrong place has
    the program in that passage, so the second question finds it and the trim
    never happens.
    """
    span_ids = [
        segment_id for segment_id, segment in enumerate(segments)
        if float(segment.start_s) < float(ad.end_s) and float(segment.end_s) > float(ad.start_s)
    ]
    if len(span_ids) < 2:
        return None
    window_ids = span_ids[:OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS]

    try:
        program_start_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_PROGRAM_START_PROMPT, "program_start_id",
            window_ids, window_ids, segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        progress("ads.detect.span.resize.skipped", f"resize review failed: {type(error).__name__}: {error}")
        return None
    if program_start_id == window_ids[0]:
        progress("ads.detect.span.resize.skipped", "the span is advertising throughout")
        return None

    if program_start_id - 1 > window_ids[0] and _program_starts_inside(
        ads_module, backend, segments, program_start_id - 1
    ):
        # One step back only. The mixed segment is the boundary segment by
        # construction: the advertisement ends in it, so the one before it is
        # advertising throughout.
        progress(
            "ads.detect.boundary.shortened",
            f"the program starts inside segment {program_start_id - 1}, so the cut stops before it",
        )
        program_start_id -= 1
    end_s = float(segments[program_start_id].start_s)
    if end_s <= float(ad.start_s):
        progress("ads.detect.span.resize.skipped", "the program resumes before the span begins")
        return None
    share = (end_s - float(ad.start_s)) / total_seconds
    if share > MAXIMUM_SINGLE_AD_SHARE:
        progress(
            "ads.detect.span.resize.skipped",
            f"the program still resumes {share:.0%} into the episode",
        )
        return None

    opening_ids = [segment_id for segment_id in window_ids if segment_id < program_start_id]
    try:
        program_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_CONFIRM_PROMPT, "program_id",
            opening_ids, [-1, *opening_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        progress("ads.detect.span.resize.skipped", f"resize confirmation failed: {type(error).__name__}: {error}")
        return None
    if program_id != -1:
        progress("ads.detect.span.resize.skipped", f"the shortened span holds program content at {program_id}")
        return None

    progress(
        "ads.detect.span.resized",
        f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} shortened to "
        f"{float(ad.start_s):.3f}-{end_s:.3f} before program ID {program_start_id}",
    )
    # Only the front of the span is recovered. A true bracket -- advertising at
    # both ends with program between -- keeps its tail read in the audio, which
    # is the safe half of the trade and not worth a backwards pass to close.
    return ads_module.AdSegment(float(ad.start_s), end_s, float(ad.confidence), ad.label)


def resize_oversized_ad_spans(ads_module, backend, segments, detections, total_seconds):
    """Ask where the program resumes inside any span too large to be an ad.

    Runs while the model is loaded, before the arithmetic guard below, so a
    span the detector overreached on can be recovered as the advertisement it
    started as rather than dropped whole. Whatever this declines to trim is
    still handed to `reject_implausible_ad_spans`, which is the net.

    `total_seconds` is the probed audio duration, the same denominator the
    rejection below uses, so the two bounds cannot disagree about how large a
    span is.
    """
    if total_seconds <= 0 or not detections or not segments:
        return detections
    resized = []
    for ad in detections:
        share = (float(ad.end_s) - float(ad.start_s)) / total_seconds
        if share <= MAXIMUM_SINGLE_AD_SHARE:
            resized.append(ad)
            continue
        trimmed = _resize_one_oversized_span(ads_module, backend, segments, ad, total_seconds)
        resized.append(trimmed if trimmed is not None else ad)
    return resized


def reject_implausible_ad_spans(detections, total_seconds):
    """Drop detections too large to be advertising, and say which and why.

    Dropping the span rather than trimming it is deliberate: nothing here knows
    where the advertisement actually ended, and a guessed boundary would cut
    programme audio with the same confidence the detector just misplaced.
    """
    if total_seconds <= 0 or not detections:
        return detections
    kept = []
    for ad in detections:
        span_seconds = float(ad.end_s) - float(ad.start_s)
        share = span_seconds / total_seconds
        if share > MAXIMUM_SINGLE_AD_SHARE:
            progress(
                "ads.detect.span.rejected",
                f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} is {share:.0%} of the episode; "
                "a span that size is a detection failure, not an advertisement",
            )
            continue
        kept.append(ad)
    removed = sum(float(ad.end_s) - float(ad.start_s) for ad in kept)
    if removed / total_seconds > MAXIMUM_TOTAL_AD_SHARE:
        progress(
            "ads.detect.refused",
            f"{removed:.1f}s of {total_seconds:.1f}s ({removed / total_seconds:.0%}) was classified "
            "as advertising; keeping the episode whole",
        )
        return []
    return kept


def detect_and_cut(request: dict, audio_path: Path, cues: list[dict], segments, *, model_lock=None):
    """Detect ads and rewrite the audio without them.

    Returns `(output_path, ad_spans, keep_intervals)`. `output_path` is the
    input path when nothing was cut, and `keep_intervals` is empty in that
    case, which is the signal that cue timing still matches the file.
    """
    from wilted import ads as ads_module
    from wilted import llm as llm_module

    if not segments:
        return audio_path, [], []

    model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
    model_lock = model_lock or prepare_ad_model_lock(model, aligned_stt=False)
    # The previous project loads lazily and explicitly, under a coordinator
    # that keeps one model resident at a time. Without `load()` every
    # inference raises, and the detector's tolerance for bad completions turns
    # that into a clean, instant, wrong "no advertisements".
    with model_lock or contextlib.nullcontext():
        progress("ads.model.locked", "shared GPU inference lock acquired")
        progress("ads.model.load", Path(model).name)
        backend = None
        try:
            backend = llm_module.create_backend("gguf", model=model)
            backend.load()
        except Exception as error:  # noqa: BLE001 - reported, not raised through
            if backend is not None:
                try:
                    backend.close()
                except Exception:  # noqa: BLE001 - the load failure is the report
                    pass
            raise WorkerError("ads-model-unavailable", f"{type(error).__name__}: {error}") from error
        counting = CountingBackend(backend)
        try:
            progress("ads.detect.start", f"{len(segments)} segments")
            install_legacy_sponsor_opening_compatibility(ads_module)
            # The archive says what it threw away at INFO, and the logger's
            # effective level is WARNING, so the level is lifted for the length
            # of the detection and put back afterwards.
            discarded = DiscardedRuns(segments)
            ads_logger = logging.getLogger("wilted.ads")
            previous_level = ads_logger.level
            ads_logger.addHandler(discarded)
            ads_logger.setLevel(logging.INFO)
            try:
                detections = ads_module.detect_ads(segments, counting)
            finally:
                ads_logger.removeHandler(discarded)
                ads_logger.setLevel(previous_level)
                discarded.summarize()
            # Probed before the recovery passes, not after them. The closing
            # review cuts to the end of the file and sizes itself against the
            # episode, and the case it exists for is the one where the detector
            # found nothing at all, so a probe conditional on detections would
            # never run for it. Both size guards then share this denominator.
            total = probe_duration(audio_path)
            detections = recover_unclaimed_explicit_sponsor_reads(
                ads_module,
                counting,
                segments,
                detections,
            )
            detections = recover_transcript_start_preroll(
                ads_module,
                counting,
                segments,
                detections,
            )
            detections = recover_transcript_end_postroll(
                ads_module,
                counting,
                segments,
                detections,
                total,
            )
            detections = resize_oversized_ad_spans(
                ads_module,
                counting,
                segments,
                detections,
                total,
            )
        finally:
            try:
                backend.close()
            except Exception:  # noqa: BLE001 - a close failure cannot undo a detection
                pass
    if counting.mostly_failed:
        raise WorkerError(
            "ads-backend-failed",
            f"the model failed {counting.failures} of {counting.calls} requests; last error: "
            f"{type(counting.last_error).__name__}: {counting.last_error}",
        )
    progress("ads.detect.calls", f"{counting.calls} requests, {counting.failures} failed")
    if not detections:
        progress("ads.detect.complete", "0 spans")
        return audio_path, [], []

    detections = reject_implausible_ad_spans(detections, total)
    ad_spans = [
        {
            "startSeconds": round(float(ad.start_s), 3),
            "endSeconds": round(float(ad.end_s), 3),
            "label": ad.label,
            "confidence": round(float(ad.confidence), 4),
        }
        for ad in detections
    ]
    progress("ads.detect.complete", f"{len(ad_spans)} spans")
    if not detections:
        return audio_path, [], []

    keep_segments = ads_module._compute_keep_segments(total, detections, 0.5)  # noqa: SLF001
    if not keep_segments:
        # Everything was called an ad. Refusing to cut is the only safe
        # reading: an empty file is worse than an unedited one.
        progress("ads.cut.refused", "every span was classified as an advertisement")
        return audio_path, ad_spans, []

    output_path = Path(request["outputPath"])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    progress("ads.cut.start", f"{len(keep_segments)} keep spans")
    ads_module.cut_ads(audio_path, detections, output_path)
    if not output_path.exists() or output_path.stat().st_size == 0:
        output_path.unlink(missing_ok=True)
        progress("ads.cut.empty", "cut produced no audio; keeping the original")
        return audio_path, ad_spans, []
    progress("ads.cut.complete", f"{output_path.stat().st_size} bytes")
    return output_path, ad_spans, build_keep_map(keep_segments)


def probe_duration(audio_path: Path) -> float:
    import subprocess

    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(audio_path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run(request: dict) -> dict:
    audio_path = Path(request["audioPath"])
    if not audio_path.exists():
        raise WorkerError("audio-missing", f"no audio at {audio_path}")

    transcript_policy = request.get("transcriptPolicy")
    if transcript_policy is None:
        # Protocol-v1 callers predate explicit snapshots. Preserve their
        # published-first ordering and their existing STT switch exactly.
        allow_published_transcript = True
        allow_speech_to_text = request.get("allowSpeechToText", True)
    elif transcript_policy == "bestAvailable":
        allow_published_transcript = True
        allow_speech_to_text = True
    elif transcript_policy == "alwaysTranscribe":
        allow_published_transcript = False
        allow_speech_to_text = True
    elif transcript_policy == "noLocalSTT":
        allow_published_transcript = True
        allow_speech_to_text = False
    else:
        raise WorkerError("invalid-request", f"unknown transcriptPolicy: {transcript_policy}")

    if request.get("removeAds", True):
        preflight_ad_removal(request)

    cues: list[dict] = []
    segments = None
    timing = "none"
    text: str | None = None
    language = request.get("language")

    published = request.get("publishedTranscript") if allow_published_transcript else None
    if published:
        progress("transcript.published.parse", published.get("mediaType", ""))
        # Sorted for the same reason speech-to-text is: a feed's own file is no
        # more guaranteed to be in time order, and the detector reads it by
        # position either way.
        segments = in_time_order(parse_published_transcript(
            published.get("body", ""), published.get("mediaType", ""), published.get("url", "")
        ))
        if segments and not published_transcript_matches_audio(segments, audio_path):
            # Dropped rather than kept with a warning: these segments are what
            # the detector cuts from, so keeping them would aim the cut at the
            # wrong seconds of a file they do not describe. Speech-to-text
            # below reads the audio that was actually downloaded.
            segments = None
        if segments:
            cues = segments_to_cues(segments)
            timing = "published"
            language = published.get("languageCode") or language
            progress("transcript.published.accepted", f"{len(cues)} cues")

    if not cues and allow_speech_to_text:
        aligned_model = request.get("alignedTranscriptModel") or ALIGNED_STT_MODEL
        source_hash = request.get("sourceHash")
        try:
            if isinstance(source_hash, str) and source_hash and isinstance(aligned_model, str) and aligned_model:
                segments = _load_cached_aligned_segments(request, source_hash, aligned_model)
            if segments is None:
                segments = transcribe_with_daemon(audio_path, aligned_model)
                if isinstance(source_hash, str) and source_hash and isinstance(aligned_model, str) and aligned_model:
                    _store_cached_aligned_segments(request, source_hash, aligned_model, segments)
            cues = segments_to_cues(segments)
            timing = "aligned"
        except Exception as error:  # noqa: BLE001 - a failed tier falls through
            segments = None
            progress("transcript.stt.failed", f"{type(error).__name__}: {error}")
        if cues and request.get("readableTranscript", True):
            cues = transcribe_readable(request, audio_path, cues)

    if not cues:
        page = request.get("episodePage")
        if page:
            progress("transcript.prose.extract", "")
            text = extract_prose(page)
            if text:
                progress("transcript.prose.accepted", f"{len(text.split())} words")

    if not cues and not text:
        progress("transcript.absent", "no published, aligned, or prose transcript")

    output_path, ad_spans, keeps = audio_path, [], []
    if request.get("removeAds", True) and segments:
        from wilted import llm as llm_module

        model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
        model_lock = prepare_ad_model_lock(model, aligned_stt=timing == "aligned")
        output_path, ad_spans, keeps = detect_and_cut(
            request, audio_path, cues, segments, model_lock=model_lock
        )
        if keeps:
            before = len(cues)
            cues = remap_cues(cues, keeps)
            progress("transcript.remap", f"{before} cues to {len(cues)} on the cut timeline")

    if cues:
        cues = polish_with_notes(request, cues)
        text = cues_to_text(cues)

    # Measure the delivered file rather than subtracting what was removed: the
    # encoder decides the final frame boundaries, and a duration that disagrees
    # with the audio would desynchronise the very cues this pipeline exists to
    # align. A probe failure is not fatal -- the caller keeps its own value.
    try:
        duration = probe_duration(output_path)
    except Exception as error:  # noqa: BLE001 - the caller has a fallback
        duration = None
        progress("audio.probe.failed", f"{type(error).__name__}: {error}")

    return {
        "ok": True,
        "protocolVersion": PROTOCOL_VERSION,
        "durationSeconds": duration,
        "timing": timing if cues else "none",
        "cues": cues,
        "text": text,
        "languageCode": language,
        "audioPath": str(output_path),
        "audioChanged": str(output_path) != str(audio_path),
        "adSegments": ad_spans,
        # The exact original-to-output time map, so the caller can move a
        # listener's saved position onto the cut audio instead of losing it.
        # Empty means nothing was cut and every timestamp still matches.
        "keepIntervals": serialize_keep_map(keeps),
        "removedSeconds": round(sum(a["endSeconds"] - a["startSeconds"] for a in ad_spans), 3) if keeps else 0.0,
    }


def main() -> int:
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as error:
        json.dump({"ok": False, "code": "bad-request", "message": str(error)}, sys.stdout)
        return 2
    if not isinstance(request, dict):
        json.dump({"ok": False, "code": "bad-request", "message": "request must be an object"}, sys.stdout)
        return 2

    data_dir = Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline"
    data_dir.mkdir(parents=True, exist_ok=True)
    warnings = ForwardedWarnings()
    # The root logger, not `wilted`: the speech daemon client and the
    # transcript parsers log under their own names.
    logging.getLogger().addHandler(warnings)
    try:
        # The previous project gates model construction behind an explicit
        # capability so nothing loads a multi-gigabyte model by accident. This
        # process exists to do exactly that, so it claims the capability once
        # around the whole run.
        from wilted.execution_capability import execution_capability_scope

        with execution_capability_scope(owner_id="wilted-native-pipeline", data_dir=data_dir):
            result = run(request)
    except WorkerError as error:
        warnings.summarize()
        json.dump({"ok": False, "code": error.code, "message": str(error)}, sys.stdout)
        return 1
    except Exception as error:  # noqa: BLE001 - the caller needs a result, not a traceback
        warnings.summarize()
        json.dump({"ok": False, "code": "worker-failed",
                   "message": f"{type(error).__name__}: {error}"}, sys.stdout)
        return 1
    warnings.summarize()
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
