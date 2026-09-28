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
from . import reporting as _worker_reporting

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

_WORD = re.compile(r"[^\W_][^\W_'&.-]*(?:['&.-][^\W_]+)*")

_LABEL = re.compile(r"\s*(?:[-*\u2022]\s*)?[A-Za-z][A-Za-z ]{0,24}:\s+")

_MARKS = ".,;:?!\"'()[]\u201c\u201d\u2018\u2019"

_EDGE_MARKS = re.compile(r"^[\"'(\[\u201c\u2018]*")

_TRAILING_MARKS = re.compile(r"[.,;:?!\"')\]\u201d\u2019]*$")

_URL = re.compile(r"(?:https?://)?(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?:/[^\s)]*)?", re.IGNORECASE)

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
        _worker_reporting.progress("transcript.glossary.terms", f"{len(glossary)} terms from the show notes")
        if not glossary:
            return cues
        cues, edits = apply_glossary(
            cues, glossary,
            on_progress=lambda done, total: _worker_reporting.progress("transcript.glossary.progress", f"{done} of {total} cues"),
        )
        _worker_reporting.progress("transcript.glossary.complete", f"{edits} corrections")
        return cues
    except Exception as error:  # noqa: BLE001 - a polish failure must not cost the transcript
        _worker_reporting.progress("transcript.glossary.failed", f"{type(error).__name__}: {error}")
        return cues
