# Ad removal: full review and supported reliability boundaries

**Review date:** 7 September 2026.
**Review baseline:** `1112f05`, plus the imported detector in `wilted-old/src/wilted/ads.py`, which is read and wrapped rather than reimplemented.
**Remediation accepted at:** `6ae4e1f` (audited detector adapter), `8250887` (timing, render and outcome enforcement), `ee8d5a9` (strict shared-path evaluation). Measurements below were taken at `565b03f`, which differs from `ee8d5a9` only in the manifest's top-level provenance prose; no detector, worker or scoring code changed between them.

This report exists because the honest answer to "how reliable is ad removal" was not written down anywhere. It states what the review found, what was corrected and with which test, what remains an open gap, and — most importantly — what the evidence supports. It does not claim general reliability, and nothing here should be read as owner acceptance.

## What this evidence supports, and what it does not

Two episodes carry hand-labelled truth. Both were tuning inputs: the failures they encode are the failures the fixes were written against. A candidate that passes them has not been shown to generalise, and eleven reviewed incidents have no case at all because their inputs or labels no longer exist. The supported claim is narrow:

- The worker can no longer report a successful ad-removal outcome without auditable evidence that the detector actually ran and resolved every segment it was given.
- A destructive cut is refused unless its timing is audio-aligned, and the rendered file is measured against the map that produced it before it is published.
- On the two labelled episodes, at `565b03f`, the live detector removes every labelled advertisement and touches no labelled programme.

Not supported: any statement about an unlabelled episode, any statement about a show not in the corpus, and any statement that the current library is correct. As of `565b03f` the saved library still scores **0 of 2** — the point of keeping the two scoring modes separate.

## Current measurements at `565b03f`

| Mode | Command | Result |
|---|---|---|
| Recorded (lenient) — what is saved on this machine | `make ad-corpus` | 0/2. Waveform leaves 56.6s and 40.0s of two labelled advertisements and 1.2s at a third; Pop Culture Happy Hour has lost 20.3s of programme, which also breaches the 5.0s episode budget. One case scored only in part. |
| Replay (strict) — what the installed detector does now | `make ad-corpus-replay` | 2/2, 0 skipped, 1 scored only in part. Every labelled advertisement removed with 0.0s left, every `must-keep` interval untouched. |

The recorded mode measures files written by an older detector; the replay measures the current one over the exact aligned segments the original runs consumed. Neither replaces listening, and the bad Waveform and Pop Culture Happy Hour files are still on disk.

The partial verdict in both modes is not a defect being hidden. Pop Culture Happy Hour's labels reach the whole episode, and the current closing cut runs 2.2s past the last labelled boundary, so that much of what the detector did is unmeasured and the case says so rather than passing silently.

## Runtime findings

Each row is the review's finding, the correction that landed, and the test that holds it — or an explicit statement that it is still open.

| Sev | Finding at `1112f05` | Status |
|---|---|---|
| High | Ad detection was skipped when timed segments were absent, and the run still returned `ok: true`; the Swift side committed unchanged audio and summarised it as no advertisements found. | **Fixed** at `8250887`. The v2 outcome vocabulary is exactly `disabled`, `noAds`, `cut`; anything else is a typed failure. Removal without audio-aligned timing raises `aligned-stt-required`, and `noLocalSTT` with removal requested is refused before any model work. Tests: `test_v2_removal_rejects_no_local_stt_before_any_model_work`, `test_a_misaligned_transcript_never_reaches_the_ad_detector`, `test_v2_no_ads_uses_the_required_aligned_pass_and_emits_a_report`; Swift `rejectsAV2PayloadWhoseOutcomeContradictsItsTimeline`. |
| High | The archived classifier retries malformed answers, splits batches, and treats an exhausted singleton as content; the counting backend recorded thrown errors but not invalid answers. | **Fixed** at `6ae4e1f`. The adapter audits the real request and parser contract, requires resolved coverage of every cue, and raises `ads-classification-unresolved` or `ads-classification-incomplete` rather than returning a clean empty result. Tests: `test_exhausted_singleton_is_unresolved_not_a_clean_no_ads_result`, `test_corrected_and_split_classification_has_resolved_coverage`, `test_an_independently_failed_window_remains_unresolved`, `test_one_answered_singleton_does_not_turn_a_dead_backend_into_zero_ads`. |
| High | The published-transcript timing guard compared only audio duration minus transcript end, so an arbitrarily longer transcript and a failed probe both passed; duration equality cannot prove identity of dynamically inserted advertising anyway. | **Fixed** at `8250887`. Destructive cuts require the aligned Parakeet pass; `validate_aligned_segments` fails closed on non-finite, unordered or out-of-range timing, allowing only a declared 3.0s tail. Published transcripts remain usable for transcript-only preparation, which is what the 45s/0.5% comparison now governs. Tests: `test_aligned_timing_allows_only_the_declared_short_tail`, `test_aligned_timing_rejects_segments_that_are_not_in_time_order`. |
| High | A refused guard or an empty cut could return unchanged audio while still reporting proposed spans, and zero removed seconds became "no advertisements found". | **Fixed** at `8250887`. Typed failures (`cut-unsafe`, `cut-output-empty`, `cut-output-alias`, `cut-render-failed`, `cut-render-timeout`, `cut-duration-mismatch`, `output-duration-invalid`) end the run and preserve the prior revision. Swift refuses an audit-free removal outcome: `rejectsAnAdRemovalOutcomeThatCannotBeAudited`. |
| Med | Classification uses overlapping ten-minute windows then disjoint batches; an overlap tie became content, discarding the disagreement. | **Fixed** at `6ae4e1f` as far as observation allows. Disagreement, truncated context and positively classified sparse runs are retained as audit candidates at the backend seam. The adapter does not claim to know the archive's internal filter state: `test_observed_diagnostics_do_not_claim_archive_filter_state`. |
| Med | Bracket recovery in the archive permits 128 cues or ten minutes, enough to swallow a short news programme. | **Partly fixed; the archive is unchanged.** The worker rejects a span covering more than half the episode, or a set covering more than 60%, and gives an oversized span one bounded resize review before dropping it. Tests: `test_a_span_covering_most_of_the_episode_is_dropped_and_said_out_loud`, `test_spans_that_are_individually_plausible_can_still_be_refused_together`, `test_an_oversized_span_is_shortened_to_where_the_program_resumes`. **Open:** the archive still proposes the whole-programme pod; only the repair is ours. Tracked in `TASKS.md` as "The detector brackets a short episode's whole programme as one ad pod". |
| Med | Reported ad spans and removed totals were raw detector nominations, while the physical keep map adds a half-second buffer, so the two disagreed. | **Fixed** at `8250887`. `adSegments` and `removedSeconds` are derived from `effective_removed_intervals`, the exact complement of the rendered keep map; the nominations move to `report.rawNominations`, where they are review material rather than a claim about the delivered audio. Short interstitials survive: `test_cut_map_preserves_a_short_interstitial_between_two_advertisements`, `test_cut_map_unions_overlapping_nominations_without_padding_them`. |
| Med | Nonempty ffmpeg output was accepted without checking its duration against the theoretical map, and the archive stream-copies compressed packets. | **Fixed** at `8250887`. The cut re-encodes accurately, then probes the result and requires agreement with the declared keep map within `RENDER_DURATION_TOLERANCE_S = 0.35`, for both MP3 and AAC. Tests: `test_accurate_render_matches_the_declared_keep_map_for_mp3_and_aac`, `test_a_wedged_render_reports_progress_and_then_fails_on_its_bound`, `test_a_failing_render_reports_the_encoder_stderr`. |
| Med | Confidence is a window-vote ratio in the archive, but the recovery passes hardcode 1.0; all 22 recorded spans reported 1.0, including spans known to be wrong in both directions. | **Open, and characterised rather than fixed.** `test_the_detector_reports_the_same_confidence_for_every_span_it_finds` freezes the behaviour so a future change to it is loud. Nothing branches on the number, which is the only reason it has not caused a visible fault. Tracked in `TASKS.md` as "The detector reports 1.0 for every span, so confidence decides nothing". |
| Med | The recovery sequence was written twice — once in the worker, once in `ad_corpus.replay_spans` — and the replay omitted the live path's remaining-anchor audit. | **Fixed** at `ee8d5a9`. Both call one entry, `analyze_ad_detections`, and the ordering of the recovery passes is asserted rather than assumed. Tests: `test_a_replay_and_a_preparation_make_the_same_analysis_call`, `test_the_recovery_passes_run_in_the_order_the_worker_defines`, `test_post_cut_audit_fails_if_a_proposed_explicit_anchor_is_dropped`. A replay is also proved never to transcribe again: `test_a_replay_never_transcribes_anything_a_second_time`. |

## The four no-GPU reproductions

The review confirmed its findings with a throwaway diagnostic that no longer exists for any reader. Each reproduction is now a regression test in the repository, which is where the evidence should live.

| Reproduction | Now covered by |
|---|---|
| A 200-second published cue accepted against a stubbed 100-second file | `test_aligned_timing_allows_only_the_declared_short_tail`, `test_cut_map_clamps_the_declared_tail_and_refuses_anything_past_it` |
| Ad removal with no timed input returning success | `test_a_misaligned_transcript_never_reaches_the_ad_detector`, `test_v2_removal_rejects_no_local_stt_before_any_model_work` |
| Ten malformed classification responses yielding zero detections and zero counted failures | `test_exhausted_singleton_is_unresolved_not_a_clean_no_ads_result`, `test_an_independently_failed_window_remains_unresolved` |
| Overlapping cuts totalling ten unique seconds scored as 160% of a ten-second advertisement | `test_overlapping_cuts_score_exactly_as_their_union_does`, `test_duplicate_cuts_cannot_report_more_of_a_spot_than_there_is`, `test_duplicate_cuts_cannot_hide_programme_loss_either` |

## What each reported failure teaches

Fourteen incidents were reviewed. Three are covered by the two labelled corpus cases; the other eleven are recorded in the manifest's `gaps` array with what is missing and what would close each. Two of those eleven are fixed runtime invariants rather than open failures -- they are recorded there because they cannot be expressed as labels on audio, and a regression in either would otherwise be silent.

| Incident | Mechanism | Where it now lives |
|---|---|---|
| TWiT 1098 returned zero advertisements almost immediately | Backend constructed but never loaded; every failure converted to content | Gap `twit-1098-unloaded-backend`. Explicit load, lock and counted exceptions are installed; the original STT cache is gone, so the episode cannot be replayed. |
| Concurrent preparations failed around model load | Speech and GGUF residency contention | Gap `concurrent-preparation-gpu-contention`. Shared GPU lock, residency drain and bounded progress are installed; retryable re-enqueue and shared speech admission remain open tasks. |
| Giant Bombcast 955 cuts drifted | The publisher's transcript described a shorter rendering of the episode | Gap `giant-bombcast-955-drifted-cuts`. Aligned timing is now mandatory for cuts; the historical cache is gone. |
| Video Game Town host read survived | The coarse pass called it conversation, and the spoken address carried no recognisable spelling | Gap `video-game-town-unanchored-host-read`. Anchor-plus-call-to-action and dense sponsor recurrence are installed and covered by synthetic cues only. |
| A Daily produced spot was discarded | The sparse-run promotional-evidence gate rejected legal and brand copy | Gap `daily-chase-sapphire-sparse-spot`. Legal disclaimers were added to the evidence set; the retained input still needs bounded programme labels. |
| A Daily sister-show pitch split at a cue boundary | The call to action completed outside the sparse run | Gap `daily-sister-show-pitch-split-cue`, classified as policy: naming another show is not by itself paid advertising, and no verified general fix exists. |
| Waveform's two opening produced spots survived | Produced opening spots escape ordinary nomination | Covered by case `waveform-two-preroll-sponsor-reads` (the first two `must-cut` spans). Dedicated preroll nomination with programme confirmation; the replay removes both. |
| Waveform's Granola read survived | The aligned transcript omitted the leading word of an explicit sponsor phrase | Covered by the same case. Omission-compatible nomination with destination and resumption checks; the replay removes it whole. |
| Pop Culture Happy Hour's premise was removed | The opening confirmation took a formal introduction for the start of the programme | Covered by case `pchh-preroll-swallowed-the-premise`. Programme-aware nomination and confirmation; the replay leaves the premise intact. The saved bad file still needs replacing. |
| A short TechCrunch episode was overcut | Two host reads bracketed nearly the whole news programme | Gap `techcrunch-short-episode-overcut`. Proportional rejection and bounded resize are installed; the original fixture is unavailable and another episode of the same show is not that case. |
| A cue held both advertising and programme; a postroll was removed only in part | Coarse cue boundaries straddle the boundary | Gap `mixed-cue-and-partial-postroll`. A dedicated boundary-segment question is installed; no retained input exhibiting it has been identified. |
| Two speech engines did duplicate work | Detection and the displayed transcript transcribed independently | **Fixed.** One `parakeet-tdt-1.1b` pass supplies both, and the replay path is tested never to transcribe again. Recorded as gap `duplicate-transcription-passes` because it is an invariant about how many passes run, not about which seconds are advertising, so no label could catch a regression. |
| Ready labels overstated the work done | A transcript or a downloaded file was taken for completed preparation | **Fixed.** A successful terminal journal must match the current ready revision, and the outcome contract now requires the detector's audit before `noAds` or `cut` is accepted. Recorded as gap `ready-labels-overstated-work` for the same reason as the row above: the defect is in what the app claims, not in which seconds were cut. |
| Installation interrupted a preparation | The app was replaced while the worker was running | Gap `install-interrupted-preparation`. Bootstrap closes interrupted runs as failed; the installer's in-flight guard is an open task. |

## The evaluator

The review's finding was that the corpus could not establish quality even if the detector were perfect, because the measurement was wrong in four ways: predicted spans were summed rather than unioned, a `must-cut` interval passed at 75% removal, every `must-keep` interval had its own allowance with no episode budget, and predictions in unlabelled time received no verdict at all. All four are corrected at `ee8d5a9`.

| Constant | Value | Why |
|---|---|---|
| `KEEP_TOLERANCE_SECONDS` | 1.0 | Both a cut boundary and a label land on cue edges; a second of slack forgives rounding, not a lost sentence. |
| `CUT_REMNANT_TOLERANCE_SECONDS` | 2.0 | An advertisement is judged by the seconds left of it, not by a fraction: 75% of a sixty-second read leaves fifteen seconds playing, which is the failure being measured. Two seconds is one at each edge. |
| `KEEP_LOSS_BUDGET_SECONDS` | 5.0 | Per-span tolerance forgives rounding once; twenty spans each losing nine tenths of a second is a sentence gone from every break, and every one of them passes. This bounds the episode total. |
| `UNKNOWN_CUT_TOLERANCE_SECONDS` | 1.0 | Cut time in no labelled region is neither right nor wrong. Past this, the verdict is reported as partial. |

Two of those numbers are judgement, and the report says so rather than letting them read as measurements:

1. `CUT_REMNANT_TOLERANCE_SECONDS` was widened from 1.0 to 2.0 **after** the saved Waveform closing break failed on a 1.2s leading remnant that is a cue edge rather than audible advertising. The per-edge rationale stands on its own, but the number was chosen with that run in view.
2. `KEEP_LOSS_BUDGET_SECONDS` is chosen, not derived from any reported failure. The smallest loss anyone has reported noticing is a twenty-second premise; five seconds is set well below that and above rounding.

Beyond the constants, the scorer now unions produced cuts before scoring, refuses a malformed interval by name instead of absorbing it, clamps labels to the probed audio so a transcript that outruns the file cannot be counted as advertising left playing, and reports unknown cut seconds and labelled coverage on every case.

The two modes differ deliberately. `make ad-corpus` is lenient: it reads mutable library state, and a machine that has prepared neither episode should still be able to run it and read the report. `make ad-corpus-replay` is strict: a case whose cached transcript is missing fails the run rather than skipping, because a candidate fix judged on a subset of the corpus is how a fix gets called good.

Frozen historical failures remain characterisation tests of the scorer. They are not a claim that the runtime must reproduce a bug.

Corpus expansion is limited by retention, not by effort. Where an input or its labels are gone, the manifest records a specific gap rather than inventing a case, and no detector prediction is treated as ground truth merely because it was saved. Every case carries `provenance` naming when it was labelled, against which cached input and speech model, and that the labels were timed in the session that added the corpus with no independent listening acceptance recorded.

## Bounded adaptation

The adaptive path is not merely disabled by default — it is unreachable in the shipped app, on both sides:

- `analyze_ad_detections` takes `experimental_candidates=()` and `experimental_max_additional_model_calls=0`, and no caller in this repository passes either. The budget is enforced before a call is spent, not after.
- The Swift side refuses any worker response whose audit reports `experimentalRequests != 0`, alongside requiring resolved coverage and no incomplete-analysis error (`PodcastPreparationPipeline.swift:715`).

Tests: `test_adaptation_is_disabled_by_default_and_budgeted_when_explicit`, `test_incomplete_adaptation_returns_no_speculative_cut`, `test_adaptation_over_budget_returns_no_speculative_cut`.

Activation is therefore a future decision, and these are the criteria it should have to meet. **They are proposed gate thresholds, not measured results**, and the first of them cannot be satisfied today because no held-out labelled case exists:

1. **Held-out labels.** Acceptance is measured on cases that were not used to tune any pass. The corpus currently holds two tuning episodes and zero held-out ones, so activation is impossible now regardless of the other criteria.
2. **No advertisement left behind.** No labelled `must-cut` interval may finish with more than `CUT_REMNANT_TOLERANCE_SECONDS` remaining.
3. **Programme loss bounded twice.** No `must-keep` interval may lose more than `KEEP_TOLERANCE_SECONDS`, and no episode more than `KEEP_LOSS_BUDGET_SECONDS` in total.
4. **Nothing accepted in unmeasured time.** Unknown cut seconds may not increase against the same case with adaptation off.
5. **Calls bounded and stated.** A per-episode maximum of additional model calls is declared in the request and enforced before spending; an exhausted budget yields no speculative cut rather than an unverified one. Proposed ceiling: no more than 20% of the same run's own `modelRequests`, and never more than 8 additional calls on one episode.
6. **Latency stated against baseline.** A wall-clock ceiling expressed as a multiple of the same episode's detection time with adaptation off, measured on the machine that will run it. Proposed ceiling: 1.25x. Stated as a ratio because no absolute latency has been measured here and none should be quoted as though it had.

Unresolved mandatory experimental answers stay unresolved; they never become a cut.

## Acoustic and audio-similarity evidence

The requirement for this delivery is zero added models, zero added dependencies and zero additional speech-to-text passes. Only one of the three candidates satisfies that today.

**Recommended: FFmpeg-only boundary corroboration.** FFmpeg's filter documentation defines `silencedetect`, which reports silence intervals against a noise threshold (default −60 dB) and a minimum duration (default 2s), and `astats`, which reports peak, RMS and dynamic-range statistics; `ebur128` reports loudness on the same page ([FFmpeg filters](https://ffmpeg.org/ffmpeg-filters.html#silencedetect), fetched 2026-09-07). FFmpeg is already a hard requirement of the worker, so this adds no model, no dependency and no transcription pass. Its limit is decisive: silence, a music bed and a voice change are all ordinary programme structure, so these signals can corroborate a boundary the transcript already nominated but cannot identify advertising by themselves. This is an inference from the documented scope of the filters, not a measured Wilted accuracy result. It should be evaluated as **nominate and corroborate, never cut**: accepted only if, on the strict corpus, unknown cut seconds fall or hold, no `must-cut` remnant increases, and episode keep-loss does not rise at all.

**Deferred: speaker diarization.** Pyannote's diarization pipeline composes a pretrained segmentation model, a pretrained embedding model and a clustering stage ([pyannote-audio speaker_diarization.py](https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/pipelines/speaker_diarization.py), fetched 2026-09-07). That is two additional models and a new runtime beyond the existing speech path, so it fails this delivery's constraint outright. It also answers the wrong question: it separates speakers, not commercial intent, and a host reads both the programme and the sponsor message. Optional corroboration at most, and never automatic cut authority.

**Deferred: repeated-ad fingerprinting.** Chromaprint is designed to identify near-identical audio and trades precision for search performance; its `fpcalc` tool needs FFmpeg's libraries, and building it against FFTW3 makes the resulting binary GPL ([Chromaprint](https://github.com/acoustid/chromaprint), fetched 2026-09-07). It adds a dependency and a licence question, and it cannot recognise a new host read or judge commercial meaning. A local, source-hash-bound seed index remains plausible future work, and would need explicit false-match tests and human-confirmed seeds before any span it proposes could be cut.

## Evidence discipline

Planning, historical replay, installation, a live media replacement and owner listening are five different kinds of evidence and none substitutes for another. This report is repository evidence: tests, a strict replay over cached input, and a recorded score of files already on this machine. It is not owner acceptance, and it is not a claim that any episode outside the corpus is cut correctly.
