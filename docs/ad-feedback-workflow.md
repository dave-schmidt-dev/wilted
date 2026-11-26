# Ad feedback: investigation and engine tuning

This is the operational procedure for responding to stored listening feedback.
Use it whenever investigating Ad here, Good cut, or Not an ad reports, or changing
ad detection, transcription, recovery, boundaries, or preservation rules.
The operator owns the inventory, evidence, experiments, and dispositions.

## 1. Preserve and account for every report

At intake, snapshot the current `ad-feedback.json` and record its capture time.
Keep the snapshot and supporting evidence together under the private, ignored
`.logs/ad-feedback-weekly/` directory, or outside the repository. Never commit
the owner inbox or investigation artifacts. Retain the original report.
An investigation must not silently relabel or dismiss the owner's inbox entry.

### Weekly intake runner

Start each scheduled pass with:

```sh
make ad-feedback-weekly
```

The runner reads the app-owned inbox without changing it. It discovers prior
ad-feedback ledgers under `.logs`, then writes one content-addressed directory
per Monday and exact inbox snapshot:
`.logs/ad-feedback-weekly/<Monday>/<snapshot-SHA-256>/`. The directory contains
the byte-for-byte `ad-feedback.json` snapshot, `run.json`, `ledger.json`,
`summary.json`, and `REPORT.md`. Directories are owner-only; files are owner-only.
Git ignores `.logs`.

`REPORT.md` separates reports that are present and unhandled from reports that
are new, previously investigated, previously captured but still pending, or
changed since prior evidence. The ledger carries a prior disposition and its
evidence references forward only when the full feedback identity still matches,
including kind, item, revision, position, review, label, and review time. A
changed identity returns to `needs-verification`; it does not inherit a clean
replay result. Historical reports remain in the ledger even if no longer in the
current inbox.
When an archived ledger shares a directory with its captured `ad-feedback.json`,
the raw snapshot supplies the prior identity. The snapshot digest is recorded in
the new history manifest; this avoids treating older derived ledger fields as
the original report when their representation changed.

The runner does not classify a report, replay a model, edit the manifest, write
the app inbox, queue an app action, or launch Wilted. It will not infer that an
older replay applies to a new feedback ID. Use the exact snapshot for later
draft generation, for example:

```sh
make ad-feedback-drafts FEEDBACK=<weekly-run>/ad-feedback.json OUT=<private-file-outside-the-repo>
```

The draft exporter groups by item ID. Split drafts by revision and verified
source identity before using them as corpus cases. To score saved break objects,
run `phase2_replay_score.py` against the exact fixture and write its report
outside that fixture, under the same private weekly run directory. Preserve the
candidate commit, fixture identity, command, and report digest for any later
handled proof.

Rerunning with the same Monday and inbox bytes reuses the same directory. The
snapshot is immutable; the ledger and report are atomically replaced rather than
appended. If a run stops after saving the snapshot or ledger, the next invocation
resumes that directory before capturing current input. If report installation
succeeded but its directory sync was uncertain, a retry verifies and syncs the
existing bytes. A changed inbox gets a separate SHA-256 directory, so a retry
does not hide new presses or duplicate the prior report.
If a newly recognized historical snapshot changes an automatically generated
disposition, the same run refreshes that derived status while retaining operator
notes and evidence references.

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
with cut audio. The current download path is **not proof of original audio**.
Use the original file's probed duration when available. The last retained or
removed timeline endpoint can exclude trimmed trailing silence and is not proof
of the full source duration. Correct both sides of a comparison together.

Search the current cache, pinned corpus, historical snapshots, and retained
artifacts by embedded source identity, not just filenames. Record the transcript
model and schema as well: a matching audio hash with a different speech model
does not establish the exact transcript consumed by the reported preparation.
For recovered audio, compare its bytes with the original source hash. A new
download may contain different dynamically inserted ads. Never reuse old times
or labels on changed bytes.

**Current limitation:** player presses persist metadata only. Neither the inbox
nor `make ad-feedback-drafts` automatically preserves audio or aligned inputs.
Preservation is an explicit intake operation today. Do not claim otherwise.

## 2. Classify the available evidence

| Evidence | Permitted conclusion |
| --- | --- |
| Exact original aligned transcript, source identity, timeline and known configuration | Labelling again on the retained preparation input; audio-render accuracy still needs audio |
| Exact original audio, but a newly generated transcript | Retranscription experiment; not reproduction of the old labelling input |
| Different downloaded audio | New case with new identity and freshly checked labels; original report remains unresolved |
| Prepared audio or display transcript | Diagnostic listening/content evidence with explicit timeline mapping; cannot reconstruct removed material or prove original-input replay |
| Report metadata alone | Unresolved report with a concrete recovery action; no guessed verdict |

When retrieving an episode, show download progress, set a deadline, and compare
the downloaded file with the original source hash. Use credentials or personal
request data only as authorized. A missing input blocks only the checks that need it.

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
must say so. Mixed or still-uncertain passages remain protected. No confidence
score or agreement count substitutes for source evidence. Independent model
adjudication can accept labels without a human review step. Reference labels must
never directly become runtime cuts.

## 4. Reproduce and diagnose

Use `make ad-feedback-drafts` for draft labels only. Its current exporter groups
by item, so split the input by revision and source identity before using it on
multi-revision reports. Never adopt a draft without identity and timing review.
`make ad-corpus-adopt SOURCE=<snapshot-directory>` pins inputs for cases and
acquired gap inputs already named in the manifest. It does not automatically
turn new feedback into cases or establish their labels.

Record the saved cuts, matched to their labels' input identity. Recorded
scoring (the one mode of `ad_corpus.py`) requires a successful
preparation with the case's source hash and, when supplied, `revisionID`.
An unmatched or malformed timeline is unavailable, never a passing empty cut.
Use `ad_corpus.py --strict --case <case-id>` for a targeted case, then the
full strict corpus for candidate acceptance. A saved labelling reply is
replayed through the reply check and the cut stage's break objects by
`LabelledAcceptanceReplayTests` (Producer package).

Identify the failing stage: transcription, labelling, reply validation, break
placement, final outcome, or audio rendering. Retain relevant
bounded model requests/responses locally when needed to explain a failure.
Never include raw replies in owner journals or public artifacts.
Compare like-for-like configuration, including self-promotion policy. An unknown
historical setting stays unknown. Testing a declared setting is a new experiment.

## 5. Iterate against declared acceptance criteria

Before each trial, record the hypothesis, exact candidate commit (or HEAD plus
working diff), target intervals, model/policy configuration, baseline metrics,
and pass/fail criteria. Change one causal behavior at a time. Keep tests alongside
regression fixes and ensure the existing runner discovers any new test file.

Compare target ad remnants, programme loss, changed cut boundaries, unresolved
reviews, model failures, and unknown/unlabelled cut time. Repeat relevant baseline
and candidate runs when outcomes vary. Improvement must exceed observed variation.
A different refusal reason or one favorable run is not a demonstrated fix.
Frozen retained inputs and labels are the comparison basis, not a fresh download.

Accept only when the targeted improvement is demonstrated, reviewed programme
loss does not increase, confirmed-ad remnants do not worsen, and affected tests
and required gates pass. Evaluate all runnable corpus cases and inspect new cuts
outside reviewed labels. Missing cases prevent a whole-corpus pass claim. Report
the exact tested scope. A small tuning set is not evidence of generalization.
Use held-out confirmed cases and distinguish them from examples used to tune.
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
owner audio require their normal authorization. No experiment grants it.
Existing episodes are not automatically repaired by a newer engine.

End each pass with report counts, accepted/rejected changes, measured scope,
unresolved inputs, and exact next actions. Reconcile any newly arrived feedback
against the intake snapshot so reports cannot disappear between passes.

## 7. Mark a replayed report handled

Only queue a report after its source and revision match the app's preparation
journal, and a clean replay of the current committed candidate passes the exact
labelled interval. `Ad here` needs its reported point inside a passing
`must-cut` span and inside an actual produced cut. `Good cut` needs the stored
cut fully removed. `Not an ad` needs its point and stored cut in passing
`must-keep` evidence, with neither cut. A whole-case pass alone is insufficient.

The tuning proof links each feedback ID to one corpus case and pins both the
intake snapshot and replay report by SHA-256. The replay report must identify
the candidate commit, fixture and command. Its case identity must match the
feedback's item, revision and source hash, and the app library must contain that
same source hash in the exact revision's successful preparation record. Missing
or contradictory evidence leaves the report unhandled.

After acceptance, run:

```sh
make ad-feedback-mark-handled PROOF=<proof.json> SNAPSHOT=<intake.json> REPLAY=<replay.json>
```

The command only reads the inbox and library. It writes a validated, owner-only
request in Wilted's private pending queue, then opens Wilted with a fixed URL
that carries no report ID or file path. Wilted rechecks the current report and
writes handled timestamps plus replay receipts through its own atomic inbox
writer. Stale, dismissed, relabelled or missing reports stay unchanged; a
replayed request is idempotent. The entry remains in the historical inbox and
keeps its label. Ordinary inbox writes keep schema version 1; the first
verified action writes version 2 with its receipt. An older build quarantines
version 2 rather than rewriting it as version 1. On upgrade, Wilted merges that
archive with any new version-1 feedback before its next write, retaining the
receipt and historical entries.

