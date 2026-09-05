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
get back from the cut file. `must-keep` is therefore scored to a tight
tolerance and `must-cut` to a coverage fraction.
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

# An advertisement is "found" when most of it is gone. Requiring every second
# would fail a fix that trims a spot's last breath, which is not the failure
# mode worth guarding.
CUT_COVERAGE_FLOOR = 0.75


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


def load_manifest(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def score_case(case: dict, produced: list[Span]) -> CaseVerdict:
    """Score one case's produced cuts against its labelled truth.

    Pure: every input is already resolved, so both modes and the unit tests
    share exactly this arithmetic.
    """
    verdicts: list[SpanVerdict] = []
    failures: list[str] = []

    for expected in case["expected"]:
        span = Span(float(expected["start"]), float(expected["end"]))
        label = expected["label"]
        shared = sum(span.overlap(cut) for cut in produced)

        if label == "must-keep":
            passed = shared <= KEEP_TOLERANCE_SECONDS
            note = (
                f"{shared:.1f}s of programme removed"
                if not passed
                else f"intact ({shared:.1f}s touched)"
            )
            if not passed:
                failures.append(f"lost {shared:.1f}s of programme at {span.start:.1f}s")
        elif label == "must-cut":
            covered = shared / span.seconds if span.seconds else 0.0
            passed = covered >= CUT_COVERAGE_FLOOR
            note = f"{covered:.0%} of the advertisement removed"
            if not passed:
                failures.append(
                    f"left {span.seconds - shared:.1f}s of advertising at {span.start:.1f}s"
                )
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

    return CaseVerdict(
        case_id=case["id"],
        show=case["show"],
        passed=not failures,
        reason="; ".join(failures) if failures else "every labelled span is where it should be",
        spans=verdicts,
        produced=produced,
    )


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


def replay_spans(case: dict, *, cache: Path) -> list[Span] | None:
    """Re-run the live detector over this case's cached segments.

    Imports through `wilted_pipeline` so every compatibility shim and recovery
    pass the real preparation installs is installed here too. A replay that
    reached `wilted.ads` directly would measure a detector the app does not
    ship.
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
        # Wrapped exactly as the worker wraps it, so a replay against a model
        # that is failing every request reports that instead of "no ads".
        counting = wp.CountingBackend(backend)
        try:
            wp.install_legacy_sponsor_opening_compatibility(ads_module)
            wp.install_produced_disclaimer_evidence(ads_module)
            detections = ads_module.detect_ads(aligned, counting)
            detections = wp.recover_unclaimed_explicit_sponsor_reads(
                ads_module, counting, aligned, detections)
            detections = wp.recover_transcript_start_preroll(
                ads_module, counting, aligned, detections)
            detections = wp.recover_transcript_end_postroll(
                ads_module, counting, aligned, detections, total)
            detections = wp.resize_oversized_ad_spans(
                ads_module, counting, aligned, detections, total)
        finally:
            backend.close()
    if counting.mostly_failed:
        raise RuntimeError(
            f"the model failed {counting.failures} of {counting.calls} requests;"
            f" this replay measured nothing: {counting.last_error}"
        )
    detections = wp.reject_implausible_ad_spans(detections, total)
    return [Span(float(ad.start_s), float(ad.end_s)) for ad in detections]


def run(mode: str, *, library: Path, cache: Path, manifest: Path = MANIFEST) -> list[CaseVerdict]:
    results: list[CaseVerdict] = []
    for case in load_manifest(manifest)["cases"]:
        produced = (
            recorded_spans(case, library=library) if mode == "recorded"
            else replay_spans(case, cache=cache)
        )
        if produced is None:
            results.append(CaseVerdict(
                case_id=case["id"], show=case["show"], passed=True, skipped=True,
                reason=("no preparation for this item in the local library"
                        if mode == "recorded" else "no cached transcript for this source hash"),
            ))
            continue
        results.append(score_case(case, produced))
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
        lines.append("")
    scored = [r for r in results if not r.skipped]
    failed = [r for r in scored if not r.passed]
    lines.append(
        f"ad-corpus: {len(scored) - len(failed)}/{len(scored)} cases pass"
        f", {len(results) - len(scored)} skipped"
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mode", choices=("recorded", "replay"), default="recorded",
                        help="score the library's committed cuts, or re-run the live detector")
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--cache", type=Path, default=DEFAULT_ALIGNED_CACHE)
    parser.add_argument("--json", action="store_true", help="machine-readable verdicts")
    args = parser.parse_args(argv)

    results = run(args.mode, library=args.library, cache=args.cache)
    if args.json:
        print(json.dumps([{
            "case": r.case_id, "passed": r.passed, "skipped": r.skipped, "reason": r.reason,
            "spans": [{"label": s.label, "start": s.span.start, "end": s.span.end,
                       "passed": s.passed, "note": s.note} for s in r.spans],
        } for r in results], indent=2))
    else:
        print(report(results))
    # A skip is not a pass. It exits zero so a machine without the library can
    # still run the gate, and says so on the last line either way.
    return 1 if any(not r.passed for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
