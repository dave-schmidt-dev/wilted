"""Conservative validation and alignment for transcript cleanup."""
from __future__ import annotations

import difflib
import re
import unicodedata
from collections import Counter
from typing import Any, Sequence

from .glossary import GLOSSARY_STOPWORDS, _in_dictionary, _load_dictionary
from .transcript_word_timing import TranscriptWord

MAX_METADATA_TITLE_CHARS = 256
MAX_METADATA_AUTHOR_CHARS = 128
MAX_METADATA_NOTES_CHARS = 4096


def strip_formatting_punctuation(text: str) -> str:
    """Strip outer quotes, brackets, and sentence punctuation while strictly preserving
    numeric signs (+, -), decimal points (.5), currency, percent (%, ‰), and internal
    apostrophes/hyphens."""
    s = text.strip()
    if not s:
        return ""

    # Strip leading formatting punctuation that is not part of a number or currency
    while s:
        c = s[0]
        # Numeric sign (+ or -) followed by digit or decimal dot
        if c in ("+", "-"):
            if len(s) > 1 and (s[1].isdigit() or (s[1] == "." and len(s) > 2 and s[2].isdigit())):
                break
        # Decimal dot (.5) followed by digit
        if c == ".":
            if len(s) > 1 and s[1].isdigit():
                break
        # Currency symbol (Unicode category Sc)
        if unicodedata.category(c) == "Sc":
            break
        # Formatting punctuation to strip
        if c in "\"'“”‘’«»([{<—–":
            s = s[1:]
        else:
            break

    # Strip trailing formatting punctuation that is not a percent symbol
    while s:
        c = s[-1]
        if c in ("%", "‰"):
            break
        if c in ".,!?;:…—–\"'“”‘’«»)]}>":
            s = s[:-1]
        else:
            break

    return s


def is_ascii_case_equal(s1: str, s2: str) -> bool:
    """Compare two stripped tokens allowing ASCII case and equivalent punctuation to vary.

    Non-ASCII spelling, casing, and normalization must stay exact.
    """
    if len(s1) != len(s2):
        return False
    for c1, c2 in zip(s1, s2):
        if c1 == c2:
            continue
        # Straight vs curly apostrophe
        if c1 in ("'", "’") and c2 in ("'", "’"):
            continue
        # Hyphen-minus vs unicode hyphen
        if c1 in ("-", "‐") and c2 in ("-", "‐"):
            continue
        # ASCII letter case variation only
        if ("a" <= c1 <= "z" or "A" <= c1 <= "Z") and ("a" <= c2 <= "z" or "A" <= c2 <= "Z"):
            if c1.lower() == c2.lower():
                continue
        return False
    return True


def _has_internal_apostrophe(text: str) -> bool:
    return bool(re.search(r"\b\w+['’]\w+\b", text))


def _has_internal_hyphen(text: str) -> bool:
    return bool(re.search(r"\b\w+[-‐]\w+\b", text))


def _levenshtein_distance(s1: str, s2: str) -> int:
    if len(s1) < len(s2):
        return _levenshtein_distance(s2, s1)
    if len(s2) == 0:
        return len(s1)
    previous_row = list(range(len(s2) + 1))
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row
    return previous_row[-1]


def extract_bounded_metadata(request: dict[str, Any]) -> dict[str, str]:
    """Extract and bound untrusted metadata fields from the request."""
    result: dict[str, str] = {}
    field_limits = {
        "episodeTitle": MAX_METADATA_TITLE_CHARS,
        "showTitle": MAX_METADATA_TITLE_CHARS,
        "episodeAuthor": MAX_METADATA_AUTHOR_CHARS,
        "showAuthor": MAX_METADATA_AUTHOR_CHARS,
        "episodeNotes": MAX_METADATA_NOTES_CHARS,
    }
    for key, limit in field_limits.items():
        val = request.get(key)
        if isinstance(val, str):
            clean = val.strip()
            if clean:
                result[key] = clean[:limit]
    return result


def extract_proper_name_candidates(
    metadata: dict[str, str],
    dictionary: frozenset[str],
) -> set[str]:
    """Conservatively derive candidate proper names from actual metadata."""
    candidates: set[str] = set()
    for key, text in metadata.items():
        is_title_or_author = key in ("episodeTitle", "showTitle", "episodeAuthor", "showAuthor")
        tokens = re.findall(r"[^\W_]+(?:['’.-][^\W_]+)*", text, flags=re.UNICODE)
        for token in tokens:
            clean = strip_formatting_punctuation(token)
            if not clean or len(clean) < 2:
                continue
            lower = clean.lower()
            if lower in GLOSSARY_STOPWORDS:
                continue
            is_cap = clean[:1].isupper() or any(c.isupper() for c in clean)
            if is_title_or_author:
                if is_cap:
                    candidates.add(clean)
            else:
                if is_cap and not _in_dictionary(lower, dictionary):
                    candidates.add(clean)
    return candidates


def validate_and_align_cleaned_text(
    original_words: Sequence[TranscriptWord],
    cleaned_text: str,
    metadata: dict[str, str],
) -> tuple[bool, list[TranscriptWord], str]:
    """Independently validate cleaned text against original words.

    Guards:
    1. Preserves numeric signs (+, -), decimal separators (.5), grouping, percent, currency.
    2. Enforces internal apostrophes and hyphens.
    3. Validates numbers before spacing joins so 1+0 -> 10 is rejected.
    4. Rejects ordinary-word substitutions even if in metadata or repeated.
    5. Rejects ambiguous proper-name corrections (e.g. Paxon -> Paxton when Paxson is also present).
    6. Retains exact original timed word units separately from display units on joins.
    """
    if not original_words:
        return True, [], "empty"

    cleaned_tokens = cleaned_text.strip().split()
    if not cleaned_tokens:
        return False, list(original_words), "rejected: empty cleaned text"

    if len(cleaned_tokens) < max(1, int(len(original_words) * 0.7)):
        return False, list(original_words), "rejected: candidate is summary or missing words"
    if len(cleaned_tokens) > len(original_words) + 5:
        return False, list(original_words), "rejected: extra words in candidate"

    dictionary = _load_dictionary()
    candidate_names = extract_proper_name_candidates(metadata, dictionary)
    # Repeated source spellings are evidence, never a hand-written glossary.
    spellings = Counter(strip_formatting_punctuation(w.text).lower() for w in original_words)
    candidate_names.update(
        spelling for spelling, count in spellings.items()
        if count >= 2 and len(spelling) >= 5 and spelling.isascii() and spelling.isalpha()
        and spelling not in GLOSSARY_STOPWORDS and not _in_dictionary(spelling, dictionary)
    )
    candidate_names_lower = {c.lower(): c for c in candidate_names}
    unicode_names_in_metadata = {
        c.lower() for c in candidate_names if any(ord(ch) >= 128 for ch in c)
    }

    aligned_words: list[TranscriptWord] = []
    orig_idx = 0
    clean_idx = 0

    while orig_idx < len(original_words) and clean_idx < len(cleaned_tokens):
        orig_w = original_words[orig_idx]
        clean_tok = cleaned_tokens[clean_idx]

        norm_orig = strip_formatting_punctuation(orig_w.text)
        norm_clean = strip_formatting_punctuation(clean_tok)

        orig_has_digit = bool(re.search(r"\d", orig_w.text))
        clean_has_digit = bool(re.search(r"\d", clean_tok))

        # 1. Numeric validation - enforced BEFORE spacing joins
        if orig_has_digit or clean_has_digit:
            if not is_ascii_case_equal(norm_orig, norm_clean):
                return False, list(original_words), "rejected: numeric alteration"
            aligned_words.append(
                TranscriptWord(
                    start_s=orig_w.start_s,
                    end_s=orig_w.end_s,
                    text=clean_tok,
                    raw_text=orig_w.raw_text or orig_w.text,
                    speaker=orig_w.speaker,
                    partition_id=orig_w.partition_id,
                )
            )
            orig_idx += 1
            clean_idx += 1
            continue

        # 2. Defensible 2-to-1 spacing join (non-numeric only)
        if (
            orig_idx + 1 < len(original_words)
            and not bool(re.search(r"\d", original_words[orig_idx + 1].text))
            and norm_orig.lower() + strip_formatting_punctuation(original_words[orig_idx + 1].text).lower()
            == norm_clean.lower()
        ):
            w_next = original_words[orig_idx + 1]
            if w_next.start_s - orig_w.end_s <= 0.4 and orig_w.speaker == w_next.speaker:
                # Retain exact original timed word units separately from cleaned display units
                aligned_words.append(
                    TranscriptWord(
                        start_s=orig_w.start_s,
                        end_s=orig_w.end_s,
                        text=orig_w.text,
                        raw_text=orig_w.raw_text or orig_w.text,
                        speaker=orig_w.speaker,
                        partition_id=orig_w.partition_id,
                        display_text=clean_tok,
                    )
                )
                aligned_words.append(
                    TranscriptWord(
                        start_s=w_next.start_s,
                        end_s=w_next.end_s,
                        text=w_next.text,
                        raw_text=w_next.raw_text or w_next.text,
                        speaker=w_next.speaker,
                        partition_id=w_next.partition_id,
                        display_text="",
                    )
                )
                orig_idx += 2
                clean_idx += 1
                continue

        # 3. Internal apostrophe and hyphen preservation
        if _has_internal_apostrophe(orig_w.text) and not _has_internal_apostrophe(clean_tok):
            return False, list(original_words), "rejected: internal apostrophe alteration"
        if _has_internal_hyphen(orig_w.text) and not _has_internal_hyphen(clean_tok):
            return False, list(original_words), "rejected: internal hyphen alteration"

        # 4. Case 1: Identical base text (only ASCII case and/or punctuation formatting changed)
        if is_ascii_case_equal(norm_orig, norm_clean):
            aligned_words.append(
                TranscriptWord(
                    start_s=orig_w.start_s,
                    end_s=orig_w.end_s,
                    text=clean_tok,
                    raw_text=orig_w.raw_text or orig_w.text,
                    speaker=orig_w.speaker,
                    partition_id=orig_w.partition_id,
                )
            )
            orig_idx += 1
            clean_idx += 1
            continue

        # 5. Case 2: Lexical change (proper-name edit only)
        # Reject ordinary-word substitutions even if target appears in metadata or is repeated elsewhere
        clean_lower = norm_clean.lower()
        orig_lower = norm_orig.lower()

        if _in_dictionary(orig_lower, dictionary) or (
            _in_dictionary(clean_lower, dictionary) and clean_lower not in candidate_names_lower
        ):
            return False, list(original_words), "rejected: ordinary-word substitution"

        # Proper Unicode names can be corrected only with exact metadata evidence
        has_unicode = any(ord(ch) >= 128 for ch in norm_clean)
        if has_unicode and clean_lower not in unicode_names_in_metadata:
            return False, list(original_words), "rejected: proper Unicode name lacks exact metadata evidence"

        # Target must have unambiguous metadata or repeated source evidence.
        if clean_lower in candidate_names_lower:
            target_distance = _levenshtein_distance(orig_lower, clean_lower)
            target_ratio = difflib.SequenceMatcher(None, orig_lower, clean_lower).ratio()

            if target_distance <= 2 and target_ratio >= 0.8:
                # Check for ambiguity among candidate names: reject if another candidate is equally close
                ambiguous = False
                for other_cand in candidate_names:
                    other_lower = other_cand.lower()
                    if other_lower != clean_lower:
                        other_dist = _levenshtein_distance(orig_lower, other_lower)
                        if other_dist <= target_distance:
                            ambiguous = True
                            break

                if not ambiguous:
                    aligned_words.append(
                        TranscriptWord(
                            start_s=orig_w.start_s,
                            end_s=orig_w.end_s,
                            text=clean_tok,
                            raw_text=orig_w.raw_text or orig_w.text,
                            speaker=orig_w.speaker,
                            partition_id=orig_w.partition_id,
                        )
                    )
                    orig_idx += 1
                    clean_idx += 1
                    continue
                else:
                    return False, list(original_words), "rejected: ambiguous proper name candidate"

        return False, list(original_words), "rejected: unsupported lexical correction or word divergence"

    if orig_idx < len(original_words):
        return False, list(original_words), "rejected: missing words at tail"
    if clean_idx < len(cleaned_tokens):
        return False, list(original_words), "rejected: extra words at tail"

    return True, aligned_words, "ok"
