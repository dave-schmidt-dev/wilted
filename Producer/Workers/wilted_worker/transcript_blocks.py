"""Sentence and paragraph grouping with deterministic transport caps."""
from __future__ import annotations

import json
from typing import Any, Sequence

from . import reporting
from .transcript_word_timing import TranscriptWord

MAX_CUE_COUNT = 20_000
MAX_CUES_ENCODED_BYTES = 1_000_000
MAX_CUE_TEXT_BYTES = 8_192
MAX_CUE_SPEAKER_BYTES = 128
MAX_CUE_RAW_TEXT_BYTES = 8_192
MAX_WORD_TEXT_BYTES = 1_024
MAX_WORD_RAW_TEXT_BYTES = 1_024

PAUSE_SPLIT_THRESHOLD_S = 1.2
PARAGRAPH_MIN_WORDS = 25
PARAGRAPH_MAX_WORDS = 75
PARAGRAPH_MAX_DURATION_S = 30.0

ABBREVIATIONS = frozenset({
    "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "vs.", "e.g.", "i.e.", "jr.", "sr."
})


class TranscriptSizeError(ValueError):
    """Raised when transcript cues cannot deterministically fit within contract limits."""
    pass


def _is_sentence_boundary(word_text: str) -> bool:
    cleaned = word_text.rstrip("\"'”’) ]")
    if not cleaned.endswith((".", "?", "!")):
        return False
    lower = cleaned.lower()
    return lower not in ABBREVIATIONS


def _clean_transient_keys(cues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    for cue in cues:
        cue.pop("_partition_id", None)
    return cues


def group_words_into_blocks(
    words: Sequence[TranscriptWord],
    *,
    pause_threshold_s: float = PAUSE_SPLIT_THRESHOLD_S,
    min_words: int = PARAGRAPH_MIN_WORDS,
    max_words: int = PARAGRAPH_MAX_WORDS,
    max_duration_s: float = PARAGRAPH_MAX_DURATION_S,
) -> list[dict[str, Any]]:
    """Group timed words into sentence and short paragraph cues.

    Never bridges speaker changes or cut partitions / removed-audio discontinuities.
    Timestamps are built strictly from original word boundaries.
    Enforces max_words, max_duration_s (unconditional), and 8192-byte cue text cap.
    """
    if not words:
        return []

    cues: list[dict[str, Any]] = []
    current_block: list[TranscriptWord] = []

    def flush_block():
        if not current_block:
            return
        start_s = round(current_block[0].start_s, 3)
        end_s = round(current_block[-1].end_s, 3)

        # Build display text respecting spacing join units
        display_tokens: list[str] = []
        for w in current_block:
            if w.display_text is not None:
                if w.display_text != "":
                    display_tokens.append(w.display_text)
            else:
                display_tokens.append(w.text)
        text = " ".join(display_tokens).strip()

        raw_text = " ".join(w.raw_text or w.text for w in current_block).strip()
        speaker = current_block[0].speaker
        partition_id = current_block[0].partition_id

        cue: dict[str, Any] = {
            "startSeconds": start_s,
            "endSeconds": max(start_s, end_s),
            "text": text,
            "words": [w.to_dict() for w in current_block],
            "_partition_id": partition_id,
        }
        if speaker:
            cue["speaker"] = speaker
        if raw_text != text:
            cue["rawText"] = raw_text

        cues.append(cue)
        current_block.clear()

    for idx, word in enumerate(words):
        if current_block:
            prev = current_block[-1]
            speaker_changed = word.speaker != prev.speaker
            partition_changed = word.partition_id != prev.partition_id
            timing_gap = word.start_s - prev.end_s
            has_discontinuity = (word.start_s < prev.end_s - 0.05) or (timing_gap > pause_threshold_s * 2.5)

            # Check 8192-byte cue text cap before adding word
            hypothetical_tokens = [w.display_text if w.display_text is not None else w.text for w in current_block]
            hypothetical_tokens.append(word.display_text if word.display_text is not None else word.text)
            hypothetical_text = " ".join(t for t in hypothetical_tokens if t)
            byte_cap_exceeded = len(hypothetical_text.encode("utf-8")) > MAX_CUE_TEXT_BYTES

            if speaker_changed or partition_changed or has_discontinuity or byte_cap_exceeded:
                flush_block()

        current_block.append(word)

        if len(current_block) >= 1:
            prev = current_block[-1]
            is_sentence_end = _is_sentence_boundary(word.text)
            next_word = words[idx + 1] if idx + 1 < len(words) else None
            next_pause = (next_word.start_s - prev.end_s) if next_word else 0.0
            is_natural_pause = next_pause >= pause_threshold_s

            block_duration = prev.end_s - current_block[0].start_s
            word_count = len(current_block)

            # max_duration_s is an actual bound at a measured word boundary, not conditional on punctuation
            should_split = False
            if word_count >= max_words or block_duration >= max_duration_s:
                should_split = True
            elif (is_sentence_end or is_natural_pause) and (word_count >= min_words):
                should_split = True

            if should_split and next_word is not None:
                flush_block()

    flush_block()
    return enforce_transcript_caps(cues)


def group_tokenless_cues(
    cues: Sequence[dict[str, Any]],
    *,
    pause_threshold_s: float = PAUSE_SPLIT_THRESHOLD_S,
    max_words: int = PARAGRAPH_MAX_WORDS,
    max_duration_s: float = PARAGRAPH_MAX_DURATION_S,
) -> list[dict[str, Any]]:
    """Group tokenless/legacy cues merging only at existing boundaries.

    Respects real gaps, overlap, speaker partitions, and cut discontinuities.
    Preserves rawText and word metadata when present, never throwing it away.
    """
    if not cues:
        return []

    grouped: list[dict[str, Any]] = []
    current_group: list[dict[str, Any]] = []

    def flush_group():
        if not current_group:
            return
        start_s = float(current_group[0]["startSeconds"])
        end_s = float(current_group[-1]["endSeconds"])
        text = " ".join(c["text"].strip() for c in current_group).strip()
        speaker = current_group[0].get("speaker")
        partition_id = current_group[0].get("_partition_id")

        cue: dict[str, Any] = {
            "startSeconds": round(start_s, 3),
            "endSeconds": round(end_s, 3),
            "text": text,
        }
        if speaker:
            cue["speaker"] = speaker
        if partition_id is not None:
            cue["_partition_id"] = partition_id

        # Preserve rawText if present
        if any("rawText" in c for c in current_group):
            raw_parts = [str(c.get("rawText", c["text"])).strip() for c in current_group]
            combined_raw = " ".join(raw_parts).strip()
            if combined_raw != text:
                cue["rawText"] = combined_raw

        # Preserve word detail if present
        if any("words" in c for c in current_group):
            combined_words = []
            for c in current_group:
                if c.get("words"):
                    combined_words.extend(c["words"])
            if combined_words:
                cue["words"] = combined_words

        grouped.append(cue)
        current_group.clear()

    for cue in cues:
        if current_group:
            prev = current_group[-1]
            prev_speaker = prev.get("speaker")
            curr_speaker = cue.get("speaker")
            prev_part = prev.get("_partition_id")
            curr_part = cue.get("_partition_id")
            timing_gap = float(cue["startSeconds"]) - float(prev["endSeconds"])
            is_backwards = float(cue["startSeconds"]) < float(prev["startSeconds"]) - 1e-4

            speaker_changed = curr_speaker != prev_speaker
            partition_changed = (curr_part is not None or prev_part is not None) and (curr_part != prev_part)
            has_gap = timing_gap > pause_threshold_s * 2.5 or is_backwards

            total_words = sum(len(c["text"].split()) for c in current_group)
            duration = float(cue["endSeconds"]) - float(current_group[0]["startSeconds"])
            hypothetical_text = " ".join(c["text"].strip() for c in current_group) + " " + cue["text"].strip()
            byte_exceeded = len(hypothetical_text.encode("utf-8")) > MAX_CUE_TEXT_BYTES

            if speaker_changed or partition_changed or has_gap or byte_exceeded:
                flush_group()
            elif total_words >= max_words or duration >= max_duration_s:
                flush_group()

        current_group.append(cue)

    flush_group()
    return enforce_transcript_caps(grouped)


def _cue_encoded_bytes(cues: Sequence[dict[str, Any]]) -> int:
    try:
        return len(json.dumps(cues, ensure_ascii=False).encode("utf-8"))
    except Exception as exc:
        raise TranscriptSizeError(f"Transcript cues failed JSON serialization: {exc}") from exc


def _trimmed_string(value: Any) -> str:
    """Match Swift's storage normalization before measuring a string field."""
    return str(value).strip()


def _utf8_bytes(value: str) -> int:
    return len(value.encode("utf-8"))


def _sanitize_optional_detail(cues: Sequence[dict[str, Any]]) -> tuple[list[dict[str, Any]], bool]:
    """Keep optional detail within Swift's byte caps without losing cue text."""
    sanitized_cues: list[dict[str, Any]] = []
    omitted_detail = False

    for source_cue in cues:
        cue = dict(source_cue)
        cue["text"] = _trimmed_string(cue.get("text", ""))

        speaker = cue.get("speaker")
        if speaker is not None:
            speaker = _trimmed_string(speaker)
            speaker_bytes = _utf8_bytes(speaker)
            if speaker_bytes > MAX_CUE_SPEAKER_BYTES:
                raise TranscriptSizeError(
                    f"Transcript cue speaker ({speaker_bytes} bytes) exceeds limit of {MAX_CUE_SPEAKER_BYTES} bytes"
                )
            cue["speaker"] = speaker

        if "rawText" in cue:
            raw_text = _trimmed_string(cue["rawText"])
            if _utf8_bytes(raw_text) > MAX_CUE_RAW_TEXT_BYTES:
                cue.pop("rawText")
                omitted_detail = True
            else:
                cue["rawText"] = raw_text

        words = cue.get("words")
        if words is not None:
            if not isinstance(words, list):
                cue.pop("words")
                omitted_detail = True
            else:
                sanitized_words: list[dict[str, Any]] = []
                omit_words = False
                for source_word in words:
                    if not isinstance(source_word, dict):
                        omit_words = True
                        break

                    word = dict(source_word)
                    word["text"] = _trimmed_string(word.get("text", ""))
                    if _utf8_bytes(word["text"]) > MAX_WORD_TEXT_BYTES:
                        omit_words = True
                        break

                    if "rawText" in word:
                        raw_text = _trimmed_string(word["rawText"])
                        if _utf8_bytes(raw_text) > MAX_WORD_RAW_TEXT_BYTES:
                            word.pop("rawText")
                            omitted_detail = True
                        else:
                            word["rawText"] = raw_text
                    sanitized_words.append(word)

                if omit_words:
                    cue.pop("words")
                    omitted_detail = True
                else:
                    cue["words"] = sanitized_words

        sanitized_cues.append(cue)

    return sanitized_cues, omitted_detail


def enforce_transcript_caps(cues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Deterministically enforce the 1MB aggregate and 20k cue limits.

    Rechecks every limit, including the 8192-byte text cap per cue.
    Omits optional word and raw text details before exceeding limits, while
    preserving all base grouped text, start, end, and speaker.
    Raises TranscriptSizeError if the transcript cannot fit without dropping text
    or speaker boundaries.
    """
    if not cues:
        return []

    capped_cues, omitted_detail = _sanitize_optional_detail(cues)
    if omitted_detail:
        reporting.progress(
            "transcript.caps.warning",
            "Transcript optional detail exceeded field byte caps; omitting detail to preserve transcript",
        )

    # Verify each cue satisfies the required display-text bound.
    for c in capped_cues:
        text_bytes = _utf8_bytes(c["text"])
        if text_bytes > MAX_CUE_TEXT_BYTES:
            raise TranscriptSizeError(
                f"Transcript cue text ({text_bytes} bytes) exceeds limit of {MAX_CUE_TEXT_BYTES} bytes"
            )

    encoded_size = _cue_encoded_bytes(capped_cues)
    if encoded_size <= MAX_CUES_ENCODED_BYTES and len(capped_cues) <= MAX_CUE_COUNT:
        return _clean_transient_keys(capped_cues)

    reporting.progress(
        "transcript.caps.warning",
        "Transcript payload exceeds size budget; omitting word detail to preserve transcript",
    )

    stripped_cues: list[dict[str, Any]] = []
    for c in capped_cues:
        stripped: dict[str, Any] = {
            "startSeconds": c["startSeconds"],
            "endSeconds": c["endSeconds"],
            "text": c["text"],
        }
        if c.get("speaker"):
            stripped["speaker"] = c["speaker"]
        if c.get("_partition_id") is not None:
            stripped["_partition_id"] = c["_partition_id"]
        stripped_cues.append(stripped)

    stripped_size = _cue_encoded_bytes(stripped_cues)
    if stripped_size <= MAX_CUES_ENCODED_BYTES and len(stripped_cues) <= MAX_CUE_COUNT:
        return _clean_transient_keys(stripped_cues)

    # Safe deterministic merge of adjacent cues from same speaker and partition
    if len(stripped_cues) > MAX_CUE_COUNT:
        merged_cues: list[dict[str, Any]] = []
        for cue in stripped_cues:
            if (
                merged_cues
                and merged_cues[-1].get("speaker") == cue.get("speaker")
                and merged_cues[-1].get("_partition_id") == cue.get("_partition_id")
                and (float(cue["startSeconds"]) - float(merged_cues[-1]["endSeconds"]) <= PAUSE_SPLIT_THRESHOLD_S * 2.5)
                and (float(cue["endSeconds"]) - float(merged_cues[-1]["startSeconds"]) <= PARAGRAPH_MAX_DURATION_S)
                and (len((merged_cues[-1]["text"] + " " + cue["text"]).encode("utf-8")) <= MAX_CUE_TEXT_BYTES)
            ):
                merged_cues[-1]["endSeconds"] = cue["endSeconds"]
                merged_cues[-1]["text"] += " " + cue["text"]
            else:
                merged_cues.append(dict(cue))

        merged_size = _cue_encoded_bytes(merged_cues)
        if merged_size <= MAX_CUES_ENCODED_BYTES and len(merged_cues) <= MAX_CUE_COUNT:
            return _clean_transient_keys(merged_cues)

    raise TranscriptSizeError(
        f"Transcript content exceeds transport capacity ({MAX_CUES_ENCODED_BYTES} bytes / {MAX_CUE_COUNT} cues) "
        "and cannot deterministically fit without dropping base text or speakers"
    )
