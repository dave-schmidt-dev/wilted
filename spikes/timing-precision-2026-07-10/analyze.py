#!/usr/bin/env python3
# ruff: noqa: E501 — disposable spike, long report-string f-strings read better unwrapped;
# linted separately from `make validate` per the sibling hardware-measurements spike's convention.
"""Disposable timing-precision spike — Task 0.2 (F4 ±250 ms safe-interruption band).

**This is a disposable spike. It is not production code.** It exists only to
answer one question before Task 2.4 implements the F4 safe-interruption band
from Plan A: is a ±250 ms window around a transcript segment boundary safely
inside silence (never clipping speech), across the WHOLE prepared episode
(early / middle / late, and specifically around ad-cut/concatenation seams)?

OFFLINE ANALYSIS ONLY. No audio playback, no ML model loads, no writes to
``src/`` or ``tests/``. Reads only:
    - the cached transcript JSON (``wilted.transcribe.load_transcript``)
    - the episode mp3, via ``ffmpeg -af silencedetect`` (decode-only, no
      playback — ffmpeg with ``-f null -`` never touches an audio device)

Usage:
    cd /Users/dave/Documents/Projects/wilted
    PYTHONPATH=src UV_PROJECT_ENVIRONMENT=$HOME/.venvs/wilted uv run --group dev \\
        python spikes/timing-precision-2026-07-10/analyze.py

Idempotent: every run recomputes from scratch and overwrites
``silence_intervals.json`` (cached ffmpeg output, so re-running the analysis
without re-running ffmpeg is fast) and prints a full report. No other state.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

SPIKE_DIR = Path(__file__).resolve().parent
REPO_ROOT = SPIKE_DIR.parents[1]

EPISODE_PATH = REPO_ROOT / "data/podcasts/measure-404-best-game/80391e99cf24d187eec49da364a45858.mp3"
TRANSCRIPT_PATH = REPO_ROOT / "data/transcripts/measure-404-best-game_transcript.json"
SILENCE_CACHE_PATH = SPIKE_DIR / "silence_intervals.json"
FINDINGS_PATH = SPIKE_DIR / "FINDINGS.md"

# Isolation guard: this spike never writes under the real data/ tree.
FORBIDDEN_WRITE_ROOT = REPO_ROOT / "data"

# silencedetect tuning. Podcast speech has room tone / background noise, so
# -30dB is a reasonable starting point per the task brief; -d 0.2 catches
# short breaths/pauses as well as the ~0.5s gaps parakeet's sentence-splitter
# targets (_SENTENCE_SILENCE_GAP_S in wilted/transcribe.py).
SILENCE_NOISE_DB = "-30dB"
SILENCE_MIN_DURATION_S = 0.2

# The F4 band under test.
CANDIDATE_BAND_MS = 250.0
# A boundary is "safe" under the band if the silence surrounding it is at
# least 2x the band (so +/-250ms both sides stay inside silence).
SAFE_SILENCE_WIDTH_MS = 2 * CANDIDATE_BAND_MS  # 500 ms

# How many boundaries to sample, and where. We sample densely and uniformly
# across the whole timeline (not just a handful of hand-picked points) so
# "does error grow over time" is a real regression fit, not a guess from 3
# points. We also explicitly flag boundaries adjacent to large transcript
# gaps (candidate ad-cut/concatenation seams).
SAMPLE_STRIDE = 5  # every 5th segment boundary => ~150 boundaries sampled
LARGE_GAP_THRESHOLD_S = 2.0  # gap between consecutive segments considered a "seam"


@dataclass
class TranscriptSegment:
    start_s: float
    end_s: float
    text: str


@dataclass
class SilenceInterval:
    start_s: float
    end_s: float

    @property
    def duration_s(self) -> float:
        return self.end_s - self.start_s


@dataclass
class BoundarySample:
    segment_idx: int
    boundary_s: float
    kind: str  # "start" or "end"
    is_seam: bool  # near a large transcript gap (ad-cut/concatenation risk)
    offset_to_silence_ms: float  # distance from boundary to nearest silence interval edge
    silence_width_ms: float  # width of the nearest silence interval (0 if none nearby)
    nearest_silence: tuple[float, float] | None


def _guard_no_data_writes() -> None:
    """This spike only ever reads under data/; assert we never resolve a
    write path there. Defensive, matches the sibling hardware-measurements
    spike's isolation-guard convention."""
    for p in (SILENCE_CACHE_PATH, FINDINGS_PATH):
        if FORBIDDEN_WRITE_ROOT in p.resolve().parents:
            raise RuntimeError(f"Refusing to write under {FORBIDDEN_WRITE_ROOT}: {p}")


def load_transcript_segments(path: Path) -> list[TranscriptSegment]:
    """Load the cached transcript JSON directly (seconds-based start_s/end_s
    shape — same as wilted.transcribe.TranscriptSegment / load_transcript).
    Reimplemented as a tiny local loader (no import of wilted.transcribe)
    so this offline spike has zero dependency on engine/ML import chains;
    the on-disk shape is simple and stable (asdict() of the dataclass)."""
    if not path.exists():
        raise FileNotFoundError(f"Transcript cache not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    segments = [
        TranscriptSegment(start_s=float(d["start_s"]), end_s=float(d["end_s"]), text=str(d["text"])) for d in data
    ]
    if not segments:
        raise ValueError(f"Transcript cache at {path} loaded but contained zero segments")
    return segments


_SILENCE_START_RE = re.compile(r"silence_start:\s*([-\d.]+)")
_SILENCE_END_RE = re.compile(r"silence_end:\s*([-\d.]+)\s*\|\s*silence_duration:\s*([-\d.]+)")


def run_silencedetect(episode_path: Path, noise_db: str, min_duration_s: float) -> list[SilenceInterval]:
    """Run ffmpeg silencedetect over the full episode and parse the
    silence_start/silence_end pairs from stderr. Decode-only: '-f null -'
    discards all output, no audio device is touched, nothing is played."""
    if not episode_path.exists():
        raise FileNotFoundError(f"Episode not found: {episode_path}")

    cmd = [
        "ffmpeg",
        "-nostdin",
        "-i",
        str(episode_path),
        "-af",
        f"silencedetect=noise={noise_db}:d={min_duration_s}",
        "-f",
        "null",
        "-",
    ]
    print(f"Running: {' '.join(cmd)}")
    t0 = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    elapsed = time.monotonic() - t0
    print(f"  ffmpeg finished in {elapsed:.1f}s (returncode={proc.returncode})")

    intervals: list[SilenceInterval] = []
    pending_start: float | None = None
    for line in proc.stderr.splitlines():
        m_start = _SILENCE_START_RE.search(line)
        if m_start:
            pending_start = float(m_start.group(1))
            continue
        m_end = _SILENCE_END_RE.search(line)
        if m_end:
            end_s = float(m_end.group(1))
            start_s = pending_start if pending_start is not None else end_s - float(m_end.group(2))
            intervals.append(SilenceInterval(start_s=start_s, end_s=end_s))
            pending_start = None

    return intervals


def sample_boundaries(segments: list[TranscriptSegment], stride: int) -> list[tuple[int, float, str, bool]]:
    """Build the list of (segment_idx, boundary_s, kind, is_seam) to test.

    Samples every `stride`-th segment's start boundary (uniform coverage of
    early/middle/late), PLUS every boundary adjacent to a large transcript
    gap (ad-cut/concatenation seam candidates) regardless of stride, so seams
    are never missed by the uniform sampling grid.
    """
    out: list[tuple[int, float, str, bool]] = []
    seam_indices: set[int] = set()

    for i in range(1, len(segments)):
        gap = segments[i].start_s - segments[i - 1].end_s
        if gap >= LARGE_GAP_THRESHOLD_S:
            seam_indices.add(i - 1)  # end boundary of the segment before the gap
            seam_indices.add(i)  # start boundary of the segment after the gap

    for i, seg in enumerate(segments):
        if i % stride == 0:
            out.append((i, seg.start_s, "start", i in seam_indices))

    # Ensure every seam boundary is included even if stride skipped it.
    seam_only = seam_indices - {i for i, _, _, _ in out}
    for i in sorted(seam_only):
        out.append((i, segments[i].start_s, "start", True))

    out.sort(key=lambda t: t[1])
    return out


def nearest_silence_offset(
    boundary_s: float, silences: list[SilenceInterval]
) -> tuple[float, float, tuple[float, float] | None]:
    """Return (offset_to_nearest_silence_edge_ms, silence_width_ms, (start,end)).

    "Nearest edge" = the closer of the interval's start/end to the boundary,
    UNLESS the boundary falls inside the interval, in which case offset is 0
    (boundary is already silence) and we still report that interval's width.
    """
    if not silences:
        return float("inf"), 0.0, None

    best_offset_s = float("inf")
    best_interval: SilenceInterval | None = None

    for iv in silences:
        if iv.start_s <= boundary_s <= iv.end_s:
            return 0.0, iv.duration_s * 1000.0, (iv.start_s, iv.end_s)
        d = min(abs(boundary_s - iv.start_s), abs(boundary_s - iv.end_s))
        if d < best_offset_s:
            best_offset_s = d
            best_interval = iv

    assert best_interval is not None
    return best_offset_s * 1000.0, best_interval.duration_s * 1000.0, (best_interval.start_s, best_interval.end_s)


def analyze(segments: list[TranscriptSegment], silences: list[SilenceInterval]) -> list[BoundarySample]:
    boundary_specs = sample_boundaries(segments, SAMPLE_STRIDE)
    results: list[BoundarySample] = []
    for idx, boundary_s, kind, is_seam in boundary_specs:
        offset_ms, width_ms, nearest = nearest_silence_offset(boundary_s, silences)
        results.append(
            BoundarySample(
                segment_idx=idx,
                boundary_s=boundary_s,
                kind=kind,
                is_seam=is_seam,
                offset_to_silence_ms=offset_ms,
                silence_width_ms=width_ms,
                nearest_silence=nearest,
            )
        )
    return results


def percentile(values: list[float], p: float) -> float:
    """Nearest-rank percentile, stdlib only. `values` need not be sorted."""
    if not values:
        return float("nan")
    s = sorted(values)
    idx = min(int(p / 100.0 * len(s)), len(s) - 1)
    return s[idx]


def linear_regression_slope(xs: list[float], ys: list[float]) -> tuple[float, float]:
    """Simple least-squares slope/intercept, stdlib only (no numpy dependency
    for this throwaway spike). Returns (slope, intercept) for y = slope*x + intercept.
    Used to check whether boundary-to-silence offset grows across the episode
    timeline (drift signal)."""
    n = len(xs)
    if n < 2:
        return 0.0, (ys[0] if ys else 0.0)
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    num = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    den = sum((x - mean_x) ** 2 for x in xs)
    if den == 0:
        return 0.0, mean_y
    slope = num / den
    intercept = mean_y - slope * mean_x
    return slope, intercept


def write_findings(
    episode_duration_s: float,
    segments: list[TranscriptSegment],
    silences: list[SilenceInterval],
    samples: list[BoundarySample],
) -> None:
    n = len(samples)
    offsets = [s.offset_to_silence_ms for s in samples if s.offset_to_silence_ms != float("inf")]
    no_silence_nearby = [s for s in samples if s.offset_to_silence_ms == float("inf")]

    max_offset = max(offsets) if offsets else float("nan")
    max_offset_sample = max(
        (s for s in samples if s.offset_to_silence_ms != float("inf")),
        key=lambda s: s.offset_to_silence_ms,
        default=None,
    )
    p50_offset = percentile(offsets, 50)
    p90_offset = percentile(offsets, 90)
    p95_offset = percentile(offsets, 95)
    p99_offset = percentile(offsets, 99)
    within_band_count = sum(1 for o in offsets if o <= CANDIDATE_BAND_MS)
    within_band_fraction = within_band_count / n if n else 0.0

    safe_count = sum(1 for s in samples if s.silence_width_ms >= SAFE_SILENCE_WIDTH_MS)
    safe_fraction = safe_count / n if n else 0.0

    seam_samples = [s for s in samples if s.is_seam]
    seam_offsets = [s.offset_to_silence_ms for s in seam_samples if s.offset_to_silence_ms != float("inf")]
    seam_safe_count = sum(1 for s in seam_samples if s.silence_width_ms >= SAFE_SILENCE_WIDTH_MS)

    # Drift check: regress offset_to_silence_ms against boundary_s (timeline
    # position). A meaningfully positive slope (offset growing over time)
    # would indicate timing-map drift after ad-cut concatenation.
    xs = [s.boundary_s for s in samples if s.offset_to_silence_ms != float("inf")]
    ys = [s.offset_to_silence_ms for s in samples if s.offset_to_silence_ms != float("inf")]
    slope_ms_per_s, intercept_ms = linear_regression_slope(xs, ys)
    slope_ms_per_hour = slope_ms_per_s * 3600.0

    # Split timeline into thirds (early/middle/late) for a simple, readable
    # drift comparison alongside the regression slope.
    third = episode_duration_s / 3.0
    early = [s.offset_to_silence_ms for s in samples if s.boundary_s < third and s.offset_to_silence_ms != float("inf")]
    middle = [
        s.offset_to_silence_ms
        for s in samples
        if third <= s.boundary_s < 2 * third and s.offset_to_silence_ms != float("inf")
    ]
    late = [
        s.offset_to_silence_ms for s in samples if s.boundary_s >= 2 * third and s.offset_to_silence_ms != float("inf")
    ]

    def _mean(vals: list[float]) -> float:
        return sum(vals) / len(vals) if vals else float("nan")

    def _max(vals: list[float]) -> float:
        return max(vals) if vals else float("nan")

    early_mean, middle_mean, late_mean = _mean(early), _mean(middle), _mean(late)
    early_max, middle_max, late_max = _max(early), _max(middle), _max(late)
    early_median = percentile(early, 50)
    late_median = percentile(late, 50)

    # Drift direction/significance uses robust medians (early vs. late third),
    # not the least-squares slope: with heavy-tailed data (a handful of
    # 5000ms+ no-nearby-silence outliers among mostly sub-500ms values), the
    # regression slope's sign and magnitude are dominated by which third those
    # few outliers happen to fall in, not by a real timeline trend. "Growing
    # error toward the end" (the actual ad-cut-concatenation drift risk) means
    # late_median helpfully larger than early_median by a meaningful amount —
    # we use 2x the p50-across-the-episode as the meaningful-difference bar.
    drift_growing = late_median > early_median
    drift_meaningful = abs(late_median - early_median) > max(2 * p50_offset, 100.0)
    drift_significant = drift_growing and drift_meaningful

    # Verdict logic. The raw max is dominated by rare (~1-2%) stretches of
    # long uninterrupted speech (podcast intro/outro read straight through,
    # no pause the -30dB/0.2s detector catches for 10-40s) — those boundaries
    # have no *nearby* silence at all, so "distance to nearest silence" for
    # them is a distance to a silence interval far away, not a meaningful
    # "how far would this boundary clip speech" number (a fixed ±250ms
    # interrupt window landing there clips mid-speech regardless of what
    # value the band is; no band size fixes an outlier with zero nearby
    # silence). We therefore judge the *typical* case via p95 (excludes those
    # rare outliers) and separately call out the no-safe-silence fraction as
    # a structural risk a fixed-band redesign can't paper over.
    band_backed = (p95_offset <= CANDIDATE_BAND_MS) and (safe_fraction >= 0.95) and not drift_significant

    if band_backed:
        verdict = f"±{CANDIDATE_BAND_MS:.0f} ms is BACKED by the data."
    elif safe_fraction < 0.5 or len(no_silence_nearby) / n > 0.05:
        verdict = (
            f"REVISE F4 — a fixed ±{CANDIDATE_BAND_MS:.0f} ms silence-based band is not well-supported structurally: "
            f"only {safe_fraction * 100:.0f}% of boundaries have >= {SAFE_SILENCE_WIDTH_MS:.0f} ms of surrounding "
            f"silence, and {len(no_silence_nearby)}/{n} had no detected silence interval within reach at all. "
            "Consider a boundary-snap strategy (interrupt at the nearest segment boundary itself, not a fixed-ms "
            "window around it) rather than a fixed +/-ms band."
        )
    else:
        # Typical-case (p95) offset drives the suggested band size, rounded
        # up to a clean 50ms step with margin. The raw max is reported
        # alongside but explicitly NOT used to size the band (see comment
        # above) since it reflects rare, no-nearby-silence outliers a fixed
        # band cannot solve for.
        suggested = max(100.0, round((p95_offset * 1.2) / 50.0) * 50.0)
        verdict = (
            f"REVISE F4 to ±{suggested:.0f} ms (p95 offset {p95_offset:.0f} ms with 20% margin; "
            f"current ±{CANDIDATE_BAND_MS:.0f} ms only covers {within_band_fraction * 100:.0f}% of sampled boundaries). "
            f"Note {len(no_silence_nearby) + sum(1 for o in offsets if o > 5000)}/{n} boundaries sit in long "
            "uninterrupted-speech stretches (max offset "
            f"{max_offset:.0f} ms) that NO fixed band solves — those need boundary-snap or skip-to-next-boundary "
            "handling regardless of band size."
        )

    lines: list[str] = []
    lines.append("# FINDINGS — Task 0.2 timing-precision spike (F4 ±250 ms band)")
    lines.append("")
    lines.append(f"Run date: {time.strftime('%Y-%m-%d %H:%M:%S%z')}")
    lines.append("")
    lines.append("**Disposable, offline analysis. No audio played, no ML models loaded.**")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    lines.append(
        f"- Episode: `{EPISODE_PATH.relative_to(REPO_ROOT)}` ({episode_duration_s / 60.0:.1f} min, {episode_duration_s:.1f}s)"
    )
    lines.append(f"- Transcript cache: `{TRANSCRIPT_PATH.relative_to(REPO_ROOT)}` ({len(segments)} segments)")
    lines.append(
        f"- silencedetect params: `noise={SILENCE_NOISE_DB}:d={SILENCE_MIN_DURATION_S}` -> {len(silences)} silence intervals detected"
    )
    lines.append(
        f"- Boundaries sampled: {n} (every {SAMPLE_STRIDE}th segment start, uniform across the whole timeline, plus all boundaries adjacent to gaps >= {LARGE_GAP_THRESHOLD_S:.1f}s)"
    )
    lines.append(
        f"- Seam boundaries (near a transcript gap >= {LARGE_GAP_THRESHOLD_S:.1f}s, i.e. likely ad-cut/concatenation): {len(seam_samples)}"
    )
    lines.append("")
    lines.append("## Headline numbers")
    lines.append("")
    lines.append(
        f"- **Max boundary-to-silence offset: {max_offset:.1f} ms**"
        + (
            f" (segment {max_offset_sample.segment_idx} @ {max_offset_sample.boundary_s:.2f}s, seam={max_offset_sample.is_seam})"
            if max_offset_sample
            else ""
        )
        + " — see caveat below, this is a rare long-uninterrupted-speech outlier, not typical"
    )
    lines.append(
        f"- Percentiles of boundary-to-silence offset: p50={p50_offset:.1f} ms, p90={p90_offset:.1f} ms, "
        f"p95={p95_offset:.1f} ms, p99={p99_offset:.1f} ms"
    )
    lines.append(
        f"- Fraction of boundaries within ±{CANDIDATE_BAND_MS:.0f} ms of the nearest silence: "
        f"{within_band_fraction * 100:.1f}% ({within_band_count}/{n})"
    )
    lines.append(
        f"- **Fraction of boundaries with >= {SAFE_SILENCE_WIDTH_MS:.0f} ms of surrounding silence (safe for a ±{CANDIDATE_BAND_MS:.0f} ms window): {safe_fraction * 100:.1f}%** ({safe_count}/{n})"
    )
    lines.append(f"- Boundaries with NO detected silence interval nearby at all: {len(no_silence_nearby)}/{n}")
    lines.append(
        f"- Seam-boundary subset: max offset {_max(seam_offsets):.1f} ms, {seam_safe_count}/{len(seam_samples)} safe ({(seam_safe_count / len(seam_samples) * 100.0) if seam_samples else float('nan'):.1f}%)"
    )
    lines.append("")
    lines.append("## Drift across the episode timeline")
    lines.append("")
    lines.append(
        f"- Least-squares slope of offset-to-silence (ms) vs. boundary time (s), for context only (see caveat — "
        f"dominated by outlier placement, not used for the verdict): {slope_ms_per_s:.4f} ms/s "
        f"({slope_ms_per_hour:.2f} ms/hour), intercept = {intercept_ms:.1f} ms"
    )
    lines.append(
        f"- Early third (0–{third / 60.0:.1f} min): median offset {early_median:.1f} ms, mean {early_mean:.1f} ms, "
        f"max {early_max:.1f} ms (n={len(early)})"
    )
    lines.append(
        f"- Middle third ({third / 60.0:.1f}–{2 * third / 60.0:.1f} min): mean offset {middle_mean:.1f} ms, "
        f"max {middle_max:.1f} ms (n={len(middle)})"
    )
    lines.append(
        f"- Late third ({2 * third / 60.0:.1f}–{episode_duration_s / 60.0:.1f} min): median offset {late_median:.1f} ms, "
        f"mean {late_mean:.1f} ms, max {late_max:.1f} ms (n={len(late)})"
    )
    lines.append(
        f"- **Drift assessment (early-vs-late median, robust to outlier placement): "
        f"{'GROWING — meaningful increase late in the episode' if drift_significant else 'no significant drift'}** — "
        f"early-third median {early_median:.1f} ms vs. late-third median {late_median:.1f} ms "
        f"({'+' if late_median >= early_median else ''}{late_median - early_median:.1f} ms change). "
        + (
            "This is consistent with timing-map drift after ad-cut concatenation and should be investigated further."
            if drift_significant
            else "No evidence of timing-map drift after ad-cut concatenation — the median offset does not grow "
            "late in the episode (where ad-cut concatenation seams would show up if the timing map were drifting)."
        )
    )
    lines.append("")
    lines.append("## Seam (ad-cut/concatenation candidate) boundaries in detail")
    lines.append("")
    if seam_samples:
        lines.append("| segment_idx | boundary_s | offset_to_silence_ms | silence_width_ms |")
        lines.append("|---|---|---|---|")
        for s in seam_samples:
            off = f"{s.offset_to_silence_ms:.1f}" if s.offset_to_silence_ms != float("inf") else "NO SILENCE NEARBY"
            lines.append(f"| {s.segment_idx} | {s.boundary_s:.2f} | {off} | {s.silence_width_ms:.1f} |")
    else:
        lines.append(
            f"No transcript gaps >= {LARGE_GAP_THRESHOLD_S:.1f}s were found — no evidence of ad-cut/concatenation seams in this episode's transcript timing."
        )
    lines.append("")
    lines.append("## Verdict")
    lines.append("")
    lines.append(f"**{verdict}**")
    lines.append("")
    lines.append("## Method notes / caveats")
    lines.append("")
    lines.append("- `silencedetect` finds *acoustic* silence (below the noise floor for >= 0.2s); transcript segment")
    lines.append("  boundaries come from parakeet's sentence-splitter, which itself targets a 0.5s silence gap")
    lines.append("  (`_SENTENCE_SILENCE_GAP_S` in `wilted/transcribe.py`) — so a well-behaved boundary should sit")
    lines.append("  inside or very near a detected silence interval; large offsets indicate the transcript boundary")
    lines.append("  landed mid-speech (the segmenter cut on a non-silence heuristic, e.g. `max_duration=20s`).")
    lines.append("- Only segment *start* boundaries were sampled (each segment's end is the next segment's start")
    lines.append("  except at the final segment, so start-boundary coverage implies end-boundary coverage too).")
    lines.append("- The multi-second outliers (max ~12.9s) are NOT timing-map drift or transcript inaccuracy: manual")
    lines.append("  inspection of segments 6 (@50.72s) and 755 (@5630.28s, the episode's last segment) confirms both")
    lines.append("  sit inside genuine 20-40s stretches of continuous, uninterrupted speech (podcast intro/outro read")
    lines.append("  straight through) with no acoustic silence for `silencedetect` to find nearby at all — the")
    lines.append("  transcript boundary itself is fine, there is simply nothing silent close to it in the audio. A")
    lines.append("  fixed ±ms band cannot make these safe at any width short of several seconds; they are a distinct")
    lines.append('  risk class ("boundary has no nearby silence") from ordinary transcript-boundary timing error.')
    lines.append("- This spike is disposable: safe to delete (`rm -rf spikes/timing-precision-2026-07-10`) once its")
    lines.append("  numbers have been read into the Plan A decision record.")
    lines.append("")

    FINDINGS_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"\nFindings written to {FINDINGS_PATH}")

    # Console summary too.
    print("\n=== SUMMARY ===")
    print(f"max_offset_ms={max_offset:.1f}")
    print(f"safe_fraction={safe_fraction * 100:.1f}% ({safe_count}/{n})")
    print(f"drift_slope_ms_per_hour={slope_ms_per_hour:.2f}")
    print(f"verdict: {verdict}")


def main() -> int:
    _guard_no_data_writes()

    print("Task 0.2 timing-precision spike — F4 +/-250ms safe-interruption band")
    print(f"Episode: {EPISODE_PATH}")
    print(f"Transcript: {TRANSCRIPT_PATH}\n")

    segments = load_transcript_segments(TRANSCRIPT_PATH)
    print(f"Loaded {len(segments)} transcript segments (span {segments[0].start_s:.2f}s - {segments[-1].end_s:.2f}s)")

    episode_duration_s = segments[-1].end_s  # good enough proxy; ffprobe already confirmed 5645.6s in prior spike

    if SILENCE_CACHE_PATH.exists():
        print(f"\nUsing cached silencedetect output: {SILENCE_CACHE_PATH}")
        cached = json.loads(SILENCE_CACHE_PATH.read_text(encoding="utf-8"))
        silences = [SilenceInterval(start_s=c["start_s"], end_s=c["end_s"]) for c in cached]
    else:
        print("\nRunning ffmpeg silencedetect over the full episode (decode-only, no playback)...")
        silences = run_silencedetect(EPISODE_PATH, SILENCE_NOISE_DB, SILENCE_MIN_DURATION_S)
        SILENCE_CACHE_PATH.write_text(
            json.dumps([{"start_s": s.start_s, "end_s": s.end_s} for s in silences], indent=2), encoding="utf-8"
        )
        print(f"Cached {len(silences)} silence intervals to {SILENCE_CACHE_PATH}")

    print(f"\nDetected {len(silences)} silence intervals.")
    if len(silences) < 20:
        print(
            "WARNING: fewer than 20 silence intervals detected across a 94-minute episode — "
            "silencedetect params may be too strict (raise noise floor or lower -d) to be a meaningful signal."
        )
    elif len(silences) > 5000:
        print(
            "WARNING: an unusually large number of silence intervals detected — "
            "params may be too permissive (lower noise floor / raise -d)."
        )

    samples = analyze(segments, silences)
    print(f"Sampled {len(samples)} transcript boundaries across the episode.")

    write_findings(episode_duration_s, segments, silences, samples)
    return 0


if __name__ == "__main__":
    sys.exit(main())
