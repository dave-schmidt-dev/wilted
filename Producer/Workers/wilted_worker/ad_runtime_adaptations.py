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
from .constants import LEGACY_SPONSOR_OPENING_COMPATIBILITY_PATTERN, PRODUCED_DISCLAIMER_CUE_PATTERN

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

def install_produced_disclaimer_evidence(ads_module) -> None:
    """Let recited legal terms stand as the promotional evidence a sparse run needs.

    Appended rather than substituted, so the archive's own cues keep deciding
    everything they already decided. The position matters: the tuple's first
    entry is the sponsor acknowledgement, and one caller slices it off to ask
    for a commercial signal beyond that acknowledgement. Added at the end, a
    disclaimer answers that question too, which is right -- reciting terms is
    not an acknowledgement, it is the spot itself.
    """
    existing = ads_module._SPARSE_PROMO_CUES
    if any(PRODUCED_DISCLAIMER_CUE_PATTERN == pattern.pattern for pattern in existing):
        return
    ads_module._SPARSE_PROMO_CUES = (
        *existing,
        re.compile(PRODUCED_DISCLAIMER_CUE_PATTERN, re.IGNORECASE),
    )

_PROPORTIONAL_RENDER_MARKER = "wilted_proportional_render_budget"

_CONTEXT_AWARE_OVERLAP_MARKER = "wilted_context_aware_overlap_resolution"

def _context_aware_overlap_adjustment(raw_classifications):
    """Return adjusted votes and the positive runs recovered by that adjustment."""
    if not isinstance(raw_classifications, list):
        return raw_classifications, frozenset()

    windows = []
    for chunk in raw_classifications:
        if not isinstance(chunk, list):
            return raw_classifications, frozenset()
        entries = []
        for entry in chunk:
            if (
                not isinstance(entry, tuple)
                or len(entry) != 3
                or isinstance(entry[0], bool)
                or not isinstance(entry[0], int)
                or not isinstance(entry[1], bool)
            ):
                return raw_classifications, frozenset()
            entries.append(entry)
        if any(right[0] <= left[0] for left, right in zip(entries, entries[1:])):
            return raw_classifications, frozenset()
        windows.append(entries)

    removals: set[tuple[int, int]] = set()
    recovered_ranges: set[tuple[int, int]] = set()
    for source_index, source in enumerate(windows):
        index = 0
        while index < len(source):
            if not source[index][1]:
                index += 1
                continue
            start_index = index
            while (
                index + 1 < len(source)
                and source[index + 1][1]
                and source[index + 1][0] == source[index][0] + 1
            ):
                index += 1
            end_index = index
            index += 1

            if start_index == 0 or end_index == len(source) - 1:
                continue
            start_id = source[start_index][0]
            end_id = source[end_index][0]
            if (
                source[start_index - 1][0] != start_id - 1
                or source[end_index + 1][0] != end_id + 1
            ):
                continue

            for content_index, content in enumerate(windows):
                if content_index == source_index or not content:
                    continue
                content_start_id, content_starts_as_ad, _label = content[0]
                if content_starts_as_ad or not start_id <= content_start_id <= end_id:
                    continue

                tied_suffix = [
                    (entry_index, entry)
                    for entry_index, entry in enumerate(content)
                    if content_start_id <= entry[0] <= end_id
                ]
                if [entry[0] for _entry_index, entry in tied_suffix] != list(
                    range(content_start_id, end_id + 1)
                ) or any(entry[1] for _entry_index, entry in tied_suffix):
                    continue

                candidate_removals = {
                    (content_index, entry_index) for entry_index, _entry in tied_suffix
                }
                qualifies = True
                for segment_id in range(start_id, end_id + 1):
                    votes = [
                        (window_index, entry_index, is_ad)
                        for window_index, window in enumerate(windows)
                        for entry_index, (vote_id, is_ad, _vote_label) in enumerate(window)
                        if vote_id == segment_id
                    ]
                    if segment_id < content_start_id:
                        if not votes or any(not is_ad for _window, _entry, is_ad in votes):
                            qualifies = False
                            break
                    elif (
                        len(votes) != 2
                        or sum(is_ad for _window, _entry, is_ad in votes) != 1
                        or not any(
                            (window, entry) in candidate_removals and not is_ad
                            for window, entry, is_ad in votes
                        )
                    ):
                        qualifies = False
                        break
                if qualifies:
                    removals.update(candidate_removals)
                    recovered_ranges.add((start_id, end_id))

    if not removals:
        return raw_classifications, frozenset()
    return (
        [
            [
                entry
                for entry_index, entry in enumerate(chunk)
                if (chunk_index, entry_index) not in removals
            ]
            for chunk_index, chunk in enumerate(raw_classifications)
        ],
        frozenset(recovered_ranges),
    )

def install_context_aware_overlap_resolution(ads_module) -> None:
    """Install the contextual exception and its coarse-right-edge guard."""
    resolver = getattr(ads_module, "_resolve_overlaps")
    sparse_content_start = getattr(ads_module, "_verify_sparse_content_start")
    if getattr(resolver, _CONTEXT_AWARE_OVERLAP_MARKER, False):
        return

    provenance = threading.local()

    def resolve_overlaps(raw_classifications, segments):
        provenance.runs = ()
        adapted, recovered_ranges = _context_aware_overlap_adjustment(raw_classifications)
        runs = resolver(adapted, segments)
        provenance.runs = tuple(
            run for run in runs if (run.start_id, run.end_id) in recovered_ranges
        )
        return runs

    def verify_sparse_content_start(coarse_run, confirmed_start_id, segments, backend):
        recovered_runs = getattr(provenance, "runs", ())
        if any(coarse_run is recovered for recovered in recovered_runs):
            provenance.runs = tuple(
                recovered for recovered in recovered_runs if recovered is not coarse_run
            )
            return coarse_run.end_id + 1
        return sparse_content_start(coarse_run, confirmed_start_id, segments, backend)

    setattr(resolve_overlaps, _CONTEXT_AWARE_OVERLAP_MARKER, True)
    setattr(verify_sparse_content_start, _CONTEXT_AWARE_OVERLAP_MARKER, True)
    ads_module._resolve_overlaps = resolve_overlaps  # noqa: SLF001 - archive adaptation seam
    ads_module._verify_sparse_content_start = (  # noqa: SLF001 - paired archive seam
        verify_sparse_content_start
    )

def _proportional_render_budgets(lengths: list[int], text_budget: int) -> list[int]:
    """Split a text budget so no cue is truncated while another's share goes unused.

    A water-fill: every cue that fits inside an equal share takes only what it
    needs, and what it declines is redivided among the cues still over. Repeat
    until nothing more fits, at which point the survivors split what is left
    equally -- which is the flat allocation this replaces, so a batch of
    uniformly long cues renders exactly as it did before.
    """
    budgets = [0] * len(lengths)
    pending = list(range(len(lengths)))
    remaining = text_budget
    while pending:
        share, extra = divmod(remaining, len(pending))
        if all(lengths[index] > share for index in pending):
            for rank, index in enumerate(pending):
                budgets[index] = share + (rank < extra)
            break
        for index in pending:
            if lengths[index] <= share:
                budgets[index] = lengths[index]
                remaining -= lengths[index]
        pending = [index for index in pending if lengths[index] > share]
    return budgets

def install_proportional_render_budget(ads_module) -> None:
    """Stop the classifier truncating short cues to pay for a share they cannot use.

    The archive divides a request's character budget equally across its IDs, so
    a two-word cue holds a share it will never spend while the sponsor read
    beside it loses its middle. Measured on the Practical AI episode that left
    the Framer read whole: every classification window fit under the cap in
    full, and 20 to 25 of roughly 60 cues per window were truncated regardless,
    discarding ~2,300 characters of transcript while ~3,600 characters of budget
    went unused. The batching pass already sizes requests to fit; this makes the
    renderer spend the budget the same way it was measured, and still falls back
    to the equal split for cues that genuinely do not fit.
    """
    installed = getattr(ads_module, "_render_segments_bounded", None)
    if getattr(installed, _PROPORTIONAL_RENDER_MARKER, False):
        return
    segment_prefix = ads_module._segment_prefix  # noqa: SLF001
    truncate_head_tail = ads_module._truncate_head_tail  # noqa: SLF001
    default_max_chars = ads_module._MAX_CLASSIFICATION_BATCH_CHARS  # noqa: SLF001

    def render_segments_bounded(segment_ids, segments, headers=None, max_chars=default_max_chars):
        """Render required IDs under a hard cap, giving each only what it needs."""
        header_lines = list(headers or [])
        prefixes = [segment_prefix(segment_id, segments[segment_id]) for segment_id in segment_ids]
        line_count = len(header_lines) + len(segment_ids)
        fixed_chars = sum(map(len, header_lines)) + sum(map(len, prefixes)) + max(0, line_count - 1)
        if fixed_chars > max_chars:
            raise ValueError("required transcript IDs and headers exceed the rendering budget")
        texts = [segments[segment_id].text for segment_id in segment_ids]
        budgets = _proportional_render_budgets(
            [len(text) for text in texts], max_chars - fixed_chars
        )
        rendered = [
            prefix + truncate_head_tail(text, budget)
            for prefix, text, budget in zip(prefixes, texts, budgets)
        ]
        return "\n".join(header_lines + rendered)

    setattr(render_segments_bounded, _PROPORTIONAL_RENDER_MARKER, True)
    ads_module._render_segments_bounded = render_segments_bounded  # noqa: SLF001
