"""Word-level timing extraction, validation, and keep-map remapping for Wilted transcripts."""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Sequence

from .cue_timing import KeepInterval


@dataclass(frozen=True)
class TranscriptWord:
    """One timed word unit derived from aligned speech-to-text tokens or cues."""

    start_s: float
    end_s: float
    text: str
    raw_text: str | None = None
    speaker: str | None = None
    partition_id: int = 0
    display_text: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "startSeconds": round(self.start_s, 3),
            "endSeconds": round(self.end_s, 3),
            "text": self.text,
        }
        if self.raw_text is not None and self.raw_text.strip():
            result["rawText"] = self.raw_text.strip()
        return result

    @classmethod
    def from_dict(cls, data: dict[str, Any], speaker: str | None = None) -> TranscriptWord:
        start = float(data["startSeconds"])
        end = float(data["endSeconds"])
        text = str(data["text"]).strip()
        raw_text = data.get("rawText")
        raw = str(raw_text).strip() if raw_text is not None else None
        spk = data.get("speaker") or speaker
        return cls(
            start_s=start,
            end_s=end,
            text=text,
            raw_text=raw,
            speaker=str(spk) if spk else None,
        )


def _token_text(tok: Any) -> str:
    if isinstance(tok, str):
        return tok
    if isinstance(tok, dict):
        return str(tok.get("text", ""))
    return str(getattr(tok, "text", ""))


def _token_start(tok: Any) -> float:
    if isinstance(tok, dict):
        return float(tok.get("start_s", tok.get("startSeconds", 0.0)))
    return float(getattr(tok, "start_s", getattr(tok, "startSeconds", 0.0)))


def _token_end(tok: Any) -> float:
    if isinstance(tok, dict):
        return float(tok.get("end_s", tok.get("endSeconds", 0.0)))
    return float(getattr(tok, "end_s", getattr(tok, "endSeconds", 0.0)))


def extract_words_from_tokens(
    tokens: Sequence[Any],
    speaker: str | None = None,
) -> list[TranscriptWord]:
    """Join subword tokens into word units by leading whitespace.

    A token that begins with whitespace marks the start of a new word. Tokens
    without leading whitespace continue the preceding word. The very first
    token always opens the first word.
    """
    if not tokens:
        return []

    words: list[TranscriptWord] = []
    current_tokens: list[Any] = []

    def flush_word():
        if not current_tokens:
            return
        w_start = _token_start(current_tokens[0])
        w_end = _token_end(current_tokens[-1])
        tok_texts = tuple(_token_text(t) for t in current_tokens)
        joined_raw = "".join(tok_texts)
        cleaned_text = joined_raw.strip()
        if cleaned_text and math.isfinite(w_start) and math.isfinite(w_end) and w_start >= 0 and w_end >= w_start:
            words.append(
                TranscriptWord(
                    start_s=w_start,
                    end_s=w_end,
                    text=cleaned_text,
                    raw_text=cleaned_text,
                    speaker=speaker,
                )
            )
        current_tokens.clear()

    for index, token in enumerate(tokens):
        text = _token_text(token)
        is_new_word = (index == 0) or (len(text) > 0 and text[0].isspace())
        if is_new_word and current_tokens:
            flush_word()
        current_tokens.append(token)

    flush_word()
    return validate_words(words)


def extract_words_from_segment(segment: Any) -> list[TranscriptWord]:
    """Extract validated word units from a segment if aligned tokens exist."""
    tokens = getattr(segment, "tokens", None)
    if isinstance(segment, dict):
        tokens = segment.get("tokens")
    speaker = getattr(segment, "speaker", None)
    if isinstance(segment, dict) and not speaker:
        speaker = segment.get("speaker")
    if tokens:
        return extract_words_from_tokens(tokens, speaker=speaker)
    return []


def validate_words(
    words: Sequence[TranscriptWord],
    cue_start: float | None = None,
    cue_end: float | None = None,
) -> list[TranscriptWord]:
    """Ensure finite, nonnegative, ordered timestamps within optional cue bounds."""
    validated: list[TranscriptWord] = []
    prev_start = -1.0

    for word in words:
        if not (math.isfinite(word.start_s) and math.isfinite(word.end_s)):
            continue
        if word.start_s < 0 or word.end_s < word.start_s:
            continue
        if not word.text.strip():
            continue
        # Non-decreasing start timestamps
        if word.start_s < prev_start - 1e-6:
            continue
        if cue_start is not None and word.start_s < cue_start - 1e-4:
            continue
        if cue_end is not None and word.end_s > cue_end + 1e-4:
            continue
        validated.append(word)
        prev_start = word.start_s

    return validated


def remap_words_with_keep_map(
    words: Sequence[TranscriptWord],
    keeps: Sequence[KeepInterval],
) -> list[TranscriptWord]:
    """Remap word timestamps across keep intervals without inventing interior times.

    Words falling entirely or partially across removed audio cuts are dropped;
    exact measured boundaries are preserved for surviving words.
    Surviving words carry a transient partition_id identifying the keep interval.
    """
    if not words or not keeps:
        return []

    remapped: list[TranscriptWord] = []
    keep_iter = enumerate(keeps)
    keep_idx, current_keep = next(keep_iter, (0, None))

    for word in words:
        while current_keep is not None and word.start_s >= current_keep.end_s - 1e-4:
            keep_idx, current_keep = next(keep_iter, (keep_idx + 1, None))
        if current_keep is None:
            break

        # Reject a word spanning a cut boundary rather than manufacturing part-word timing.
        # Word must fall wholly within the surviving keep span with exact measured boundaries.
        if word.start_s >= current_keep.start_s - 1e-4 and word.end_s <= current_keep.end_s + 1e-4:
            offset = current_keep.output_start_s - current_keep.start_s
            remapped.append(
                TranscriptWord(
                    start_s=round(word.start_s + offset, 3),
                    end_s=round(word.end_s + offset, 3),
                    text=word.text,
                    raw_text=word.raw_text,
                    speaker=word.speaker,
                    partition_id=keep_idx,
                    display_text=word.display_text,
                )
            )

    return validate_words(remapped)


def _emit_remapped_cue(
    words: list[TranscriptWord],
    parent_cue: dict[str, Any],
    speaker: str | None,
    out_cues: list[dict[str, Any]],
) -> None:
    if not words:
        return
    cue_dict: dict[str, Any] = {
        "startSeconds": words[0].start_s,
        "endSeconds": words[-1].end_s,
        "text": " ".join(w.text for w in words),
        "words": [w.to_dict() for w in words],
        "_partition_id": words[0].partition_id,
    }
    if speaker:
        cue_dict["speaker"] = speaker
    if parent_cue.get("rawText"):
        cue_dict["rawText"] = " ".join(w.raw_text or w.text for w in words)
    out_cues.append(cue_dict)


def remap_cues_with_keep_map(
    cues: Sequence[dict[str, Any]],
    keeps: Sequence[KeepInterval],
) -> list[dict[str, Any]]:
    """Remap cue dictionaries across keep intervals.

    Tokenless cues merge only at existing boundaries and never invent interior
    timestamps. Cues with word detail have their words remapped; empty cues
    resulting from cuts are pruned. Cues never bridge across cut intervals.
    """
    if not cues or not keeps:
        return []

    remapped_cues: list[dict[str, Any]] = []

    for cue in cues:
        c_start = float(cue["startSeconds"])
        c_end = float(cue["endSeconds"])
        text = str(cue["text"]).strip()
        speaker = cue.get("speaker")
        raw_words = cue.get("words")

        if raw_words:
            domain_words = [TranscriptWord.from_dict(w, speaker=speaker) for w in raw_words]
            remapped_words = remap_words_with_keep_map(domain_words, keeps)
            if remapped_words:
                current_part_words: list[TranscriptWord] = []
                for w in remapped_words:
                    if current_part_words and w.partition_id != current_part_words[-1].partition_id:
                        _emit_remapped_cue(current_part_words, cue, speaker, remapped_cues)
                        current_part_words = []
                    current_part_words.append(w)
                if current_part_words:
                    _emit_remapped_cue(current_part_words, cue, speaker, remapped_cues)
        else:
            matching_keep = None
            matching_idx = None
            for idx, keep in enumerate(keeps):
                if c_start >= keep.start_s - 1e-4 and c_end <= keep.end_s + 1e-4:
                    matching_keep = keep
                    matching_idx = idx
                    break
            if matching_keep is not None:
                offset = matching_keep.output_start_s - matching_keep.start_s
                new_start = round(c_start + offset, 3)
                new_end = round(c_end + offset, 3)
                cue_dict: dict[str, Any] = {
                    "startSeconds": new_start,
                    "endSeconds": new_end,
                    "text": text,
                    "_partition_id": matching_idx,
                }
                if speaker:
                    cue_dict["speaker"] = speaker
                if cue.get("rawText"):
                    cue_dict["rawText"] = str(cue["rawText"]).strip()
                remapped_cues.append(cue_dict)

    return remapped_cues
