"""Score the ad detector against hand-labelled real episodes.

The detector's unit tests script the model's answer -- `FakeLLM(preroll_program_start_id=9)`
-- and then check the arithmetic around it. That catches a broken recovery pass
and cannot catch a wrong judgement, which is what every failure David has
reported actually is. This module closes that gap: it holds ground truth for
real episodes and scores what the detector produced against it.

Two input modes, because they answer different questions:

`recorded` reads the spans a real preparation already committed, out of the
library database. It needs no model, runs in milliseconds, and answers "is the
episode in my library still wrong?". It reads mutable local state, so the gate
does not run it: the gate runs unit tests that score the frozen snapshot each
manifest case carries, which is deterministic and committed.

`replay` re-runs the live detector over the aligned segments the original run
consumed, so a fix can be measured before anything is re-prepared. It loads the
GGUF model and takes minutes, so it is opt-in and never in the gate.

Scoring is asymmetric on purpose. Leaving an advertisement in is an annoyance;
removing programme content destroys something the listener wanted and cannot
get back from the cut file. `must-keep` is therefore bounded twice, per span
and across the episode, while `must-cut` is bounded once.

Both labels are measured against the *union* of the produced cuts. Two
overlapping nominations for one spot are one removal, and summing them would
have reported a thirty-second spot as sixty seconds removed -- coverage above
100% and programme loss above what was lost.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sqlite3
import sys
from dataclasses import dataclass, field
from pathlib import Path

MANIFEST = Path(__file__).resolve().parent / "adcorpus" / "manifest.json"

DEFAULT_LIBRARY = Path.home() / "Library" / "Application Support" / "Wilted" / "library.sqlite"
DEFAULT_ALIGNED_CACHE = (
    Path.home() / "Library" / "Application Support" / "Wilted" / "media" / "preparation"
    / "wilted-pipeline" / "aligned-stt-cache"
)

# Where the archived detector lives. Swift resolves this from the same variable
# with the same fallback when it spawns the worker, in
# `PodcastPreparationPipeline.Configuration.resolved`; a replay that resolved it
# differently would be measuring a detector the app does not run.
DEFAULT_ARCHIVE_SOURCES = Path.home() / "Documents" / "Projects" / "wilted-old" / "src"

# A cut boundary lands on a transcript segment edge, and the labelled truth was
# read off those same edges, so a second of slack absorbs rounding without
# hiding a real overreach. The Pop Culture Happy Hour failure lost twenty
# seconds; nothing this tolerance forgives is a defect anyone would notice.
KEEP_TOLERANCE_SECONDS = 1.0

# The same slack in the other direction, a second at each edge, and for the
# same reason: both boundaries land on cue edges and both can round. A fraction
# would have been the wrong shape -- three quarters of a sixty-second read
# leaves fifteen seconds of advertising playing, which is the failure being
# measured, not a rounding error. An advertisement is removed when what is left
# of it is an edge. Two seconds rather than one because at one second the saved
# Waveform closing break fails on a 1.2s leading remnant that is a cue edge, not
# advertising anyone hears: the number was widened after seeing that run, which
# is worth knowing when reading a verdict it produces.
CUT_REMNANT_TOLERANCE_SECONDS = 2.0

# Per-span tolerance forgives rounding once. Twenty spans each losing nine
# tenths of a second is a sentence gone from every break in the episode, and
# every one of them passes. This bounds the total. Five seconds because the
# smallest loss anyone has reported noticing is the twenty-second Pop Culture
# Happy Hour premise, and a whole spoken sentence is a few seconds: below this
# the aggregate would fire on rounding, above it the losses stop being edges.
# Chosen here, not measured from a reported failure.
KEEP_LOSS_BUDGET_SECONDS = 5.0

# Cut time that falls in no labelled region is neither right nor wrong -- the
# labels simply do not reach it. Past this much of it, the case's verdict is
# reported as partial, because most of what the detector did went unmeasured.
UNKNOWN_CUT_TOLERANCE_SECONDS = 1.0


@dataclass(frozen=True)
class Span:
    """A half-open interval of the original audio, in seconds."""

    start: float
    end: float

    @property
    def seconds(self) -> float:
        return max(0.0, self.end - self.start)

    def overlap(self, other: "Span") -> float:
        """Seconds this span shares with `other`."""
        return max(0.0, min(self.end, other.end) - max(self.start, other.start))


@dataclass
class SpanVerdict:
    label: str
    span: Span
    why: str
    overlap_seconds: float
    passed: bool
    note: str


@dataclass
class CaseVerdict:
    case_id: str
    show: str
    passed: bool
    reason: str
    spans: list[SpanVerdict] = field(default_factory=list)
    produced: list[Span] = field(default_factory=list)
    skipped: bool = False
    # Programme seconds removed across every `must-keep` span, which is what
    # the aggregate budget is measured against.
    keep_loss_seconds: float = 0.0
    # Cut time that lands in no labelled region at all. Neither a pass nor a
    # failure: the labels do not reach it, and saying so is the honest report.
    unknown_cut_seconds: float = 0.0
    # How much of the episode carries any label. Both manifest cases label
    # their openings closely and leave the middle alone, so a verdict of
    # "every labelled span is where it should be" covers less than it sounds.
    labelled_coverage: float = 0.0
    coverage_complete: bool = True
    audit: dict | None = None


class ReplayRefused(RuntimeError):
    """The worker refused to produce an analysis, carrying its refusal code.

    A refusal is a measurement, not a crash: it is the pipeline declining to
    guess. Raised as its own type so `run` can record which case refused and
    why without importing the worker at module scope.
    """

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.detail = message


def load_manifest(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def union_spans(spans) -> list[Span]:
    """The same seconds, counted once, in order.

    The detector nominates spans and the recovery passes add more; two of them
    covering one advertisement is normal. Overlap is only double counting.
    """
    merged: list[Span] = []
    for span in sorted(spans, key=lambda item: (item.start, item.end)):
        if merged and span.start <= merged[-1].end:
            if span.end > merged[-1].end:
                merged[-1] = Span(merged[-1].start, span.end)
        else:
            merged.append(span)
    return merged


def _invalid_interval(span: Span, total: float | None) -> str | None:
    """Why this produced interval cannot be scored, or None if it can.

    A cut the arithmetic cannot make sense of has to be named rather than
    absorbed: silently ignoring it reports the episode as clean.
    """
    for name, value in (("start", span.start), ("end", span.end)):
        if value != value or value in (float("inf"), float("-inf")):
            return f"{name} is not a finite number"
    if span.end <= span.start:
        return "ends at or before it starts"
    if span.start < 0.0:
        return "starts before the audio does"
    if total is not None and span.start >= total:
        return f"starts after the {total:.1f}s episode ends"
    return None


def score_case(case: dict, produced: list[Span]) -> CaseVerdict:
    """Score one case's produced cuts against its labelled truth.

    Pure: every input is already resolved, so both modes and the unit tests
    share exactly this arithmetic.
    """
    verdicts: list[SpanVerdict] = []
    failures: list[str] = []
    total = float(case["audioDurationSeconds"]) if "audioDurationSeconds" in case else None

    malformed = [
        f"cut {span.start}-{span.end} {why}"
        for span in produced
        for why in [_invalid_interval(span, total)]
        if why is not None
    ]
    if malformed:
        # Refused rather than scored around. An interval the arithmetic cannot
        # read makes every number below it meaningless, and reporting a clean
        # episode off one is worse than reporting nothing.
        return CaseVerdict(
            case_id=case["id"], show=case["show"], passed=False,
            reason="; ".join(malformed), produced=produced,
        )

    cuts = union_spans(produced)
    keep_loss = 0.0

    for expected in case["expected"]:
        span = Span(float(expected["start"]), float(expected["end"]))
        label = expected["label"]
        # Scored against the part of the label that is inside the audio. Labels
        # are read off cue edges and the transcript can run past the probed
        # duration -- Waveform's closing break is labelled 2.5s beyond the end
        # of its own file -- and counting seconds that do not exist as
        # advertising left playing is measuring the transcript, not the cut.
        scored = _clamped([span], total)
        scored_span = scored[0] if scored else Span(span.start, span.start)
        shared = sum(scored_span.overlap(cut) for cut in cuts)

        if label == "must-keep":
            keep_loss += shared
            passed = shared <= KEEP_TOLERANCE_SECONDS
            note = (
                f"{shared:.1f}s of programme removed"
                if not passed
                else f"intact ({shared:.1f}s touched)"
            )
            if not passed:
                failures.append(f"lost {shared:.1f}s of programme at {span.start:.1f}s")
        elif label == "must-cut":
            remnant = scored_span.seconds - shared
            covered = shared / scored_span.seconds if scored_span.seconds else 0.0
            passed = remnant <= CUT_REMNANT_TOLERANCE_SECONDS
            note = f"{covered:.0%} of the advertisement removed, {remnant:.1f}s left"
            if not passed:
                failures.append(f"left {remnant:.1f}s of advertising at {span.start:.1f}s")
        elif label == "acceptable-cut":
            # Deliberately unscored. Recorded so a reader can see what happened
            # to it without the harness taking a side David has not taken.
            passed = True
            note = f"{shared:.1f}s removed; either way is acceptable"
        else:
            raise ValueError(f"{case['id']}: unknown label {label!r}")

        verdicts.append(
            SpanVerdict(label=label, span=span, why=expected["why"],
                        overlap_seconds=shared, passed=passed, note=note)
        )

    if keep_loss > KEEP_LOSS_BUDGET_SECONDS:
        failures.append(
            f"lost {keep_loss:.1f}s of programme across the episode"
            f" (budget {KEEP_LOSS_BUDGET_SECONDS:.1f}s)"
        )

    labelled = union_spans(
        Span(float(entry["start"]), float(entry["end"])) for entry in case["expected"]
    )
    unknown = sum(
        max(0.0, cut.seconds - sum(cut.overlap(region) for region in labelled))
        for cut in _clamped(cuts, total)
    )
    labelled_coverage = (
        sum(region.seconds for region in _clamped(labelled, total)) / total if total else 0.0
    )

    return CaseVerdict(
        case_id=case["id"],
        show=case["show"],
        passed=not failures,
        reason="; ".join(failures) if failures else "every labelled span is where it should be",
        spans=verdicts,
        produced=produced,
        keep_loss_seconds=keep_loss,
        unknown_cut_seconds=unknown,
        labelled_coverage=labelled_coverage,
        coverage_complete=unknown <= UNKNOWN_CUT_TOLERANCE_SECONDS,
    )


def _clamped(spans, total: float | None) -> list[Span]:
    """The spans inside the episode. A cut to end-of-file overhangs the probe."""
    if total is None:
        return list(spans)
    inside = [Span(max(0.0, s.start), min(total, s.end)) for s in spans]
    return [s for s in inside if s.seconds > 0.0]


def recorded_spans(case: dict, *, library: Path) -> list[Span] | None:
    """The spans a real preparation committed, or None when it is not here.

    Returns None rather than an empty list for an absent item, because "this
    machine never prepared it" and "the detector found nothing" are opposite
    readings and only one of them is a failure.
    """
    if not library.exists():
        return None
    connection = sqlite3.connect(f"file:{library}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT CAST(ZSTATUSDATA AS TEXT) FROM ZPREPARATIONRECORD"
            " WHERE ZITEMID = ? ORDER BY ZEMITTEDAT DESC",
            (case["itemID"],),
        ).fetchall()
    finally:
        connection.close()

    for (blob,) in rows:
        try:
            status = json.loads(blob or "")
        except (ValueError, TypeError):
            continue
        timeline = status.get("timeline") or {}
        if "removed" not in timeline:
            continue
        return [
            Span(float(entry["originalStartSeconds"]), float(entry["originalEndSeconds"]))
            for entry in timeline["removed"]
        ]
    return None


def cached_segments(case: dict, *, cache: Path):
    """The aligned segments the original detection consumed, or None.

    Matched by the source hash the pipeline itself keys the cache on, so a
    replay sees byte-identical input to the run being reproduced rather than a
    transcript reconstructed after the fact.
    """
    if not cache.is_dir():
        return None
    for path in sorted(cache.glob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if payload.get("sourceHash") == case["sourceHash"]:
            return payload.get("segments") or None
    return None


def archive_sources() -> Path:
    """The directory holding `wilted.ads`, resolved the way the app resolves it."""
    override = os.environ.get("WILTED_PIPELINE_PYTHONPATH")
    return Path(override) if override else DEFAULT_ARCHIVE_SOURCES


def replay_spans(case: dict, *, cache: Path):
    """Re-run the live detector over this case's cached segments.

    Returns the spans it produced and the serialized audit that travels with
    every live analysis, or None when this machine has no cached transcript
    for the case.

    The judgement, the safeguards and the refusals all come from
    `analyze_ad_detections`, which is the same call `detect_and_cut` makes. The
    corpus deliberately owns none of it: a replay that assembled the passes
    itself would drift from the app one edit at a time, and it drifted already
    -- it was missing the coverage refusals and the dropped-anchor audit, so it
    could score a run the app would have refused outright.
    """
    segments = cached_segments(case, cache=cache)
    if segments is None:
        return None

    # The worker never sets this up itself -- Swift hands it a PYTHONPATH when it
    # spawns it -- so a replay has to do the same job or die on `import wilted`.
    sources = archive_sources()
    if not (sources / "wilted" / "ads.py").is_file():
        raise RuntimeError(
            f"no archived detector under {sources}; set WILTED_PIPELINE_PYTHONPATH "
            "to the previous project's src directory"
        )
    sys.path.insert(0, str(sources))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import wilted_pipeline as wp  # noqa: PLC0415 - deferred; loading it is expensive

    from wilted import ads as ads_module  # noqa: PLC0415
    from wilted import llm as llm_module  # noqa: PLC0415

    # `CachedAlignedSegment`, not the archive's `TranscriptSegment`: the worker
    # hands the detector its own cached type and the two are only duck-typed
    # alike, so replaying with the other one would measure a call the app never
    # makes.
    aligned = [
        wp.CachedAlignedSegment(
            text=segment["text"],
            start_s=float(segment["start_s"]),
            end_s=float(segment["end_s"]),
        )
        for segment in segments
    ]
    # `probe_duration` of the original file, which preparation has since
    # overwritten -- the manifest carries it derived. Both size guards divide by
    # this, so using the transcript's last cue instead would shift them.
    total = float(case["audioDurationSeconds"])
    model = str(llm_module.DEFAULT_GGUF_MODEL)
    # The archive refuses to build a multi-gigabyte model outside an execution
    # capability, which the worker claims once around its whole run. A replay
    # loads the same model for the same reason, so it claims it the same way and
    # at the same depth -- outside the admission lock, as `main` is outside
    # `run`. The capability carries a data directory nothing reads; it gets the
    # one the worker would have derived so the two calls stay identical.
    from wilted.execution_capability import execution_capability_scope  # noqa: PLC0415

    # The same admission lock a preparation takes, so replaying while the app is
    # working queues behind it instead of contending for the GPU.
    lock = wp.prepare_ad_model_lock(model, aligned_stt=False)
    with execution_capability_scope(owner_id="wilted-ad-corpus-replay", data_dir=cache.parent), \
            (lock or contextlib.nullcontext()):
        backend = llm_module.create_backend("gguf", model=model)
        backend.load()
        try:
            # Handed the raw backend, exactly as `detect_and_cut` hands its own:
            # the audit wrapper is built inside, so the replay cannot wrap it
            # differently from the run it is reproducing.
            analysis = wp.analyze_ad_detections(ads_module, backend, aligned, total)
        except wp.WorkerError as error:
            raise ReplayRefused(error.code, str(error)) from error
        finally:
            backend.close()
    return (
        [Span(float(ad.start_s), float(ad.end_s)) for ad in analysis.detections],
        wp.serialize_ad_audit(analysis.audit),
    )


def run(mode: str, *, library: Path, cache: Path, manifest: Path = MANIFEST,
        strict: bool = False) -> list[CaseVerdict]:
    results: list[CaseVerdict] = []
    for case in load_manifest(manifest)["cases"]:
        if mode == "replay":
            # A replay loads a four-gigabyte model and spends minutes per case,
            # and the only thing it emits meanwhile is the detector's own
            # journal, which names no case. Two cases running produce one
            # interleaved stream nobody can attribute until the report lands, so
            # say whose turn it is first. Stderr, because stdout carries the
            # report and the `--json` payload.
            print(f"ad-corpus: replaying {case['id']}", file=sys.stderr, flush=True)
        audit = None
        try:
            if mode == "recorded":
                produced = recorded_spans(case, library=library)
            else:
                replayed = replay_spans(case, cache=cache)
                produced, audit = replayed if replayed is not None else (None, None)
        except ReplayRefused as refusal:
            # The pipeline declining to guess is a result, not a crash, and it
            # belongs against the case that provoked it rather than taking the
            # rest of the corpus down with it.
            results.append(CaseVerdict(
                case_id=case["id"], show=case["show"], passed=False,
                reason=f"the worker refused this analysis -- {refusal}",
            ))
            continue
        if produced is None:
            missing = (
                f"no preparation for {case['itemID']} in {library}" if mode == "recorded"
                else f"no cached transcript for {case['sourceHash']} in {cache}"
            )
            results.append(CaseVerdict(
                case_id=case["id"], show=case["show"],
                # Strict is the candidate-measurement mode: a case that did not
                # run measured nothing, and a corpus that quietly shrinks to the
                # cases a machine happens to hold is how a fix gets called good.
                passed=not strict, skipped=not strict,
                reason=missing if strict else missing + " (skipped)",
            ))
            continue
        verdict = score_case(case, produced)
        verdict.audit = audit
        results.append(verdict)
    return results


def report(results: list[CaseVerdict]) -> str:
    lines: list[str] = []
    for result in results:
        mark = "SKIP" if result.skipped else ("PASS" if result.passed else "FAIL")
        lines.append(f"{mark}  {result.case_id}  ({result.show})")
        lines.append(f"      {result.reason}")
        for span in result.spans:
            flag = " " if span.passed else "!"
            lines.append(
                f"    {flag} {span.label:<14} {span.span.start:8.2f}-{span.span.end:8.2f}  {span.note}"
            )
        if result.produced:
            cuts = ", ".join(f"{s.start:.1f}-{s.end:.1f}" for s in result.produced)
            lines.append(f"      detector cut: {cuts}")
        if result.spans:
            # Said on every case, passing or not: "every labelled span is where
            # it should be" is a much smaller claim when the labels cover half
            # the episode and a minute of cutting happened outside them.
            lines.append(
                f"      {result.labelled_coverage:.0%} of the episode is labelled"
                f", {result.unknown_cut_seconds:.1f}s cut outside those labels"
                f"{'' if result.coverage_complete else ' -- verdict is partial'}"
            )
        lines.append("")
    scored = [r for r in results if not r.skipped]
    failed = [r for r in scored if not r.passed]
    partial = [r for r in scored if not r.coverage_complete]
    lines.append(
        f"ad-corpus: {len(scored) - len(failed)}/{len(scored)} cases pass"
        f", {len(results) - len(scored)} skipped"
        f", {len(partial)} scored only in part"
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mode", choices=("recorded", "replay"), default="recorded",
                        help="score the library's committed cuts, or re-run the live detector")
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--cache", type=Path, default=DEFAULT_ALIGNED_CACHE)
    parser.add_argument("--strict", action="store_true",
                        help="require every case to run; a missing input fails rather than skips")
    parser.add_argument("--json", action="store_true", help="machine-readable verdicts")
    args = parser.parse_args(argv)

    results = run(args.mode, library=args.library, cache=args.cache, strict=args.strict)
    if args.json:
        print(json.dumps([{
            "case": r.case_id, "passed": r.passed, "skipped": r.skipped, "reason": r.reason,
            "keepLossSeconds": round(r.keep_loss_seconds, 3),
            "unknownCutSeconds": round(r.unknown_cut_seconds, 3),
            "labelledCoverage": round(r.labelled_coverage, 4),
            "coverageComplete": r.coverage_complete,
            "spans": [{"label": s.label, "start": s.span.start, "end": s.span.end,
                       "passed": s.passed, "note": s.note} for s in r.spans],
            # The same evidence the live result publishes, so a corpus verdict
            # can be trusted or distrusted on the same grounds as a preparation.
            "audit": r.audit,
        } for r in results], indent=2))
    else:
        print(report(results))
    # Outside strict mode a skip exits zero, so a machine holding neither the
    # library nor the cache can still run this and read the report.
    return 1 if any(not r.passed for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
