# Task 8: ad proximity as review-priority evidence

Date: 2026-10-19. Harness: `Producer/Workers/ad_proximity_eval.py`. Tests: `Producer/Workers/test_ad_proximity_eval.py`.

## Question

Can kept audio sitting just before or just after an advertisement the engine already removed be put first in line for
human review? The case that matters most is an episode prepared by an older engine, whose stored cuts predate later
detector fixes. Proximity is treated as review evidence only. Nothing here authorises a cut, feeds the detector, or joins
two cuts across programme.

## Verdict

Weak support for looking *before* a stored cut; no support for looking *after* one beyond what the engine already
does. Neither is strong enough to build a review signal on.

1. **After-side proximity finds nothing new.** The continuation's own reach (`after-sponsor-read-continuation-reach`)
   reached 0 of 8 missed ads, and widening it to any anchor label (`after-90`) still reached 0 while flagging 180 s of
   programme across 2 intervals. Nothing labelled as a missed ad sits just after a stored cut; the rest of what those
   windows flagged (270.2 s and 450.2 s) is unlabelled.
2. **Before-side proximity concentrates missed ads, on very little evidence.** `before-90` reached 3 of 8 missed ads, but
   through only 2 of its 10 windows, in 2 different cases. Of its labelled flagged time, 110.2 s was missed ad against
   249.3 s of programme and 10.3 s of acceptable cut: labelled precision 0.298 against a 0.054 base rate, a 5.5x lift.
   Counting every unlabelled second as a false positive, only 110.2 of 733.4 flagged seconds (0.150) were missed ad.
3. **Widening both ways only adds programme.** No two-sided configuration reached more than the 3 ads `before-90` reached;
   `both-90` flagged 429.3 s of programme for the same 110.2 s of missed ad.
4. **Anchor quality matters more than window shape.** With oracle anchors (`label-confirmed`), `before-90` keeps the same
   3 reached ads while programme drops from 249.3 s to 98.1 s. The app cannot compute that filter; it shows the ceiling,
   not a result.

## How this differs from the existing continuation

The engine already acts on one kind of proximity. `recover_adjacent_ad_pod_continuations`
(`Producer/Workers/wilted_worker/span_bounds.py`) looks forward from a surviving `sponsor_read` cut, runs only when the
next segment starts within 3 s, reviews at most 12 segments and 90 s with the model, and extends the cut when the model
says programme resumes later. Commercial-evidence recovery (`commercial_seeds.py`,
`commercial_preservation.py`) also reviews context either side of a candidate, but only around explicit commercial
evidence in the transcript, and only cuts once programme is confirmed on both sides.

This evaluation differs on every axis: both directions, any anchor label, no model call, no transcript, and the output is
a review window, never a cut. The configuration `after-sponsor-read-continuation-reach` reproduces the continuation's
forward reach in time (90 s after a `sponsor_read` anchor, `AD_POD_CONTINUATION_MAX_SECONDS`) so the two can be compared
on the same data.

## Method

- Input: the six committed cases in `Producer/Workers/adcorpus/manifest.json`. No owner data was read or reprocessed.
- Anchors and cut: each case's `recorded` spans, which are the cuts an older engine committed. That is the realistic input
  for an old prepared episode. A second anchor set, `label-confirmed`, keeps only recorded spans that are at least half
  `must-cut` and touch `must-keep` for at most 1 s. It is an oracle upper bound, not something the app can compute.
- Review window: for each anchor, `W` seconds before its start and/or after its end, clipped to the episode, merged, with
  every removed second subtracted. A window never contains removed audio.
- Scoring, against the human labels: a missed ad is a `must-cut` label with more than 1 s left uncut; it is reached when a
  window overlaps its uncut part by more than 1 s. Flagged seconds are split into missed ad, programme (`must-keep`),
  acceptable cut, and unlabelled.
- Lift: the share of labelled flagged seconds that are missed ad, divided by the same share across all uncut labelled
  audio. Lift above 1 means the window concentrates missed ads relative to reviewing at random.
- The seven configurations were fixed before the harness was written and were not tuned afterwards. They were
  chosen after a rough exploratory pass over the same six cases, so they are not blind choices.

Reproduce with:

```
python3 Producer/Workers/ad_proximity_eval.py
```

## Corpus results

Base rate for both anchor sets: 393.0 of 7304.0 uncut labelled seconds are missed ad (0.054). Lift is
labelled precision divided by that base rate.

### Recorded anchors (what an old prepared episode actually has)

| Config | Windows | With a missed ad | Missed ads reached (of 8) | Flagged s | Missed-ad s | Programme s | Programme intervals | Acceptable s | Unlabelled s | Labelled precision | Lift |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `after-sponsor-read-continuation-reach` | 4 | 0 | 0 | 270.2 | 0.0 | 0.0 | 0 | 0.0 | 270.2 | 0.0 | 0.0 |
| `after-90` | 8 | 0 | 0 | 630.2 | 0.0 | 180.0 | 2 | 0.0 | 450.2 | 0.0 | 0.0 |
| `before-90` | 10 | 2 | 3 | 733.4 | 110.2 | 249.3 | 4 | 10.3 | 363.6 | 0.298 | 5.519 |
| `both-30` | 18 | 2 | 2 | 463.6 | 50.2 | 125.5 | 5 | 10.3 | 277.6 | 0.27 | 5.0 |
| `both-60` | 18 | 2 | 3 | 913.6 | 80.2 | 279.3 | 5 | 10.3 | 543.8 | 0.217 | 4.019 |
| `both-90` | 18 | 2 | 3 | 1363.6 | 110.2 | 429.3 | 5 | 10.3 | 813.8 | 0.2 | 3.704 |
| `both-120` | 18 | 2 | 3 | 1813.6 | 116.8 | 579.3 | 5 | 10.3 | 1107.2 | 0.165 | 3.056 |

### Label-confirmed anchors (oracle upper bound)

| Config | Windows | With a missed ad | Missed ads reached (of 8) | Flagged s | Missed-ad s | Programme s | Programme intervals | Acceptable s | Unlabelled s | Labelled precision | Lift |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `after-sponsor-read-continuation-reach` | 3 | 0 | 0 | 180.2 | 0.0 | 0.0 | 0 | 0.0 | 180.2 | 0.0 | 0.0 |
| `after-90` | 5 | 0 | 0 | 360.2 | 0.0 | 0.0 | 0 | 0.0 | 360.2 | 0.0 | 0.0 |
| `before-90` | 6 | 2 | 3 | 540.0 | 110.2 | 98.1 | 2 | 0.0 | 331.7 | 0.529 | 9.796 |
| `both-30` | 11 | 2 | 2 | 300.2 | 50.2 | 34.3 | 2 | 0.0 | 215.7 | 0.594 | 11.0 |
| `both-60` | 11 | 2 | 3 | 600.2 | 80.2 | 68.1 | 2 | 0.0 | 451.9 | 0.541 | 10.019 |
| `both-90` | 11 | 2 | 3 | 900.2 | 110.2 | 98.1 | 2 | 0.0 | 691.9 | 0.529 | 9.796 |
| `both-120` | 11 | 2 | 3 | 1200.2 | 116.8 | 128.1 | 2 | 0.0 | 955.3 | 0.477 | 8.833 |

### Each `before-90` window, recorded anchors

Seconds of each label kind inside the window.

| case | window | must-cut | must-keep | acceptable-cut | unlabelled |
| --- | --- | --- | --- | --- | --- |
| waveform-two-preroll-sponsor-reads | 2639.8-2729.8 | 0.0 | 90.0 | 0.0 | 0.0 |
| waveform-two-preroll-sponsor-reads | 4072.8-4162.8 | 90.0 | 0.0 | 0.0 | 0.0 |
| waveform-two-preroll-sponsor-reads | 5188.6-5278.6 | 0.0 | 0.0 | 0.0 | 90.0 |
| pchh-preroll-swallowed-the-premise | 1433.2-1523.2 | 0.0 | 81.4 | 8.6 | 0.0 |
| practical-ai-two-host-reads-left-whole | 2606.0-2696.0 | 0.0 | 69.8 | 0.0 | 20.2 |
| techcrunch-preroll-swallowed-the-headline-lead-in | 0.0-6.7 | 0.0 | 0.0 | 1.7 | 5.0 |
| planet-money-palantir-midroll-pod-left-whole | 172.1-262.1 | 0.0 | 0.0 | 0.0 | 90.0 |
| planet-money-palantir-midroll-pod-left-whole | 1604.9-1694.9 | 0.0 | 0.0 | 0.0 | 90.0 |
| techcrunch-alexa-postroll-left-its-opening | 0.0-6.7 | 0.0 | 0.0 | 0.0 | 6.7 |
| techcrunch-alexa-postroll-left-its-opening | 473.4-563.4 | 20.2 | 8.1 | 0.0 | 61.7 |

## Synthetic fixtures

Five fixtures in `test_ad_proximity_eval.py`. The first four run the real `detect_and_cut` with the existing model
doubles and a patched renderer; the fifth scores a stored preparation with no engine run:

1. **Adjacent ad after.** A confirmed `sponsor_read` at 50-60 s with a produced spot at 60-70 s, and
   `FakeLLM(adjacent_program_start_id=7)`. The existing continuation extends the cut to 50-70 s, every programme second
   survives in `keeps`, and the after-windows add 0 missed-ad seconds: the engine already removed the spot.
2. **Adjacent ad before.** The same read with an unannounced spot at 40-50 s. The engine cuts only 50-60 s and keeps the
   spot (it is not told about it and does not guess). `before-90` reaches it: 1 missed ad, 10.0 s flagged.
3. **Ad, programme, ad.** The read at 50-60 s, programme at 60-120 s, a missed spot at 120-130 s. The 60 s of programme is
   wholly kept, so nothing bridges across it. Both after-windows reach the spot (10.0 s), at the cost of 80.0 s of
   programme flagged (60-120 s and 130-150 s).
4. **Nearby genuine programme.** The read with programme on both sides. Every programme second is kept, and every
   flagged second of `before-90`, `after-90` and the continuation reach is programme: all false positives.
5. **Old prepared provenance.** No engine run. A stored older preparation (`adSegments` 60-70 s, an older
   `pipelineFingerprint`, no `report`) is turned into anchors and a cut and scored, with `detect_and_cut`, transcription
   and rendering all patched to fail if called. `after-90` reaches the missed 70-80 s spot without reprocessing anything.

For every engine fixture the test also checks that computing review windows leaves `ad_spans` and `keeps` unchanged
(deep comparison) and that no window overlaps removed audio.

## Limits

1. Six cases, eight missed ads. The corpus cases were tuning inputs for the current detector, so these are in-sample
   numbers with no holdout. Two windows reached a missed ad; that is too few to estimate precision with any confidence.
2. Much flagged time is unlabelled, and unlabelled time counts as neither a hit nor a false positive. Precision on
   labelled time alone, as in the tables, is the optimistic reading; the verdict also gives the share of all flagged time.
3. The `recorded` anchors are one older engine's output. Episodes prepared by other engine versions may sit differently.
4. Proximity says nothing about content. A window next to an ad holds the programme returning just as readily as a
   second spot; in this corpus the windows held more programme than missed ad.

## Decision and follow-ups

No review signal was implemented. The worker, its audit and the app protocol are unchanged.

- The only positive result rests on 2 windows in 2 tuning cases with no holdout, and it flags more than twice as much
  programme as missed ad. That does not meet the bar for shipping even a review hint.
- `review_windows` in the harness is already the pure function a consumer would need: stored cuts in, review windows
  out, never a cut. Nothing needs to be added to the worker to use it later.
- Follow-up for David: whether to build an app-side "review first" hint for the 90 s before each stored cut in old
  prepared episodes. If yes, measure it first on newly labelled episodes that were not used to tune the detector; this
  corpus cannot answer the question with any confidence.
