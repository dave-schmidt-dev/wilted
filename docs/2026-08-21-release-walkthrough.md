# Wilted release walkthrough — 2026-08-21

Candidate source: working tree after the 2026-08-21 listener, playback,
pixel-baseline, and release-runner changes. This is a review inventory, not a
release approval.

## Directly captured

The real iOS app was launched on the iPhone 17 Pro simulator with a
device-free listener fixture. The eight current screenshots are under
`WiltediOSUITests/__Snapshots__/WiltediOSPixelSnapshotTests/`:

- Library, Downloads, Now Playing, and terminal sync failure in light and dark.
- Library shows the wordmark, refresh, downloaded article, Play, Remove
  Download, Send Playback Progress, and the tab bar.
- Downloads shows the selected tab and a playable downloaded article.
- Now Playing shows the selected article and transport controls.
- Terminal failure shows the quarantined sync recovery copy.

The focused Mac unit/snapshot target passed with 22 retained baselines:
six listener/fixture states in both schemes and ten Mac shell baselines,
including producer library, sidebar selection, URL focus, and player.

## iPhone listener review

| Route or state | Controls / expected result | Release evidence |
| --- | --- | --- |
| Library, empty | Refresh; empty-copy recovery | Not yet attended |
| Library, busy | Cancel; no duplicate refresh/send action | Not yet attended |
| Library, retryable failure | Retry | Not yet attended |
| Library, article metadata | Download | Not yet attended |
| Library, downloaded article | Play; Remove Download; Send Playback Progress | Captured fixture; physical device pending |
| Now Playing | Rewind, Pause, Restart; elapsed-time readout | Captured fixture; attended background audio pending |
| Downloads | Select downloaded article to play; empty-copy recovery | Captured fixture; physical device pending |
| Settings | Read-only settings tab | Source-inventoried; attended review pending |
| Terminal sync failure | Error copy and account-change recovery boundary | Captured fixture; Production CloudKit pending |

The listener has no user role selection. Its visible boundary is the signed-in
iCloud account; account changes must quarantine sync rather than blend data.

## Mac producer review

| Route or state | Controls / expected result | Release evidence |
| --- | --- | --- |
| Library, empty | HTTPS URL field; Add Article; explanatory empty state | Snapshot baseline; attended signed build pending |
| Sync normal | Refresh and Upload | Snapshot baseline; Production CloudKit pending |
| Sync busy | Cancel | Source-inventoried; attended review pending |
| Sync quarantined | Use Current iCloud Account; Refresh/Upload disabled | Source-inventoried; Production CloudKit pending |
| Article preparation | Progress, status detail, Cancel when available | Snapshot baseline; attended review pending |
| Ready article | Open Now Playing | Snapshot baseline; attended review pending |
| Now Playing | Rewind 15 seconds, Play/Pause, Skip 30 seconds, Restart | Snapshot baseline; physical audio-path pending |
| Audio recovery | Recover audio route; error text if recovery fails | Source-inventoried; attended audio interruption pending |

## System-owned and human-only checks

- iCloud sign-in/account-change and CloudKit permission surfaces.
- Media playback/background-audio and audio-route interruption behavior.
- Xcode signing and any system authentication sheet.
- Production-entitled Mac producer to Production CloudKit to signed physical
  iPhone listener round trip.
- Owner review of this walkthrough after those captures are refreshed.

## Current release disposition

The automated iOS UI suite and its eight screenshot comparisons passed on the
iPhone 17 Pro simulator. The macOS snapshot target passed with its 22 retained
baselines. The current iOS candidate has also passed its local gate, signed
Production archive, signature verification, and artifact verification.

This inventory still requires release-owner review before upload. The pending
physical-device, Production CloudKit, account-change, and audio-route checks
remain explicitly listed above; they are not represented as completed by the
simulator evidence. Refresh this walkthrough for any user-visible route,
control, state, or copy change before deployment.
