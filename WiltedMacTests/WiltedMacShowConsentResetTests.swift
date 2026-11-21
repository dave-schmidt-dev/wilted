import XCTest
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacShowConsentResetTests: XCTestCase {
    func testBoardReloadReadsChangesMadeFromAnotherShowSettingsEntryPoint() async {
        let defaults = WiltedMacTestPreferences.ephemeral()
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("show-reload"),
            preferences: defaults
        )
        addTeardownBlock { await model.close() }
        let board = WiltedMacFeedPolicyBoard(model: model)
        let other = WiltedMacFeedPolicyBoard(model: model)
        other.loadForPreview(feedID: "show", isArticleFeed: false, isNews: false)
        XCTAssertTrue(other.setAdFree(true, for: "show"))
        XCTAssertTrue(other.setRemoveSelfPromotion(true, for: "show"))
        await board.reload()
        XCTAssertTrue(board.isAdFree("show"))
        XCTAssertTrue(board.removesSelfPromotion("show"))
    }

    func testConfirmedShowKeepsConsentWhenGlobalRemoveAdsIsOff() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("consent-route"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let defaults = model.preferences
        let consent = AdLabellerPreferences(preferences: defaults)
        consent.isEnabled = true
        consent.setConfirmed(feedID: "public", true)
        addTeardownBlock { await model.close() }
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/morning.xml"))
        model.subscriptions = [.init(id: "public", title: "Morning", feedURL: url, episodeCount: 0,
                                     subscribedAt: Date(timeIntervalSince1970: 0), enabled: true)]
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .bestAvailable, removeAds: false
        ))
        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true })
        XCTAssertTrue(board.sendsForAdFinding("public"))
        XCTAssertEqual(board.adRoute(for: "public"), .notSent(.adRemovalOff))
    }

    func testResetAllOnRefusedAndNewShowsPreservesBothRawConsentLists() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("reset-all-refused"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let defaults = model.preferences
        let confirmed = "wilted.adLabeller.confirmedFeedIDs"
        let refused = "wilted.adLabeller.localOnlyFeedIDs"
        defaults.set(["both", "other"], forKey: confirmed)
        defaults.set(["both", "refused"], forKey: refused)
        defaults.set(["both", "other"], forKey: "wilted.feeds.adFree")
        addTeardownBlock { await model.close() }
        let board = WiltedMacFeedPolicyBoard(model: model)
        for id in ["both", "refused", "new"] {
            board.loadForPreview(feedID: id, isArticleFeed: false, isNews: false)
            XCTAssertTrue(board.update(id, autoKeep: .off))
            board.resetAllOverrides(for: id)
            XCTAssertEqual(board.explicitOverrideCount(for: id), 0)
            XCTAssertFalse(board.sendsForAdFinding(id))
            XCTAssertEqual(defaults.stringArray(forKey: confirmed), ["both", "other"])
            XCTAssertEqual(defaults.stringArray(forKey: refused), ["both", "refused"])
            XCTAssertEqual(defaults.stringArray(forKey: "wilted.feeds.adFree"), ["other"])
            XCTAssertFalse(AdLabellerPreferences(preferences: defaults).isEnabled)
        }
    }

    func testResetAdFindingRevokesOnlyAnEffectiveOptInAndPreservesRefusals() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("consent-reset"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let defaults = model.preferences
        let confirmed = "wilted.adLabeller.confirmedFeedIDs"
        let refused = "wilted.adLabeller.localOnlyFeedIDs"
        defaults.set(["both", "control", "other"], forKey: confirmed)
        defaults.set(["both", "refused"], forKey: refused)
        addTeardownBlock { await model.close() }
        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true })
        for id in ["both", "refused", "new", "control"] {
            board.loadForPreview(feedID: id, isArticleFeed: false, isNews: false)
            board.resetAdFinding(for: id)
            XCTAssertFalse(board.sendsForAdFinding(id))
            XCTAssertEqual(defaults.stringArray(forKey: refused), ["both", "refused"])
            XCTAssertEqual(defaults.stringArray(forKey: confirmed),
                           id == "control" ? ["both", "other"] : ["both", "control", "other"])
        }
    }
}
