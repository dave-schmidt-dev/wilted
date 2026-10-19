"""Measure whether proximity to a confirmed ad is useful review evidence.

The worker's sponsor-read continuation is a narrow forward-only review: it
starts at a surviving `sponsor_read`, reaches at most 90 seconds into the
following passage, and then *extends the cut*. This harness measures a
different question with pure interval geometry: if a stretch of kept audio sits
immediately before or after an independently confirmed advertisement, does
pointing a reviewer at it find advertising the older preparation left behind?

Only committed manifest data is used. The corpus cases were tuning inputs for
the detector, not a holdout, so these numbers describe the cases they were
measured on and cannot stand in for a fresh evaluation. An unlabelled second is
neither a hit nor a false positive: the labels do not reach it. Review windows
are evidence for a human and never become cuts; nothing here produces, edits or
feeds a detection.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass

import ad_corpus
from wilted_worker.constants import AD_POD_CONTINUATION_MAX_SECONDS

# A window only counts as reaching a label when it shares more than this much
# audio with it. The slop absorbs cue-edge rounding without turning a brush
# against an advertisement into a review hit.
REVIEW_OVERLAP_SECONDS = 1.0

ANCHOR_SETS = ("recorded", "label-confirmed")


@dataclass(frozen=True)
class ProximityConfig:
    """One fixed reach/window shape for the review-priority experiment."""

    name: str
    window_seconds: float
    before: bool
    after: bool
    anchor_labels: frozenset[str] | None


# Fixed before any fixture was written. The first copies the existing worker
# continuation's forward reach so the two can be compared directly; the rest
# bracket the window sizes being considered for human review only.
CONFIGS = (
    ProximityConfig(
        "after-sponsor-read-continuation-reach",
        AD_POD_CONTINUATION_MAX_SECONDS,
        before=False,
        after=True,
        anchor_labels=frozenset({"sponsor_read"}),
    ),
    ProximityConfig("after-90", 90.0, before=False, after=True, anchor_labels=None),
    ProximityConfig("before-90", 90.0, before=True, after=False, anchor_labels=None),
    ProximityConfig("both-30", 30.0, before=True, after=True, anchor_labels=None),
    ProximityConfig("both-60", 60.0, before=True, after=True, anchor_labels=None),
    ProximityConfig("both-90", 90.0, before=True, after=True, anchor_labels=None),
    ProximityConfig("both-120", 120.0, before=True, after=True, anchor_labels=None),
)


def _rounded_seconds(value: float) -> float:
    """Seconds to the tenth the report prints, never below zero."""
    return round(max(0.0, value), 1)


def _spans(entries) -> list[ad_corpus.Span]:
    """Turn manifest-shaped start/end entries into half-open spans."""
    return [
        ad_corpus.Span(float(entry["start"]), float(entry["end"]))
        for entry in entries
    ]


def _label_spans(case: dict, label: str) -> list[ad_corpus.Span]:
    """Every labelled interval of one kind, in manifest order."""
    return _spans(entry for entry in case.get("expected", ()) if entry["label"] == label)


def _subtract(spans, cuts) -> list[ad_corpus.Span]:
    """Remove every cut second from already merged spans."""
    result: list[ad_corpus.Span] = []
    for span in spans:
        cursor = span.start
        for cut in cuts:
            if cut.end <= cursor:
                continue
            if cut.start >= span.end:
                break
            if cut.start > cursor:
                result.append(ad_corpus.Span(cursor, min(cut.start, span.end)))
            cursor = max(cursor, cut.end)
            if cursor >= span.end:
                break
        if cursor < span.end:
            result.append(ad_corpus.Span(cursor, span.end))
    return [span for span in result if span.seconds > 0.0]


def review_windows(anchors: list[dict], cut: list[ad_corpus.Span], duration: float,
                   config: ProximityConfig) -> list[ad_corpus.Span]:
    """The kept audio within reach of each eligible anchor, in order.

    Each anchor contributes the passage before its start and/or after its end,
    clipped to the episode and then stripped of every removed interval. Removed
    audio cannot be reviewed because the listener will never hear it.
    """
    if duration <= 0.0:
        return []
    raw: list[ad_corpus.Span] = []
    for anchor in anchors:
        if config.anchor_labels is not None and anchor.get("label") not in config.anchor_labels:
            continue
        start = float(anchor["start"])
        end = float(anchor["end"])
        if config.before:
            lower, upper = max(0.0, start - config.window_seconds), min(duration, start)
            if upper > lower:
                raw.append(ad_corpus.Span(lower, upper))
        if config.after:
            lower, upper = max(0.0, end), min(duration, end + config.window_seconds)
            if upper > lower:
                raw.append(ad_corpus.Span(lower, upper))
    merged = ad_corpus.union_spans(raw)
    return _subtract(merged, ad_corpus.union_spans(cut))


def _anchor(entry: dict) -> dict:
    """Keep only the fields review geometry needs; confidence is not evidence."""
    return {
        "start": float(entry["start"]),
        "end": float(entry["end"]),
        "label": entry.get("label", ""),
    }


def _anchors_for(case: dict, anchor_set: str) -> list[dict]:
    """The anchors a named set contributes for one manifest case."""
    recorded = [_anchor(entry) for entry in case.get("recorded", ())]
    if anchor_set == "recorded":
        return recorded
    if anchor_set == "label-confirmed":
        must_cut = ad_corpus.union_spans(_label_spans(case, "must-cut"))
        must_keep = ad_corpus.union_spans(_label_spans(case, "must-keep"))
        confirmed = []
        for anchor in recorded:
            span = ad_corpus.Span(anchor["start"], anchor["end"])
            if span.seconds <= 0.0:
                continue
            inside = sum(span.overlap(region) for region in must_cut)
            keep_overlap = sum(span.overlap(region) for region in must_keep)
            if inside >= span.seconds / 2.0 and (
                keep_overlap <= ad_corpus.UNKNOWN_CUT_TOLERANCE_SECONDS
            ):
                confirmed.append(anchor)
        return confirmed
    raise ValueError(f"unknown anchor set {anchor_set!r}")


def _label_overlap(windows, regions) -> float:
    """Seconds shared by review windows and a merged set of labelled regions."""
    return sum(window.overlap(region) for window in windows for region in regions)


def _window_breakdown(case: dict, window: ad_corpus.Span) -> dict:
    """One review window's seconds by label kind, self-consistent when rounded."""
    must_cut = ad_corpus.union_spans(_label_spans(case, "must-cut"))
    must_keep = ad_corpus.union_spans(_label_spans(case, "must-keep"))
    acceptable = ad_corpus.union_spans(_label_spans(case, "acceptable-cut"))
    flagged = _rounded_seconds(window.seconds)
    missed_ad = _rounded_seconds(sum(window.overlap(region) for region in must_cut))
    programme = _rounded_seconds(sum(window.overlap(region) for region in must_keep))
    acceptable_seconds = _rounded_seconds(
        sum(window.overlap(region) for region in acceptable)
    )
    return {
        "flagged": flagged,
        "missedAdFlagged": missed_ad,
        "programmeFlagged": programme,
        "acceptableFlagged": acceptable_seconds,
        "unlabelledFlagged": round(
            max(0.0, flagged - missed_ad - programme - acceptable_seconds), 1
        ),
    }


def score(case: dict, config: ProximityConfig, anchor_set: str) -> dict:
    """Score one case's review windows against its hand labels.

    The anchor set chooses which recorded spans may attract review; the cut is
    always the union of every recorded span, because an older preparation
    removes all of them whether or not they pass the oracle label filter.
    """
    recorded = _spans(case.get("recorded", ()))
    cut = ad_corpus.union_spans(recorded)
    duration = float(case["audioDurationSeconds"])
    windows = review_windows(_anchors_for(case, anchor_set), cut, duration, config)

    must_cut = _label_spans(case, "must-cut")
    must_keep = _label_spans(case, "must-keep")
    acceptable = _label_spans(case, "acceptable-cut")
    all_labelled = ad_corpus.union_spans([*must_cut, *must_keep, *acceptable])

    missed = []
    missed_uncut = 0.0
    for span in must_cut:
        uncut = max(0.0, span.seconds - sum(span.overlap(cut_span) for cut_span in cut))
        if uncut > REVIEW_OVERLAP_SECONDS:
            missed.append(span)
            missed_uncut += uncut

    missed_regions = ad_corpus.union_spans(missed)
    missed_flagged = sum(
        window.overlap(region) for window in windows for region in missed_regions
    )
    programme_flagged = _label_overlap(windows, ad_corpus.union_spans(must_keep))
    acceptable_flagged = _label_overlap(windows, ad_corpus.union_spans(acceptable))
    flagged = sum(window.seconds for window in windows)

    flagged_seconds = _rounded_seconds(flagged)
    missed_seconds = _rounded_seconds(missed_flagged)
    programme_seconds = _rounded_seconds(programme_flagged)
    acceptable_seconds = _rounded_seconds(acceptable_flagged)
    uncut_labelled = sum(
        max(0.0, span.seconds - sum(span.overlap(cut_span) for cut_span in cut))
        for span in all_labelled
    )

    return {
        "windows": len(windows),
        "windowsWithMissedAd": sum(
            1 for window in windows
            if any(window.overlap(region) > REVIEW_OVERLAP_SECONDS for region in missed)
        ),
        "missedAds": len(missed),
        "missedAdsReached": sum(
            1 for region in missed
            if any(window.overlap(region) > REVIEW_OVERLAP_SECONDS for window in windows)
        ),
        "programmeIntervalsFlagged": sum(
            1 for region in must_keep
            if any(window.overlap(region) > REVIEW_OVERLAP_SECONDS for window in windows)
        ),
        "flagged": flagged_seconds,
        "missedAdFlagged": missed_seconds,
        "programmeFlagged": programme_seconds,
        "acceptableFlagged": acceptable_seconds,
        "unlabelledFlagged": round(
            max(
                0.0,
                flagged_seconds - missed_seconds - programme_seconds - acceptable_seconds,
            ),
            1,
        ),
        "missedAdUncut": _rounded_seconds(missed_uncut),
        "labelledUncut": _rounded_seconds(uncut_labelled),
    }


def _ratio(numerator: float, denominator: float) -> float:
    """A ratio to three places, or zero when its denominator is empty."""
    return round(numerator / denominator, 3) if denominator else 0.0


def evaluate(manifest: dict, anchor_set: str) -> list[dict]:
    """Totals for every fixed config across the whole committed corpus."""
    count_keys = (
        "windows", "windowsWithMissedAd", "missedAds", "missedAdsReached",
        "programmeIntervalsFlagged",
    )
    second_keys = (
        "flagged", "missedAdFlagged", "programmeFlagged", "acceptableFlagged",
        "unlabelledFlagged", "missedAdUncut", "labelledUncut",
    )
    rows: list[dict] = []
    for config in CONFIGS:
        totals = {key: 0 for key in count_keys}
        totals.update({key: 0.0 for key in second_keys})
        for case in manifest["cases"]:
            result = score(case, config, anchor_set)
            for key in count_keys:
                totals[key] += int(result[key])
            for key in second_keys:
                totals[key] += float(result[key])

        total_seconds = {key: round(totals[key], 1) for key in second_keys}
        precision_denominator = (
            total_seconds["missedAdFlagged"]
            + total_seconds["programmeFlagged"]
            + total_seconds["acceptableFlagged"]
        )
        window_precision = _ratio(totals["windowsWithMissedAd"], totals["windows"])
        labelled_precision = _ratio(
            total_seconds["missedAdFlagged"], precision_denominator
        )
        labelled_base_rate = _ratio(
            total_seconds["missedAdUncut"], total_seconds["labelledUncut"]
        )
        rows.append({
            "config": config.name,
            **{key: totals[key] for key in count_keys},
            **total_seconds,
            "windowPrecision": window_precision,
            "labelledPrecision": labelled_precision,
            "labelledBaseRate": labelled_base_rate,
            "lift": _ratio(labelled_precision, labelled_base_rate),
        })
    return rows


def _print_totals(anchor_set: str) -> None:
    columns = (
        "config", "windows", "windowsWithMissedAd", "missedAds", "missedAdsReached",
        "flagged", "missedAdFlagged", "programmeFlagged", "acceptableFlagged",
        "unlabelledFlagged", "missedAdUncut", "labelledUncut",
        "programmeIntervalsFlagged", "windowPrecision", "labelledPrecision",
        "labelledBaseRate", "lift",
    )
    print(f"## Anchor set: {anchor_set}")
    print()
    print("| " + " | ".join(columns) + " |")
    print("| " + " | ".join("---" for _ in columns) + " |")
    for row in evaluate(ad_corpus.load_manifest(), anchor_set):
        print("| " + " | ".join(str(row[column]) for column in columns) + " |")
    print()


def _print_windows() -> None:
    config = next(item for item in CONFIGS if item.name == "before-90")
    columns = (
        "case", "window", "must-cut", "must-keep", "acceptable-cut", "unlabelled",
    )
    print("## Per-window review: before-90 (recorded anchors)")
    print()
    print("| " + " | ".join(columns) + " |")
    print("| " + " | ".join("---" for _ in columns) + " |")
    for case in ad_corpus.load_manifest()["cases"]:
        recorded = _spans(case.get("recorded", ()))
        windows = review_windows(
            _anchors_for(case, "recorded"),
            ad_corpus.union_spans(recorded),
            float(case["audioDurationSeconds"]),
            config,
        )
        for window in windows:
            values = _window_breakdown(case, window)
            print(
                f"| {case['id']} | {window.start:.1f}-{window.end:.1f} "
                f"| {values['missedAdFlagged']} | {values['programmeFlagged']} "
                f"| {values['acceptableFlagged']} | {values['unlabelledFlagged']} |"
            )
    print()


def main() -> int:
    """Print both anchor-set totals and the detailed before-90 windows."""
    for anchor_set in ANCHOR_SETS:
        _print_totals(anchor_set)
    _print_windows()
    return 0


if __name__ == "__main__":
    sys.exit(main())
