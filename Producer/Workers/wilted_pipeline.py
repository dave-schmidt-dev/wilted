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

import difflib
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
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


def transcribe_with_daemon(audio_path: Path):
    """Tier three: our own speech-to-text, aligned against this exact audio."""
    from wilted import transcribe

    progress("transcript.stt.start", str(audio_path.name))
    segments = transcribe.transcribe_audio(audio_path)
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


def evict_legacy_stt_model() -> None:
    """Release aligned-STT memory before the ad model is allocated, if supported."""
    try:
        from wilted import transcribe

        transcribe.evict_stt_model()
    except Exception:  # noqa: BLE001 - old transcribers do not all expose this hint
        pass


def detect_and_cut(request: dict, audio_path: Path, cues: list[dict], segments):
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
    progress("ads.model.load", Path(model).name)
    # The previous project loads lazily and explicitly, under a coordinator
    # that keeps one model resident at a time. Without `load()` every
    # inference raises, and the detector's tolerance for bad completions turns
    # that into a clean, instant, wrong "no advertisements".
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
        detections = ads_module.detect_ads(segments, counting)
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

    total = probe_duration(audio_path)
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
    if request.get("removeAds", True):
        preflight_ad_removal(request)

    cues: list[dict] = []
    segments = None
    timing = "none"
    text: str | None = None
    language = request.get("language")

    published = request.get("publishedTranscript")
    if published:
        progress("transcript.published.parse", published.get("mediaType", ""))
        segments = parse_published_transcript(
            published.get("body", ""), published.get("mediaType", ""), published.get("url", "")
        )
        if segments:
            cues = segments_to_cues(segments)
            timing = "published"
            language = published.get("languageCode") or language
            progress("transcript.published.accepted", f"{len(cues)} cues")

    if not cues and request.get("allowSpeechToText", True):
        try:
            segments = transcribe_with_daemon(audio_path)
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
        if timing == "aligned":
            evict_legacy_stt_model()
        output_path, ad_spans, keeps = detect_and_cut(request, audio_path, cues, segments)
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
        "keepIntervals": [
            {"startSeconds": round(k.start_s, 3), "endSeconds": round(k.end_s, 3),
             "outputStartSeconds": round(k.output_start_s, 3)}
            for k in keeps
        ],
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
