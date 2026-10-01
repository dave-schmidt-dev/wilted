# Siri voice commands

## Mechanism decision (2026-09-30)

App Intents, not SiriKit media intents. Apple's SiriKit page says the Intents framework now only
"provide[s] legacy support" and new work should use App Intents
(<https://developer.apple.com/documentation/sirikit>). `AudioPlaybackIntent` (iOS 17+) marks an intent
as playing audio so the system avoids interrupting it
(<https://developer.apple.com/documentation/appintents/audioplaybackintent>); `AppShortcutsProvider`
(iOS 16+) registers spoken phrases with no user setup
(<https://developer.apple.com/documentation/appintents/appshortcutsprovider>). The deployment target
was iOS 17 when this was written and is now iOS 26. No entitlement is needed for in-app App Intents; no Intents extension target is needed
while the intents run in the app process (`openAppWhenRun = false`).

## Layers

1. `WiltedKit/Sources/WiltedLibrary/Voice/`: framework-free `VoiceCommand`, `VoiceSnapshot`,
   `VoiceShowMatcher`, `VoiceCommandPlanner` (command + snapshot -> `VoicePlan`). Tested with `swift test`.
2. `WiltediOS/Siri/`: `VoiceCommandTarget` protocol (snapshot + perform), an adapter over
   `LibraryAppModel` and `LibraryPlayer`, and thin App Intent shells. Tested in `WiltediOSTests`.

## Planner semantics and dialog (every line is one short sentence)

| Command | Condition | Action | Dialog |
|---|---|---|---|
| playNext(show) | show given, no title matches | none | "I can't find a show called <spoken>." |
| | show given, ambiguous | none | "Did you mean <A> or <B>?" |
| | show matched, none downloaded | none | "No <Show> episodes are on your phone." |
| | show matched, playing episode is of that show | play the next downloaded episode of that show after it, in Larder order | "Playing <title>." |
| | ... and it is the last one | none | "That was the last <Show> episode on your phone." |
| | show matched, playing episode is another show (or nothing) | play the first downloaded episode of that show | "Playing <title>." |
| (all lists) | order | The shared play order (also the phone list's order): downloaded episodes someone is partway through (here, on the Mac or elsewhere) first, newest play first; then not-started ones, oldest published first (ties keep the Larder order); then completed ones last. "Next", "what's downloaded" and the disambiguation lists follow it; "play something" takes the head of this order; only the car's "newest" request (`playLatest`) is the newest published | |
| playNext(nil) | nothing downloaded | none | "No episodes are on your phone." |
| | otherwise | next downloaded episode after the playing one (first when nothing plays or the playing one is not listed); last one -> none | "Playing <title>." / "That was the last episode on your phone." |
| pause | playing | pause | "Paused." |
| | paused or nothing | none | "Nothing is playing." |
| resume | paused episode loaded | resume | "Resuming <title>." |
| | already playing | none | "Already playing." |
| | nothing loaded | none | "Nothing to resume." |
| skipForward / skipBack | episode loaded | skipForward / skipBack | "Skipped forward." / "Skipped back." |
| | nothing loaded | none | "Nothing is playing." |
| restart | episode loaded | restart | "Starting over." |
| | nothing loaded | none | "Nothing is playing." |
| markCompleted | episode loaded and canMarkCompleted | markCompleted(id), needsConfirmation | "Mark <title> completed?" |
| | episode loaded, cannot yet | none | "I can't mark that completed yet." |
| | nothing loaded | none | "Nothing is playing." |
| whatsPlaying | episode loaded | none | "<title>, from <Show>." (omit the show when empty) |
| | nothing loaded | none | "Nothing is playing." |
| listDownloaded | none | none | "No episodes are on your phone." |
| | n episodes | none | "<n> episode(s) on your phone: <t1>, <t2>, <t3>." (first 3; "and <n-3> more" when more) |

"Playing" means the player holds the episode (playing or paused); the next-episode rules use the
loaded episode, not whether it is audible.

## Coverage map (TASKS.md v1 set)

Siri also handles transport words itself ("pause", "resume", "skip") through the lock-screen remote
commands `LibraryPlayer` installs on `MPRemoteCommandCenter` when Wilted is the Now Playing app; the
App Intents below add the phrases that name Wilted and the commands the remote center cannot express.
An app may declare at most 10 App Shortcuts (the build fails on the 11th), so pause, resume and the two
skips, which the remote commands already serve, have intents but no App Shortcut phrase (the intents stay
in the Shortcuts app); the other seven each have one, and time left and speed (phase 3) take two more: 9 of 10.
The sleep timer intent has no App Shortcut (see Phase 3).

| v1 command | Path | Intent | Planner command | Tests |
|---|---|---|---|---|
| play next episode of a show | App Intent | `PlayNextEpisodeIntent` | `playNext(show:)` | `VoiceCommandPlannerTests`, `LibraryVoiceTargetTests` |
| play a named episode | App Intent | `PlayEpisodeIntent` | `playEpisodeByID(id)`; `playEpisode(title:show:)` for title-only callers | `VoiceCommandPlannerTests` |
| play something | App Intent | `PlayFirstEpisodeIntent` | `playFirst(show:)` | `VoicePlayLookupPlannerTests`, `VoiceRealRuntimeTests` |
| newest (SiriKit "play the newest ...", the car) | `INPlayMediaIntent` | `PlayMediaIntentHandler` | `playLatest(show:)` | `PlayMediaIntentTests` |
| pause | remote command (spoken); App Intent in Shortcuts app | `PauseEpisodeIntent` | `pause` | planner, runner, adapter |
| resume | remote command (spoken); App Intent in Shortcuts app | `ResumeEpisodeIntent` | `resume` | planner, runner, adapter |
| skip forward / back | remote command (spoken); App Intent in Shortcuts app | `SkipForwardIntent`, `SkipBackIntent` | `skipForward`, `skipBack` | planner, adapter |
| restart this episode | App Intent | `RestartEpisodeIntent` | `restart` | planner, adapter |
| mark this episode completed (confirms first) | App Intent | `MarkCompletedIntent` | `markCompleted` | planner, runner, adapter |
| what's playing | App Intent | `WhatsPlayingIntent` | `whatsPlaying` | planner |
| list downloaded | App Intent | `ListDownloadedIntent` | `listDownloaded` | planner |

### Added rows for play a named episode and play latest

| Command | Condition | Action | Dialog |
|---|---|---|---|
| playEpisode(title, show) | show given, no title matches | none | "I can't find a show called <show>." |
| | show given, ambiguous | none | "Did you mean <A> or <B>?" |
| | show matched, none downloaded | none | "No <Show> episodes are on your phone." |
| | no episodes downloaded | none | "No episodes are on your phone." |
| | title matches none of the candidate episodes (all downloaded, or the matched show's) | none | "I can't find an episode called <title> on your phone." |
| | title ambiguous (distinct titles tie) | none | "Did you mean <A> or <B>?" |
| | title matches | play it (first in Larder order when two episodes share a title); a playing episode is played again from where it is, never toggled | "Playing <title>." |
| playEpisodeByID(id) | id not among the downloaded episodes | none | "That episode isn't on your phone." |
| | id downloaded (an `EpisodeEntity` Siri resolved; the id decides, so equal titles are never confused) | play it | "Playing <title>." |
| playLatest(show) | show rules as playNext (no match, ambiguous, none downloaded) | none | same lines as playNext |
| | no episodes downloaded (no show) | none | "No episodes are on your phone." |
| | otherwise | play the downloaded episode (of the show, if given) with the newest `publishedAt`; ties keep Larder order. Only the SiriKit "newest" request sends this | "Playing <title>." |
| playFirst(show) | show rules as playNext (no match, ambiguous, none downloaded) | none | same lines as playNext |
| | otherwise | play the first downloaded episode (of the show, if given) in the shared play order: partway through first (newest play first), then not-started oldest first, then completed; never `publishedAt` | "Playing <title>." |

Episode titles are matched with `VoiceShowMatcher.match` over the candidate episodes' titles, so
the same tolerance (case, punctuation, accents, leading "the", whole-word runs, close spelling) applies.

## Real-runtime tests

`WiltediOSTests/VoiceRealRuntimeTests.swift` calls each intent's `perform()` through the default
`VoiceRuntime.provider` against a real `LibraryRuntime`: a library persisted on disk
(`FileLibraryStore`), a real WAV in `FileMediaCache`, the real `LibraryAudioEngine`, and
`UnavailableLibraryTransport` (no network, nothing synced; only `prepare()` runs). It asserts the engine
itself plays, pauses, skips (30 s forward, 15 s back) and restarts, that an episode not on the phone is
never started or fetched, and that an empty phone plays nothing. Only the AVAudioSession, Now Playing
and remote-command hooks are fakes, because they need a device. Mark completed needs
`requestConfirmation`, which only exists inside a running intent, so it stays covered by the adapter tests.

## App Intents metadata

`WiltediOSTests/AppIntentsMetadataTests.swift` reads `Metadata.appintents/extract.actionsdata` from the
built app (the tests are hosted in it) and asserts all 14 intents, `ShowEntity`, `EpisodeEntity`, both
queries and the `SpeedOption` and `SleepTimerOption` enums are exported, exactly 9 App Shortcuts are declared
(every intent except the four voiced by Siri's transport commands and the sleep timer has one), every phrase contains
`${applicationName}`, and no phrase starts with pause, resume, continue, stop or skip. Last build log (`xcodebuild test`, Xcode 27): no `appintentsmetadataprocessor`
warnings for the app target; the only ones are "Metadata extraction skipped, no AppIntents.framework
dependency found" for the unit- and UI-test bundles, which do not link AppIntents. `requestConfirmation(dialog:)` (iOS 18) shows the mark-completed question; the deployment target is iOS 26, so it is called directly.

## Outcomes and races

`VoiceCommandTarget.perform` returns `VoiceOutcome` (`done`, `queued`, `failed`), not a Bool.
- Play never toggles: `LibraryAppModel.playCachedWithoutToggling` decides after its cache read, so a start from
  CarPlay or the phone during that await is resumed, not undone.
- Mark completed says "Marked completed." only when the decision was sent to the Mac, "Queued. It will go to
  your Mac when it's reachable." when it exists but the send failed (it is retried), and "That didn't work."
  when no markDone decision exists (not offered, or another action owns the row).

## Phase 3: time left, speed, sleep timer (Shortcuts app only)

The sleep timer has no App Shortcut. On a device (phone and CarPlay, the PCC Siri planner) every phrase tried,
including ones without the word "timer", was handled as a system sleep timer by the Clock (a 30 second timer
was created, and "end of episode" was refused), so Wilted's intent was never reached. David does not expect to
use it, so the slot is free (9 of 10). The `SleepTimerIntent` stays available in the Shortcuts app and works
from there; the planner, `SleepTimer` and `LibraryPlayer.stopsAfterCurrentItem` are unchanged.

| Command | Condition | Action | Dialog |
|---|---|---|---|
| timeLeft | nothing loaded | none | "Nothing is playing." |
| | episode loaded, length unknown | none | "I can't tell how long is left." |
| | under a second left | none | "<title> has finished." |
| | otherwise | none | "About <n> minutes left." / "About 1 hour 5 minutes left." / "Less than a minute left." (under 30 s) |
| setSpeed(rate) | rate not one of `LibraryPlayer.rates` | none | "That speed isn't available." |
| | episode loaded | set the speed now and as the app's default speed | "Speed set to 1.5 times." ("normal" for 1) |
| | nothing loaded | set the default speed | "Default speed set to 1.5 times." |
| sleepTimer(minutes) | 1 to 720 minutes, episode loaded | pause after that long | "Sleep timer set for 30 minutes." |
| | nothing loaded | none | "Nothing is playing." |
| | out of range | none | "Pick a sleep timer between 1 minute and 12 hours." |
| sleepTimer(endOfEpisode) | episode loaded, not already finished | stop after it, no auto-play next | "Sleep timer set for the end of this episode." |
| | nothing loaded | none | "Nothing is playing." |
| | already at its end | none | "<title> has finished." |
| sleepTimer(off) | always | cancel the timer (minutes or end of episode) | "Sleep timer is off." |

- Time left is wall time at the current speed (`(duration - position) / rate`), so it matches what the listener
  will sit through, and it is the same while paused.
- Speed persists as `LibrarySettingsStore.defaultSpeed` (the Settings speed, kept in `UserDefaults`) and is also
  applied to the loaded episode with `LibraryPlayer.setRate`. `player.setRate` alone would be reset by the next
  `start()`. `SpeedOption` (an `AppEnum`, because a phrase may only carry an enum or entity parameter) has exactly
  the player's six rates; `VoiceStateTests` keeps `SpeedOption`, `LibraryPlayer.rates` and
  `VoiceCommandPlanner.supportedSpeeds` equal.
- The sleep timer (`SleepTimer`, one per process) is deadline-based: it wakes, checks the clock and sleeps the
  remainder. A wake more than 30 s past the deadline (the app was suspended while paused) is dropped, so it never
  pauses something started since. Starting again replaces it; "off" cancels it. Presets are 5, 10, 15, 20, 30,
  45, 60 and 90 minutes (`SleepTimerOption`, an `AppEnum` with "off" as a case so one intent covers cancel).
  "End of episode" is a `SleepTimerOption` too: it sets `LibraryPlayer.stopsAfterCurrentItem`, which makes the
  next natural end report auto-play off (once) through `onFinished`, so the episode finishes, its bookkeeping
  runs, and `autoContinue` never starts the next one. It is cleared when used, by "off", by a minutes timer
  and by `stop()`. The minutes and end-of-episode timers replace each other.

## Siri readiness (iOS 26 APIs only)

Availability checked against Apple's documentation data (developer.apple.com/documentation, `IndexedEntity`
iOS 18.0, `IntentDonationManager` iOS 16.0, `CSSearchableIndex` iOS 9.0) and the iOS SDK's `AppIntents`
module interface (`CSSearchableIndex.indexAppEntities` and `deleteAppEntities` iOS 18.0). Nothing here needs
iOS 27: `IndexedEntityQuery` (iOS 27) is not used, and `IntentDonationManager.deleteDonations` (iOS 26.4, above
the iOS 26.0 floor) is not used.

- **Spotlight.** `EpisodeEntity` and `ShowEntity` are `IndexedEntity`. `SpotlightIndexer` keeps the index equal to
  the episodes on the phone and their shows, observing the model like `ShortcutParameterRefresher`: the first
  non-empty state resets the index and indexes everything (so an episode removed while the app was not running
  cannot linger), an empty first state (model not loaded yet) does nothing, and later states index what is new or
  changed and delete what left. A renamed show is deleted under its old id (the id is the title) and added
  again. Index failures are logged and retried by the next change.
- **Donations.** `IntentDonor` donates `PlayEpisodeIntent` when an episode starts playing (once until another
  one plays) and `MarkCompletedIntent` when the loaded episode is marked completed in the app, through
  `IntentDonationManager`. It watches `LibraryPlayer` and the model's decisions, so the model is untouched.
  A play or mark Siri itself ran is skipped (the system already counted it), and a decision restored at launch
  is not donated (nothing is loaded then).

## App Shortcut phrases (9 of 10)

Every phrase names the app, none starts with pause, resume, continue, stop or skip, and none stands in
for "resume" (Siri's own "resume" covers it; Play next would skip ahead).

| Shortcut | Phrases |
|---|---|
| Play next | "Play the next episode of <show> in Wilted", "Play the next Wilted episode", "Play my next podcast in Wilted", "Play the next podcast of <show> in Wilted" |
| Play episode | "Play <episode> in Wilted", "Put on <episode> in Wilted" |
| Play something | "Play something in Wilted", "Play an episode of <show> in Wilted", "Play the first episode of <show> in Wilted", "Play my top Wilted episode" (the app's own pick: partway through first, otherwise the oldest not started; it replaced the "latest" and "newest" phrases, which played the newest published and so disagreed with the phone list and autoplay) |
| Restart | "Restart this episode in Wilted", "Start this episode over in Wilted" |
| Mark completed | "Mark this episode completed in Wilted", "Mark this episode as done in Wilted" |
| What's playing | "What's playing in Wilted", "What am I listening to in Wilted" |
| Downloaded | "What's downloaded in Wilted", "What episodes do I have in Wilted" |
| Time left | "How much is left in Wilted", "How much time is left in Wilted", "How long is left in Wilted" |
| Set speed | "Set speed to <0.75, 1, 1.25, 1.5, 1.75 or 2> in Wilted", "Set the speed to <speed> in Wilted" |

Unverified on a physical iPhone: how Siri's speech recognition matches the numeric speed titles and the
minute presets (the enum cases carry spoken synonyms such as "one and a half" and "an hour"). The
enums, phrases and exported metadata are covered by tests; recognition is not.
