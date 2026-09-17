# Review of the external "Wilted daily-driver" handoff packet

**Date:** 2026-09-17
**Packet:** `Wilted_Daily_Driver_Handoff.zip` (START_HERE, REVIEW_AND_SPEC, IMPLEMENTATION_PLAN, ACCEPTANCE_TESTS, SOURCES, MANIFEST)
**Packet's pinned commit:** `c7a95e59ccc1cf95666e0790805aed72ea9a1893`
**Repository HEAD at review time:** `c7a95e5` — identical. No revalidation drift.
**Update (2026-09-17, post-review):** HEAD has since moved to `e2491b8` ("fix: resample the concat filter graph before the encoder"), which touches only `Producer/Workers/wilted_pipeline.py` and its test. No finding below cites either file, so every verdict still holds against current HEAD. That commit also left the worker fingerprint unbumped; fixed separately and re-gated green.
**Worktree at review time:** `Shared/WiltedSurfaces.swift`, `Producer/Workers/wilted_pipeline.py` modified; `Producer/Runtime/src/wilted.egg-info/` untracked.
**Method:** source verification of all fifteen findings against HEAD by three independent adversarial reviewers, plus direct checks of schema version, runtime resolution, Makefile targets, and test coverage. No macOS build, no Swift test run, no app session.

---

## 1. Verdict on the packet

**Substantially accurate and unusually well-disciplined.** It states its own limits correctly (source review only; nothing executed), it pins every claim to a symbol rather than a line number, and it explicitly instructs the implementing agent not to trust it over local code. Every symbol it names exists at HEAD under the stated name.

Three of its claims need correction, and two real defects sit next to claims it made (see §3). None of the corrections overturn a finding's existence — they correct the *mechanism*, which matters because the packet's proposed fixes follow from the mechanism.

**The most important thing the packet gets right, and understates:** F01. Automatic Menu admission does not merely "sometimes miss" — it is inert on the locally-prepared path, which is the only path this machine uses. And the test suite structurally cannot see it.

**The most important thing the packet could not know:** roughly a third of its findings are already in `TASKS.md`, and the issue-#1 state-model plan is mid-flight at Phase 9. The packet is substantially corroboration of an existing queue, not fifteen new units of work.

---

## 2. Disposition of F01–F15

All paths relative to repository root.

| ID | Verdict | Evidence | Already queued? |
| --- | --- | --- | --- |
| **F01** Successful preparation misses Menu admission | **CONFIRMED — high** | `WiltedMac/WiltedMacModel.swift:2880-2896`; `applyEpisodes` 3507-3527; overlay 3570-3584; arrival filter 3535-3539; sole call site of `autoAddPreparedEpisodesToMenu` is 3526 | Partly — as F02's row |
| **F02** Menu admission is not recoverable | **CONFIRMED mechanism; "no recovery" overstated** | `:3539` `knownBefore` filter; `:3561` `try?`; `refreshPodcastQueueState` overwrites the optimistic append. Manual route exists: `preparedEpisodesReadyForMenu` (3797) + bulk add | **Yes** — "Auto-add to Menu fails silently and never retries" |
| **F03a** `libraryItems` Finished uses 0.95, ignores `isPlayed` | **CONFIRMED** | `WiltedMacModel.swift:2000` vs `WiltedMacEpisodeRow.progressLabel` `WiltedMacRootView.swift:1358-1367` | **New** |
| **F03b** Retired-episode filter hides completed items from history | **NOT A DEFECT** | Retirement on completion is the designed Larder exit (`retireFinishedEpisode` :4589, doc 4578-4587); every Larder projection applies the same guard | — |
| **F04** Feed counts include records Larder hides | **CONFIRMED — high** | `WiltedMacModel.swift:5710` counts all snapshot episodes; `WiltedMacRootView.swift:842-846` labels it "in Larder"; `libraryItems:1995` excludes retired. **Also ignores `hiddenEpisodeIDs`** | **New** |
| **F05** Waiting preparation encoded as running | **CONFIRMED — mechanism corrected** | `isRunning` :600 true for all `.preparing`; `preparationQueueStatus:2138` checks it before queue membership. All five `preparationQueue.enter` sites set `.preparing`, so **the `.queued` branch at :2139 is unreachable dead code** | Partly — issue #1 scope |
| **F06a** Bulk intake is split across three screens | **CONFIRMED** | No bulk control in Larder header (`WiltedMacRootView.swift:374-401`); "Prepare all" only at :1414; "Add all prepared" only at :2017 | **Yes** — "Unify download and preparation scheduling" |
| **F06b** Bulk Prepare misses in-flight downloads | **CONFIRMED only under `.manual` policy** | Default is `.immediate` (`:478`); every download self-admits preparation (`:2598`); `.offPeak` intent *is* persisted (`:2663`) | Low-medium UX gap |
| **F07** Menu cannot sort oldest-first | **CONFIRMED — understated** | `WiltedMacMenuSort:141-149` has no `oldest` (Larder's does, :118). Worse: **`libraryOrder` has no UI writer anywhere** — only a `didSet`, two loads, three reads. Doc comments at :3781 and :4074 are now false | **New** |
| **F08** Play now strands unheard predecessors | **CONFIRMED** | `playEpisode:4113` appends + selects, never promotes; `menuUpcomingEpisodeIDs:3640` slices after current. Reachable only via the player's Previous transport, one step at a time | **Yes** — "Menu items before the current index are invisible and unremovable" |
| **F09** Skip is destructive | **CONFIRMED — worse than stated** | `dismissPodcastEpisode` `LocalLibraryStore.swift:3566-3600` deletes 8 record types; `PodcastListeningRecord` *does* survive. Restore requires network (`WiltedMacModel.swift:3344`) and **fails permanently once the feed drops the entry** (:3388) while the media bytes remain on disk | Partly — "Skip should mark an episode completed once started" |
| **F10a** Larder totals mix whole-shelf and filtered scopes | **CONFIRMED but intentional** | Doc comments at :1979-1981, :2020-2022 state the independence explicitly; each section carries its own `audio` | Low severity |
| **F10b** Prep total counts episodes with no visible section | **CONFIRMED** | `preparationAudioSummary:2107` includes `.notDownloaded`; Prep renders four hardcoded sections, none of which holds them. **`preparationQueueSections:2127-2133` is dead code — zero references** | **New** |
| **F10c** Menu total hides upcoming time | **NOT REPRODUCED** | Both labels render adjacently, `WiltedMacRootView.swift:1973-1981` | — |
| **F11** No after-last drop zone | **CONFIRMED** | `dropDestination` is per-row only (`WiltedMacRootView.swift:2135-2140`); no trailing zone exists. **You cannot make an item last by dragging.** Accessibility move-later *can*. No feed selector (`:319-345`) | **Yes** — "Menu drag-and-drop always inserts before the target" |
| **F12** Refresh defaults to Manual | **CONFIRMED; enum understated** | `:475-482` default `.manual`; policy has `.manual`, `.onLaunch`, `.whileOpen(6/12/24)` — packet omits `.onLaunch` | Not a defect |
| **F13** Row/Activity redundancy + stale copy | **CONFIRMED** | Row renders 7 info elements + 4 controls (`:1125-1220`); "Add all prepared" panel is unconditional (:2001-2027). **Stale string confirmed:** `WiltedMacModel.swift:2972` directs restore to "Podcast feeds", where no restore control exists — it is in Larder | **New** (the string) |
| **F14** Scaling risks | **CONFIRMED as described** | `podcastLibrarySnapshot` fetches every `TranscriptRecord` (`LocalLibraryStore.swift:2678-2682`) and every `PreparationRecord` unbounded (:2709 → :2566-2581); Prep polls at 1s (`WiltedMacRootView.swift:1567-1574`); no `LazyVStack` or `List` in any queue list | Unmeasured |
| **F15** Menu is podcast-only | **CONFIRMED** | Every controller queue API is podcast-typed (`PlaybackController.swift:258-311`); `beginArticlePlaybackTransition:4044-4053` clears queue context. No route for article audio into Menu | Future scope |

### The test gap behind F01

`grep "applyEpisodes(" WiltedMacTests/*.swift` returns **nothing**. The only relevant test, `testOnlyEpisodesThatBecamePreparedOnThisReloadCountAsMenuArrivals` (`WiltedMacModelTests.swift:1873-1897`), calls a `nonisolated static` helper with hand-built sets — no model, no reload. The sole `prepareEpisode(` in tests (:1551) asserts a fixture-mode failure and cannot reach `.prepared`. The auto-add tests (:3150, :3170) install pre-`.prepared` rows and call the bulk action directly.

So the real `prepareEpisode` → `applyEpisodes` → `episodeIDsNewlyPrepared` → `autoAddPreparedEpisodesToMenu` composition is untested. The packet's A01 is exactly the right test, and its insistence that helper tests are insufficient is correct.

---

## 3. Corrections to the packet

1. **F03's predicate is misattributed.** `WiltedMacLarderRemaining` contains no `0.95` rule — it is purely `isPlayed`-driven (`:69-70`). The 0.95 comparison exists in exactly one place, `libraryItems:2000`. The divergence is real; the packet names the wrong second party.
2. **F05's `larderQueueStatus` framing is wrong.** It does not check `isRunning` before queue membership — it has no preparation-queue check at all (`:2050-2052`). Its `.queued` means *download* queued, an unrelated fact. The user-visible symptom is the same; the fix is not.
3. **F06's consequence does not hold under defaults.** The default processing policy is `.immediate`, not manual, and every download self-admits preparation on completion (`:2598`). The gap is real but confined to `.manual`.

**Two defects the packet missed, found next to its claims:**

- `preparationQueueSections` and its `.unavailable` → "Not downloaded" mapping are dead code with zero references. That orphaning is *why* F10b reproduces — the model can build the section the view never asks for.
- `libraryOrder` has no UI writer. A fresh install is pinned to `.newest` with no reachable control, and two doc comments assert a Larder-order relationship that no longer exists. This makes F07 materially worse than the packet's version.

---

## 4. What the packet could not know

**Its W0 ("Revalidate and freeze the contract") is now done** — this document is that deliverable. Nobody should redo it.

**Roughly a third of the packet is corroboration, not new work.** F02, F06a, F08, F11 and part of F09 map onto existing `TASKS.md` rows. That is a meaningful signal about the queue's quality, and it changes effort sizing: the packet is not fifteen new units of work.

**Phase 9 is the sequencing constraint.** The issue-#1 episode-state-model plan is `in progress`; phases 1–8 have landed; Phase 9 closeout is blocked on `make native-ui` needing an unlocked screen, with a Red-blocker already filed in Todoist (`6hVmvrrGPPCFR2Xf`). The packet's W1–W5 touch exactly the files phases 1–8 rewrote. Starting them before Phase 9 closes forks the state-model work into two concurrent rewrites of `WiltedMacModel.swift`, `LocalLibraryStore.swift`, and `PlaybackController.swift`.

---

## 5. Recommended action plan

Ordered. Each step's gate is stated.

**0. Close Phase 9 before opening new state work. — David owns this step.** It needs an unlocked screen, which is why Todoist blocker `6hVmvrrGPPCFR2Xf` is already filed; no second task has been created for it. One batched screen-seizing session: `make native-ui` (all legs, `WILTED_MAC_UI=1`) with the screen unlocked, plus the dated walkthrough. This is already a filed blocker; it is also now the gate on everything below. Nothing in §5.1+ should start while Phase 9 is open.

**1. F01 + the test gap — first and alone.** Write the A01-shaped assembled-component regression first: drive a real preparation to success through its injected runner, let the real model completion path run, and assert exactly one durable Menu admission. It must fail against HEAD. Then make delivery a store/service responsibility tied to durable intent rather than a side effect of diffing UI arrays, which also closes F02. This is the daily-driver defect; everything else is downstream.

**2. F09 — Skip.** Argued up from the packet's ranking. This is reachable data loss behind one unconfirmed button sitting next to Download: eight record types deleted, restore network-dependent, and permanently impossible once the feed rotates the entry — while the audio is still on disk. Make Skip a reversible exclusion that preserves identity, media reference and outcomes. Offline Undo is the acceptance bar.

**3. F07 — oldest-first.** Small, high daily value, and explicitly the owner's stated requirement. Add `oldest` to `WiltedMacMenuSort`, give the queue its own explicit policy, delete the `libraryOrder` dependency (or restore its control — decide deliberately), and fix the two false doc comments.

**4. Cheap correctness batch, one commit each.** F04 (derive the feed count from the same ID set Larder shows, or relabel), F03a (one completion definition), F10b + delete dead `preparationQueueSections`, F13's stale "Podcast feeds" string, F05's unreachable `.queued` branch.

**5. F08 and F11 — Menu mechanics.** Play-now promotion; after-last and before-first drop targets. Both already queued.

**6. Deferred, needs your decision — not scheduled here.** The packet's §1 restructure (Larder/Menu/Feeds/Activity + Activity drawer, its W4) is a product direction, not a defect fix, and it competes directly for the same files. F12 (refresh cadence), F14 (profiling — unmeasured, do not act on it as fact), F15 (article audio in Menu) all sit behind the podcast journey.

---

## 6. Stale queue items to retire

Not edited in this session — another session (`wilted-22`) was live in this repository at review time.

1. **"Bug: Restore the preparation runtime dependency"** (`blocked`) is stale. Its premise is that the app resolves `~/Documents/Projects/wilted-old`. It does not: `PodcastPreparationPipeline.swift:220-226` resolves `Producer/Runtime/.venv/bin/python` and `Producer/Runtime/src`, both exist, and `import wilted` succeeds from that interpreter. Re-verify against a signed-app launch, then retire.
2. **`docs/2026-09-11-episode-state-model-plan.md`'s V9→V10 framing** is superseded. `LocalLibraryStore.swift:22` is `.v11`. The packet flags this itself and is correct.

---

## 7. Limits of this review

Source verification only. No macOS build, no Swift test execution, no migration rehearsal, no performance measurement, no app session. Every verdict above is a claim about what the code says, not about what a run does. F14 in particular is unmeasured by both the packet and this review — treat it as a hypothesis.
