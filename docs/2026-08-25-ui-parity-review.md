# Wilted UI and parity review — 2026-08-25

**Scope.** Mac producer and iOS listener UI, reviewed against the **uncommitted working tree**
(26 files, 588 insertions) — the same source the owner ran during the 2026-08-25 Mac acceptance
rejection. Evidence is SwiftUI source plus the checked-in pixel baselines
(`WiltedMacTests/__Snapshots__/`, `WiltediOSUITests/__Snapshots__/`).

**Not evidence.** No device run, no CloudKit run, no signed build, no accessibility audit, no
TestFlight claim. This is a source-and-baseline design review only.

---

## Part 1 — Mac acceptance feedback: root cause

The owner's report ("library list always visible, Library shows *Add an article*, Now Playing
opens another right sidebar while *Add an article* stays in the middle") is reproduced exactly by
the source. Four distinct defects compound:

| # | Defect | Location |
|---|---|---|
| M-1 | **Sidebar selection does nothing.** `WiltedMacLibraryView` is rendered unconditionally in the `detail:` closure. `selectedNavigation` only gates whether a Now Playing pane is *appended* to the right. Selecting **Library** changes zero pixels. | `WiltedMac/WiltedMacRootView.swift:78-92` |
| M-2 | **Library's page title is "Add an article".** The Library destination's `.display` heading is the composer's title, not the destination's. This is why the middle column reads as an unrelated form. | `WiltedMac/WiltedMacRootView.swift:172-175` |
| M-3 | **Sidebar duplicates the detail list.** `Section("Library")` renders every article as a row; the detail region renders the same articles again under "Saved articles". Two lists, same data, different affordances. | `WiltedMac/WiltedMacRootView.swift:41-77` vs `:196-205` |
| M-4 | **A de-facto third column.** `NavigationSplitView` is two-column, but the detail is an `HStack` that appends the player. Now Playing therefore reads as "another right-side sidebar" rather than a destination. | `WiltedMac/WiltedMacRootView.swift:79-91` |

**Assessment.** This is not a styling problem. The window has a navigation control that isn't wired
to navigation. M-1 is the primary defect; M-2 through M-4 are what make the result *look*
deliberate and therefore confusing rather than obviously broken.

---

## Part 2 — Triage: all open work

`TODO`/`FIXME`/`HACK` across `Shared/ WiltedMac/ WiltediOS/ WiltedKit/ CloudSync/ Listener/ Producer/`: **none**.
`gh issue list`: **empty** (exit 0). TASKS.md is the only queue.

### P0 — blocks everything downstream

| ID | Item | State |
|---|---|---|
| **T15** | Mac navigation/window composition redesign | **blocked on owner decision.** Task scope forbids inferring a replacement. Options in Part 5. |
| **U-1** | iOS account-quarantine dead end (see Part 3, I-1) | **new, unqueued.** Functional, not cosmetic. Should be its own task. |

### P1 — gated behind T15

| ID | Item | Why it waits |
|---|---|---|
| **T7a** | Refreshed dated screen-by-screen walkthrough | Mac routes change under any T15 option. |
| **T7b** | Mac UI evidence + pixel baselines re-record | Same. |
| **D-1** | `docs/2026-08-24-navigation-walkthrough.md` disposition | Untracked, self-marked REJECTED/STALE for Mac. Supersede with the post-T15 walkthrough; do not commit two live route maps. |

### P2 — independent of T15, still open under Task 7

These are release-evidence gates, not code. They are listed separately because TASKS.md currently
carries them as one paragraph:

| ID | Gate | State |
|---|---|---|
| **T7c** | Physical-device background/audio evidence | outstanding |
| **T7d** | Signed Production-entitled Mac → promoted Production CloudKit round trip | outstanding |
| **T7e** | Signed Production Mac → signed physical iPhone listener delivery | outstanding |

Historical Development/device evidence (2026-08-18) does **not** satisfy T7c–T7e; the source has
changed since.

### P3 — quality debt surfaced by this review

| ID | Item |
|---|---|
| **Q-1** | Mac pixel baselines render at a 520×260 canvas; the sidebar captures as a blank white rectangle in dark mode (see Part 6). |
| **Q-2** | `HISTORY.md` carries a completed "Persistent producer and listener navigation" entry for work that was never committed and has since been rejected. |
| **Q-3** | Two divergent Mac sidebars exist: the preview-only branch in `Shared/WiltedRootView.swift` and the shipping `WiltedMacRootView`. They already disagree (see X-1). |

### Recommended order

`T15 decision → U-1 → T15 implementation → T7a/T7b → T7c–T7e`.
**No new alpha build until T15 lands** — a TestFlight receipt against a rejected UI spends the
build number for nothing.

---

## Part 3 — UI review

### iOS listener

| # | Finding | Severity |
|---|---|---|
| **I-1** | **Account quarantine is a dead end.** On a typed iCloud account change the model sets `.failed("iCloud account changed; sync is quarantined", retryable: false)`. Library only renders **Retry** when `retryable: true`, so the shipping app shows a red status line and **no recovery control at all**. The only "Recover Library" button lives in the `DEBUG`-only `ListenerMVPFixture`. Mac has **Use Current iCloud Account**; iOS has nothing. Visible in `listener-terminal-failure-*.png`. | **High** |
| **I-2** | **Three different title treatments across four tabs.** Downloads and Settings draw a `.display` `Text` inside the ScrollView; Now Playing uses `.navigationTitle`; Library has no title at all, only the wordmark. | Medium |
| **I-3** | **Card geometry is inconsistent within one app.** Library and Downloads rows use `Rectangle().stroke` (square corners); Settings cards use `RoundedRectangle(cornerRadius: 8)`. | Medium |
| **I-4** | **Refresh is a content button, not a toolbar item.** A `.bordered` button floats right-aligned above the status line rather than sitting in the navigation bar. | Medium |
| **I-5** | **"Send Playback Progress" sits in the Library list.** A sync-plumbing action presented as a primary listener control. Belongs in Settings, or should be automatic. | Medium |
| **I-6** | **Settings row duplicates its card title.** The "Audio" card contains a row also labeled "Audio". | Low |
| **I-7** | **Downloads rows are weaker than Library rows.** No per-item size, no **Remove Download**, no transcript — all present on the same item in Library. | Low |
| **I-8** | **Wordmark appears on Library only.** Mac shows it on every route. | Low |

### Mac producer

| # | Finding | Severity |
|---|---|---|
| **M-1…M-4** | Navigation composition — see Part 1. | **High** |
| **M-5** | **No Settings destination.** Sync status, producer identity, last fetch/send, Refresh/Upload/Cancel and quarantine recovery are inlined into the Library page. iOS puts the same information in Settings. | Medium |
| **M-6** | **Player is missing four components iOS has:** progress bar, elapsed/total readout, status line, transcript disclosure. Confirmed in `mac-shell-player-dark.png`. | Medium |
| **M-7** | **"Back to Library" is redundant** under a persistent sidebar, and iOS has no equivalent. Note: a Mac UI journey asserts it (HISTORY 2026-08-24), so removal is test work. | Low |
| **M-8** | **"Recover audio route" is always visible**, including when nothing is playing and no route fault exists. Recovery controls elsewhere appear only when valid. | Low |
| **M-9** | **Empty-library copy differs by platform** for the same concept: Mac `ContentUnavailableView("Your library is empty")` vs iOS bare `Text("No articles yet")`. Both strings are in `WiltedScreenCopy`. | Low |

### Cross-platform

| # | Finding | Severity |
|---|---|---|
| **X-1** | **The preview Mac shell and the shipping Mac app disagree on the destination set.** `Shared/WiltedRootView.swift`'s macOS branch offers Library / **Downloads** / **Settings** (it filters *out* Now Playing); the shipping app offers Library / Now Playing. Downloads is a listener-only concept and should never appear on Mac. This divergence is baked into `mac-shell-navigation-selection-*.png`, which renders "Downloads" as a Mac destination. | **High** |
| **X-2** | **No shared card modifier.** `WiltedMacCard` (Mac) and the two ad-hoc iOS treatments are independent implementations of one visual concept. Nothing prevents further drift. | Medium |
| **X-3** | **Status color semantics are duplicated, not shared.** `statusColor` is written twice in `ListenerAppView.swift` and again inline on Mac. | Low |

---

## Part 4 — Parity axes

`W-INV-002` makes Mac the producer and iOS the listener, so parity cannot mean identical features.

**Must match — same concept, same treatment:**
navigation model (persistent, exclusive destinations) · destination titles and copy · card
geometry and border · player component vocabulary (mark, title, source, progress, readout,
status, transports, Restart, transcript) · status color semantics · empty-state pattern ·
recovery-control availability · where sync lives (Settings).

**Legitimately role-divergent — do not force:**
Add Article + preparation progress (Mac only; iOS never produces) · Downloads (iOS only; Mac
audio is local at creation, there is no download concept) · audio route recovery (macOS routing) ·
tab bar vs sidebar (correct platform idiom for each; the *model* matches, the control doesn't).

**Net:** after T15, both apps should present **Library / Now Playing / Settings** as persistent
exclusive destinations, plus **Downloads** on iOS only.

---

## Part 5 — Mac composition options (owner decision)

All three fix M-1 through M-4. They differ in scope and in snapshot cost.

### Option A — Destination switch (minimal)

Sidebar becomes destinations only (Library / Now Playing). Detail renders exactly one. Library's
H1 becomes "Library" with the composer as a card beneath it. Drop the duplicate sidebar list and
the appended player pane.

- Fixes M-1, M-2, M-3, M-4. Leaves M-5 (no Settings), M-6 (player gaps), M-7, M-8.
- Parity: partial — Mac still has no Settings, player still thinner than iOS.
- Cost: ~10 Mac shell baselines re-recorded, 162-state matrix untouched, 1–2 UI journeys touched.

### Option B — Destination switch + parity pass (recommended)

Option A, plus: add a **Settings** destination carrying sync/identity/Refresh/Upload/Cancel/
quarantine recovery and audio mode, mirroring iOS Settings' card structure. Bring the Mac player
to iOS's component set (progress bar, elapsed/total, status line, transcript). Remove "Back to
Library". Gate "Recover audio route" on an actual route fault. Extract one shared card modifier
and one shared status-color mapping. Fix X-1 so the preview shell matches shipping.

- Fixes M-1 through M-9, X-1, X-2, X-3. Pairs naturally with fixing I-1 on the same pass.
- Parity: full on every must-match axis.
- Cost: ~10 Mac shell baselines + new Settings/player baselines, `expected_count=162` in
  `tests/test-native-gate.sh` changes, 3–4 Mac UI journeys touched, iOS journeys touched for I-1.

### Option C — Inspector composition

Sidebar = destinations. Library owns the full-width detail. Now Playing becomes a real
`.inspector()` trailing panel the user toggles, rather than a destination — a persistent
mini-player that never hides the producer surface.

- Fixes M-1 through M-4 and keeps playback visible during production, which the current design was
  reaching for.
- Risk: `.inspector()` is macOS 14+ (target floor is macOS 14 — usable, but untested here), and it
  reintroduces a two-region right side that is close in shape to what was just rejected.
- Cost: highest — new interaction model, all Mac shell baselines, new journeys.

---

## Part 6 — Evidence-quality findings

- **Q-1 (important).** Mac pixel baselines render through `NSHostingView` at a **520×260** canvas —
  no real window is that size. At that size the split-view sidebar captures as a **blank white
  rounded rectangle in dark mode** (`mac-shell-producer-library-dark.png`). The Mac pixel suite
  therefore does not verify sidebar content or real window composition, and HISTORY's "captures are
  nonblank" claim does not hold for the sidebar region. This is why the rejected composition
  cleared the gate.
- **Mac baselines were not re-recorded** for the uncommitted persistent-navigation change; only the
  10 iOS baselines were. Mac pixel evidence is stale relative to the tree the owner ran.
- **Q-2.** HISTORY records the rejected navigation work as completed; it was never committed.
- `tests/test-native-gate.sh` hardcodes `expected_count=162` and an iOS floor of 11 tests. Both move
  under Option B.

---

## Decision needed

1. **Which Mac composition** — A, B, or C. Recommendation: **B**.
2. **Whether I-1 (iOS quarantine dead end) rides the same change** or opens as its own task.

On acceptance: implement, re-record affected baselines, update the gate counts, produce the
refreshed dated walkthrough, and retire `docs/2026-08-24-navigation-walkthrough.md`.
