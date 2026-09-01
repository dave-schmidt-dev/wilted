#!/usr/bin/env python3
"""Prepare one downloaded podcast episode: transcript, ad detection, ad removal.

This is the bridge to the previous Python Wilted. The valuable, hard to
reproduce part of that codebase is `wilted.ads` -- roughly 1,500 lines of tuned
prompts and boundary verification -- and the transcript parsers beside it. None
of that is reimplemented here; this module is the process boundary the native
app talks to.

Protocol, deliberately narrow:

  stdin   one JSON request object, then EOF
  stderr  newline-delimited JSON progress records, one per line
  stdout  one JSON response object

The worker performs no network access. Every document it needs -- the published
transcript, the episode page -- is fetched by the caller and passed in as text,
so the transport policy (HTTPS only, size caps, redirect rules) stays in one
place on the Swift side and no credentialed feed URL ever reaches this process.

Run it with the previous project's virtualenv and source tree on the path:

    PYTHONPATH=<wilted-old>/src <wilted-old>/.venv/bin/python wilted_pipeline.py
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

PROTOCOL_VERSION = 1

# Tools the audio cut shells out to. Checked before any work starts: a GUI app
# launched from Finder inherits a PATH without Homebrew, and finding that out
# after twelve minutes of speech-to-text is the wrong time.
CUT_TOOLS = ("ffmpeg", "ffprobe")

# How many of the previous project's warnings are relayed verbatim before the
# rest are counted. The ad detector logs one warning per failed batch and
# halves down to singletons, so a dead backend produces thousands.
FORWARDED_WARNING_LIMIT = 20

# Media types whose timing the publisher states. Mirrors
# WiltedDomain.PodcastTranscriptSource.timedMediaTypes; the two must agree,
# because the Swift side decides what to send based on its copy and this side
# decides what to parse based on this one.
TIMED_MEDIA_TYPES = {
    "text/vtt": "vtt",
    "application/x-subrip": "srt",
    "application/srt": "srt",
    "text/srt": "srt",
    "application/json": "podcast-json",
}

# Below this, an extracted web page is show notes rather than a transcript.
# Carried over from the previous pipeline's own threshold.
MINIMUM_PROSE_WORDS = 500


class WorkerError(RuntimeError):
    """A failure that should be reported as a structured result, not a crash."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------


def progress(stage: str, detail: str = "", fraction: float | None = None) -> None:
    """Emit one progress record on stderr.

    Every stage below is minutes long on a real episode. A caller with no
    feedback channel cannot tell a working transcription from a hung one, so
    this is part of the contract rather than logging.
    """
    record = {"stage": stage, "detail": detail}
    if fraction is not None:
        record["fraction"] = round(max(0.0, min(1.0, fraction)), 4)
    sys.stderr.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stderr.flush()


class ForwardedWarnings(logging.Handler):
    """Relay WARNING+ log records from every library in this process as progress.

    The previous project reports trouble through `logging`. With no handler
    installed, Python's last-resort handler printed those lines to raw stderr,
    where the Swift collector discards anything that is not a JSON record --
    so the thousands of "Model not loaded" warnings that explained the TWiT
    1098 false negative were thrown away. Each relayed record gets its own
    numbered stage because the journal keeps one row per stage.
    """

    def __init__(self, limit: int = FORWARDED_WARNING_LIMIT):
        super().__init__(level=logging.WARNING)
        self.limit = limit
        self.forwarded = 0
        self.suppressed = 0

    def emit(self, record: logging.LogRecord) -> None:
        if self.forwarded >= self.limit:
            self.suppressed += 1
            return
        self.forwarded += 1
        try:
            progress(f"log.{record.levelname.lower()}.{self.forwarded}", f"{record.name}: {record.getMessage()}")
        except Exception:  # noqa: BLE001 - a handler must never unwind its caller
            self.handleError(record)

    def summarize(self) -> None:
        if self.suppressed:
            progress("log.suppressed", f"{self.suppressed} further warnings not relayed")


# ---------------------------------------------------------------------------
# Cue timing
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class KeepInterval:
    """One span of the original audio that survives the cut."""

    start_s: float
    end_s: float
    output_start_s: float

    @property
    def duration_s(self) -> float:
        return self.end_s - self.start_s


def build_keep_map(keep_segments: list[tuple[float, float]]) -> list[KeepInterval]:
    """Turn ffmpeg's keep spans into a map from original time to output time."""
    intervals: list[KeepInterval] = []
    output = 0.0
    for start, end in keep_segments:
        if end <= start:
            continue
        intervals.append(KeepInterval(start_s=start, end_s=end, output_start_s=output))
        output += end - start
    return intervals


def remap_cues(cues: list[dict], keeps: list[KeepInterval]) -> list[dict]:
    """Move cue timing onto the cut audio's clock.

    Cutting ads shifts every timestamp after the first cut, so a transcript
    that was synchronised with the download is wrong the moment the file is
    rewritten. The previous pipeline never did this -- its transcript was read,
    not followed -- which is why this is new code rather than a port.

    A cue landing entirely inside a removed span is dropped. A cue straddling a
    boundary keeps its whole text and is bracketed by the surviving audio: the
    text may then include a few words that were cut, which is a smaller error
    than dropping a line of real content or leaving the timing pointing at
    audio that no longer exists.
    """
    if not keeps:
        return []
    remapped: list[dict] = []
    for cue in cues:
        start, end = float(cue["startSeconds"]), float(cue["endSeconds"])
        covered = [k for k in keeps if k.end_s > start and k.start_s < end]
        if not covered:
            continue
        first, last = covered[0], covered[-1]
        new_start = first.output_start_s + max(0.0, start - first.start_s)
        new_end = last.output_start_s + min(last.duration_s, max(0.0, end - last.start_s))
        if new_end < new_start:
            new_end = new_start
        remapped.append({
            "startSeconds": round(new_start, 3),
            "endSeconds": round(new_end, 3),
            "text": cue["text"],
        })
    # Cutting can pull two cues onto the same instant. Order is a contract
    # invariant on the Swift side, so it is restored here rather than there.
    remapped.sort(key=lambda c: c["startSeconds"])
    return remapped


def segments_to_cues(segments) -> list[dict]:
    """Project the previous pipeline's segments onto the cue contract.

    Token-level timing is dropped on purpose: it is input to ad-boundary
    refinement, not durable state, and keeping it would multiply the stored
    transcript several times over for no reading benefit.
    """
    cues: list[dict] = []
    for segment in segments:
        text = (segment.text or "").strip()
        if not text:
            continue
        start = max(0.0, float(segment.start_s))
        end = max(start, float(segment.end_s))
        cues.append({"startSeconds": round(start, 3), "endSeconds": round(end, 3), "text": text})
    cues.sort(key=lambda c: c["startSeconds"])
    return cues


def cues_to_text(cues: list[dict]) -> str:
    return " ".join(cue["text"] for cue in cues).strip()


# ---------------------------------------------------------------------------
# Transcript sourcing
# ---------------------------------------------------------------------------


def parse_published_transcript(body: str, media_type: str, url: str):
    """Parse a transcript the feed published, or return None if unusable."""
    from wilted import transcribe

    parsers = {
        "vtt": transcribe.parse_vtt,
        "srt": transcribe.parse_srt,
        "podcast-json": transcribe.parse_podcast_json,
    }
    kind = TIMED_MEDIA_TYPES.get(media_type.strip().lower())
    if kind is None:
        # The type attribute is advisory and publishers get it wrong. Falling
        # back to the extension recovers a real transcript that would
        # otherwise be thrown away for a typo.
        lowered = url.lower()
        for extension, guess in ((".vtt", "vtt"), (".srt", "srt"), (".json", "podcast-json")):
            if lowered.endswith(extension):
                kind = guess
                break
    if kind is None:
        return None
    try:
        return parsers[kind](body) or None
    except Exception as error:  # noqa: BLE001 - a bad transcript is not a failed episode
        progress("transcript.published.unparseable", f"{kind}: {error}")
        return None


def extract_prose(html: str) -> str | None:
    """Pull readable prose out of an episode page, or None if it is show notes.

    The result carries no timing and is never presented as if it did. The
    previous pipeline estimated timestamps here at 150 words per minute; that
    number is a guess about a page, not a measurement of audio, and it cannot
    drive a reading position or an audio cut.
    """
    import trafilatura

    try:
        text = trafilatura.extract(html)
    except Exception:  # noqa: BLE001
        return None
    if not text:
        return None
    return text if len(text.split()) >= MINIMUM_PROSE_WORDS else None


def transcribe_with_daemon(audio_path: Path):
    """Tier three: our own speech-to-text, aligned against this exact audio."""
    from wilted import transcribe

    progress("transcript.stt.start", str(audio_path.name))
    segments = transcribe.transcribe_audio(audio_path)
    progress("transcript.stt.complete", f"{len(segments)} segments")
    return segments


# ---------------------------------------------------------------------------
# Ad removal
# ---------------------------------------------------------------------------


class CountingBackend:
    """Wrap the classifier's backend so a run that never reached the model is
    distinguishable from one that ran and found nothing.

    The detector treats every backend exception as a malformed response: it
    retries, halves the batch, and finally labels each segment as content. That
    is the right call for one bad completion and the wrong one for a backend
    that cannot answer at all, which it cannot tell apart. This can.
    """

    def __init__(self, backend):
        self._backend = backend
        self.calls = 0
        self.failures = 0
        self.last_error: Exception | None = None

    def generate(self, system_prompt: str, user_content: str, *, response_format=None):
        self.calls += 1
        try:
            return self._backend.generate(system_prompt, user_content, response_format=response_format)
        except Exception as error:
            self.failures += 1
            self.last_error = error
            raise

    @property
    def mostly_failed(self) -> bool:
        """True when the backend, not the completions, is what is broken.

        A healthy backend raises essentially never: the accepted four-podcast
        trial made 207 calls with no malformed responses, and a malformed
        response is the detector's parse error rather than a backend exception
        anyway. A majority of raised calls is an environment fault, and one
        lucky singleton must not disarm the check.
        """
        return self.calls > 0 and self.failures * 2 > self.calls


def preflight_ad_removal(request: dict) -> None:
    """Fail before any work if the cut cannot possibly succeed.

    Both checks are cheap, and both failures were silent before: the model
    reached the detector unloaded and every batch was quietly classified as
    content, and the missing `ffprobe` surfaced only as a skipped duration
    probe on the way out. A run that skips ad removal skips this too.
    """
    from wilted import llm as llm_module

    missing = [tool for tool in CUT_TOOLS if shutil.which(tool) is None]
    if missing:
        raise WorkerError(
            "cut-tools-missing",
            f"{', '.join(missing)} not on PATH ({os.environ.get('PATH', '')}); install ffmpeg",
        )
    model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
    # An `hf:<repo>/<file>` spec is resolved by the previous project's cache
    # at load time; only a literal path can be checked here.
    if not model.startswith("hf:") and not Path(model).is_file():
        raise WorkerError("ads-model-missing", f"no ad-detection model at {model}")


def detect_and_cut(request: dict, audio_path: Path, cues: list[dict], segments):
    """Detect ads and rewrite the audio without them.

    Returns `(output_path, ad_spans, keep_intervals)`. `output_path` is the
    input path when nothing was cut, and `keep_intervals` is empty in that
    case, which is the signal that cue timing still matches the file.
    """
    from wilted import ads as ads_module
    from wilted import llm as llm_module

    if not segments:
        return audio_path, [], []

    model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
    progress("ads.model.load", Path(model).name)
    # The previous project loads lazily and explicitly, under a coordinator
    # that keeps one model resident at a time. Without `load()` every
    # inference raises, and the detector's tolerance for bad completions turns
    # that into a clean, instant, wrong "no advertisements".
    backend = None
    try:
        backend = llm_module.create_backend("gguf", model=model)
        backend.load()
    except Exception as error:  # noqa: BLE001 - reported, not raised through
        if backend is not None:
            try:
                backend.close()
            except Exception:  # noqa: BLE001 - the load failure is the report
                pass
        raise WorkerError("ads-model-unavailable", f"{type(error).__name__}: {error}") from error
    counting = CountingBackend(backend)
    try:
        progress("ads.detect.start", f"{len(segments)} segments")
        detections = ads_module.detect_ads(segments, counting)
    finally:
        try:
            backend.close()
        except Exception:  # noqa: BLE001 - a close failure cannot undo a detection
            pass
    if counting.mostly_failed:
        raise WorkerError(
            "ads-backend-failed",
            f"the model failed {counting.failures} of {counting.calls} requests; last error: "
            f"{type(counting.last_error).__name__}: {counting.last_error}",
        )
    progress("ads.detect.calls", f"{counting.calls} requests, {counting.failures} failed")
    ad_spans = [
        {
            "startSeconds": round(float(ad.start_s), 3),
            "endSeconds": round(float(ad.end_s), 3),
            "label": ad.label,
            "confidence": round(float(ad.confidence), 4),
        }
        for ad in detections
    ]
    progress("ads.detect.complete", f"{len(ad_spans)} spans")
    if not detections:
        return audio_path, [], []

    total = probe_duration(audio_path)
    keep_segments = ads_module._compute_keep_segments(total, detections, 0.5)  # noqa: SLF001
    if not keep_segments:
        # Everything was called an ad. Refusing to cut is the only safe
        # reading: an empty file is worse than an unedited one.
        progress("ads.cut.refused", "every span was classified as an advertisement")
        return audio_path, ad_spans, []

    output_path = Path(request["outputPath"])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    progress("ads.cut.start", f"{len(keep_segments)} keep spans")
    ads_module.cut_ads(audio_path, detections, output_path)
    if not output_path.exists() or output_path.stat().st_size == 0:
        output_path.unlink(missing_ok=True)
        progress("ads.cut.empty", "cut produced no audio; keeping the original")
        return audio_path, ad_spans, []
    progress("ads.cut.complete", f"{output_path.stat().st_size} bytes")
    return output_path, ad_spans, build_keep_map(keep_segments)


def probe_duration(audio_path: Path) -> float:
    import subprocess

    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(audio_path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def run(request: dict) -> dict:
    audio_path = Path(request["audioPath"])
    if not audio_path.exists():
        raise WorkerError("audio-missing", f"no audio at {audio_path}")
    if request.get("removeAds", True):
        preflight_ad_removal(request)

    cues: list[dict] = []
    segments = None
    timing = "none"
    text: str | None = None
    language = request.get("language")

    published = request.get("publishedTranscript")
    if published:
        progress("transcript.published.parse", published.get("mediaType", ""))
        segments = parse_published_transcript(
            published.get("body", ""), published.get("mediaType", ""), published.get("url", "")
        )
        if segments:
            cues = segments_to_cues(segments)
            timing = "published"
            language = published.get("languageCode") or language
            progress("transcript.published.accepted", f"{len(cues)} cues")

    if not cues and request.get("allowSpeechToText", True):
        try:
            segments = transcribe_with_daemon(audio_path)
            cues = segments_to_cues(segments)
            timing = "aligned"
        except Exception as error:  # noqa: BLE001 - a failed tier falls through
            segments = None
            progress("transcript.stt.failed", f"{type(error).__name__}: {error}")

    if not cues:
        page = request.get("episodePage")
        if page:
            progress("transcript.prose.extract", "")
            text = extract_prose(page)
            if text:
                progress("transcript.prose.accepted", f"{len(text.split())} words")

    if not cues and not text:
        progress("transcript.absent", "no published, aligned, or prose transcript")

    output_path, ad_spans, keeps = audio_path, [], []
    if request.get("removeAds", True) and segments:
        output_path, ad_spans, keeps = detect_and_cut(request, audio_path, cues, segments)
        if keeps:
            before = len(cues)
            cues = remap_cues(cues, keeps)
            progress("transcript.remap", f"{before} cues to {len(cues)} on the cut timeline")

    if cues:
        text = cues_to_text(cues)

    # Measure the delivered file rather than subtracting what was removed: the
    # encoder decides the final frame boundaries, and a duration that disagrees
    # with the audio would desynchronise the very cues this pipeline exists to
    # align. A probe failure is not fatal -- the caller keeps its own value.
    try:
        duration = probe_duration(output_path)
    except Exception as error:  # noqa: BLE001 - the caller has a fallback
        duration = None
        progress("audio.probe.failed", f"{type(error).__name__}: {error}")

    return {
        "ok": True,
        "protocolVersion": PROTOCOL_VERSION,
        "durationSeconds": duration,
        "timing": timing if cues else "none",
        "cues": cues,
        "text": text,
        "languageCode": language,
        "audioPath": str(output_path),
        "audioChanged": str(output_path) != str(audio_path),
        "adSegments": ad_spans,
        # The exact original-to-output time map, so the caller can move a
        # listener's saved position onto the cut audio instead of losing it.
        # Empty means nothing was cut and every timestamp still matches.
        "keepIntervals": [
            {"startSeconds": round(k.start_s, 3), "endSeconds": round(k.end_s, 3),
             "outputStartSeconds": round(k.output_start_s, 3)}
            for k in keeps
        ],
        "removedSeconds": round(sum(a["endSeconds"] - a["startSeconds"] for a in ad_spans), 3) if keeps else 0.0,
    }


def main() -> int:
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as error:
        json.dump({"ok": False, "code": "bad-request", "message": str(error)}, sys.stdout)
        return 2
    if not isinstance(request, dict):
        json.dump({"ok": False, "code": "bad-request", "message": "request must be an object"}, sys.stdout)
        return 2

    data_dir = Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline"
    data_dir.mkdir(parents=True, exist_ok=True)
    warnings = ForwardedWarnings()
    # The root logger, not `wilted`: the speech daemon client and the
    # transcript parsers log under their own names.
    logging.getLogger().addHandler(warnings)
    try:
        # The previous project gates model construction behind an explicit
        # capability so nothing loads a multi-gigabyte model by accident. This
        # process exists to do exactly that, so it claims the capability once
        # around the whole run.
        from wilted.execution_capability import execution_capability_scope

        with execution_capability_scope(owner_id="wilted-native-pipeline", data_dir=data_dir):
            result = run(request)
    except WorkerError as error:
        warnings.summarize()
        json.dump({"ok": False, "code": error.code, "message": str(error)}, sys.stdout)
        return 1
    except Exception as error:  # noqa: BLE001 - the caller needs a result, not a traceback
        warnings.summarize()
        json.dump({"ok": False, "code": "worker-failed",
                   "message": f"{type(error).__name__}: {error}"}, sys.stdout)
        return 1
    warnings.summarize()
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
