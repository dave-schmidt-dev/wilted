import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacShowSettingsAdmissionTests: XCTestCase {
    private struct Show: Sendable {
        let name: String
        var publisher = "Morning edition"
        var displayName: String?
        var confirmed = false
        var refused = false
        var adFree = false
        var ownPromotion = false
        var tokenAddress = false

        var url: URL {
            let path = tokenAddress ? "abcdefghijklmnopqrstuvwxyz0123456789" : name
            return URL(string: "https://feeds.example.test/\(path).xml")!
        }
        var feedID: ItemID { get throws { try ItemID.derivePodcastFeed(from: url) } }
    }

    func testShowSettingsPreservesStoredConsentAndAdmittedJobFlags() async throws {
        let shows = [
            Show(name: "ad-free", confirmed: true, adFree: true),
            Show(name: "own-promotion", confirmed: true, adFree: true, ownPromotion: true),
            Show(name: "both", confirmed: true, refused: true),
            Show(name: "local-only", refused: true),
            Show(name: "publisher-plus", publisher: "Morning Plus", confirmed: true),
            Show(name: "custom-plus", displayName: "Morning Plus", confirmed: true),
            Show(name: "credentialed-audio", confirmed: true),
            Show(name: "token", confirmed: true, tokenAddress: true),
            Show(name: "unknown", confirmed: true),
            Show(name: "new"),
            Show(name: "public", confirmed: true)
        ]
        let defaults = WiltedMacTestPreferences.ephemeral()
        AdLabellerPreferences(preferences: defaults).isEnabled = true
        let seed = [
            "wilted.adLabeller.confirmedFeedIDs": try shows.filter(\.confirmed).map { try $0.feedID.rawValue },
            "wilted.adLabeller.localOnlyFeedIDs": try shows.filter(\.refused).map { try $0.feedID.rawValue },
            "wilted.feeds.adFree": try shows.filter(\.adFree).map { try $0.feedID.rawValue },
            "wilted.feeds.removeSelfPromotion": try shows.filter(\.ownPromotion).map { try $0.feedID.rawValue }
        ]
        for (key, ids) in seed { defaults.set(ids, forKey: key) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("show-policy-admission"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                for show in shows where show.name != "unknown" {
                    let id = try show.feedID
                    try await store.save(feed: try PodcastFeed(
                        itemID: id, canonicalURL: show.url, title: show.publisher, createdAt: Timestamp(now)
                    ))
                    try await store.save(subscription: PodcastSubscription(
                        feedID: id, subscribedAt: Timestamp(now), displayName: show.displayName
                    ))
                }
                return store
            }, preferences: defaults
        )
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let hour = Calendar.current.component(.hour, from: now)
        let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: (hour + 2) % 24, minute: 0))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: (hour + 3) % 24, minute: 0))
        let window = try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(window),
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let board = WiltedMacFeedPolicyBoard(model: model, hasProviderKey: { true })
        await board.reload()
        for show in shows {
            let id = try show.feedID.rawValue
            if show.name != "unknown" {
                let subscription = try XCTUnwrap(model.subscriptions.first { $0.id == id })
                XCTAssertTrue(board.isLoaded(id))
                _ = try WiltedMacHeadless.render(
                    WiltedMacShowSettingsView(model: model, board: board, subscription: subscription)
                )
                XCTAssertEqual(board.sendsForAdFinding(id), show.confirmed && !show.refused, show.name)
                XCTAssertEqual(board.isAdFree(id), show.adFree, show.name)
                XCTAssertEqual(board.removesSelfPromotion(id), show.ownPromotion, show.name)
                if show.name == "public" { XCTAssertEqual(board.adRoute(for: id), .remote) }
                if show.name == "publisher-plus" || show.name == "custom-plus" {
                    XCTAssertEqual(board.adRoute(for: id), .remote)
                }
            }
            let episode = WiltedMacEpisode(
                id: "episode-\(show.name)", title: "Bulletin", feedTitle: show.displayName ?? show.publisher,
                summary: "", artworkURL: nil, releasedAt: now, durationSeconds: 600, playbackSeconds: 0,
                downloadState: .completed, feedID: id
            )
            model.admitAutomaticPreparation(for: episode, at: now)
            let saved = WiltedMacModel.loadDeferredAutomaticPreparations(from: defaults)
            let job = try XCTUnwrap(saved.first { $0.episodeID == episode.id })
            XCTAssertEqual(job.policySnapshot.removeAds, !show.adFree, show.name)
            XCTAssertEqual(job.policySnapshot.removeSelfPromotion, show.ownPromotion && !show.adFree, show.name)
            for (key, ids) in seed { XCTAssertEqual(defaults.stringArray(forKey: key), ids, show.name) }
        }
    }
}
