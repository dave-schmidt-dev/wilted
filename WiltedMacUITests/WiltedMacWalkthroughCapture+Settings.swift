import XCTest

extension WiltedMacWalkthroughCapture {
    /// Settings, including which episodes require local transcription.
    func captureSettings(into root: URL) throws {
        // The library publisher's card, as a Development build shows it, from its no-network fixture.
        let app = launch(["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts",
                          "--wilted-ui-fixture-library-sync", "sent"])
        XCTAssertTrue(element(app, "wilted-mac-larder-detail").waitForExistence(timeout: 15))
        element(app, "wilted-navigation-settings").click()
        XCTAssertTrue(element(app, "wilted-mac-settings").waitForExistence(timeout: 10))
        try write(app, "7.1-settings-with-playback", into: root)

        // The fixture's Remove ads setting is on. Only episodes that need an
        // ad check require local speech-to-text.
        element(app, "wilted-settings-tab-ads-providers").click()
        XCTAssertTrue(element(app, "wilted-automation-ad-marker").waitForExistence(timeout: 10))
        element(app, "wilted-settings-tab-listening").click()
        let transcriptPolicy = element(app, "wilted-automation-transcript-policy")
        XCTAssertTrue(transcriptPolicy.waitForExistence(timeout: 10))
        transcriptPolicy.click()
        let noLocalSTT = app.menuItems["No local speech-to-text"]
        XCTAssertTrue(noLocalSTT.waitForExistence(timeout: 10))
        noLocalSTT.click()
        let explanation = element(app, "wilted-automation-transcript-explanation")
        XCTAssertTrue(explanation.waitForExistence(timeout: 10))
        let copy = [explanation.label, explanation.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(copy.contains("Episodes that need an ad check"), copy)
        XCTAssertTrue(copy.contains("can still prepare"), copy)
        try write(app, "7.2-settings-transcript-conflict", into: root)
        app.terminate()
    }

    /// Recovery: a failed download offering retry from the Larder's Available
    /// group, and library sync held for account review with its review control.
    func captureRecovery(into root: URL) throws {
        let failure = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                              "--wilted-ui-fixture-download-failure"])
        XCTAssertTrue(element(failure, "wilted-mac-larder-detail").waitForExistence(timeout: 15))

        // Same reason as the Larder and Playback scenarios: the fixture
        // episode starts in the Feeds inbox until Keep puts it on the Larder.
        element(failure, "wilted-navigation-feeds").click()
        XCTAssertTrue(element(failure, "wilted-mac-feeds-detail").waitForExistence(timeout: 15))
        let keepFailed = failure.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-feeds-keep-'")
        ).firstMatch
        XCTAssertTrue(keepFailed.waitForExistence(timeout: 10))
        keepFailed.click()
        element(failure, "wilted-navigation-larder").click()
        XCTAssertTrue(element(failure, "wilted-mac-larder-detail").waitForExistence(timeout: 10))

        // `testEpisodeDecisionJourneyFromFeedsToLarder`
        // proves `wilted-larder-download-` exists after Keep under this same
        // fixture, so a miss here is a real regression, not a timing
        // question -- hardened to match the other scenarios rather than
        // silently writing a frame that never actually failed a download.
        let download = failure.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-download-'")
        ).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 15))
        download.click()
        let retry = failure.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'wilted-larder-retry-'")
        ).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 20))
        try write(failure, "8.1-recovery-download-retry", into: root)
        failure.terminate()

        // The library publisher holding a library after an account change, from its own fixture.
        let quarantined = launch(["--wilted-ui-fixture-ready", "--wilted-ui-fixture-library-sync", "switched"])
        let settings = element(quarantined, "wilted-navigation-settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.click()
        let settingsRoot = element(quarantined, "wilted-mac-settings")
        XCTAssertTrue(settingsRoot.waitForExistence(timeout: 10))
        element(quarantined, "wilted-settings-tab-library-sync").click()
        XCTAssertTrue(element(quarantined, "wilted-sync-review-account").waitForExistence(timeout: 10))
        XCTAssertEqual(element(quarantined, "wilted-sync-status").value as? String,
                       "Account changed. Library changes are held for review")
        XCTAssertFalse(element(quarantined, "wilted-sync-now").isEnabled)
        try write(quarantined, "8.2-recovery-sync-quarantine", into: root)
        quarantined.terminate()
    }
}
