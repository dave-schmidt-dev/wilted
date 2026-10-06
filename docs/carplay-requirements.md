# CarPlay requirements for Wilted

Binding requirements for any CarPlay work. Sources: Apple's *CarPlay Developer Guide* (June 2026, dated 2026-06-08) and the *CarPlay Entitlement Addendum* (Rev. 06-08-2026, LYL247). Page numbers are the guide's own. The PDF is kept locally under gitignored `.logs/reference/` because Apple's terms do not allow redistribution; this file is a paraphrase of the parts that apply to an audio app.

Status: Audio entitlement requested 2026-09-30 (Case-ID 22579502) and **assigned to the Zero Delta account by Apple on 2026-09-30** (email from Apple Developer Relations). Assignment is not yet a profile: the capability still has to be enabled on the App ID and a provisioning profile created and imported (see Category and entitlement). Nothing here is implemented yet.

## Category and entitlement

- Wilted is a **CarPlay audio app**: key `com.apple.developer.carplay-audio`, iOS 14 or later (p.12-13).
- Apple must assign the entitlement to the Zero Delta developer account after review; the request is made at developer.apple.com/carplay and includes accepting the CarPlay Entitlement Addendum (p.12). Submitted 2026-09-30 as app type Audio.
- After approval: enable the capability on the App ID, make a new provisioning profile, import it into Xcode. Xcode and the simulator need a profile that supports CarPlay, so testing with the real entitlement follows approval (p.12). Signing must be manual for the CarPlay build and `CODE_SIGN_ENTITLEMENTS` must point at the entitlements file (p.12).
- Once the entitlement is in a published build, the app icon appears on the CarPlay home screen for everyone. CarPlay cannot be shown to some users only, so ship it only when it is ready for all of them (p.12).
- The deprecated `com.apple.developer.playable-content` key is for iOS 13 and earlier only. Do not use it (p.67).

## Entitlement Addendum terms that bind development

- **No CarPlay API access before the entitlement profile arrives.** The Addendum (section 2) says Zero Delta will not access or attempt to access the CarPlay APIs without having received a CarPlay Entitlement Profile from Apple. So until approval there is no `import CarPlay`, no CarPlay scene declaration, and no CarPlay entitlement in any build, including simulator-only builds. Only groundwork that does not touch the CarPlay APIs is allowed (see Open items).
- Apple grants each profile case by case, may refuse, and may revoke at any time. Approval is not guaranteed and the timeline is not stated (Addendum note, sections 2 and 6.4).
- A "CarPlay App" is one Apple has approved in writing before the profile is used and before any App Store Connect submission (section 1).
- The profile is for this Zero Delta app only, under the standard Developer Program (not Enterprise), for iOS (section 2). Apple may issue a development-only profile first; it may be used only for internal testing on registered test units.
- The app must minimize driver distraction and never require physically handling the iPhone in CarPlay mode (section 3.1).
- Audio apps (section 3.4): primarily audio playback (podcasts named as an example); no gaming, commerce, social networking, texting, or mapping on the car screen or audio interface; no text-to-speech email readers, lyrics, web browsers, or turn-by-turn directions.
- Disclose the CarPlay API use in writing when submitting to App Store Connect, and the app must comply with the Addendum, the guidelines, and App Review Guidelines (section 4). Apple can still reject or stop distributing the app.
- Apple may change the terms; continued use requires accepting new terms (section 5). Retest with every new OS release (section 6.2). Additional indemnification applies (section 8).

## Guidelines the app must meet (p.4)

1. Designed primarily for audio playback.
2. Never tell the driver to pick up the iPhone. An error such as a needed sign-in may be reported, but not with wording that asks them to handle the phone.
3. Every CarPlay flow works without touching the iPhone.
4. Every flow is meaningful while driving; no unrelated settings or maintenance features.
5. No gaming or social networking.
6. Never show message, text, or email content.
7. Use templates only for their intended purpose and fill them only with the intended information types (a list to choose from, cover art on Now Playing).
8. Audio apps: never show lyrics on the CarPlay screen.

Consequence for Wilted: the car offers listening only. Downloading, deleting, Larder management, Settings, statistics, and sync status stay on the iPhone. The car cannot depend on the phone for a download the driver has not made, so it lists what is already on the phone.

## Structure

- Adopt scenes. Declare a `CPTemplateApplicationScene` with session role `CPTemplateApplicationSceneSessionRole` in the scene manifest, next to the existing iPhone window scene, with a delegate conforming to `CPTemplateApplicationSceneDelegate` (p.30-31).
- The app can be launched **only on the CarPlay screen**, with no iPhone UI running. Everything the car needs (player, library, transport) must start without the iPhone window scene (p.31).
- On `didConnect`, keep the `CPInterfaceController`, set a root template, and release it on `didDisconnect` (p.31).
- Template depth for audio apps is limited to 5 (p.14). Only these templates are allowed for audio: action sheet (iOS 17+), alert, grid, list, tab bar, voice control (iOS 27+), now playing, search (iOS 27+). Using any other template raises a runtime exception (p.14).
- Now Playing is a shared instance, `CPNowPlayingTemplate.shared`. Configure it at connect time, because iOS can show it immediately from the home screen or the navigation bar. It must always be able to show something. Only a list template may be pushed on top of it, for example an up-next queue (p.21, p.33).
- The MiniPlayer (iOS 27) is on by default; `allowsMiniPlayer = false` puts the Now Playing button in the navigation bar instead (p.21).
- Tab bar: read the maximum tab count from iOS (currently 4 for audio) and do not hard-code it. More than 4 tabs can hide the Now Playing button (p.25).
- List templates: some cars limit lists to 12 items, so read the maximum and handle 12 (p.18). Read `maximumImageSize` on list items and supply artwork of that size (p.28).
- A list item handler that does async work shows a spinner until its completion block is called, so always call it (p.32).
- Search is an alternative only, never the primary way to do anything, because many cars disable the keyboard while driving (p.24).

## Audio handling (p.29)

- Activate the audio session only when the driver actually starts playback. Activating at launch stops the car's radio or other source.
- No recording in CarPlay; configure the session without recording.
- **iPhone is usually locked in the car.** Anything CarPlay reads must be readable while locked: nothing at `NSFileProtectionComplete` or `CompleteUnlessOpen`, and no keychain items with `WhenUnlocked`, `WhenUnlockedThisDeviceOnly`, or `WhenPasscodeSetThisDeviceOnly`. Cached audio, the library snapshot, and play positions must all satisfy this. Test with the phone locked.

## Assets (p.28)

- Provide 2x and 3x, light and dark. Maximum sizes: tab bar icon 24 pt, grid icon 40 pt, Now Playing action button 20 pt, voice control image 150 pt.
- Prefer SF Symbols. Use `carTraitCollection` for the car's scale, not the iPhone's.

## Testing (p.8)

- CarPlay Simulator (Mac app, in Additional Tools for Xcode) connects to a phone over USB. Real head units work too; a wireless aftermarket unit lets the phone stay connected to Xcode by cable.

## Design decisions for Wilted (from the above)

- Root: a tab bar with two tabs, Downloaded (episodes on the phone) and Shows (one row per show with downloaded episodes, "N downloaded", show artwork; a tap pushes that show's episode list). The tab count is read from `CPTabBarTemplate.maximumTabCount` (two are used; a car allowing fewer gets the single list) and list lengths from `CPListTemplate.maximumItemCount`. Depth is tab bar, one show's list, Now Playing: three of the five allowed. Now Playing is reached from the system's navigation-bar button on every screen (iOS 26 has no mini player), which stays visible with fewer than the maximum tabs. Row tap starts playback through the existing `LibraryPlayer` and pushes Now Playing.
- Episode rows: show, then time left (or full length and "New" when unstarted), a playback-progress bar, the playing flag and cached artwork. Every CarPlay list (and Shows, ordered by each show's first episode) follows one play order, `InProgressOrdering.playOrder` in WiltedLibrary, the same one the phone list uses: episodes someone is partway through (this phone, the Mac or any device) first, newest play first; then the not-started ones, oldest published first (ties keep the Larder order); then completed ones last, most recently completed first and marked "Played". An episode played to its end counts as completed even before the Mac marks it. Auto-continue plays the first of this order that is not completed and not the one that just ended.
- Now Playing buttons: playback rate and the user's skip intervals, using the phone's settings.
- Empty and error states are statements, not instructions to use the phone ("No episodes on this iPhone").
- Handoff, position sync, and stats keep working because CarPlay drives the same `LibraryPlayer`.

## Siri

Voice commands are developed together with CarPlay but do not depend on it: they drive the same `LibraryPlayer` and work on the phone alone. The car screen shows no Siri button (the list has no assistant cell, p.18): "Hey Siri" and the car's Siri button cover it. Siri work does not use CarPlay APIs, so it may proceed before the entitlement is granted. See the Siri task in TASKS.md; the mechanism (App Intents or SiriKit media intents) is verified against current Apple docs before coding.

## iOS 26 floor and API availability

Owner decision (2026-09-30): iOS 26 is the compatibility floor, and the iOS deployment target is 26.0 (raised from 17.0 on 2026-09-30, with the WiltedKit, Listener and CloudSync packages at `.iOS(.v26)`, swift-tools-version 6.2). iOS 26.x APIs are allowed, gated with `#available` when newer than 26.0; no iOS 27-only API, not even behind `#available`. Anything that seems to need iOS 27 stops and goes to the owner with the symbol, what it gives, and the iOS 26 alternative.

Availability read from the iOS 27.0 SDK's CarPlay headers (Xcode 27.0, 27A266a). The app currently ships only symbols available since iOS 14 or earlier.

| Symbol | Available | Used |
|---|---|---|
| `CPTemplateApplicationScene`, `CPTemplateApplicationSceneDelegate` | iOS 13 | yes |
| `CPInterfaceController.setRootTemplate(_:animated:completion:)`, `pushTemplate(_:animated:completion:)`, `topTemplate` | iOS 14 (the non-completion forms are deprecated since 14) | yes |
| `CPListTemplate`, `CPListSection`, `CPListItem`, `CPListItem.isPlaying`, `CPListItem.handler` | iOS 14 | yes |
| `CPListTemplate.maximumItemCount`, `emptyViewTitleVariants`, `updateSections(_:)` | iOS 14 | yes |
| `CPNowPlayingTemplate.shared`, `updateNowPlayingButtons(_:)`, `CPNowPlayingPlaybackRateButton` | iOS 14 | yes |
| `CPTabBarTemplate`, `maximumTabCount`, `CPTemplate.tabTitle`, `tabImage` | iOS 14 | yes (Downloaded and Shows tabs) |
| `CPListItem.playbackProgress`, `setImage(_:)`, `accessoryType` | iOS 14 | yes |
| `CPNowPlayingTemplate.allowsMiniPlayer` | **iOS 27** | no; on iOS 26 there is no mini player, so the Now Playing button is always in the navigation bar |
| `CPInterfaceController.showOverlayTemplate(_:animated:completion:)`, `hideOverlayTemplateAnimated:completion:` | **iOS 27** | no |
| `CPChargingStationConnection` | **iOS 27** | no (not an audio-app feature) |
| `CPVoiceControlTemplate`, `CPSearchTemplate` | headers say iOS 12, but Apple's guide permits them for audio apps only from iOS 27 | no |
| `CPAssistantCellConfiguration`, `CPListTemplate(title:sections:assistantCellConfiguration:)` | iOS 15 (read from the iOS 27.0 SDK header) | not used: David does not want a Siri button on the car screen; see "Siri" |
| `CPListTemplate.listHeader`, `CPPlaybackConfiguration`, `CPImageOverlay`, `CPListItem` (26.4 extension) | **iOS 26.4** (above the 26.0 floor) | no |
| `CPListImageRowItem` elements, `CPGridButton`, `headerGridButtons` | iOS 26.0 | no (not needed for an episode list) |

Only a runtime check on an iOS 26 simulator and a real iOS 26 head unit proves the behaviour; the header table proves only that the symbols exist.

## Open items

- Entitlement granted 2026-09-30; the Addendum's no-access clause lifts once the CarPlay entitlement profile exists for the App ID. Until that profile is in place, nothing that touches the CarPlay APIs is added (see TASKS.md). Allowed groundwork now: the locked-phone file-protection audit, making the library model, transport, and player start without the iPhone window scene, and a framework-free episode-list model for the car. An earlier idea of adding the entitlement for simulator builds only is dropped because of the Addendum's no-access clause.
- Whether the file protection class of the audio cache, library snapshot, and positions allows access while locked is covered headless by `LibraryFileProtectionTests` (source audit plus the files on disk) and by `CarPlayJourneyTests.testOwnPositionStoreIsReadableWhileTheDeviceIsLocked` for the own-position store; a locked-phone run on a device remains the attended evidence.
- Whether launching with only the CarPlay scene can bring up the library model, transport, and player without the iPhone window scene.

## Siri

Decision (David, 2026-10-01): the CarPlay list shows no Siri assistant cell. "Hey Siri" and the car's Siri button already cover spoken requests, so `CPListTemplate(title:sections:)` is built without `assistantCellConfiguration` and `CarPlaySourceTests.testNoAssistantCellIsConfiguredAnywhereInTheApp` fails if any app source configures one.

What is built for spoken requests: `PlayMediaIntentHandler` (WiltediOS/Siri) handles `INPlayMediaIntent` in the app. It maps the request with `PlayMediaRequest` onto the existing Voice layer (`VoiceCommandPlanner`, `VoiceShowMatcher`), resolves only to episodes already on the phone, and plays through `VoiceRuntime` -> `LibraryRuntime.shared.prepare()` -> `playCachedWithoutToggling`, so it never waits on a sync and never starts a download. The `WiltediOSIntents` Intents extension (`com.zerodelta.wilted.ios.intents`, embedded in the app) resolves and confirms `INPlayMediaIntent` and answers `.handleInApp`; the app's `application(_:handle:completionHandler:)` then plays through the handler. The app declares `INIntentsSupported` = `INPlayMediaIntent`, `NSSiriUsageDescription`, and `com.apple.developer.siri` (Development only); `SiriAuthorization.requestIfNeeded()` asks once when the phone UI first appears, in the Development configuration only (`WILTED_SIRI`). No App Group; the extension sees no episode data. Tests: `PlayMediaIntentTests`, `IntentsExtensionTests`.

Release leaves the extension out (a build script embeds it for Debug and Development only), because Production has no Siri entitlement and an App Store app with an Intents extension needs one.

History: the cell was first configured without an Intents extension, which made CarPlay raise from `clientAssistantCellUnavailableWithError:` and abort the app on a device (2026-10-01, crash reports in `.logs/device-crashes/`). It was then guarded behind an embedded extension, and finally removed.
