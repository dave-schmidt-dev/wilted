# Integration seam spike — station MediaDescriptor -> PlaybackAdapter -> engine.play_file

Throwaway spike, run 2026-07-10. Harness: `spikes/integration-seam-2026-07-10/spike.py`.

## Summary

Proved, against real data and a real `AudioEngine`, that the ms->s unit
conversion between station's `TranscriptSegment` and `engine.play_file`'s
expected duck-typed shape is exactly `start_s = start_ms / 1000.0`, and that
a correctly-adapted segment list drives a real ffmpeg accurate-seek to the
right episode-time offset (segment 12: `start_ms=126680` -> engine sought to
`playback_time_s≈126.7-127.3` depending on run, delta well under 1s, always
PASS). No audio was audibly played — `sounddevice.OutputStream` was mocked
using the same pattern already established in `tests/test_engine.py`, so the
proof exercises real ffmpeg decode/seek against the real mp3 with zero sound
output. Separately inspected the real on-disk article audio cache shape
(`data/audio/1/` complete, `data/audio/2/` empty/unprepared) to ground the
PM-3 finalization contract below. Harness: `spike.py` runs in well under a
second and exits 0.

---

## PM-1: TranscriptSegment unit mismatch (station ms vs engine seconds)

**The mismatch.** Two distinct `TranscriptSegment` types exist in this
codebase, and they are not interchangeable:

- `src/wilted/station/models.py:47-66` — frozen dataclass
  `TranscriptSegment(start_ms: int, end_ms: int, text: str)`. Integer
  **milliseconds**. `__post_init__` validates `start_ms >= 0` and
  `end_ms >= start_ms`.
- `src/wilted/transcribe.py:34-40` — plain dataclass
  `TranscriptSegment(start_s: float, end_s: float, text: str)`. Float
  **seconds**. This is the shape `engine.play_file` actually consumes: it
  duck-types on `.start_s` / `.end_s` / `.text` and never isinstance-checks
  (`engine.py:465`: `seek_time_s = float(transcript_segments[start_segment].start_s)`;
  `engine.py:496`: `episode_time_s >= transcript_segments[seg_cursor].start_s`).

Passing station-shaped segments (which have `.start_ms`, not `.start_s`)
directly to `play_file` would raise `AttributeError` immediately — the more
dangerous failure mode is a **wrong conversion** that still produces a
`.start_s` attribute but with the wrong numeric value (forgetting `/1000`,
or dividing twice), which raises nothing and just silently mis-seeks resume
by three orders of magnitude, or collapses it to near-zero.

**The conversion.** Exactly one line:

```python
start_s = seg.start_ms / 1000.0
```

**Proven, concrete example from the spike run** (`spike.py`, `run_pm1_proof`):

- Loaded the real transcript cache
  `data/transcripts/measure-404-best-game_transcript.json` via
  `wilted.transcribe.load_transcript` (756 segments, already in
  transcribe.py/seconds shape).
- Segment 12 as loaded: `start_s=126.68`, `end_s=146.76`.
- Simulated the station's ms-shaped storage by round-tripping every segment
  through `start_ms = round(start_s * 1000)` — this is the direction a real
  `PlaybackAdapter` will actually face (station DB stores ms; engine wants
  s), even though today's on-disk cache happens to already be in seconds.
  Segment 12 station-shaped: `start_ms=126680`, `end_ms=146760`.
- Built a full `MediaDescriptor` around all 756 converted segments
  (`sha256` over the real mp3 bytes, real `byte_size`, `mime_type="audio/mpeg"`,
  `duration_ms` from the last segment's `end_ms`, `SafeInterruptionMap.from_transcript_segments(...)`,
  `byte_range_available=False`, `finalization=FinalizationState.complete()`).
  `descriptor.is_playable` was `True`, confirming the surrounding types
  compose without friction.
- Ran the adapter (`station_segments_to_engine_segments`, the one-line
  conversion above) over `descriptor.transcript_segments`, producing a list
  of `EngineTranscriptSegment(start_s, end_s, text)` NamedTuples.
- Called `engine.play_file(path=<real mp3>, transcript_segments=<adapted>, start_segment=12, on_progress=...)`
  in a background thread against the real 94-minute podcast mp3, with
  `sounddevice.OutputStream` mocked (see "audio played?" below). Confirmed
  the seek landed via `on_progress` firing for segment 12, then called
  `engine.stop()` and joined the thread.
- Observed (representative run): `engine.playback_time_s = 127.320000`,
  `engine.current_segment_idx = 12`, `delta = 0.640000s` (< 1.0s tolerance).
  Across 3 repeated runs, delta ranged ~0.04s-0.64s (ffmpeg decode-startup
  granularity), always well inside tolerance. **PASS** every time.

  Exact proof line (one representative run):

  ```
  PM-1 PROOF: segment 12 start_ms=126680 -> converted start_s=126.68 -> engine sought to playback_time_s=127.320000 (delta=0.640000s) PASS
  ```

**Where the real conversion must live.** A single, tested conversion
function/method owned by the `PlaybackAdapter` — e.g. the spike's
`station_segments_to_engine_segments()` — is the only place `start_ms / 1000.0`
should ever be written. It must:
- Be unit-tested directly (given ms in, assert exact s out — including a
  regression test for the "forgot to divide" and "divided twice" failure
  modes, since neither raises an exception on its own).
- Be the single call site every consumer of station transcript segments
  routes through before calling `engine.play_file` — no inline
  `/1000.0` scattered at other call sites, precisely because a second copy
  is where a future edit silently reintroduces the bug this spike exists to
  prevent.

---

## PM-3: article finalization completeness contract

This is the concrete A.2 implementation contract, derived from inspecting
real on-disk data (`spike.py`, `run_pm3_inspection`).

### 1. Article audio is a per-paragraph cache DIRECTORY, not one file

`data/audio/<item_id>/para_NNN.mp3` (NNN = `000`, `001`, ...) — one mp3 per
paragraph, e.g. `data/audio/1/` has `para_000.mp3` through `para_026.mp3`
(27 files) plus a `manifest.json`. Contrast with a podcast, where
`Item.audio_file` points to a single mp3 file.

- Generation: `src/wilted/cache.py`, `generate_article_cache()` (line 153).
- Podcast prep sets `Item.audio_file` to the single mp3 FILE path:
  `src/wilted/prepare.py:77` (`Item.update(audio_file=str(audio_path))...`, in
  `_prepare_podcast`).
- Article prep sets `Item.audio_file` to the cache DIRECTORY path:
  `src/wilted/prepare.py:238` (`audio_file=str(audio_dir)`, in `_prepare_article`).
- The DB schema does not distinguish the two shapes:
  `src/wilted/db.py:191` — `Item.audio_file = CharField(null=True)`. The
  caller must already know `item_type` to know which shape to expect.
  `MediaDescriptor`'s docstring (`station/models.py:267-272`) explicitly
  calls out that it exists to hide this inconsistency.

### 2. manifest.json schema and status semantics

Observed real shape (`data/audio/1/manifest.json`):

```json
{
  "article_id": 1, "voice": "af_heart", "lang": "a", "speed": 1.0,
  "added": "2026-04-21T21:51:38Z", "status": "complete",
  "paragraphs": [
    {"file": "para_000.mp3", "duration_seconds": 27.225, "samples": 653400},
    {"file": "para_001.mp3", "duration_seconds": 17.325, "samples": 415800},
    ... (27 entries total for article_id=1)
  ]
}
```

- `status` is `"generating"` while `generate_article_cache()` is still
  writing paragraphs (`cache.py:148`), and is only set to `"complete"` once
  every paragraph has been synthesized (`cache.py:226`,
  `manifest["status"] = "complete"`).
- `is_cache_valid()` (`cache.py:98`) is the existing validity gate: it
  requires the manifest's `voice`/`lang`/`speed`/`added` to match the
  requested values **and** `status == "complete"` (`cache.py:108`). A
  `"generating"` manifest (partial synthesis, e.g. process killed mid-run)
  is correctly treated as invalid/incomplete by this check.
- `data/audio/2/` is empty — no `manifest.json`, no mp3s at all — confirmed
  by the spike as the concrete "not yet prepared" contrast case: zero
  directory entries, `manifest.json exists = False`.

### 3. Turning the per-paragraph cache into ONE playable file for `engine.play_file`

`engine.play_file` takes a single `path`. To play an article through the
same engine call as a podcast, the per-paragraph cache must first be
concatenated:

1. Build an ffmpeg concat-list file listing `para_000.mp3 .. para_NNN.mp3`
   in the manifest's `paragraphs[]` order (order in the manifest is
   authoritative, not a re-glob/re-sort of the directory).
2. Run `ffmpeg -f concat -safe 0 -i concat_list.txt -c copy <output.mp3>`
   (stream copy, no re-encode, since all paragraph mp3s share the same
   voice/lang/speed and should already share compatible codec params) —
   fall back to re-encoding only if a codec/parameter mismatch is ever
   detected between paragraphs.
3. The manifest's per-paragraph `duration_seconds` gives the **exact**
   timing map needed to build `transcript_segments` for the concatenated
   output, with no extra probing required: paragraph N's `start_s` is the
   cumulative sum of all prior paragraphs' `duration_seconds`, and its
   `end_s` is that sum plus its own `duration_seconds`. The spike computed
   this directly from `data/audio/1/manifest.json` and printed the first
   three rows as a concrete example:

   ```
   para_000.mp3: start_s=0.000  end_s=27.225
   para_001.mp3: start_s=27.225 end_s=44.550
   para_002.mp3: start_s=44.550 end_s=80.300
   ...
   derived total duration = 695.225s
   ```

   This cumulative-duration map is precisely the "timing map" referenced in
   `FinalizationState.timing_map_created` below — it can be derived directly
   from the existing manifest without any new source of truth, though A.2
   should decide whether to persist it as its own artifact (e.g.
   `timing_map.json` alongside the concatenated mp3) or recompute it
   on-demand from `manifest.json` each time.

### 4. Conditions for `MediaDescriptor.is_playable` to be True, for an article

`is_playable` (`station/models.py`) is just `self.finalization.is_complete`,
i.e. all four `FinalizationState` booleans True, enforced in order
`ads_cut -> timing_map_created -> hashed -> published`
(`station/models.py:210-260`). Mapped onto the article pipeline:

- **Manifest + files precondition** (not itself a `FinalizationState` field,
  but a precondition for computing any of the four): `manifest.json` must
  exist, `status == "complete"`, and every paragraph file it lists must
  exist on disk and be non-empty (`size > 0`). The spike verified this
  concretely for `data/audio/1/` (`all listed mp3s exist & non-empty = True`)
  and confirmed the negative case for `data/audio/2/` (no manifest at all).
- **`ads_cut`** — **no obvious article-side equivalent exists.** Ad-cutting
  is an audio-domain operation on podcast episodes; the closest article
  analog is promo-removal, but per `src/wilted/prepare.py`'s article flow
  that happens on **TEXT, before TTS** (a pre-synthesis content-filtering
  step), not as a post-hoc audio-domain edit the way ad-cutting is for
  podcasts. These are different pipeline stages operating on different
  media (text vs audio) at different times (before vs after synthesis).
  A.2 must explicitly decide one of:
  - always set `ads_cut=True` for articles (treat it as vacuously satisfied,
    since there is nothing to cut post-synthesis), or
  - rename/reinterpret the field so it means something coherent for both
    media types (e.g. `content_filtered` covering both ad-cutting and
    promo-removal), or
  - introduce a parallel/renamed `FinalizationState` variant for articles.

  This spike does not resolve which option A.2 should take — it only
  establishes that the field cannot be mapped 1:1 without a decision.
- **`timing_map_created`** — satisfied once the cumulative-duration map
  described in step 3 exists (derived from or persisted alongside the
  manifest) for the **concatenated** output file.
- **`hashed`** — the `sha256` must be computed over the bytes of the
  **final concatenated file**, never over any individual `para_NNN.mp3`,
  and never before concatenation has happened (a per-paragraph hash is not
  a valid substitute — it hashes the wrong artifact).
- **`published`** — the concatenated single file must be atomically placed
  at its final path (write-then-rename), mirroring the pattern
  `cache.py`'s `save_manifest()` already uses for the manifest itself
  (`cache.py:74-83`: write to a `tempfile.NamedTemporaryFile` in the same
  directory, then `os.replace(tmp_path, manifest_path)`). The concat output
  should follow the identical write-to-tempfile-then-`os.replace` pattern
  so a reader can never observe a partially-written concatenated mp3.

`data/audio/2/` (empty directory, no manifest) is the concrete real-data
"not `is_playable`" contrast case: none of the four `FinalizationState`
preconditions can be computed because there is no manifest and no audio at
all.

---

## Did real audio play?

**No.** `sounddevice.OutputStream` was mocked to a `MagicMock` for the
duration of the `play_file` call, using the exact pattern already
established in `tests/test_engine.py` (`mock_stream` fixture,
`tests/test_engine.py:33-39`, and its use in
`test_resume_seeks_ffmpeg_and_offsets_time`, `tests/test_engine.py:627-661`).
This leaves ffmpeg itself completely real — the spike shells out to the
actual `ffmpeg` binary against the actual mp3 file, performs a real
accurate-seek decode, and reads real PCM — so the seek proof is genuine, not
simulated. Only the final `stream.write()` call into a real audio device was
intercepted. Zero audible sound was produced. No TTS/ML model was loaded at
any point (`engine.load_model()` / `generate_audio()` were never called).

**Notable side-finding**: an initial version of this spike used a fixed
`time.sleep(0.5)` before calling `engine.stop()`, on the assumption that
0.5s would only let a couple of PCM blocks through. That assumption is
wrong once `OutputStream` is mocked: with no real playback device to
throttle it, `_stream_pcm`'s write loop consumes ffmpeg's piped PCM as fast
as ffmpeg can decode it — measured at roughly 50 blocks (~200KB) in ~0.1s
for this file, i.e. far faster than real-time — so a fixed sleep let
playback run to (near) completion before `stop()` fired, landing
`playback_time_s` over 500 seconds past the intended target. The fixed
version instead uses the `on_progress` callback as the stop trigger: it
fires exactly once as playback crosses into `start_segment` (which happens
on the very first emitted block, since `seg_cursor` starts at
`start_segment` — `engine.py:481-497`), so the spike stops playback the
instant the seek is confirmed, independent of ffmpeg's decode speed. This
is itself useful evidence for anyone writing tests/tooling in this area:
**mocking the output stream removes real-time pacing entirely**, so any
timing-based stop condition (rather than a callback/event-based one) is
unreliable once the output device is mocked.
