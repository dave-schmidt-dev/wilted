# Preparation history: bounded maintenance reads and a retention proposal

Task 7. Status: bounded reads implemented (no rows deleted beyond today's
behaviour); retention (pruning) is a proposal for David to decide.

## Terms

- **Journal row**: one `PreparationRecord` (`LocalLibrarySchemaV3Models`). Its `id` is
  `podcast-prepare|<item>|generation-<S>-<A>|<event>` for an attempt-bound run, or
  `podcast-prepare|<item>|<event>` for a legacy unbound run. `record(preparation:)`
  refuses a bound row whose id does not carry its generation prefix.
- **Generation**: every journal row of one `PreparationAttemptIdentity` (request sequence
  `S`, attempt count `A`). Events are `<stage>#<ordinal>`, `<stage>#heartbeat`, `terminal`
  and `interrupted`. Only `terminal` and `interrupted` rows are terminal statuses.
- **Ready-proving generation**: the newest generation whose last terminal status is
  `succeeded` with `revisionID` equal to the item's current Ready revision, when that
  revision has a `.current` preparation outcome. It is the only generation allowed to
  describe the Ready revision's source (`sourceRevisionID`, `sourceHash`, `fingerprint`).
- **Newest generation**: the highest `(S, A)` with journal rows. The work ticket names the
  newest acknowledged generation; journal generations never exceed it, because
  `record(preparation:)` only accepts rows for the ticket's running generation.

## Where maintenance reads history today

| Read | Caller | Shape |
|---|---|---|
| `invalidateStalePodcastPreparations` (`LocalLibraryStore+PreparationJournal.swift`) | Mac bootstrap (`WiltedMacModel.swift`, `invalidateStalePreparations`) | Fetches **every** `PreparationRecord` row (full table, blobs included) only to collect request ids and find markers. Then one newest-first read of 256 rows per `podcast-prepare|` request id, spanning all generations of that item, decoding every row. |
| `requiresForcedRedownload(for:)` | Every podcast transfer (`PodcastDownloadCoordinator`) | Full-table fetch to test one exact request id. |
| `markForcedRedownloadCompleted(for:currentFingerprint:)` | After a forced download (`WiltedMacModel+Downloads.swift`) | Full-table fetch to find one item's markers. |

Out of scope for this lane, recorded as follow-ups:

- `preparationRuns(limit:)` / `allPreparationRunSummaries` decode every journal row in the
  library, then cap at 200 runs. The bootstrap closer `closeInterruptedPreparationRuns`
  (Mac target) depends on it, so a non-terminal run older than the newest 200 runs is
  never closed. Prep's display and the Larder snapshot use the same read.
- `latestPreparationTimeline(for:revisionID:)` scans the newest 64 rows of the item. A
  Ready-proving success buried under more than 64 newer failure rows loses its timeline
  (cut markers disappear from the player). The anchored lookup below would fix it.
- `invalidateStalePodcastPreparations` also scans `outcomes` once per selected generation
  (`outcomes.first`), which is O(items x outcomes). Library-sized, not history-sized.

## Why it is unbounded

1. `PreparationRecord` has no index on `requestID`, `itemID` or `emittedAt`; only the
   unique `id`. Nothing points at the Ready-proving generation directly.
2. The first full-table fetch materialises every retained row, so bootstrap cost grows
   with total history, not with the library.
3. The per-request 256-row window spans all generations of an item. Retained failures
   after a success push the Ready-proving generation out of the window. Selection then
   finds no candidate, and pass 2 forces a **redownload** of an intact source when a rule
   condemns the outcome (the conservative fallback).
4. The window can also cut a generation in half. Its oldest row, `pipeline.start#1`,
   carries the provenance evidence, so a long generation can lose its own provenance.

## Bounded design (implemented)

Enumerate items from library-sized data, then read each item's history in bounded,
generation-exact slices.

1. **Items**: podcast-preparation ticket subjects, download records, preparation
   outcomes and invalidation markers (one fetch each). Markers are read by request-id
   prefix, not by scanning the journal.
2. **Discovery window**: per item, the newest 64 rows of `podcast-prepare|<item>`, sorted
   by `emittedAt` then `id` (descending) so ties are deterministic. Generation keys are
   parsed from row ids, so discovery needs no JSON decoding to name generations.
3. **Newest generation**: the higher of the ticket's generation (when it has rows) and
   the highest key in the window. Read it **completely** by its exact id prefix
   (`podcast-prepare|<item>|generation-S-A|`), the same exact read progress publication
   uses, keeping only rows whose decoded attempt matches the prefix.
4. **Ready-proving generation** (only when the Ready revision has a `.current` outcome):
   the newest window generation whose last terminal status proves the Ready revision.
   If none is in the window, an **anchored lookup** reads up to 32 rows of the item with
   `emittedAt >= outcome.producedAt`, ascending. The pipeline saves the outcome before it
   journals the terminal (and backfilled outcomes use the terminal's own `emittedAt`), so
   the proving terminal sits at or just after `producedAt`. The terminal's `revisionID`
   is verified exactly; a clock jump that defeats the anchor falls back to today's
   conservative redownload, never to a wrong reset. The found generation is then read
   completely by prefix.
5. **Legacy rows** (no generation) are read as one group only when the window or the
   anchored lookup names a legacy row.
6. Selection (`newerGeneration`, the Ready-proof filter) and every rule decision are
   unchanged; only the candidate set is now complete instead of windowed.
7. `requiresForcedRedownload` becomes a one-row exact read;
   `markForcedRedownloadCompleted` reads only the item's marker rows.

**Bound**: per item, rows read are at most window (64) + newest generation + anchored
batch (32) + Ready-proving generation; markers are read once per pass for the library. A generation's size is set by one
pipeline run's events, so the bound does not grow with the number of retained
generations. Each complete-generation read is capped at 4,096 rows so a corrupt or
externally written prefix cannot materialise without bound; the newest-generation search
reads at most two generations (the ticket's and the highest window key) before it stops.
`preparationMaintenanceRowsRead` counts every row the pass reads; tests
assert it is identical at history depth D and 2D.

**Storage caveat (decision for David, no change made)**: these are bounded in rows
materialised and decoded. Without an index on `requestID`, SQLite still evaluates each
per-item predicate by scanning the table, which is the same per-request cost today's
loop already pays. Making the storage cost item-bounded needs an index on
`PreparationRecord.requestID` (or `itemID`), which is a schema version. Not added here.

**Behaviour changes to note**

- A condemned generation is now deleted whole (exact prefix read, up to its full size).
  Before, rows of that generation that fell outside the 256-row window were left behind
  as orphans. This is existing invalidation behaviour applied to the complete
  generation, not new pruning.
- Journal rows for an item with no ticket, download, outcome or marker are no longer
  visited. Today such an item (a legacy run that failed before any download) could
  receive a forced-redownload marker for an episode with nothing downloaded.

## Retention proposal (David decides; not implemented)

Pruning would run at bootstrap, after `invalidateStalePodcastPreparations`, per item,
using the same bounded reads.

**Always keep**

1. The complete Ready-proving generation (source provenance, timeline, outcome proof).
2. The complete newest generation and the ticket's generation.
3. Any non-terminal generation until it is closed (`interrupted` or `terminal`).
4. Invalidation markers (`podcast-invalidation|`, `podcast-reset-preparation|`).
5. Legacy unbound rows for an item whose Ready revision has no bound proof.

**Prune candidates**

- Terminal generations older than both the Ready-proving and the newest generation,
  keeping the newest **N** failed generations so Prep still shows recent failures.
- Heartbeat rows (`#heartbeat`) of any terminal generation other than the two kept.

**Decisions needed**

1. Whether to prune at all, and the value of N (suggest 3).
2. Whether Prep history may lose runs older than N failures per item.
3. Whether an age cap (for example 90 days) should also apply to failed generations.
4. Whether to add the `requestID` index (schema version) so storage cost is bounded too.
