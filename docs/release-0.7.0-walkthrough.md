# Wilted 0.7.0 walkthrough checklist

Candidate: `efe9e256` (2026-10-26), version 0.7.0 (12). Sections A-I were written against `912d61cb` (2026-10-21); item 7 below lists what changed since, and section J covers it. Baseline: 0.6.0 (11), `0bce4c73`, 2026-10-13.

## Status before the walkthrough

1. The changelog's `[Unreleased]` section has 236 entries at `efe9e256`. 134 of them already shipped in the 0.6.0 (11) build but were never filed under 0.6.0, so you have been running them since 10-13. 102 are new since 0.6.0 (91 at the freeze, 11 added since). The split is drafted in `docs/release-0.7.0-changelog-draft.md`.
2. Classification: 201 verified by a named test, 22 need a person or live device (listed below), 0 product failures. Two entries described behaviour the code doesn't have; their wording was corrected in `fcaf44f9`.
3. Gates: the full native gate passed on `912d61cb`, including the one screen-seizing Mac UI run (Mac unit 1582, Mac UI 10, iOS unit 933, iOS pixel 36, Kit 104, CloudSync 114, Producer 817, Playback 4). The receipt still covers `fcaf44f9`. Headless `make validate` on `fcaf44f9`: 35/35 phase-0 legs and 8/8 native legs passed. An earlier run on `912d61cb` hit a 10 s timeout in one build-cache tooling test while the machine was at load 160; that test passes alone. Headless `make validate` on `efe9e256` (2026-10-27, macOS 27.2): 35/35 phase-0 legs; Playback 4, CloudSync 114, Kit 104, Producer 851, iOS pixel 36 and iOS unit 942 passed; Mac unit failed 2 of 1612, both from the macOS 27.2 update, not the code: the system link detector now gives a bare domain in show notes `https` rather than `http` (test now accepts either), and the player-chapters pixel baseline from 10-10 still showed the pre-10-13 "No episode page" control and fell just past the 1% tolerance (re-recorded). With both fixes the full Mac unit leg then passed headlessly (log `.logs/mac-unit-rerun-2026-10-27.log`). The `make native-ui` receipt for `efe9e256` (10-26, Mac UI 9/9 legs) predates the walkthrough; the Mac UI run is owed again on the final candidate after the walkthrough.
4. Installed app evidence: no WiltedMac crash from the `/Applications` copy (all 16 crash reports since 10-14 came from test hosts). The installed Mac logged iCloud "service unavailable" (CloudKit error 6) about every 5 minutes from 17:00 to 23:04 on 10-20, then nothing since.
5. Devices: the Mac runs the candidate (`make install` of `efe9e256`, 2026-10-26). The iPhone and iPad (both iOS 27.0.1) still run `fe55645e` from 2026-10-21, which lacks the iPhone ad feedback buttons and the 10-23 phone resend; section G and the iPhone line in J need a phone install of the candidate first. The embedded Watch app reaches the Watch through the iPhone.
6. Inventory tables: `.logs/release-0.7.0/class-*.md` (ids such as A1, C22, F87 refer to rows there).
7. Changes since `912d61cb`, each at your word (session transcript, 2026-10-22 to 10-26):
   - Ad engine v12 and edge trims (`74049737`, `18cd83bc`, `58d0ab22`, `e2148743`, `2176dfd9`): after "This episode started with multiple ads … we need this not to happen again" (10-22), and "no dont revert, tweak" (10-23). Pushed.
   - Phone audio resend (`7b8ac30f`): "the download to iphone button is gone? … im going to the car, try to fix" (10-23). Mac iCloud backoff reset (`574e0b20`): "Work on the Mac side" (10-23), the follow-on to that failure.
   - Prepare Again (`683d330e`, `6d41fa4d`, review fixes `9a2c73a2`, `3e2ede5f`): "add a way to re-prepare episodes whose preparation kept every ad" and "extend Prepare Again to any episode prepared by an older engine" (10-23).
   - Mac Larder progress bar (`6dd29b3e`): your report that the started Michael Douglas episode showed no progress on the Mac (10-23).
   - Undo notice clears after 10 s (`bb751ead`): "this undo message has not gone anywhere after minutes" (10-23).
   - In-player ad feedback (`994c2491`, merged in `80a282be`): from your question about pointing out good and bad ad removals (10-23); you started that session and asked for the merge. Presses counting at once (`fff3eab3`): "count my presses automatically" (10-26).
   - Mark completed on a paused episode no longer starts the next (`efe9e256`): your bug report (10-26).
   - Requested but not shipped: the in022/in105 programme-boundary mislabel fix (10-23). The attempt (`d9ee5e5f`) failed the corpus gate and was reverted (`69ce7b89`); it is open engine work in TASKS.
   - Checklist-only commits: `0c9a1a8f`, `ce216bd7`, `6294bedc`, `eb487e2e`, `ed0c6397`.

Mark each line pass, fail, or skip. A fail that crashes, loses data or breaks something 0.6.0 did gets fixed in this release; everything else goes to `## Next release`, unless you say it belongs in this one.

## A. Mac Larder (episode list)

- [ ] Rows show three lines: title, then feed and length, then date. Queued rows say Queued (F51, C50).
- [ ] Sort the Larder by oldest first, play an episode, relaunch: the sort is kept (F38).
- [ ] Click Download on several episodes in a row: each stays queued, then finishes, and the list stays responsive (F15).
- [ ] Mark an episode completed, then Undo within 10 s: it returns to its place in the queue (C22).
- [ ] Know this: finishing, skipping from Feeds or retiring an episode now deletes its downloaded audio. Mark completed keeps it so Undo works. Prepared copies of deleted episodes are gone (C37).
- [ ] Remove an episode while it plays, then relaunch: it does not come back (F72).
- [ ] Right-click a podcast row and open Review Possible Duplicate. Compare the pair and stop before Apply (A9; Apply is decision 1 below).

## B. Mac player

- [ ] Let an episode play to its end: the next Larder episode starts within about a second (F12).
- [ ] Mark the playing episode completed: "Loading next episode…" shows until the next one opens (F34).
- [ ] Change speed while an episode is still loading: it plays and saves at that speed (F19).
- [ ] Drag the slider, then Pause and Play: both respond at once (C8).
- [ ] Unplug or disconnect headphones while playing: playback pauses (C13).
- [ ] With Reports on, a headline interrupts at a pause and playback resumes after it. Seek during a bulletin: playback lands where you sought (A11, F31, F32).
- [ ] Play an audiobook and step next and previous chapter (A14).

## C. Mac Feeds board and feed settings

- [ ] No feed shows a refresh error. 0.7.0 refuses feeds whose text encoding is unusual or contradictory (C18).
- [ ] Open a feed's settings, set Auto keep On and a Kept limit: the resolved values show beside Use global (A20).
- [ ] With Processing Manual and Auto prepare On, the settings explain why Auto prepare is suppressed (A10).
- [ ] Open a feed's rules sheet from the gear, add a Keep or Skip pattern, watch the preview, and read the audio-deletion warning beside Apply. Undo after Apply if you try it (A22, F29, C40).
- [ ] Toggle a feed's News setting twice quickly: the last choice sticks (F37).
- [ ] Unsubscribe a test feed: the dialog says its downloaded audio is deleted, and other feeds keep their artwork (C43, F35).

## D. Mac Playlists

- [ ] Playlists show Manual and Smart tags and icons, and clicking anywhere on a sidebar row opens it (C12, F10).
- [ ] Edit an automatic playlist with `(1 OR 2) AND 3`: the count updates live, and a broken formula shows an inline error (A24).
- [ ] Rename, then quickly delete a playlist: it stays renamed, or stays gone (F44, C39).

## E. Mac Settings and window

- [ ] Collapse the sidebar (Control-Command-S): the icon rail and selection stay (A25).
- [ ] Hover the toolbar: no grey band (F77).
- [ ] The loading animation looks right to you (C17).
- [ ] Settings › Sync lists the iPhone and iPad and shows no lasting error (F13, C45).

## F. Prepared episodes (listen)

- [ ] On a freshly prepared episode, pauses longer than half a second are shortened, and a saved position resumes on speech (A1).
- [ ] On a fresh AI Daily Brief episode, sponsor spots at ad-break edges are gone and the show is intact (F5, F8, F9; also decision 4).
- [ ] On a long episode (for example Giant Bombcast), ads are cut. If the review could not finish, the original audio plays and the info popover says why (F4, F41, C2, C20).
- [ ] An episode's info popover shows the build and engine line (A5).

## G. iPhone and iPad (after the candidate is installed)

- [ ] The Larder shows the Mac's preparation stage while it prepares, then Ready (A6, A7).
- [ ] Filter All / Downloaded / Available, Sort and Group work. With a sort other than Play order, the list says playback still follows play order (C57, A28).
- [ ] Swipe actions ask before Remove from Larder or Mark completed, and Restore completion brings a just-completed episode back (C57).
- [ ] Airplane mode: Keep an episode, force-quit, relaunch online. The Keep reaches the Mac once (F21).
- [ ] Settings › Storage total matches the episodes under Downloaded (F14).
- [ ] With Wilted force-quit, press play on the car or a Bluetooth headset: the newest in-progress episode plays (F18).
- [ ] Siri: "play the latest episode in Wilted", "how much is left in Wilted", "set speed to 1.5 in Wilted" (A44, A59, A60, A39).
- [ ] CarPlay: open the Downloaded and Shows tabs and play from a show's list (A40, A56).
- [ ] Watch: play on the phone, then pause, skip and change speed from the Watch. Up Next show names are readable (A19, F52).
- [ ] Spotlight: search a downloaded episode's title. It disappears after you delete the download (A61).

## H. Sync across devices

- [ ] Force-quit and relaunch the iPhone app: "Connecting to your Mac" clears and the library syncs (F7, F3).
- [ ] Listen on the iPhone, pause, then press Play on the Mac: it starts at the phone's position (F87).
- [ ] Leave all three devices open for 10 minutes: "iCloud is rate limiting sync" does not appear, or it clears (F6, C51).
- [ ] Play an episode to its end on the iPhone: the Mac shows it completed (F78, F90).

## I. Owner checks and decisions (from TASKS.md)

1. TWiT duplicate (Waiting 1): on the Mac, open Review Possible Duplicate on the reported same-feed TWiT pair and accept or correct the exact preview. Nothing is applied without your approval of that pair.
2. Preparation-history retention (Waiting 2, `docs/2026-10-19-preparation-history-maintenance.md`): recommended (a) keep 3 failed generations, (b) add the requestID index, (c) keep both published behaviours. Your go puts it in this release.
3. Retired, unplayed morning reports keep their audio (Waiting 3): recommended deleting them at retirement, for new retirements only. Your go puts it in this release.
4. AI Daily Brief and silence-trim live check (Waiting 4): turn on "Remove the show's own promotion" for AI Daily Brief, and allow one read-only inspection of the next natural preparations.
5. Playlist and rule parity (Awaiting milestone check): playlist order, rule behaviour and automatic results, Manual/Smart indicators, shared sorting across list pages, Larder Add, direct Share transcript, the two conditional accessibility checks, and preparation recovery once processing runs.
6. Weekly Show 9/30 Birdie Box ad (old Task 43): this was your report. It moved to `## Next release` only because the exact episode file vanished and the fix can't be verified. Say so and it stays in this release.

## J. Added since this checklist was written (2026-10-23)

- [x] A started episode on the Mac Larder shows a small progress bar and the time left beside its date, wherever it was last played.
- [x] Mark an episode completed: the "Undo completion is available for 10 seconds" notice goes away after 10 s.
- [x] File > Prepare Again With Current Engine shows (0) now that every episode has been through the current engine; right-click a Larder row has no Prepare Again. (2026-10-26: (0) confirmed; right-click not yet checked.)
- [x] Mac Now Playing: press **Ad here** during an ad you can hear. After a cut, **Good cut** and **Not an ad** show for 30 s. Each press confirms at once with Undo. (2026-10-26: Good cut and two Ad here presses on The Weekly Show recorded and mapped.)
- [ ] iPhone full player: the same three buttons. A press reaches the Mac after about 8 s plus iCloud.
- [ ] Settings > Ad feedback on the Mac lists every press as counted, with where it falls in the episode. Change one press's label, remove one, then restore it from Removed. (2026-10-26: the earlier accept/dismiss version passed; this is the recheck after `fff3eab3`.)
- [ ] Pause an episode, then Mark completed: it is marked completed and nothing else starts. Mark completed while playing still starts the next Larder episode (`efe9e256`).

## After the walkthrough

Walkthrough fixes land as one batch with headless gates. If any fix touches the Mac UI surface, the one screen-seizing `make native-ui` run on the final candidate waits until you say you are away from the Mac.

On a pass: tag `v0.7.0` on the walked commit, finalize the CHANGELOG 0.7.0 section from `docs/release-0.7.0-changelog-draft.md` (102 entries for 0.7.0; the 134 that shipped in 0.6.0 (11) move under 0.6.0), record it in HISTORY, and set TASKS to `open`. Push, TestFlight and any other publication wait for your explicit go.
