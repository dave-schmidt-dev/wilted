# Wilted release walkthrough — 2026-08-23

Candidate source: the current working tree on 2026-08-23. This is a candidate
inventory and evidence boundary, not release approval. The authoritative local
gate passed against this source; device, Production CloudKit, App Store Connect,
and TestFlight acceptance remain separate.

## Product boundary and roles

Wilted has two product roles. The Mac producer accepts HTTPS article URLs,
extracts and prepares audio, keeps the local library, and automatically queues
revision metadata plus deterministic byte chunks for CloudKit. The iOS listener
discovers metadata, downloads a selected revision explicitly, reconstructs and
caches audio, plays it, and sends playback progress. There is no user-selectable
role or in-app account picker. The signed-in iCloud account is the identity
boundary; a typed sign-in, sign-out, or account switch quarantines local sync
work until explicit recovery.

## iOS listener (shipping routes)

| Route/state | Controls and behavior | Disabled/recovery/system boundary | Evidence |
| --- | --- | --- | --- |
| Library, empty | Refresh; empty-library copy; Send Playback Progress | Refresh and send are disabled while refresh/send is busy | Source inventory; attended current-patch capture pending |
| Library, refreshing/sending | Status text and Cancel during a busy operation | Refresh/send disabled; Cancel stops the operation | Source inventory; current-patch run pending |
| Library, retryable failure | Retry; error status | Retry is shown only for retryable failures | Source inventory; current-patch run pending |
| Library, metadata-only article | Article title/source/state; Transcript disclosure; Download button; disabled Play button | Play remains disabled until audio is downloaded; transcript reports unavailable/oversized/malformed truthfully when text cannot be shown | Current light/dark pixel baselines and UI journey; physical-device evidence pending |
| Library, downloaded article | Transcript disclosure; Play button; Remove Download button; Send Playback Progress button | Remove preserves metadata while deleting local media; Play uses the local cache | Current light/dark pixel baselines and UI journey; physical-device evidence pending |
| Library, deleted/incompatible/unavailable item | Status label and article state | Playback is unavailable; sync recovery is handled by the account/session boundary | Source-inventoried; Production/device evidence pending |
| Library, selected playback panel | Transcript disclosure; Rewind, Play/Pause, Restart buttons; position readout | Readout follows the active engine without creating a durable progress event each second | Current now-playing baselines and UI journey; attended physical audio evidence pending |
| Downloads, empty | Downloads tab; empty copy | No playable row exists | Prior fixture screenshot; current-patch capture pending |
| Downloads, populated | Download summary with real file count/bytes; article card; explicit Play button | Only downloaded items appear; size is derived from the local audio cache | Current light/dark pixel baselines and UI journey; physical-device evidence pending |
| Settings | Connected Mac: Unavailable; Last sync; Downloads count/size; Audio: Local speech | Facts are read-only and persisted/derived; no producer identity is fabricated when CloudKit cannot provide one | Current light/dark pixel baselines, repository/model tests, and UI journey |
| Terminal sync failure/quarantine | Error/status copy and recovery boundary | Account changes quarantine local work; explicit session recovery is required | Prior fixture screenshot; current Production/account evidence pending |

The iOS tab bar contains Library, Downloads, and Settings. Library is the only
tab wrapped in a navigation stack and carries the wordmark; Downloads and
Settings use literal titles. Now Playing is an inline Library panel, not a
fourth tab.

## Mac producer (shipping routes)

| Route/state | Controls and behavior | Disabled/recovery/system boundary | Evidence |
| --- | --- | --- | --- |
| Library sidebar, empty | Select Library; empty-library copy | No article row is selectable | New producer snapshot files are present; attended current-patch capture pending |
| Library sidebar, article row | Select an article to open Now Playing | Row status is Ready to play or Preparing | Source inventory; attended signed-build evidence pending |
| Add an article | HTTPS URL field; Add Article | Article preparation starts only through the producer action | New URL-focus/producer snapshots are present; current-patch gate pending |
| Sync normal | Refresh; Upload; status/detail; last successful fetch/send facts | Both actions are disabled when sync is disabled or quarantined; successful operations return only after facts are current | Lifecycle/unit evidence; Production CloudKit evidence pending |
| Sync fetching/sending/staging | Status/detail; Cancel | Cancel appears during fetching, sending, or staging | Source inventory; attended recovery exercise pending |
| Sync quarantined | Use Current iCloud Account | Refresh and Upload remain disabled until explicit recovery | Source inventory; account-change/device evidence pending |
| Preparation in progress | Progress, stage detail, Cancel when cancellable | Cancellation stops without replacing the last valid saved audio | Source inventory; current-patch run pending |
| Preparation cancelled/failed/completed | Terminal detail; completed article becomes Ready to play | Failed/cancelled work does not publish as a ready revision | Source inventory; current-patch gate pending |
| Saved article row | Open Now Playing when ready | Preparing rows have no open-player action | Source inventory; current-patch capture pending |
| Now Playing | Rewind 15 seconds, Play/Pause, Skip forward 30 seconds, Restart | Audio-route recovery is available; failure text appears if recovery fails | Source inventory; physical audio-path evidence pending |

The Mac sidebar is a producer library, not an iOS-style tab bar. The toolbar
wordmark is the sole top-level brand treatment; the Now Playing destination also
shows its artwork mark.

## System-owned surfaces and release-only checks

These are entered or controlled by the system and are not proven by source
inspection or simulator snapshots:

- iCloud sign-in/sign-out/account-switch and CloudKit permission surfaces.
- Audio-session route changes, interruption handling, background playback, and
  any system media controls.
- Xcode signing, provisioning, and any macOS authentication or TCC sheet.
- Signed Production-entitled Mac producer to promoted Production CloudKit to
  signed physical iPhone listener round trip.
- App Store Connect processing, tester-group assignment/visibility, and receipt
  closeout for a candidate built from this working tree.

## Current disposition

The walkthrough is complete as a source-backed candidate inventory. On
2026-08-23, final `make validate` passed its 10 Phase 0 legs and all 8 native
legs, including WiltedKit 66, CloudSync 45, Listener 20, Producer 73, 35 Mac
unit/pixel tests, 40 iOS unit tests, 162 Mac pixel baselines, and the
clean-simulator UI leg 11/11: ten light/dark route baselines plus the account-free
journey. Focused checks also proved oversized transcript degradation preserves
ready audio and Mac refresh/upload observability is current on return.
That journey reached Download, Downloads selection, the playback panel, account
quarantine, and recovery through the shipping listener views. After fixing the
playback status observer race and now-playing toggle, it passed 1/1 with
explicit paused, resumed-playing, and recovery assertions. The
journey uses deterministic local audio and does not prove CloudKit or physical
audio behavior. Existing 2026-08-21 device captures and prior release receipts
remain historical evidence only. Physical-device, Production CloudKit, App Store
Connect, and TestFlight boundaries remain pending until independently evidenced
and reviewed.
