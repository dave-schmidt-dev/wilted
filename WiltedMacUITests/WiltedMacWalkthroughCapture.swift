import AppKit
import XCTest

/// Records the content-viewport frames embedded in the dated Mac walkthrough.
///
/// This is capture tooling, not a gate. It runs only when
/// `WILTED_WALKTHROUGH_CAPTURE_DIR` names a directory, so the shipping suite
/// is unaffected. Pixels come from `XCUIElement.screenshot()` on the app's own
/// window -- never the screen and never another application's window -- and
/// each frame is inset by 8pt per edge because the window's rounded corners are
/// partly transparent and an uncropped frame can contain fragments of whatever
/// is behind it.
///
/// Task 0.1 retired Larder and Prep as destinations: `WiltedMacNavigation` now
/// has only `feeds`, `menu`, and `settings` (`WiltedMac/WiltedMacModel.swift`).
/// The sections below follow that -- Feeds, Menu, Playback, Settings,
/// Recovery -- rather than the old Larder/Podcast feeds/Prep/Settings shape.
@MainActor
final class WiltedMacWalkthroughCapture: XCTestCase {
    func testCaptureWalkthroughFrames() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE"] == "1",
            "capture tooling; set WILTED_WALKTHROUGH_CAPTURE=1 to record walkthrough frames"
        )
        let root = try Self.captureRoot()
        print("walkthrough.capture.root=\(root.path)")

        try captureFeeds(into: root)
        try captureMenu(into: root)
        try capturePlayback(into: root)
        try captureSettings(into: root)
        try captureRecovery(into: root)
    }

    /// Where the frames land.
    ///
    /// `WILTED_WALKTHROUGH_CAPTURE_DIR` is honoured when the runner can
    /// actually write there; the signed runner often cannot reach an arbitrary
    /// path, so the fallback is its own temporary directory and the resolved
    /// root is printed rather than assumed.
    private static func captureRoot() throws -> URL {
        var candidates: [URL] = []
        if let requested = ProcessInfo.processInfo.environment["WILTED_WALKTHROUGH_CAPTURE_DIR"] {
            candidates.append(URL(fileURLWithPath: requested, isDirectory: true))
        }
        candidates.append(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("wilted-walkthrough-captures", isDirectory: true)
        )
        for candidate in candidates {
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                let probe = candidate.appendingPathComponent(".probe")
                try Data("ok".utf8).write(to: probe)
                try FileManager.default.removeItem(at: probe)
                try purge(candidate)
                return candidate
            } catch { continue }
        }
        throw XCTSkip("no writable capture directory")
    }

    // MARK: - Scenarios

    /// Feeds: the one-decision inbox (Keep/Skip), the subscribe composer, the
    /// restorable list, and per-feed upkeep.
    ///
    /// "Off the list" now lists both removal kinds Task 4.5 folded onto one
    /// `removalKind` column -- a Skip from this inbox (retirement) and a
    /// Remove from the Menu -- each with the same Restore control, once both
    /// are present. Only the Skip (retirement) kind is driven from a UI
    /// control here: the Menu's own Remove button
    /// (`model.removeEpisodeFromUpNext`) only unqueues an episode and sends
    /// it back to the Feeds inbox, and the store operation that actually
    /// produces a dismissed (`removalKind == .dismissed`) row --
    /// `model.removeEpisode(_:)` -- is called only from
    /// `WiltedMacModelTests`/`WiltedVisualSystemTests`; two tests
    /// (`testTheSkipButtonCallsTheReversibleExclusionNotRemoval`,
    /// `testTheStartedPredicateLivesOnceInTheModelAndTheViewReadsIt`) assert
    /// it does not appear in `WiltedMacRootView.swift` at all. So this frame
    /// captures the Skipped kind only; the Removed kind's restore is
    /// evidenced by the model tests, not by a pixel here.
    private func captureFeeds(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        let navigate = element(app, "wilted-navigation-feeds")
        XCTAssertTrue(navigate.waitForExistence(timeout: 15))
        navigate.click()
        XCTAssertTrue(element(app, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        try write(app, "4.1-feeds-inbox", into: root)

        // Subscribing sits behind Add feed; the composer is a popover and a
        // window of its own, so the main window's frame cannot show it.
        element(app, "wilted-add-feed-button").click()
        XCTAssertTrue(element(app, "wilted-podcast-feed-url").waitForExistence(timeout: 10))
        try write(popover: app.popovers.firstMatch, "4.2-feeds-add-feed", into: root)
        app.typeKey(.escape, modifierFlags: [])

        // Skip retires one inbox episode outright, which is the one
        // UI-reachable action that lands a row in Off the list.
        let skip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-skip-'")
        ).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.click()

        XCTAssertTrue(element(app, "wilted-feeds-restorable").waitForExistence(timeout: 10))
        try write(app, "4.3-feeds-off-the-list", into: root)

        let feedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-row-'")
        ).firstMatch
        XCTAssertTrue(feedRow.waitForExistence(timeout: 10))
        try write(app, "4.4-feeds-management", into: root)

        // The page frame above shows the feeds as found. This one records
        // what the switch actually does, so the report is not left asserting
        // an effect it never captured.
        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-enabled-'")
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        let count = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-podcast-feed-count-'")
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        try write(app, "4.5-feeds-feed-hidden", into: root)
        app.terminate()
    }

    /// Menu: the episode queue Larder and Prep were folded into, the article
    /// composer that moved here with it, deferred and prepared episode rows,
    /// and the one place Transcript/Notes expand inline rather than into the
    /// full-window overlay.
    private func captureMenu(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(app, "wilted-compact-player").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "wilted-mac-menu-detail").waitForExistence(timeout: 10))

        // `groupList` (`WiltedMacRootView.swift`) draws only
        // `wilted-menu-empty` when nothing is on the Menu -- no group
        // header, no per-group clear button, none of the group chrome 5.1's
        // caption names. The podcast fixture episode starts in the Feeds
        // inbox (see the Keep step in the prepared-episode block below), so
        // it has to be kept here too or this frame would show an empty
        // Menu under a caption describing groups that are not on screen.
        element(app, "wilted-navigation-feeds").click()
        XCTAssertTrue(element(app, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        let keepIdle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keepIdle.waitForExistence(timeout: 10))
        keepIdle.click()
        element(app, "wilted-navigation-menu").click()
        XCTAssertTrue(element(app, "wilted-mac-menu-detail").waitForExistence(timeout: 10))
        let idleRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'")
        ).firstMatch
        XCTAssertTrue(idleRow.waitForExistence(timeout: 10))
        try write(app, "5.1-menu-idle", into: root)

        // The address box moved from the Larder's header to here; the
        // popover keeps its own identifier and is captured at its own size.
        element(app, "wilted-add-article-button").click()
        XCTAssertTrue(element(app, "wilted-link-url").waitForExistence(timeout: 10))
        try write(popover: app.popovers.firstMatch, "5.2-menu-add-article", into: root)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()

        // The Menu row does not yet show the prepared completion summary
        // ("Ready · 5 ads removed (7:22) · transcript synced") the retired
        // Larder row used to: `WiltedMacEpisodeLifecyclePresentation
        // .primaryLabel`/`.larderLabel` back that summary, and only the
        // Feeds row reads it (`WiltedMacRootView.swift`, the
        // `feedsEpisodeRow` line using `episode.lifecyclePresentation
        // .primaryLabel`) -- the Menu row's own subtitle is plainly
        // `feedTitle · group.rawValue`. Task 7.4 re-queues carrying that
        // summary onto the Menu row as its own future row, so this frame
        // asserts only what the row currently shows.
        let prepared = launch([
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        XCTAssertTrue(element(prepared, "wilted-mac-menu-detail").waitForExistence(timeout: 15))

        // A podcast fixture episode arrives in the Feeds inbox, not on the
        // Menu: `feedsEpisodes` is every episode whose id is absent from
        // `podcastQueueIDs`, and only Feeds' own Keep
        // (`model.keepEpisode(_:)`, bound to `wilted-feeds-keep-<id>`) adds
        // an id to that queue. `installPodcastFixture` never seeds
        // `podcastQueueIDs`, so the row has to be kept before it exists on
        // the Menu at all -- confirmed against
        // `WiltedMacSmokeUITests.testPodcastCompactPlayerPersistsAcrossDestinationsAndExposesCompleteControls`,
        // which drives this same launch/keep sequence.
        element(prepared, "wilted-navigation-feeds").click()
        XCTAssertTrue(element(prepared, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        let keep = prepared.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        keep.click()
        element(prepared, "wilted-navigation-menu").click()

        let preparedRow = prepared.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'")
        ).firstMatch
        XCTAssertTrue(preparedRow.waitForExistence(timeout: 10))
        try write(prepared, "5.3-menu-prepared-episode", into: root)

        // Menu is the one destination that expands Transcript and Notes
        // inline, inside its own compact player, instead of handing off to
        // the full-window overlay every other destination uses -- so this
        // state exists nowhere else and needs its own frame.
        let playEpisode = prepared.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 10))
        playEpisode.click()
        let transcript = element(prepared, "wilted-player-transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.click()
        XCTAssertTrue(element(prepared, "wilted-player-transcript-expanded").waitForExistence(timeout: 10))
        try write(prepared, "5.4-menu-transcript-inline", into: root)
        prepared.terminate()

        // The off-peak fixture keeps its preparation deferred until the
        // listener overrides that window. Capture the row before activating
        // the control so the walkthrough shows both the reason for waiting
        // and the available "Prepare now" action.
        let deferred = launch([
            "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-deferred"
        ])
        XCTAssertTrue(element(deferred, "wilted-mac-menu-detail").waitForExistence(timeout: 15))
        element(deferred, "wilted-navigation-feeds").click()
        XCTAssertTrue(element(deferred, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        let keepDeferred = deferred.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keepDeferred.waitForExistence(timeout: 10))
        keepDeferred.click()
        element(deferred, "wilted-navigation-menu").click()
        XCTAssertTrue(element(deferred, "wilted-mac-menu-detail").waitForExistence(timeout: 10))
        XCTAssertTrue(element(deferred, "wilted-menu-group-downloaded").waitForExistence(timeout: 10))
        let waitingForOffPeak = deferred.staticTexts["Waiting for off-peak"]
        XCTAssertTrue(waitingForOffPeak.waitForExistence(timeout: 10))
        XCTAssertTrue(waitingForOffPeak.isHittable)

        let deferredRow = deferred.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-row-'")
        ).firstMatch
        XCTAssertTrue(deferredRow.waitForExistence(timeout: 10))
        let prepareNow = deferred.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-prepare-now-'")
        ).firstMatch
        XCTAssertTrue(prepareNow.waitForExistence(timeout: 10))
        XCTAssertTrue(prepareNow.isEnabled)
        try write(deferred, "5.5-menu-deferred-prepare-now", into: root)
        deferred.terminate()
    }

    /// Playback: the always-visible bottom rail, and the full-window
    /// overlay Transcript/Notes/the Menu shortcut open into everywhere
    /// except Menu itself.
    private func capturePlayback(into root: URL) throws {
        // The full-window player only appears off Menu, so this drives it
        // from Settings. The article fixture plays immediately at launch.
        let app = launch(["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(app, "wilted-mac-menu-detail").waitForExistence(timeout: 15))
        element(app, "wilted-navigation-settings").click()
        XCTAssertTrue(element(app, "wilted-compact-player").waitForExistence(timeout: 10))
        try write(app, "6.1-playback-rail", into: root)

        let transcript = element(app, "wilted-player-transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.click()
        XCTAssertTrue(element(app, "wilted-player-full-window").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "wilted-player-transcript-expanded").waitForExistence(timeout: 10))
        try write(app, "6.2-playback-fullwindow-transcript", into: root)

        // The full-window player's own Menu shortcut is only drawn while
        // off Menu; pressing it is the one control that both dismisses
        // the overlay and changes the selected destination at once.
        let openMenu = element(app, "wilted-player-menu")
        XCTAssertTrue(openMenu.waitForExistence(timeout: 10))
        openMenu.click()
        XCTAssertTrue(element(app, "wilted-mac-menu-detail").waitForExistence(timeout: 10))
        try write(app, "6.3-playback-menu-from-player", into: root)
        app.terminate()

        // Notes and the speaker-labelled transcript need an episode, not the
        // article fixture, and get a launch of their own: clicking a Menu
        // row after the panels above have been expanded and collapsed did
        // not work reliably in earlier captures of this same player.
        let episodeApp = launch([
            "--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts", "--wilted-ui-fixture-prepared"
        ])
        XCTAssertTrue(element(episodeApp, "wilted-mac-menu-detail").waitForExistence(timeout: 15))

        // Same reason as the Menu scenario above: the podcast fixture
        // episode starts in the Feeds inbox, and only Feeds' Keep puts it
        // on the Menu where `wilted-menu-play-` can find it.
        element(episodeApp, "wilted-navigation-feeds").click()
        XCTAssertTrue(element(episodeApp, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        let keepEpisode = episodeApp.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keepEpisode.waitForExistence(timeout: 10))
        keepEpisode.click()
        element(episodeApp, "wilted-navigation-menu").click()
        XCTAssertTrue(element(episodeApp, "wilted-mac-menu-detail").waitForExistence(timeout: 10))

        let playEpisode = episodeApp.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-play-'")
        ).firstMatch
        XCTAssertTrue(playEpisode.waitForExistence(timeout: 10))
        playEpisode.click()
        element(episodeApp, "wilted-navigation-settings").click()

        let notes = element(episodeApp, "wilted-player-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        XCTAssertTrue(element(episodeApp, "wilted-player-notes-expanded").waitForExistence(timeout: 10))
        try write(episodeApp, "6.4-playback-fullwindow-notes", into: root)
        notes.click()

        // The episode's transcript is the publisher's own, so it is the one
        // surface that names who is speaking. The article fixture cannot show
        // this: text-to-speech has one voice and credits nobody.
        let episodeTranscript = element(episodeApp, "wilted-player-transcript")
        XCTAssertTrue(episodeTranscript.waitForExistence(timeout: 10))
        episodeTranscript.click()
        XCTAssertTrue(element(episodeApp, "wilted-now-playing-synced-transcript-cue-0")
            .waitForExistence(timeout: 10))
        try write(episodeApp, "6.5-playback-transcript-speakers", into: root)
        episodeApp.terminate()
    }

    /// Settings: appearance, podcast automation, sync, and the one
    /// automation pair that refuses to run.
    private func captureSettings(into root: URL) throws {
        let app = launch(["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"])
        XCTAssertTrue(element(app, "wilted-mac-menu-detail").waitForExistence(timeout: 15))
        element(app, "wilted-navigation-settings").click()
        XCTAssertTrue(element(app, "wilted-sync-controls").waitForExistence(timeout: 10))
        try write(app, "7.1-settings-with-playback", into: root)

        // The one settings state that refuses work. Ad removal is timed from
        // an aligned local pass, so pairing it with No local speech-to-text
        // makes every preparation fail before any model time is spent, and
        // neither control is disabled or rewritten -- the notice is all the
        // owner gets, which is why the walkthrough shows it rather than
        // describing it. A fixture launch has its own defaults domain, so
        // driving the picker here cannot reach the owner's own choice.
        let transcriptPolicy = element(app, "wilted-automation-transcript-policy")
        XCTAssertTrue(transcriptPolicy.waitForExistence(timeout: 10))
        transcriptPolicy.click()
        let noLocalSTT = app.menuItems["No local speech-to-text"]
        XCTAssertTrue(noLocalSTT.waitForExistence(timeout: 10))
        noLocalSTT.click()
        XCTAssertTrue(element(app, "wilted-automation-transcript-conflict").waitForExistence(timeout: 10))
        try write(app, "7.2-settings-transcript-conflict", into: root)
        app.terminate()
    }

    /// Recovery: a failed download offering retry from the Menu's Available
    /// group, and sync held in quarantine with its account-review control.
    private func captureRecovery(into root: URL) throws {
        let failure = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                              "--wilted-ui-fixture-download-failure"])
        XCTAssertTrue(element(failure, "wilted-mac-menu-detail").waitForExistence(timeout: 15))

        // Same reason as the Menu and Playback scenarios: the fixture
        // episode starts in the Feeds inbox until Keep puts it on the Menu.
        element(failure, "wilted-navigation-feeds").click()
        XCTAssertTrue(element(failure, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        let keepFailed = failure.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keepFailed.waitForExistence(timeout: 10))
        keepFailed.click()
        element(failure, "wilted-navigation-menu").click()
        XCTAssertTrue(element(failure, "wilted-mac-menu-detail").waitForExistence(timeout: 10))

        // `testUnpreparedEpisodeHasNoListeningActionAndTheMenuOwnsItsStep`
        // proves `wilted-menu-download-` exists after Keep under this same
        // fixture, so a miss here is a real regression, not a timing
        // question -- hardened to match the other scenarios rather than
        // silently writing a frame that never actually failed a download.
        let download = failure.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-download-'")
        ).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.click()
        let retry = failure.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-menu-retry-'")
        ).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        try write(failure, "8.1-recovery-download-retry", into: root)
        failure.terminate()

        let quarantined = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-quarantined"])
        let settings = element(quarantined, "wilted-navigation-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.click()
        XCTAssertTrue(element(quarantined, "wilted-sync-controls").waitForExistence(timeout: 10))
        try write(quarantined, "8.2-recovery-sync-quarantine", into: root)
        quarantined.terminate()
    }

    // MARK: - Capture

    /// Writes one inset PNG of the app's own window plus a geometry sidecar, so
    /// the report can state what region each frame covers instead of asserting
    /// it.
    private func write(_ app: XCUIApplication, _ name: String, into root: URL) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let shot = window.screenshot()
        let source = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
        let scale = source.pixelsWide > 0 ? CGFloat(source.pixelsWide) / max(window.frame.width, 1) : 2
        let inset = Int((8 * scale).rounded())
        let cropped = try XCTUnwrap(crop(source, by: inset))
        let png = try XCTUnwrap(cropped.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("\(name).png"))
        let sidecar = """
        {"name":"\(name)","window":{"x":\(window.frame.origin.x),"y":\(window.frame.origin.y),\
        "width":\(window.frame.width),"height":\(window.frame.height)},\
        "capturedPixels":{"width":\(source.pixelsWide),"height":\(source.pixelsHigh)},\
        "embeddedPixels":{"width":\(cropped.pixelsWide),"height":\(cropped.pixelsHigh)},\
        "insetPixelsPerEdge":\(inset)}
        """
        try Data(sidecar.utf8).write(to: root.appendingPathComponent("\(name).json"))
    }

    /// Writes one PNG of a popover plus its sidecar.
    ///
    /// A popover is a window of its own, so the main window's screenshot
    /// never contains it. The frame is the popover element's, uninset, and
    /// the sidecar says so with `"kind":"popover"`, which is how the report
    /// keeps these out of the one-geometry claim it makes for window frames.
    private func write(popover: XCUIElement, _ name: String, into root: URL) throws {
        XCTAssertTrue(popover.waitForExistence(timeout: 10))
        let shot = popover.screenshot()
        let source = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
        try shot.pngRepresentation.write(to: root.appendingPathComponent("\(name).png"))
        let sidecar = """
        {"name":"\(name)","kind":"popover","window":{"x":\(popover.frame.origin.x),"y":\(popover.frame.origin.y),\
        "width":\(popover.frame.width),"height":\(popover.frame.height)},\
        "capturedPixels":{"width":\(source.pixelsWide),"height":\(source.pixelsHigh)},\
        "embeddedPixels":{"width":\(source.pixelsWide),"height":\(source.pixelsHigh)},\
        "insetPixelsPerEdge":0}
        """
        try Data(sidecar.utf8).write(to: root.appendingPathComponent("\(name).json"))
    }

    /// Empties the capture directory before recording.
    ///
    /// The runner's fallback directory lives in its container and survives
    /// between runs, so a frame this run does not write would otherwise be
    /// served by whatever an earlier run left under the same name -- and a
    /// renamed frame would leave its predecessor behind for the generator's
    /// geometry pass to read. Stale evidence is the one thing this report
    /// cannot contain.
    private static func purge(_ directory: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where ["png", "json"].contains(file.pathExtension.lowercased()) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func crop(_ source: NSBitmapImageRep, by inset: Int) -> NSBitmapImageRep? {
        let width = source.pixelsWide - inset * 2
        let height = source.pixelsHigh - inset * 2
        guard width > 0, height > 0, let cgImage = source.cgImage,
              let cropped = cgImage.cropping(to: CGRect(x: inset, y: inset, width: width, height: height))
        else { return nil }
        return NSBitmapImageRep(cgImage: cropped)
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
