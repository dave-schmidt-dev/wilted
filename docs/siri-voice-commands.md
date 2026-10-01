# Siri voice commands

## Mechanism decision (2026-09-30)

App Intents, not SiriKit media intents. Apple's SiriKit page says the Intents framework now only
"provide[s] legacy support" and new work should use App Intents
(<https://developer.apple.com/documentation/sirikit>). `AudioPlaybackIntent` (iOS 17+) marks an intent
as playing audio so the system avoids interrupting it
(<https://developer.apple.com/documentation/appintents/audioplaybackintent>); `AppShortcutsProvider`
(iOS 16+) registers spoken phrases with no user setup
(<https://developer.apple.com/documentation/appintents/appshortcutsprovider>). The deployment target
is iOS 17. No entitlement is needed for in-app App Intents; no Intents extension target is needed
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
An app may declare at most 10 App Shortcuts (the build fails on the 11th), so pause and resume, which the
remote commands already serve, have intents but no App Shortcut phrase; the other nine each have one.

| v1 command | Path | Intent | Planner command | Tests |
|---|---|---|---|---|
| play next episode of a show | App Intent | `PlayNextEpisodeIntent` | `playNext(show:)` | `VoiceCommandPlannerTests`, `LibraryVoiceTargetTests` |
| play a named episode | App Intent | `PlayEpisodeIntent` | `playEpisodeByID(id)`; `playEpisode(title:show:)` for title-only callers | `VoiceCommandPlannerTests` |
| play latest | App Intent | `PlayLatestIntent` | `playLatest(show:)` | `VoiceCommandPlannerTests` |
| pause | remote command (spoken); App Intent in Shortcuts app | `PauseEpisodeIntent` | `pause` | planner, runner, adapter |
| resume | remote command (spoken); App Intent in Shortcuts app | `ResumeEpisodeIntent` | `resume` | planner, runner, adapter |
| skip forward / back | App Intent + remote command | `SkipForwardIntent`, `SkipBackIntent` | `skipForward`, `skipBack` | planner, adapter |
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
| | otherwise | play the downloaded episode (of the show, if given) with the newest `publishedAt`; ties keep Larder order | "Playing <title>." |

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
built app (the tests are hosted in it) and asserts all 11 intents, `ShowEntity`, `EpisodeEntity` and both
queries are exported, at most 10 App Shortcuts are declared, and every phrase contains
`${applicationName}`. Last build log (`xcodebuild test`, Xcode 27): no `appintentsmetadataprocessor`
warnings for the app target; the only ones are "Metadata extraction skipped, no AppIntents.framework
dependency found" for the unit- and UI-test bundles, which do not link AppIntents. `requestConfirmation(dialog:)` (iOS 18) shows the mark-completed question; the deployment target is iOS 26, so it is called directly.

## Outcomes and races

`VoiceCommandTarget.perform` returns `VoiceOutcome` (`done`, `queued`, `failed`), not a Bool.
- Play never toggles: `LibraryAppModel.playCachedWithoutToggling` decides after its cache read, so a start from
  CarPlay or the phone during that await is resumed, not undone.
- Mark completed says "Marked completed." only when the decision was sent to the Mac, "Queued. It will go to
  your Mac when it's reachable." when it exists but the send failed (it is retried), and "That didn't work."
  when no markDone decision exists (not offered, or another action owns the row).
