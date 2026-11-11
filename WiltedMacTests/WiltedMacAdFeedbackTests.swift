import AppKit
import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// The Mac's ad feedback: the entry a press becomes, the review inbox's file, the Now Playing
/// acknowledgement and Undo, and a phone's `adFeedback` intent reaching the inbox.
@MainActor
final class WiltedMacAdFeedbackTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    func testLoadedPodcastWithoutTimelineStillOffersAdHere() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        addTeardownBlock { await model.close() }
        XCTAssertFalse(model.offersAdFeedback, "a revision must actually be loaded")
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        model.removedSpansByEpisode[episode.id] = nil

        XCTAssertTrue(model.offersAdFeedback, "missing cut metadata must not hide missed-ad reporting")
        XCTAssertNil(model.adFeedbackNearbyCut, "no cut-specific verdict without a known cut")
        model.removedSpansByEpisode[episode.id] = []
        XCTAssertTrue(model.offersAdFeedback, "a known empty cut list also permits Ad here")
        model.currentPodcastEpisodeID = "another-episode"
        XCTAssertFalse(model.offersAdFeedback, "selection must match the loaded audio")
        model.currentPodcastEpisodeID = episode.id
        model.isPodcastPlayback = false
        XCTAssertFalse(model.offersAdFeedback, "non-podcast playback still has no ad feedback")
    }

    func testAdHereWithoutTimelineFilesTheLiveRevisionAndUnmappedPosition() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        addTeardownBlock { await model.close() }
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let revisionID = try XCTUnwrap(model.playback?.revisionID)
        model.removedSpansByEpisode[episode.id] = nil
        // A failed metadata read must not prevent filing what the listener heard.
        model.store = nil
        backend.currentTime = 7.25
        model.playbackPositionSeconds = 500

        await model.recordAdFeedback(.adHere)

        let saved = try XCTUnwrap(model.adFeedback.counted.last)
        XCTAssertEqual(saved.itemID, episode.id)
        XCTAssertEqual(saved.revisionID, revisionID.rawValue)
        XCTAssertEqual(saved.playedSeconds, 7.25)
        XCTAssertEqual(saved.mapping, .unmapped)
        XCTAssertNil(saved.originalSeconds)
        XCTAssertNil(saved.nearestCut)
    }

    func testMissingTimelineRendersAdHereWithoutCutVerdicts() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        addTeardownBlock { await model.close() }
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        model.removedSpansByEpisode[episode.id] = nil
        let bar = WiltedMacAdFeedbackBar(model: model)
            .padding(12)
            .frame(width: 420, height: 64)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let words = try WiltedMacHeadless.recognizedText(bar, size: CGSize(width: 420, height: 64))
            .joined(separator: " ").lowercased()
        XCTAssertTrue(words.contains("ad here"), words)
        XCTAssertFalse(words.contains("good cut"), words)
        XCTAssertFalse(words.contains("not an ad"), words)
        let bitmap = try WiltedMacHeadless.render(bar, size: CGSize(width: 420, height: 64))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "ad-here-without-timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A narrow window has no side pane: the rail and the full-window player are then the only
    /// players on screen, and each must offer Ad here.
    func testNarrowWindowPlayersOfferAdHere() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        addTeardownBlock { await model.close() }
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        let width = WiltedMacShellLayout.windowMinimumWidth() - WiltedMacShellLayout.railWidth
        let players: [(String, AnyView, CGFloat)] = [
            ("rail", AnyView(WiltedMacCompactPlayer(model: model)), 300),
            ("full-window", AnyView(WiltedMacFullWindowPlayer(
                model: model, presentation: .constant(.transcript), onSelect: { _ in }, onCollapse: { _ in })), 700),
        ]
        for (name, player, height) in players {
            let words = try WiltedMacHeadless.recognizedText(player, size: CGSize(width: width, height: height))
                .joined(separator: " ").lowercased()
            XCTAssertTrue(words.contains("ad here"), "\(name): \(words)")
            let bitmap = try WiltedMacHeadless.render(player, size: CGSize(width: width, height: height))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "ad-here-narrow-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Narrower than its one-row form, the bar wraps rather than pushing a button past the edge.
    func testAdFeedbackBarWrapsEveryButtonAtNarrowWidth() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        addTeardownBlock { await model.close() }
        await loadPausedThroughOwner(model, episode)
        await model.waitForPlaybackPresentationForTesting()
        model.removedSpansByEpisode[episode.id] = [WiltedMacRemovedSpan(
            id: 0, preparedSeconds: 0, originalStartSeconds: 0, originalEndSeconds: 30, label: "ad_break")]
        model.playbackPositionSeconds = 2
        XCTAssertNotNil(model.adFeedbackNearbyCut)
        let size = CGSize(width: 190, height: 140)
        let words = try WiltedMacHeadless.recognizedText(WiltedMacAdFeedbackBar(model: model), size: size)
            .joined(separator: " ").lowercased()
        for label in ["ad here", "good cut", "not an ad"] {
            XCTAssertTrue(words.contains(label), "\(label): \(words)")
        }
    }

    /// 0..<100 kept, 100..<160 cut, 160..<300 kept (prepared 100..<240).
    private func timeline() throws -> PreparationStatus.PreparationTimeline {
        try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 100, originalEndSeconds: 160, label: "ad_break", confidence: 0.9)],
            kept: [
                try .init(originalStartSeconds: 0, originalEndSeconds: 100, outputStartSeconds: 0),
                try .init(originalStartSeconds: 160, originalEndSeconds: 300, outputStartSeconds: 100),
            ])
    }

    private func entry(
        id: String = UUID().uuidString, kind: AdFeedbackKind = .goodCut, played: Double = 104,
        timeline: PreparationStatus.PreparationTimeline?, createdAt: Date? = nil
    ) throws -> WiltedMacAdFeedbackEntry {
        WiltedMacAdFeedbackEntry.make(
            id: id, kind: kind, itemID: try ItemID(rawValue: "item-a"), revisionID: try RevisionID(rawValue: "rev-1"),
            playedSeconds: played, timeline: timeline, engineVersion: "2.3.0", pipelineFingerprint: "fp",
            createdAt: createdAt ?? clock, deviceID: "mac", source: .mac, showTitle: "Show", episodeTitle: "Episode")
    }

    // MARK: The entry

    func testAPressJustAfterACutNamesThatCutOnTheOriginalClock() throws {
        let made = try entry(played: 104, timeline: timeline())
        XCTAssertEqual(made.mapping, .mapped)
        XCTAssertEqual(made.originalSeconds, 164)
        XCTAssertEqual(made.nearestCut?.originalStartSeconds, 100)
        XCTAssertEqual(made.nearestCut?.originalEndSeconds, 160)
        XCTAssertEqual(made.nearestCut?.distanceSeconds, 4, "positive: the press came after the seam")
        XCTAssertEqual(made.review, .accepted, "a press counts as soon as it is filed")
        XCTAssertTrue(made.counts)
        XCTAssertEqual(made.effectiveLabel, .mustCut)
        XCTAssertEqual(try entry(kind: .notAnAd, timeline: timeline()).effectiveLabel, .mustKeep)
    }

    func testAPressFarFromAnyCutHasNoNearestCut() throws {
        let made = try entry(kind: .adHere, played: 200, timeline: timeline())
        XCTAssertNil(made.nearestCut)
        XCTAssertEqual(made.originalSeconds, 260)
    }

    func testAPressPastTheEndIsClampedAndOneWithoutATimelineIsUnmapped() throws {
        XCTAssertEqual(try entry(played: 500, timeline: timeline()).mapping, .clamped)
        let unmapped = try entry(timeline: nil)
        XCTAssertEqual(unmapped.mapping, .unmapped)
        XCTAssertNil(unmapped.originalSeconds)
        XCTAssertNil(unmapped.nearestCut)
    }

    // MARK: The inbox file

    func testTheInboxSurvivesReopeningAndFilesAnIDOnce() async throws {
        let url = wiltedTemporaryDirectory("inbox").appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let first = try entry(id: "one", timeline: timeline())
        let inbox = WiltedMacAdFeedbackInbox(fileURL: url)
        try await inbox.add(first)
        try await inbox.add(first)
        try await inbox.add(entry(id: "two", timeline: nil, createdAt: clock.addingTimeInterval(60)))

        let reopened = WiltedMacAdFeedbackInbox(fileURL: url)
        let ids = await reopened.all().map(\.id)
        XCTAssertEqual(ids, ["two", "one"], "newest first, each id once")
        let oldest = await reopened.all().last
        XCTAssertEqual(oldest, first)
    }

    func testReviewAndUndoAreSaved() async throws {
        let url = wiltedTemporaryDirectory("review").appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        let inbox = WiltedMacAdFeedbackInbox(fileURL: url)
        try await inbox.add(entry(id: "one", timeline: timeline()))
        try await inbox.add(entry(id: "two", timeline: timeline()))
        try await inbox.review(id: "one", as: .accepted, label: .acceptableCut, at: clock)
        try await inbox.remove(id: "two")

        let saved = await WiltedMacAdFeedbackInbox(fileURL: url).all()
        XCTAssertEqual(saved.map(\.id), ["one"])
        XCTAssertEqual(saved.first?.review, .accepted)
        XCTAssertEqual(saved.first?.label, .acceptableCut)
        XCTAssertEqual(saved.first?.reviewedAt, clock)

    }

    func testSettingsLabelsUseThePlayersWords() {
        typealias Label = WiltedMacAdFeedbackEntry.CorpusLabel
        XCTAssertEqual(Label.allCases.map(\.title), ["Ad", "Not an ad", "Either is fine"])
        XCTAssertEqual(Label.suggested(for: .notAnAd).title, AdFeedbackKind.notAnAd.title)
        XCTAssertEqual(Label.suggested(for: .goodCut).title, "Ad")
    }

    func testAPendingPressFromAnOlderFileCounts() async throws {
        let directory = wiltedTemporaryDirectory("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        var old = try entry(id: "old", timeline: timeline())
        old.review = .pending
        let encoded = try String(decoding: WiltedMacAdFeedbackInbox.encoder.encode([old]), as: UTF8.self)
        try Data("{\"version\":1,\"entries\":\(encoded)}".utf8).write(to: url)
        let loaded = await WiltedMacAdFeedbackInbox(fileURL: url).all()
        XCTAssertEqual(loaded.map(\.review), [.accepted])
    }

    func testAnUnreadableInboxIsSetAsideNotOverwritten() async throws {
        let directory = wiltedTemporaryDirectory("corrupt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        try Data("{\"version\":2,\"entries\":[]}".utf8).write(to: url)

        let inbox = WiltedMacAdFeedbackInbox(fileURL: url)
        let afterSetAside = await inbox.all()
        XCTAssertTrue(afterSetAside.isEmpty)
        let aside = url.appendingPathExtension("unreadable")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{\"version\":2,\"entries\":[]}")
        try await inbox.add(entry(id: "fresh", timeline: nil))
        let fresh = await WiltedMacAdFeedbackInbox(fileURL: url).all().map(\.id)
        XCTAssertEqual(fresh, ["fresh"])
    }

    func testAFailedWriteKeepsTheInboxAsItWas() async throws {
        let inbox = WiltedMacAdFeedbackInbox(fileURL: wiltedTemporaryDirectory("fail").appendingPathComponent("x.json"),
                                             write: { _, _ in throw POSIXError(.ENOSPC) })
        do {
            try await inbox.add(entry(timeline: nil))
            XCTFail("the write failed")
        } catch {}
        let unchanged = await inbox.all()
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testTheFileHoldsNoTranscriptText() async throws {
        let url = wiltedTemporaryDirectory("shape").appendingPathComponent(WiltedMacAdFeedbackInbox.fileName)
        try await WiltedMacAdFeedbackInbox(fileURL: url).add(entry(id: "one", timeline: timeline()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let saved = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(saved.keys), [
            "id", "kind", "itemID", "revisionID", "playedSeconds", "originalSeconds", "mapping", "nearestCut",
            "engineVersion", "pipelineFingerprint", "createdAt", "deviceID", "source", "showTitle", "episodeTitle", "review",
        ])
    }

    // MARK: The press and Undo

    func testAPressIsAcknowledgedAtOnceAndUndoTakesItBack() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(fileURL: nil))
        feedback.acknowledge(entryID: "p", kind: .adHere, playedSeconds: 754)
        XCTAssertEqual(feedback.acknowledgement?.text, "Ad here marked at 12:34")
        XCTAssertTrue(feedback.isSaving)
        await feedback.undo()
        XCTAssertNotNil(feedback.acknowledgement, "nothing to take back while it is still saving")

        await feedback.file(try entry(id: "p", kind: .adHere, timeline: nil))
        feedback.pressFinished()
        XCTAssertEqual(feedback.counted.map(\.id), ["p"])
        await feedback.undo()
        XCTAssertNil(feedback.acknowledgement)
        XCTAssertTrue(feedback.entries.isEmpty)
    }

    func testAFailedSaveSaysSoAndOffersNoUndo() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(
            fileURL: wiltedTemporaryDirectory("press-fail").appendingPathComponent("x.json"),
            write: { _, _ in throw POSIXError(.ENOSPC) }))
        feedback.acknowledge(entryID: "p", kind: .notAnAd, playedSeconds: 10)
        let filed = await feedback.file(try entry(id: "p", kind: .notAnAd, timeline: nil))
        feedback.pressFinished()
        XCTAssertFalse(filed)
        XCTAssertEqual(feedback.acknowledgement?.text, "Not an ad was not saved")
        XCTAssertEqual(feedback.acknowledgement?.saved, false)
        XCTAssertNotNil(feedback.saveFailure)
    }

    func testTheAcknowledgementGoesAwayByItself() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(fileURL: nil))
        feedback.acknowledgementDuration = .milliseconds(10)
        feedback.acknowledge(entryID: "p", kind: .goodCut, playedSeconds: 1)
        for _ in 0..<200 where feedback.acknowledgement != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(feedback.acknowledgement)
    }

    func testRelabelRemoveAndRestore() async throws {
        let feedback = WiltedMacAdFeedbackController(inbox: WiltedMacAdFeedbackInbox(fileURL: nil))
        feedback.now = { [clock] in clock }
        await feedback.file(try entry(id: "a", timeline: nil))
        await feedback.file(try entry(id: "b", timeline: nil, createdAt: clock.addingTimeInterval(1)))
        XCTAssertEqual(feedback.counted.map(\.id), ["b", "a"], "both count without any review")
        await feedback.relabel("a", as: .mustKeep)
        await feedback.remove("b")
        XCTAssertEqual(feedback.counted.map(\.id), ["a"])
        XCTAssertEqual(feedback.removed.map(\.id), ["b"])
        XCTAssertEqual(feedback.entries.first { $0.id == "a" }?.effectiveLabel, .mustKeep)
        await feedback.restore("b")
        XCTAssertEqual(Set(feedback.counted.map(\.id)), ["a", "b"])
        XCTAssertEqual(feedback.entries.first { $0.id == "b" }?.effectiveLabel, .mustCut, "restored with its default label")
    }

    // MARK: A phone's intent

    func testAPhoneFeedbackIntentIsFiledWhateverTheEntryAndAnsweredApplied() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let host = FakeDecisionHost()
        let applier = WiltedMacIntentApplier(
            host: host, ledger: WiltedMacIntentLedger(fileURL: nil, now: { [clock] in clock }),
            book: WiltedMacIntentOutcomeBook(fileURL: nil, now: { [clock] in clock }),
            transport: InMemoryLibraryTransport(deviceID: "mac", server: server), now: { [clock] in clock },
            onApplied: {})
        let old = try LibraryIntent.adFeedback(
            entryID: ItemID(rawValue: "item-unknown"), revisionID: RevisionID(rawValue: "rev-1"), kind: .adHere,
            playedSeconds: 30, deviceID: "iphone", createdAt: clock.addingTimeInterval(-30 * 24 * 3600), id: "f-1")

        try await applier.apply(old)
        host.filesFeedback = false
        try await applier.apply(LibraryIntent.adFeedback(
            entryID: ItemID(rawValue: "item-unknown"), revisionID: RevisionID(rawValue: "rev-1"), kind: .adHere,
            playedSeconds: 31, deviceID: "iphone", createdAt: clock, id: "f-2"))

        XCTAssertEqual(host.calls, ["adFeedback f-1", "adFeedback f-2"],
                       "an unknown entry and a month-old press still reach the inbox")
        let published = try await InMemoryLibraryTransport(deviceID: "iphone", server: server).intentOutcomes()
        let byID = Dictionary(uniqueKeysWithValues: published.map { ($0.intentID, $0) })
        XCTAssertEqual(byID["f-1"]?.disposition, .applied)
        XCTAssertEqual(byID["f-2"]?.reason, IntentOutcome.reasonFailed)
    }

    func testTheMacAdvertisesFeedbackToThePhone() {
        XCTAssertTrue(WiltedMacLibraryPublisher.supportedIntentActions.contains("adFeedback"))
    }
}
