# Wilted screen-by-screen walkthrough — 2026-08-25

Supersedes the 2026-08-24 navigation walkthrough, which was rejected for Mac on 2026-08-25.
That file has been deleted rather than kept alongside this one, so there is only ever one
live route map to read.

This document is candidate-current for the source at the time of writing and is **source and
attended-window evidence only**. It is not deployment, TestFlight, physical-device,
production CloudKit, signing, or owner-acceptance evidence; those remain separate gates
under Task 7.

Evidence behind the Mac claims below: each destination was opened in a real `WiltedMac.app`
window and captured, because the Mac pixel-snapshot suite structurally cannot draw a
`NavigationSplitView` sidebar (`NSHostingView.cacheDisplay` does not render the navigation
column). Sidebar behaviour is owned by `WiltedMacUITests`, which drives the shipping app —
a leg that was absent from `make validate` between 2026-08-23 and today and has been
restored.

## What changed since the rejected walkthrough

The 2026-08-24 Mac composition kept a library list permanently visible, left **Add an
article** in the detail region regardless of the selected destination, and opened Now
Playing as a third region beside it. Selecting a sidebar item changed nothing that was
already on screen.

The window is now a plain destination switch:

- The sidebar lists **destinations only** — Library, Now Playing, Settings. It no longer
  repeats the article list that Library already shows.
- Exactly one destination fills the detail region. Switching destinations removes the
  previous one.
- **Settings** is a Mac destination for the first time, mirroring the listener's Settings
  tab. Sync moved out of Library and into it.
- **Back to Library** is gone. The sidebar is the return route, and it is always one click.
- **Recover audio route** is offered only after a route operation actually failed, matching
  how account review is offered only while sync is quarantined.

## First launch and onboarding

There is no onboarding on either platform, and that is a design position rather than an
omission: Wilted has no account of its own, so there is nothing to enrol in.

- Neither app shows a welcome, tour, sign-in, or setup flow. First launch lands directly on
  Library — the Mac window on its Library destination, the iPhone on its Library tab — in
  the same empty state a returning user sees with nothing saved.
- Neither app requests a system permission at launch or at any point in these flows. There
  is no `*UsageDescription` key in `project.yml` and no authorization request in source, so
  no microphone, notification, tracking, or local-network prompt can appear.
- Neither app asks for credentials. Sync uses the iCloud account already signed in at the
  system level. If iCloud is unavailable the apps say so as a state and keep working
  locally; they never block the first screen behind it.
- The one account-related interruption is deliberate and is not onboarding: if the signed-in
  iCloud account changes, sync quarantines and both apps require an explicit **Use Current
  iCloud Account** press before continuing (W-INV-007).

## Mac producer

### Window and navigation

- Two columns. The sidebar carries the Wilted wordmark and three destinations, each with a
  literal label and an icon: **Library**, **Now Playing**, **Settings**.
- The selected destination is indicated by both a filled row and its title as the detail
  region's heading, so selection is never carried by colour alone.
- Downloads is deliberately absent. Mac audio is local the moment it is produced, so there
  is nothing to download. No Mac copy names Downloads as a place to go.
- Playback continues across destination switches. Navigating to Library while audio plays
  does not stop it, and returning to Now Playing shows the transport still in **Pause**.

### Library

- **Add an article** card: explains that the URL must be HTTPS and that the saved article
  and audio stay on this Mac. The URL field takes the article URL; **Add Article** starts
  preparation and Return is its keyboard shortcut. The button is never disabled: empty or
  non-HTTPS input is rejected in place with *Enter a complete HTTPS article URL.* in the
  same card, so a rejected press always says why rather than doing nothing.
- **Saved articles** lists each saved article as a card with title, source, and readiness.
  A ready row exposes **Open Now Playing**; a preparing row does not, and says
  **Preparing**.
- An empty library shows **Your library is empty** with *Add an article to start
  listening.* — producer wording, not the listener's.
- Preparation reports the current stage, a progress bar, a detail line, and **Cancel**
  while cancellation is still safe. Cancelling states that the current work stops without
  replacing saved audio. Invalid input and preparation failures stay in the same card as
  explicit error text.

### Now Playing

- With no article selected: **Nothing is playing**, with *Choose a ready article in
  Library, then return here for playback controls.* Only destinations this window has are
  named, and only a *ready* article can be opened.
- With an article: the Wilted mark, title, source, a progress bar, an elapsed/total readout
  (`0 of 120 seconds`), a status line, transports **Rewind 15 seconds** / **Play**–**Pause**
  / **Skip forward 30 seconds**, **Restart**, and a **Transcript** disclosure. This is the
  same component set the listener shows, in the same order.
- The readout refreshes on a one-second cadence while audio runs, so the producer can
  answer "how far in am I?" — it previously froze at the loaded value.
- The transcript row is always present. When text is unreadable it says why (absent,
  oversized, malformed) instead of disappearing.
- A playback error is shown in the player. **Recover audio route** appears only once a
  route operation has actually failed.

### Settings

- **Sync** card: **Status**, **Detail**, **Producer identity**, **Last fetch**, **Last
  send**. Status is tinted by phase — neutral, active, positive, caution, failure — while
  always spelling the phase out in words.
- **Refresh** and **Upload** are disabled while sync is disabled or quarantined. **Cancel**
  appears only during staging, fetching, or sending.
- A quarantined account shows *Wilted paused sync and kept your local work. Review before
  continuing with the account now signed in.* and a prominent **Use Current iCloud
  Account**. Pressing it clears quarantine; the control then disappears. Wilted never
  silently adopts a changed account.
- **Audio** card: **Speech mode** → **Local speech**.

## iPhone listener

### Tab bar

- **Library**, **Now Playing**, **Downloads**, **Settings** are always present, each owning
  a `NavigationStack`. No feature requires reaching a preceding page first.

### Library

- Title **Library**; the toolbar's primary action is **Refresh**, disabled while work is
  active.
- The status line reports progress, readiness, offline, incompatible-revision,
  deleted-item, and failure states. **Cancel** appears during active work; retryable
  failures expose **Retry**.
- A quarantined iCloud account shows the same detail copy and the same **Use Current iCloud
  Account** control as the Mac. Before this change a quarantined iPhone showed a
  non-retryable red line and had no way out.
- An empty library shows **Your library is empty** with *Articles you prepare on your Mac
  appear here.* Both apps share the title and differ only on the detail line, because only
  the Mac can act on it. (**No articles yet** exists in `WiltedScreenCopy` but is used only
  by the preview shell, not by either shipping library.)
- Each article is a card with title, source, and local availability. **Play** is disabled
  until audio is downloaded. Metadata-only items expose **Download**; downloaded items
  expose **Remove Download**. **Transcript** is a disclosure when readable and states why
  when it is not.

### Now Playing

- With nothing selected: **Nothing is playing**, with *Choose a downloaded article from
  Library or Downloads, then return here for playback controls.* — the listener does have
  a Downloads tab, so its wording legitimately differs from the Mac's.
- With playback: mark, title, source, progress bar, `31 of 120 seconds`, status line,
  the three transports, **Restart**, and **Transcript**.

### Downloads

- Empty: **No Downloads**.
- Populated: saved-file count and storage size, then one card per downloaded article with
  its own **Play** and **Remove Download**. Transports live in the Now Playing tab.

### Settings

- **Sync**: **Connected Mac**, **Last successful sync**, **Last sync issue** when one
  exists, and **Send Playback Progress** (disabled while another operation is active).
- **Downloads**: **Saved audio**, **Storage used**.
- **Audio**: **Speech mode** → **Local speech**.
- A Wilted wordmark closes the screen.

## Parity: what matches and what legitimately differs

Matches by construction — these are shared components, so they cannot drift:

| Concern | Shared surface |
| --- | --- |
| Card geometry | `WiltedCardModifier` / `.wiltedCard` |
| Settings groups and rows | `WiltedSettingsCard`, `WiltedSettingsRow` |
| Status colour meaning | `WiltedStatusTone` |
| Account-change recovery | `WiltedAccountRecoveryNotice` |
| Transcript disclosure | `WiltedTranscriptSection` |
| Empty player | `WiltedNowPlayingEmptyView` |
| Screen copy | `WiltedScreenCopy` |

Divergences that are role, not drift:

- The Mac produces: URL composer, preparation stages, Upload. The iPhone consumes:
  Download, Remove Download, Send Playback Progress.
- The iPhone has a Downloads destination; the Mac does not, because Mac audio is already
  local. Copy that names a destination is split per platform for exactly this reason.
- Navigation idiom: split view on Mac, tab bar on iPhone.
- Mac Sync reports producer-side fields (producer identity, last fetch, last send); iPhone
  Sync reports listener-side fields (connected Mac, last successful sync).

## Roles, permissions, recovery, and system surfaces

- Producer-only controls never appear on iPhone; listener-only Downloads never appears in
  the Mac window.
- iCloud-unavailable, offline, incompatible-revision, deleted-item, retryable-failure,
  cancellation, and account-quarantine states are explicit on both platforms. Every
  recovery control is gated on the fault it can actually clear.
- The account-free MVP fixture hosts the same shipping views and root. Its **Simulate
  Account Switch** and **Recover Library** overlay is test-only and is not release UI.
- No custom system-owned sheet is entered from these controls. iOS may surface active audio
  on the Lock Screen and in Control Center; macOS may route audio outside the app. Those
  surfaces need separate device evidence and are not proven here.

## Coverage and gaps

- `WiltedMacUITests` (7 tests) drives the shipping Mac window: destination exclusivity,
  sidebar contents, player readout, article add/cancel, playback surviving destination
  switches, and quarantine recovery. This leg is back in `make validate`.
- `WiltediOSUITests` covers the listener routes plus ten light/dark pixel baselines and the
  account-free journey.
- **Gap, stated plainly:** the Mac pixel suite cannot capture the sidebar at any canvas
  size. `testWindowBaselinesCaptureTheDetailRegionAtWindowScale` asserts only the detail
  region and says so. Sidebar regressions are caught by the XCUITest leg or by attended
  review, not by pixels.

## Review gate

The release owner reviews this walkthrough before any deployment trigger. Any change to a
user-visible route, control, state, or copy string requires a refreshed walkthrough. No new
alpha build should be cut until the composition described here is accepted.
