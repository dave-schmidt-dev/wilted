# Queue drawdown: read-path measurements

Date: 2026-09-18. Task 3.2 of `queue-drawdown-2026-09-17-tasks.md`.

Recorded so a structural change to the read paths has a number behind it. Nothing
here is a ceiling the app enforces; the assertions in the measuring tests are loose
order-of-magnitude guards, not the measurement.

## How to reproduce

```
WILTED_MEASURE=1 swift test --package-path Producer \
  --filter testMeasureTheLibrarySnapshotAndThePreparationRunQuery
```

Fixture (`Producer/Tests/WiltedProducerTests/LocalLibraryStoreTests.swift`): 12
subscribed shows, 50 published episodes each. Backfill admits a 30-day window plus
the minimum floor rather than the whole back catalogue, so 600 published episodes
become **360 admitted rows** — the admitted count is the one the read paths pay for.
Journal: 200 preparation runs of 4 statuses each, **800 journal rows**, about a month
of nightly preparation.

Each figure is the mean of 5 calls after a warm-up call, on an M5 Max. Resident-size
deltas come from `mach_task_basic_info` and are noisy at this scale (32–82 KB across
runs of the identical fixture); treat them as "allocates tens of kilobytes, not
megabytes", not as a precise figure.

## Figures

| Read path | Journal rows | Wall time | Resident delta | Rows returned |
|---|---|---|---|---|
| `podcastLibrarySnapshot()` | 0 | 0.0308 s, 0.0330 s | 82 KB | 360 episodes |
| `podcastLibrarySnapshot()` | 800 | 0.0920 s, 0.0934 s | 49–66 KB | 360 episodes |
| `preparationRuns()` | 0 | 0.0000 s | 0 | 0 runs |
| `preparationRuns()` | 800 | 0.0617 s, 0.0642 s | 0–33 KB | 200 runs |

Two runs of each configuration are listed rather than one, because a single point
figure cannot be told apart from noise. The spread within a configuration is under
8%; the gap between configurations is 3x.

## The Prep poll and the queue lists

```
TEST_RUNNER_WILTED_MEASURE=1 xcodebuild test -project Wilted.xcodeproj -scheme WiltedMac \
  -only-testing:WiltedMacTests/WiltedMacModelTests/testMeasureThePrepPollAndTheEagerlyBuiltQueueLists \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

`TEST_RUNNER_` is the prefix, not a typo: a plain `WILTED_MEASURE=1` does not reach the
test host process, so the figures never print. The gate runs this test without the
variable, which is why it is silent there.

Fixture (`WiltedMacTests/WiltedMacModelTests.swift`): 12 subscribed shows, 30 episodes
each, 360 in the library and 180 on the Menu, plus the same 200-run / 800-row journal.
Titles and publication dates are shuffled so a sort has real work to do.

Two costs, paid in different places:

| What | Where it runs | Wall time (3 runs) |
|---|---|---|
| `feedsEpisodes` (filter + sort, 180 rows) | main actor | 0.0005, 0.0005, 0.0006 s |
| `menuEpisodes(in:)` × one view pass (7 calls) | main actor | 0.0024, 0.0024, 0.0024 s |
| `refreshProcessorRuns()` to published runs | off the main actor | 0.1154, 0.1099, 0.0952 s |

**The poll is not a frame cost.** `refreshProcessorRuns()` spawns a `Task`; its ~110 ms
is store reads off the main actor. What lands on the main actor is the assignment and
the list rebuild, and that is the 2.9 ms total above — under a fifth of a 60 Hz frame.

**The Menu lists are rebuilt per call, and the view makes seven of them.** Every
`menuEpisodes(in:)` call rebuilds `menuWaitingEpisodes`, which builds a dictionary over
all 360 visible episodes (`WiltedMac/WiltedMacModel.swift:3709`). The chip count, the
rows, and the continue-button check each pay for it separately. At 360 episodes that is
2.4 ms per view pass; it is linear in library size, so it stays a frame-safe cost until
the library is several times larger.

## What the numbers say

**The snapshot's cost is the library plus the whole journal.**
`podcastLibrarySnapshot()` ends with `allPreparationRunSummaries(in: context)`
(`Producer/Sources/WiltedProducer/LocalLibraryStore.swift:2832`), which decodes every
journalled status in the library. The arithmetic is exact: 0.031 s of library work
plus 0.062 s of journal work is the 0.093 s measured. So the snapshot does not scale
with the size of the library the reader sees — 360 episodes either way — it scales
with how much preparation has ever run. A year of nightly preparation is roughly
10,000 journal rows, which extrapolates to ~0.8 s per snapshot, and the snapshot is
taken on every library refresh.

**The journal is the growth term and it is unbounded.** Episodes are bounded by the
30-day admission window; journal rows are not pruned by anything measured here.

## Decision

**Dated 2026-09-18: accepted as measured, no structural change landed.**

The main-actor costs are accepted outright: 2.9 ms per Menu view pass and 0.5 ms for
the Feeds list leave the frame budget intact at a realistic library size, and caching
`menuWaitingEpisodes` would buy a couple of milliseconds at the price of a cache to
invalidate. Not worth it without a number saying otherwise.

At the size a user reaches today the snapshot is 92 ms off the main actor, which is
not a frame cost and is not worth a schema change against the risk of touching the
read path that every destination depends on. The finding that matters is the growth
term, not the present figure, and the fix for it (either journal retention, or
splitting run summaries out of the snapshot so callers that do not need them do not
pay) is a change with its own design and its own migration — not something to land
inside a queue drawdown.

Carried as a `TASKS.md` row rather than done here. The measuring test is the guard in
the meantime: if either path gets an order of magnitude worse it fails rather than
being noticed as a slow window.
