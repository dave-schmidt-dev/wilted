# Ad feedback: investigation and engine tuning

This is the operational procedure for responding to stored listening feedback.
Use it whenever investigating Ad here, Good cut, or Not an ad reports, or changing
ad detection, transcription, recovery, boundaries, or preservation rules.
The operator owns the inventory, evidence, experiments, and dispositions.

## 1. Preserve and account for every report

At intake, snapshot the current `ad-feedback.json` and record its capture time.
Keep this snapshot and all episode-specific evidence in private local storage,
never in tracked files or external review packets. Retain the original report;
an investigation must not silently relabel or dismiss the owner's inbox entry.

Create one ledger row per feedback ID, including dismissed, duplicate, unmapped,
and contradictory reports. Record item ID, revision ID, engine version, pipeline
fingerprint, reported kind, mapped original position, nearest cut, source
identity, evidence paths, investigation status, findings, and next action.
Duplicates may share an investigation but retain their individual IDs.
Group only matching item, revision, and verified original source identity.
Never combine different preparations merely because their item IDs match.

Pin available original audio, the exact aligned transcript used by preparation,
the preparation timeline, provenance, and relevant policy/model settings before
running experiments. Copy; do not move, replace, or re-prepare owner media.
Identify source audio by its journal `sourceHash`, and prepared audio by the
revision's content hash. A successful preparation can replace downloaded bytes
with cut audio; the current download path is **not proof of original audio**.
Use the original file's probed duration when available. The last retained or
removed timeline endpoint can exclude trimmed trailing silence and is not proof
of the full source duration. Correct both sides of a comparison together.

Search the current cache, pinned corpus, historical snapshots, and retained
artifacts by embedded source identity, not just filenames. Record the transcript
model and schema as well: a matching audio hash with a different speech model
does not establish the exact transcript consumed by the reported preparation.
For recovered audio, compare its bytes with the original source hash. A new
download may contain different dynamically inserted ads; never reuse old times
or labels on changed bytes.

**Current limitation:** player presses persist metadata only. Neither the inbox
nor `make ad-feedback-drafts` automatically preserves audio or aligned inputs.
Preservation is an explicit intake operation today. Do not claim otherwise.

## 2. Classify the available evidence

| Evidence | Permitted conclusion |
| --- | --- |
| Exact original aligned transcript, source identity, timeline and known configuration | Detector replay on the retained preparation input; audio-render accuracy still needs audio |
| Exact original audio, but a newly generated transcript | Retranscription experiment; not reproduction of the old detector input |
| Different downloaded audio | New case with new identity and freshly checked labels; original report remains unresolved |
| Prepared audio or display transcript | Diagnostic listening/content evidence with explicit timeline mapping; cannot reconstruct removed material or prove original-input replay |
| Report metadata alone | Unresolved report with a concrete recovery action; no guessed verdict |

Try bounded source recovery before declaring an input unavailable. Public
enclosure retrieval must retain progress, a deadline, and source-hash comparison.
Private feed credentials and personal request data retain their authorization
boundaries. A missing input blocks only its dependent proof, not other cases.

## 3. Verify what the report means

Prioritize possible programme loss, then missed ads, while keeping all reports
accounted for. Inspect the surrounding passage, not only the marked instant.
Map prepared positions through the report's exact revision timeline.

`Ad here` is a location clue. The exporter's +/-15-second interval is a search
window, not a verified ad boundary. `Good cut` and `Not an ad` reference a stored
cut, but a press alone does not establish the content of everything removed.
Conflicting feedback is investigated and documented, not silently resolved in
favor of the label that makes a candidate pass.

Verify every proposed programme flank through the next call to action or clear
return to the show: an apparent discussion after one sponsor may introduce the
next sponsor. Independently recheck any label that implies programme loss before
diagnosing the engine. Preserve superseded labels and invalidate their scores.

Define source-time `must-cut` and adjacent `must-keep` intervals, with the model
and evidence that verified each, source identity, and boundary uncertainty.
Manual gold review and human confirmation are not required. Use a fresh full-
transcript labeling pass, then a separate blind pass before either reviewer sees
the other's labels; adjudicate differences against the source. Keep the two
self-promotion policies explicit. Spoken programme introductions, credits and
participation instructions are not ads merely because they contain a show name
or call to action.

When original audio is available, re-transcribe missing speech and uncertain
boundary windows locally and have the model adjudicate that source-bound
supplement. Preserve the original labels, exact clip offsets, audio/transcript
hashes and model provenance. Re-transcription is evidence, not a claim that a
model listened directly or verified every acoustic boundary. Text-only judgments
must say so. Mixed or still-uncertain passages remain protected; no confidence
score or agreement count substitutes for source evidence. Independent model
adjudication can accept labels without a human review step. Never promote a
reference label directly into a runtime cut or active feed profile.

## 4. Reproduce and diagnose

Use `make ad-feedback-drafts` for draft labels only. Its current exporter groups
by item, so split the input by revision and source identity before using it on
multi-revision reports; never adopt a draft without identity and timing review.
`make ad-corpus-adopt SOURCE=<snapshot-directory>` pins inputs for cases and
acquired gap inputs already named in the manifest; it does not automatically
turn new feedback into cases or establish their labels.

Record both the saved cuts and a current-source replay, each matched to its
labels' input identity. Recorded scoring requires a successful
preparation with the case's source hash and, when supplied, `revisionID`;
an unmatched or malformed timeline is unavailable, never a passing empty cut.
Replay uses the shipping `analyze_ad_detections` path, including the final outcome decision;
a classifier-only result is a diagnostic, not what the app would cut.
Use `ad_corpus.py --mode replay --strict --case <case-id>` for a targeted case,
then the full strict corpus for candidate acceptance. Run with the project's
runtime interpreter and existing GPU admission lock, deadline, and progress.

Identify the failing stage: transcription, nomination/classification, recovery,
boundary review, preservation, final outcome, or audio rendering. Retain relevant
bounded model requests/responses locally when needed to explain a failure;
never include raw replies in owner journals or public artifacts.
Compare like-for-like configuration, including self-promotion policy. An unknown
historical setting stays unknown; testing a declared setting is a new experiment.

## 5. Iterate against declared acceptance criteria

Before each trial, record the hypothesis, exact candidate commit (or HEAD plus
working diff), target intervals, model/policy configuration, baseline metrics,
and pass/fail criteria. Change one causal behavior at a time. Keep tests alongside
regression fixes and ensure the existing runner discovers any new test file.

Compare target ad remnants, programme loss, changed cut boundaries, unresolved
reviews, model failures, and unknown/unlabelled cut time. Repeat relevant baseline
and candidate runs when outcomes vary; improvement must exceed observed variation.
A different refusal reason or one favorable run is not a demonstrated fix.
Frozen retained inputs and labels are the comparison basis, not a fresh download.

Accept only when the targeted improvement is demonstrated, reviewed programme
loss does not increase, confirmed-ad remnants do not worsen, and affected tests
and required gates pass. Evaluate all runnable corpus cases and inspect new cuts
outside reviewed labels. Missing cases prevent a whole-corpus pass claim; report
the exact tested scope. A small tuning set is not evidence of generalization;
use held-out confirmed cases and distinguish them from examples used to tune.
Unknown new cuts cannot be treated as harmless merely because the scorer has no
label there. Never loosen a safety threshold to make a candidate pass.

Retain rejected trials, reasons, and evidence. If two trials leave the same
uncertainty, change the diagnostic method instead of continuing prompt tweaks.
Stop a particular experiment when it lacks evidence, regresses, or reaches its
deadline; continue independent reports. Do not force a product change just to
claim progress. Record the unresolved cause and concrete next experiment.

## 6. Close the loop without overstating completion

Each ledger row has an evidence status (`exact-input`, `retranscribed-original`,
`changed-source`, `prepared-only`, or `metadata-only`) and a separate disposition:
`needs-verification`, `reproduced`, `trial-rejected`, `source-verified`,
`unresolved`, `dismissed`, or `duplicate-of`. Every nonterminal row names its next
action and missing evidence. A duplicate links to the controlling report.
An unavailable original is unresolved, not fixed or dismissed.

Commit accepted source changes and update CHANGELOG/HISTORY/TASKS under the normal
repository gates. Track installation and owner-listening acceptance separately
from source verification. Publication, installation, and replacement of prepared
owner audio require their normal authorization; no experiment grants it.
Existing episodes are not automatically repaired by a newer engine.

End each pass with report counts, accepted/rejected changes, measured scope,
unresolved inputs, and exact next actions. Reconcile any newly arrived feedback
against the intake snapshot so reports cannot disappear between passes.
