import AppKit
import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Feeds as the reader sees it: the view is hosted headlessly and its rendered text is read back, so
/// these count what is drawn, not what the source declares. SwiftUI vends no accessibility tree to a
/// hosted view with no assistive technology attached, so rendered text is the machine-readable form.
@MainActor
final class WiltedMacFeedsStructureTests: XCTestCase {
    private let arguments = ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]
    private let tall = CGSize(width: 1_000, height: 2_000)

    private func lines(_ model: WiltedMacModel) throws -> [(text: String, top: CGFloat)] {
        try WiltedMacHeadless.recognizedLines(WiltedMacFeedsView(model: model), size: tall)
    }

    func testRefreshKeepExplanationIsHelpRatherThanRepeatedInlineCopy() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let view = WiltedMacFeedsView(model: model)
        let text = try WiltedMacHeadless.recognizedText(view, size: tall).joined(separator: " ")
        XCTAssertFalse(text.contains("Refresh only admits metadata"), text)
        XCTAssertFalse(text.contains("Refresh adds metadata only"), text)
        XCTAssertFalse(text.contains("Download and preparation begin"), text)
        XCTAssertTrue(text.contains("Subscriptions"), text)
        try retainCopyEvidence(WiltedMacHeadless.render(view, size: tall), name: "feeds-inline-light")
        let help = try WiltedMacHeadless.recognizedText(view.refreshHelp, size: CGSize(width: 400, height: 300)).joined(separator: " ")
        XCTAssertTrue(help.contains("Refresh"), help)
        XCTAssertTrue(help.contains("Keep"), help)
        try retainCopyEvidence(WiltedMacHeadless.render(view.refreshHelp, size: CGSize(width: 400, height: 300)), name: "feeds-refresh-help-light")
        try retainCopyEvidence(WiltedMacHeadless.render(view.refreshHelp.environment(\.colorScheme, .dark), size: CGSize(width: 400, height: 300)), name: "feeds-refresh-help-dark")
    }

    private func retainCopyEvidence(_ bitmap: NSBitmapImageRep, name: String) throws {
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func index(of prefix: String, in lines: [(text: String, top: CGFloat)]) -> Int? {
        lines.firstIndex { $0.text.lowercased().hasPrefix(prefix.lowercased())
            || $0.text.lowercased().hasPrefix("> \(prefix.lowercased())") }
    }

    func testFeedsDrawsOneHeadingAndOneMessageWithOneUndoPerOperation() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.podcastOperationMessage = "Skipped Quiet Machines."
        model.undoableSkip = episode

        let shown = try lines(model).map(\.text)
        XCTAssertEqual(shown.filter { $0 == "Feeds" }.count, 1, "one Feeds heading: \(shown)")
        XCTAssertEqual(shown.filter { $0.contains("Skipped Quiet Machines") }.count, 1, "one operation message: \(shown)")
        XCTAssertEqual(shown.filter { $0.contains("Undo completion") }.count, 1, "one Undo: \(shown)")
        XCTAssertFalse(shown.contains { $0.hasPrefix("Last updated") }, "the label is Last refreshed")
    }

    func testRenderedSectionOrderIsOperationsThenSubscriptionsThenOffTheList() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let episode = try XCTUnwrap(model.feedsEpisodes.first)
        model.decideFeedEpisodes(.skip, episodes: [episode])
        await WiltedMacHeadless.drainDecisions(model)
        await WiltedMacHeadless.eventually("the skipped episode is off the list") { !model.skippedFeedEpisodes.isEmpty }

        let shown = try lines(model)
        let heading = try XCTUnwrap(index(of: "Feeds", in: shown), "\(shown.map(\.text))")
        let refreshed = try XCTUnwrap(index(of: "Last refreshed", in: shown), "\(shown.map(\.text))")
        let subscriptions = try XCTUnwrap(index(of: "Subscriptions", in: shown), "\(shown.map(\.text))")
        let offList = try XCTUnwrap(index(of: "Off the list", in: shown), "\(shown.map(\.text))")
        XCTAssertLessThan(heading, refreshed, "the heading, then the operation status")
        XCTAssertLessThan(refreshed, subscriptions, "active operations before subscriptions")
        XCTAssertLessThan(subscriptions, offList, "Off the list last")
        XCTAssertEqual(shown.map(\.text).filter { $0.localizedCaseInsensitiveContains("Off the list") }.count, 1)
    }

    func testPerFeedCountsExcludeRetiredAndHiddenEpisodes() async throws {
        let model = await WiltedMacHeadless.model(self, arguments)
        let base = try XCTUnwrap(model.episodes.first)
        let feedID = try XCTUnwrap(model.subscriptions.first?.id)
        func extra(_ id: String, retired: Bool = false) -> WiltedMacEpisode {
            var value = WiltedMacEpisode(
                id: id, title: id, feedTitle: base.feedTitle, summary: "", artworkURL: nil,
                releasedAt: base.releasedAt, durationSeconds: 60, playbackSeconds: 0, downloadState: .completed,
                preparationState: .prepared(summary: "Ready"))
            value.feedID = feedID
            if retired { value.retiredAt = Date() }
            return value
        }
        let retired = extra("extra-retired", retired: true)
        let hidden = extra("extra-hidden")
        let shown = extra("extra-shown")
        let before = model.larderEpisodeCount(forFeedID: feedID)
        for value in [retired, hidden, shown] { model.installEpisodeForTesting(value) }
        model.hiddenEpisodeIDs.insert(hidden.id)

        XCTAssertEqual(model.larderEpisodeCount(forFeedID: feedID), before + 1,
                       "only the visible, unretired episode is counted")
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertTrue(model.subscriptions.allSatisfy { board.isLoaded($0.id) })
        let kept = model.episodes.filter {
            $0.feedID == feedID && $0.removalKind == nil && model.podcastQueueIDs.contains($0.id)
        }.count
        XCTAssertEqual(board.keptCount(forFeed: feedID), kept)
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedsView(model: model, policyBoard: board), size: tall).joined(separator: " ")
        XCTAssertTrue(text.contains("\(kept) kept"), text)
        XCTAssertTrue(text.contains("No limit"), text)
        XCTAssertTrue(text.contains("0 waiting for space"), text)
        XCTAssertFalse(text.contains("Capacity loading"), text)
    }

    /// Capacity follows committed Keep/Skip/removal, while raw feed metadata retains all three records.
    func testCapacityRendersCommittedKeepRetirementAndDismissalExcludingRawMetadataCount() async throws {
        let fixture = try await WiltedMacCapacityCountFixture.make(self, autoKeep: .off)
        let model = fixture.model
        try await fixture.assertRendered(kept: 1, waiting: 0)
        let added = try XCTUnwrap(model.feedsEpisodes.first { $0.id == fixture.ids[1] })
        model.decideFeedEpisodes(.keep, episodes: [added])
        await WiltedMacHeadless.drainDecisions(model)
        await model.refreshPodcastQueueState()
        XCTAssertTrue(model.podcastQueueIDs.contains(added.id))
        try await fixture.assertRendered(kept: 2, waiting: 0)
        let retired = try XCTUnwrap(model.episodes.first { $0.id == fixture.ids[0] })
        model.decideFeedEpisodes(.skip, episodes: [retired])
        await WiltedMacHeadless.drainDecisions(model)
        await model.refreshPodcastQueueState()
        XCTAssertEqual(model.episodes.first { $0.id == retired.id }?.removalKind, .retired)
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == retired.id })
        try await fixture.assertRendered(kept: 1, waiting: 0)
        let dismissed = try XCTUnwrap(model.episodes.first { $0.id == added.id })
        model.removeEpisode(dismissed)
        await WiltedMacHeadless.drainDecisions(model)
        await model.refreshPodcastQueueState()
        XCTAssertFalse(model.podcastQueueIDs.contains(dismissed.id), "assert after the durable removal, not the optimistic hide")
        XCTAssertFalse(model.larderVisibleEpisodes.contains { $0.id == dismissed.id })
        try await fixture.assertRendered(kept: 0, waiting: 0)
    }

    func testKeepIsFilledAndSkipIsOutlined() throws {
        let components = try WiltedMacHeadless.viewSource("WiltedMacFeedsComponents.swift")
        XCTAssertTrue(components.contains(".buttonStyle(.borderedProminent)"), "Keep is the filled answer")
        XCTAssertTrue(components.contains(".buttonStyle(WiltedMacOutlinedButtonStyle())"), "Skip is outlined")
        XCTAssertTrue(components.contains("strokeBorder(leaf, lineWidth: 1)"))
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: ".buttonStyle(.bordered)", in: components), 0)
    }

    func testDownloadedFilterWithNothingDownloadedExplainsItself() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"])
        model.larderFilter = .downloaded
        XCTAssertTrue(model.larderEpisodes(in: .downloaded).isEmpty)
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacLarderView(model: model, paneMode: .side), size: CGSize(width: 1_000, height: 1_200))
        XCTAssertTrue(text.contains { $0.contains("Downloaded audio is empty") }, "\(text)")
    }

    func testAddFeedCountControlIsLabelledEpisodesListedWithFiveTenAndCustom() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(source.contains("Picker(\"Episodes listed\", selection: initialMetadataPreset)"))
        for option in ["Text(\"5\").tag(5)", "Text(\"10\").tag(10)", "Text(\"Custom\").tag(0)"] {
            XCTAssertTrue(source.contains(option), option)
        }
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "WiltedMacPodcastOperationMessage(model: model)", in: source), 1,
                       "the message component is mounted once")
    }
}

/// A real store-backed capacity snapshot shared by the count regressions; no fabricated board state.
@MainActor
struct WiltedMacCapacityCountFixture {
    let model: WiltedMacModel
    let feedID: String
    let ids: [String]

    static func make(_ test: XCTestCase, autoKeep: FeedAutomationOverride) async throws -> Self {
        let feedURL = URL(string: "https://fixtures.example.test/capacity.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let ids = try (0..<3).map { index in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "capacity-episode-\(index)",
                enclosureURL: URL(string: "https://fixtures.example.test/\(index).mp3")!)
        }
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: test.wiltedTemporaryDirectory("capacity-counts"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Capacity Feed", createdAt: timestamp))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: timestamp))
                for (index, id) in ids.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: "capacity-episode-\(index)",
                        title: "Capacity episode \(index)", publishedTime: Timestamp(timestamp.date.addingTimeInterval(Double(index))),
                        enclosureURL: URL(string: "https://fixtures.example.test/\(index).mp3")!,
                        enclosureMediaType: "audio/mpeg", createdAt: timestamp))
                }
                try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [ids[0]], currentEpisodeID: nil))
                try await store.save(episodeDecision: .init(
                    episodeID: ids[0], decision: .keep, source: .manual, decidedAt: timestamp))
                try await store.save(feedAutomationPolicy: .init(
                    autoKeep: autoKeep, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(2)), for: feedID)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        test.addTeardownBlock { await model.close() }
        XCTAssertEqual(model.startupState, .ready, "the seeded store must finish real bootstrap")
        let store = try XCTUnwrap(model.store, "bootstrap must publish the seeded store")
        let snapshot = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(Set(snapshot.episodes.map(\.itemID)), Set(ids))
        XCTAssertEqual(Set(model.episodes.map(\.id)), Set(ids.map(\.rawValue)),
                       "real bootstrap must load the seeded episodes before capacity reload")
        return Self(model: model, feedID: feedID.rawValue, ids: ids.map(\.rawValue))
    }

    func assertRendered(kept: Int, waiting: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(model.startupState, .ready, file: file, line: line)
        _ = try XCTUnwrap(model.store, "capacity reload requires a booted real store", file: file, line: line)
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertTrue(board.isLoaded(feedID), file: file, line: line)
        XCTAssertEqual(board.keptCount(forFeed: feedID), kept, file: file, line: line)
        XCTAssertEqual(board.waitingEpisodes(forFeed: feedID).count, waiting, file: file, line: line)
        XCTAssertEqual(model.subscriptions.first { $0.id == feedID }?.episodeCount, 3, "raw snapshot retains every metadata row", file: file, line: line)
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedsView(model: model, policyBoard: board).environment(\.wiltedTextScale, .largest),
            size: CGSize(width: 1000, height: 2000)).joined(separator: " ")
        XCTAssertTrue(text.contains("\(kept) of 2 kept"), text, file: file, line: line)
        XCTAssertTrue(text.contains("\(waiting) waiting for space"), text, file: file, line: line)
        XCTAssertFalse(text.contains("3 of 2 kept"), "raw snapshot count must never masquerade as kept capacity: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("Capacity loading"), text, file: file, line: line)
    }
}
