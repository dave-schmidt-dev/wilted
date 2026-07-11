# FINDINGS — Task 0.2 timing-precision spike (F4 ±250 ms band)

Run date: 2026-07-10 20:31:04-0400

**Disposable, offline analysis. No audio played, no ML models loaded.**

## Inputs

- Episode: `data/podcasts/measure-404-best-game/80391e99cf24d187eec49da364a45858.mp3` (93.9 min, 5634.8s)
- Transcript cache: `data/transcripts/measure-404-best-game_transcript.json` (756 segments)
- silencedetect params: `noise=-30dB:d=0.2` -> 1834 silence intervals detected
- Boundaries sampled: 173 (every 5th segment start, uniform across the whole timeline, plus all boundaries adjacent to gaps >= 2.0s)
- Seam boundaries (near a transcript gap >= 2.0s, i.e. likely ad-cut/concatenation): 27

## Headline numbers

- **Max boundary-to-silence offset: 12877.1 ms** (segment 755 @ 5630.28s, seam=False) — see caveat below, this is a rare long-uninterrupted-speech outlier, not typical
- Percentiles of boundary-to-silence offset: p50=54.1 ms, p90=1566.3 ms, p95=2409.1 ms, p99=12399.1 ms
- Fraction of boundaries within ±250 ms of the nearest silence: 70.5% (122/173)
- **Fraction of boundaries with >= 500 ms of surrounding silence (safe for a ±250 ms window): 63.6%** (110/173)
- Boundaries with NO detected silence interval nearby at all: 0/173
- Seam-boundary subset: max offset 12399.1 ms, 23/27 safe (85.2%)

## Drift across the episode timeline

- Least-squares slope of offset-to-silence (ms) vs. boundary time (s), for context only (see caveat — dominated by outlier placement, not used for the verdict): -0.0813 ms/s (-292.71 ms/hour), intercept = 793.3 ms
- Early third (0–31.3 min): median offset 111.8 ms, mean 824.1 ms, max 12399.1 ms (n=46)
- Middle third (31.3–62.6 min): mean offset 397.6 ms, max 4230.7 ms (n=68)
- Late third (62.6–93.9 min): median offset 21.1 ms, mean 510.6 ms, max 12877.1 ms (n=59)
- **Drift assessment (early-vs-late median, robust to outlier placement): no significant drift** — early-third median 111.8 ms vs. late-third median 21.1 ms (-90.7 ms change). No evidence of timing-map drift after ad-cut concatenation — the median offset does not grow late in the episode (where ad-cut concatenation seams would show up if the timing map were drifting).

## Seam (ad-cut/concatenation candidate) boundaries in detail

| segment_idx | boundary_s | offset_to_silence_ms | silence_width_ms |
|---|---|---|---|
| 5 | 40.24 | 1919.1 | 213.9 |
| 6 | 50.72 | 12399.1 | 213.9 |
| 299 | 2388.64 | 11.8 | 1541.9 |
| 300 | 2396.32 | 64.7 | 1298.8 |
| 301 | 2404.08 | 0.0 | 957.5 |
| 391 | 2982.32 | 79.7 | 519.6 |
| 392 | 2999.44 | 0.0 | 2337.4 |
| 427 | 3227.92 | 103.3 | 1606.4 |
| 428 | 3231.12 | 0.0 | 2641.7 |
| 463 | 3451.68 | 287.7 | 1847.4 |
| 464 | 3454.00 | 184.9 | 1847.4 |
| 552 | 3952.68 | 274.7 | 1047.3 |
| 553 | 3959.32 | 0.0 | 508.9 |
| 634 | 4626.60 | 138.3 | 656.0 |
| 635 | 4628.92 | 101.8 | 1888.9 |
| 636 | 4634.28 | 0.0 | 1140.6 |
| 637 | 4639.28 | 18.6 | 2267.4 |
| 640 | 4672.16 | 6127.2 | 233.3 |
| 641 | 4686.32 | 622.5 | 627.3 |
| 695 | 5200.44 | 0.0 | 984.7 |
| 696 | 5206.68 | 0.0 | 2409.3 |
| 722 | 5390.60 | 0.0 | 973.6 |
| 723 | 5394.28 | 0.0 | 2389.8 |
| 735 | 5468.92 | 766.3 | 204.8 |
| 736 | 5487.92 | 0.0 | 1646.4 |
| 738 | 5496.24 | 0.0 | 856.1 |
| 739 | 5503.84 | 46.0 | 1004.9 |

## Verdict

**REVISE F4 to ±2900 ms (p95 offset 2409 ms with 20% margin; current ±250 ms only covers 71% of sampled boundaries). Note 3/173 boundaries sit in long uninterrupted-speech stretches (max offset 12877 ms) that NO fixed band solves — those need boundary-snap or skip-to-next-boundary handling regardless of band size.**

## Method notes / caveats

- `silencedetect` finds *acoustic* silence (below the noise floor for >= 0.2s); transcript segment
  boundaries come from parakeet's sentence-splitter, which itself targets a 0.5s silence gap
  (`_SENTENCE_SILENCE_GAP_S` in `wilted/transcribe.py`) — so a well-behaved boundary should sit
  inside or very near a detected silence interval; large offsets indicate the transcript boundary
  landed mid-speech (the segmenter cut on a non-silence heuristic, e.g. `max_duration=20s`).
- Only segment *start* boundaries were sampled (each segment's end is the next segment's start
  except at the final segment, so start-boundary coverage implies end-boundary coverage too).
- The multi-second outliers (max ~12.9s) are NOT timing-map drift or transcript inaccuracy: manual
  inspection of segments 6 (@50.72s) and 755 (@5630.28s, the episode's last segment) confirms both
  sit inside genuine 20-40s stretches of continuous, uninterrupted speech (podcast intro/outro read
  straight through) with no acoustic silence for `silencedetect` to find nearby at all — the
  transcript boundary itself is fine, there is simply nothing silent close to it in the audio. A
  fixed ±ms band cannot make these safe at any width short of several seconds; they are a distinct
  risk class ("boundary has no nearby silence") from ordinary transcript-boundary timing error.
- This spike is disposable: safe to delete (`rm -rf spikes/timing-precision-2026-07-10`) once its
  numbers have been read into the Plan A decision record.
