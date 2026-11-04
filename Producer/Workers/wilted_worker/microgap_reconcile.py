"""Reconcile one source-bounded opening-gap decode against its original words."""
from __future__ import annotations

import dataclasses
import math
from dataclasses import dataclass


# The selected Parakeet model uses sample_rate=16 kHz, window_stride=10 ms,
# and subsampling_factor=8. parakeet_mlx's time_ratio formula yields one 80 ms
# token frame; callers enable this allowance only for that configured model.
MICROGAP_ALIGNMENT_FRAME_S = 0.08
MICROGAP_FRAGMENT_MINIMUM_CHARACTERS = 4


@dataclass(frozen=True)
class InterCueGap:
    """One positive source interval between adjacent lexical transcript cues."""

    start_s: float
    end_s: float
    left_segment_index: int
    right_segment_index: int


@dataclass(frozen=True)
class _Word:
    """One lexical word and its source support in a transcript or recheck."""

    text: str
    key: str
    start_s: float
    end_s: float
    segment_index: int
    token_start: int
    token_end: int
    tokens: tuple
    source_segment: object


@dataclass(frozen=True)
class _Decision:
    """Source-supported edits accepted for one original gap."""

    updates: tuple[tuple[int, float, float], ...] = ()
    additions: tuple[_Word, ...] = ()
    replacements: tuple[tuple[int, _Word], ...] = ()
    state: str = "unchanged"


def _lexical(text: object) -> bool:
    return any(character.isalnum() for character in str(text or ""))


def _word_key(text: str) -> str:
    return "".join(character.casefold() for character in text if character.isalnum())


def _normalized_segment_text(text: str) -> str:
    return " ".join(str(text or "").split()).casefold()


def _token_groups(tokens) -> list[tuple[int, int, tuple]]:
    """Group subword tokens by their whitespace word-start marker."""
    groups = []
    start = 0
    current = []
    for index, token in enumerate(tokens):
        if current and str(getattr(token, "text", ""))[:1].isspace():
            groups.append((start, index, tuple(current)))
            start, current = index, []
        current.append(token)
    if current:
        groups.append((start, len(tokens), tuple(current)))
    return groups


def words_from_segments(
    segments,
    *,
    offset_s: float,
    duration_s: float,
    window_duration_s: float | None = None,
) -> list[_Word]:
    """Extract finite lexical token groups in source time, ignoring punctuation support."""
    words = []
    for segment_index, segment in enumerate(segments or ()):
        tokens = getattr(segment, "tokens", None) or ()
        for token_start, _token_end, group in _token_groups(tokens):
            text = "".join(str(getattr(token, "text", "")) for token in group).strip()
            key = _word_key(text)
            lexical_indexes = [index for index, token in enumerate(group) if _lexical(getattr(token, "text", ""))]
            if not key or not lexical_indexes:
                continue
            timings = []
            valid = True
            for token in group:
                try:
                    start, end = float(token.start_s), float(token.end_s)
                except (AttributeError, TypeError, ValueError, OverflowError):
                    valid = False
                    break
                if not (math.isfinite(start) and math.isfinite(end) and 0.0 <= start < end):
                    valid = False
                    break
                if window_duration_s is not None and end > window_duration_s:
                    valid = False
                    break
                timings.append((start + offset_s, end + offset_s))
            if not valid:
                continue
            first_lexical, last_lexical = lexical_indexes[0], lexical_indexes[-1]
            start, end = timings[first_lexical][0], timings[last_lexical][1]
            if not (math.isfinite(start) and math.isfinite(end) and 0.0 <= start < end <= duration_s):
                continue
            lexical_tokens = tuple(
                dataclasses.replace(group[index], start_s=timings[index][0], end_s=timings[index][1])
                for index in lexical_indexes
            )
            words.append(_Word(
                text,
                key,
                start,
                end,
                segment_index,
                token_start + first_lexical,
                token_start + last_lexical + 1,
                lexical_tokens,
                segment,
            ))
    return sorted(words, key=lambda word: (word.start_s, word.end_s, word.segment_index))


def _overlap(left: _Word, right: _Word) -> float:
    return min(left.end_s, right.end_s) - max(left.start_s, right.start_s)


def _intersects(word: _Word, gap: InterCueGap) -> bool:
    return word.start_s < gap.end_s and word.end_s > gap.start_s


def _unique_anchor_index(anchor: _Word, words: list[_Word], frame_s: float) -> int | None:
    # Ignore only a competing same-spelling overlap no larger than one model
    # frame; a later ordered repeat must not steal the unique anchor slot.
    matches = [
        index for index, word in enumerate(words)
        if word.key == anchor.key and _overlap(anchor, word) > frame_s + 1e-9
    ]
    return matches[0] if len(matches) == 1 else None


def _outer_anchors(baseline: list[_Word], gap: InterCueGap):
    left = [(index, word) for index, word in enumerate(baseline) if word.end_s <= gap.start_s]
    right = [(index, word) for index, word in enumerate(baseline) if word.start_s >= gap.end_s]
    if not left or not right:
        return None
    return (
        max(left, key=lambda row: (row[1].end_s, row[1].start_s)),
        min(right, key=lambda row: (row[1].start_s, row[1].end_s)),
    )


def _fragment_completion(
    baseline: list[_Word],
    decoded: list[_Word],
    gap: InterCueGap,
    frame_s: float,
) -> _Decision | None:
    """Replace one timed, non-word-start edge fragment with its exact completion."""
    matches: list[tuple[int, _Word]] = []
    for fragment_index, fragment in enumerate(baseline):
        if (
            fragment.segment_index != gap.right_segment_index
            or fragment.token_start != 0
            or len(fragment.key) < MICROGAP_FRAGMENT_MINIMUM_CHARACTERS
            or fragment.tokens[0].text[:1].isspace()
            or fragment.start_s < gap.end_s - frame_s
            or fragment.start_s > gap.end_s + frame_s
        ):
            continue
        source_tokens = getattr(fragment.source_segment, "tokens", None) or ()
        token_text = "".join(str(token.text) for token in source_tokens)
        if _normalized_segment_text(fragment.source_segment.text) != _normalized_segment_text(token_text):
            continue
        left_right = _outer_anchors(baseline, gap)
        if left_right is None:
            continue
        left, _immediate_right = left_right
        outer_right_options = [
            (index, word) for index, word in enumerate(baseline)
            if index != fragment_index and word.start_s >= fragment.end_s
        ]
        if not outer_right_options:
            continue
        outer_right = min(outer_right_options, key=lambda row: (row[1].start_s, row[1].end_s))
        if left[0] >= fragment_index or fragment_index >= outer_right[0]:
            continue

        candidates = [
            (index, word) for index, word in enumerate(decoded)
            if _intersects(word, gap)
            and word.key.endswith(fragment.key)
            and word.key != fragment.key
            and word.start_s >= gap.start_s
            and word.start_s < fragment.start_s
            and word.end_s >= fragment.end_s - frame_s
            and word.end_s <= float(fragment.source_segment.end_s)
        ]
        if len(candidates) != 1:
            continue
        candidate_index, candidate = candidates[0]
        overlapping = [
            (base_index, base) for base_index, base in enumerate(baseline)
            if _overlap(candidate, base) > 0.0
        ]
        if len(overlapping) != 1 or overlapping[0][0] != fragment_index:
            continue
        union_start = min(fragment.start_s, candidate.start_s)
        union_end = max(fragment.end_s, candidate.end_s)
        if union_start < gap.start_s or union_end > float(fragment.source_segment.end_s):
            continue
        if any(
            _intersects(word, gap) and index != candidate_index
            for index, word in enumerate(decoded)
        ):
            continue
        left_decoded = _unique_anchor_index(left[1], decoded, frame_s)
        right_decoded = _unique_anchor_index(outer_right[1], decoded, frame_s)
        if (
            left_decoded is None
            or right_decoded is None
            or not left_decoded < candidate_index < right_decoded
            or decoded[left_decoded].end_s > candidate.start_s
            or candidate.end_s > decoded[right_decoded].start_s
        ):
            continue
        matches.append((fragment_index, candidate))

    if len(matches) != 1:
        return None
    fragment_index, candidate = matches[0]
    # This is the sole baseline-token identity exception: an anchored full
    # returned word completes an edge fragment; all other baseline words stay.
    return _Decision(replacements=((fragment_index, candidate),), state="accepted-fragment-completion")


def _independent_edge_addition(
    baseline: list[_Word],
    decoded: list[_Word],
    word_index: int,
    gap: InterCueGap,
    left_baseline_anchor_index: int,
    right_baseline_anchor_index: int,
    left_decoded_anchor_index: int,
    right_decoded_anchor_index: int,
    frame_s: float,
) -> bool:
    """Allow a distinct full decode word to cross one cue edge by one frame."""
    if not left_decoded_anchor_index < word_index < right_decoded_anchor_index or not _intersects(decoded[word_index], gap):
        return False
    word = decoded[word_index]
    if word_index == 0 or word_index + 1 >= len(decoded):
        return False
    if decoded[word_index - 1].end_s > word.start_s or word.end_s > decoded[word_index + 1].start_s:
        return False
    overlaps = [
        (index, baseline_word) for index, baseline_word in enumerate(baseline)
        if _overlap(word, baseline_word) > 0.0
    ]
    if len(overlaps) != 1:
        return False
    anchor_index, anchor = overlaps[0]
    if anchor_index not in (left_baseline_anchor_index, right_baseline_anchor_index):
        return False
    shared = _overlap(word, anchor)
    if shared > frame_s + 1e-9:
        return False
    if anchor_index == left_baseline_anchor_index:
        return word.start_s < gap.start_s and word.start_s >= gap.start_s - frame_s and word.end_s <= gap.end_s
    return word.end_s > gap.end_s and word.end_s <= gap.end_s + frame_s and word.start_s >= gap.start_s


def reconcile_gap(
    baseline: list[_Word],
    decoded: list[_Word],
    gap: InterCueGap,
    *,
    frame_tolerance_s: float = MICROGAP_ALIGNMENT_FRAME_S,
) -> _Decision:
    """Accept only complete, anchored source words and exact edge completions."""
    frame_s = float(frame_tolerance_s)
    if not math.isfinite(frame_s) or frame_s < 0.0:
        frame_s = 0.0
    completion = _fragment_completion(baseline, decoded, gap, frame_s)
    if completion is not None:
        return completion

    left_words = [(index, word) for index, word in enumerate(baseline) if word.start_s < gap.start_s]
    right_words = [(index, word) for index, word in enumerate(baseline) if word.end_s > gap.end_s]
    if not left_words or not right_words:
        return _Decision(state="ambiguous-no-anchors")
    left_anchor_index, left_anchor = max(left_words, key=lambda row: (row[1].end_s, row[1].start_s))
    right_anchor_index, right_anchor = min(right_words, key=lambda row: (row[1].start_s, row[1].end_s))
    if left_anchor_index >= right_anchor_index:
        return _Decision(state="ambiguous-anchor-order")
    left_decoded_index = _unique_anchor_index(left_anchor, decoded, frame_s)
    right_decoded_index = _unique_anchor_index(right_anchor, decoded, frame_s)
    if (
        left_decoded_index is None
        or right_decoded_index is None
        or left_decoded_index >= right_decoded_index
    ):
        return _Decision(state="ambiguous-anchors")

    intersecting = [index for index, word in enumerate(decoded) if _intersects(word, gap)]
    if not intersecting:
        return _Decision(state="unchanged-empty-gap")
    if any(index < left_decoded_index or index > right_decoded_index for index in intersecting):
        return _Decision(state="ambiguous-order")

    updates: dict[int, tuple[float, float]] = {}
    additions: list[_Word] = []
    matched_ids: set[int] = set()
    for index in intersecting:
        word = decoded[index]
        overlapping = [(base_index, base) for base_index, base in enumerate(baseline) if _overlap(word, base) > 0.0]
        conflicts = [(base_index, base) for base_index, base in overlapping if base.key != word.key]
        matches = [(base_index, base) for base_index, base in overlapping if base.key == word.key]
        if len(matches) > 1:
            return _Decision(state="ambiguous-overlap")
        if conflicts or matches:
            if _independent_edge_addition(
                baseline, decoded, index, gap,
                left_anchor_index, right_anchor_index,
                left_decoded_index, right_decoded_index,
                frame_s,
            ):
                additions.append(word)
                continue
            if conflicts or len(matches) != 1:
                return _Decision(state="ambiguous-overlap")
            baseline_index, base = matches[0]
            if baseline_index in matched_ids:
                return _Decision(state="ambiguous-repeat-match")
            # A later same-spelling token is a distinct occurrence when the
            # returned decode separates it from its matched outer anchor.
            if baseline_index in (left_anchor_index, right_anchor_index) and index not in (
                left_decoded_index, right_decoded_index
            ):
                if _independent_edge_addition(
                    baseline, decoded, index, gap,
                    left_anchor_index, right_anchor_index,
                    left_decoded_index, right_decoded_index,
                    frame_s,
                ):
                    additions.append(word)
                    continue
                return _Decision(state="ambiguous-repeat-overlap")
            matched_ids.add(baseline_index)
            supported_start = max(word.start_s, gap.start_s)
            supported_end = min(word.end_s, gap.end_s)
            if supported_start < supported_end:
                updates[baseline_index] = (
                    min(base.start_s, max(gap.start_s, word.start_s)),
                    max(base.end_s, min(gap.end_s, word.end_s)),
                )
            continue
        if word.start_s < gap.start_s or word.end_s > gap.end_s:
            return _Decision(state="ambiguous-partial-word")
        additions.append(word)

    if not updates and not additions:
        return _Decision(state="unchanged-no-supported-words")
    if any(
        _overlap(left, right) > 0.0
        for index, left in enumerate(additions)
        for right in additions[index + 1:]
    ):
        return _Decision(state="ambiguous-overlapping-additions")
    return _Decision(
        updates=tuple((index, start, end) for index, (start, end) in updates.items()),
        additions=tuple(additions),
        state="accepted",
    )


def apply_decisions(segments, baseline: list[_Word], decisions: list[_Decision], ordering) -> list:
    """Apply all edits against immutable token offsets; replacements run right-to-left."""
    updated = list(segments)
    original_tokens = [list(getattr(segment, "tokens", None) or ()) for segment in updated]
    token_edges: dict[tuple[int, int], tuple[float | None, float | None]] = {}
    segment_bounds: dict[int, list[float]] = {}
    replacements: dict[int, list[tuple[_Word, _Word]]] = {}
    additions: list[_Word] = []

    for decision in decisions:
        for word_index, start, end in decision.updates:
            word = baseline[word_index]
            tokens = original_tokens[word.segment_index]
            bounds = segment_bounds.setdefault(
                word.segment_index,
                [float(updated[word.segment_index].start_s), float(updated[word.segment_index].end_s)],
            )
            prefix_has_word = any(_lexical(token.text) for token in tokens[:word.token_start])
            suffix_has_word = any(_lexical(token.text) for token in tokens[word.token_end:])
            if not prefix_has_word and start < word.start_s:
                token_index = word.token_start
                old_start, old_end = token_edges.get((word.segment_index, token_index), (None, None))
                token_edges[(word.segment_index, token_index)] = (start if old_start is None else min(old_start, start), old_end)
                bounds[0] = min(bounds[0], start)
            if not suffix_has_word and end > word.end_s:
                token_index = word.token_end - 1
                old_start, old_end = token_edges.get((word.segment_index, token_index), (None, None))
                token_edges[(word.segment_index, token_index)] = (old_start, end if old_end is None else max(old_end, end))
                bounds[1] = max(bounds[1], end)
        additions.extend(decision.additions)
        for word_index, replacement in decision.replacements:
            baseline_word = baseline[word_index]
            replacements.setdefault(baseline_word.segment_index, []).append((baseline_word, replacement))
            bounds = segment_bounds.setdefault(
                baseline_word.segment_index,
                [float(updated[baseline_word.segment_index].start_s), float(updated[baseline_word.segment_index].end_s)],
            )
            bounds[0] = min(bounds[0], replacement.start_s)

    changed_segments = set(segment_bounds) | {segment_index for segment_index, _ in token_edges}
    for segment_index in changed_segments:
        tokens = list(original_tokens[segment_index])
        for (owner_index, token_index), (start, end) in token_edges.items():
            if owner_index != segment_index:
                continue
            token = tokens[token_index]
            tokens[token_index] = dataclasses.replace(
                token,
                start_s=float(token.start_s) if start is None else min(float(token.start_s), start),
                end_s=float(token.end_s) if end is None else max(float(token.end_s), end),
            )
        # Token indices were captured from the immutable baseline. Applying
        # slot replacements from right to left keeps earlier slots stable.
        for baseline_word, replacement in sorted(
            replacements.get(segment_index, ()), key=lambda pair: pair[0].token_start, reverse=True
        ):
            slot = tokens[baseline_word.token_start:baseline_word.token_end]
            if not slot or not replacement.tokens:
                continue
            replacement_tokens = list(replacement.tokens)
            old_has_space = str(slot[0].text)[:1].isspace()
            new_text = str(replacement_tokens[0].text)
            replacement_tokens[0] = dataclasses.replace(
                replacement_tokens[0],
                text=(f" {new_text.lstrip()}" if old_has_space else new_text.lstrip()),
            )
            union_end = max(float(replacement_tokens[-1].end_s), baseline_word.end_s)
            if replacement_tokens[-1].start_s < union_end and replacement_tokens[-1].end_s < union_end:
                replacement_tokens[-1] = dataclasses.replace(
                    replacement_tokens[-1], end_s=union_end
                )
            tokens[baseline_word.token_start:baseline_word.token_end] = replacement_tokens
        segment = updated[segment_index]
        bounds = segment_bounds.get(segment_index, [float(segment.start_s), float(segment.end_s)])
        fields = {
            "start_s": bounds[0],
            "end_s": bounds[1],
            "tokens": tuple(tokens),
        }
        if replacements.get(segment_index):
            fields["text"] = "".join(str(token.text) for token in tokens).strip()
        updated[segment_index] = dataclasses.replace(segment, **fields)

    for word in additions:
        try:
            updated.append(dataclasses.replace(
                word.source_segment,
                start_s=word.start_s,
                end_s=word.end_s,
                text=word.text,
                tokens=word.tokens,
            ))
        except (TypeError, ValueError):
            continue
    return ordering(updated)
