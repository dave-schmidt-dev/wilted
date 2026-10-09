import Foundation
import SwiftUI
import UIKit
import Vision
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryContinuationTests: XCTestCase {
    private let entryID = try! ItemID(rawValue: "continue-episode")
    private let revision = try! RevisionID(rawValue: "continue-revision")
    private let now = Date(timeIntervalSince1970: 10_000)
    private let title = "A careful journey through the complete history of everyday listening with the final chapter fully visible"

    private func observed(epoch: Int = 2, date: TimeInterval = 9_800, playing: Bool = true,
                          device: String = "mac", published: TimeInterval = 500) throws -> ObservedPlayback {
        ObservedPlayback(record: try DevicePlaybackPosition(deviceID: device, entryID: entryID,
            revision: revision, positionSeconds: 120, isPlaying: playing, epoch: epoch,
            publishedAt: Date(timeIntervalSince1970: published)), serverModifiedAt: Date(timeIntervalSince1970: date))
    }

    private func plan(_ records: [ObservedPlayback], cached: RevisionID? = nil, offset: Double = 0) throws -> LibraryContinuation {
        try XCTUnwrap(LibraryContinuationPlanner.plan(records: LibraryDeviceRecords(nowPlaying: records), deviceID: "phone",
            cachedRevisions: cached.map { [entryID: $0] } ?? [:], durations: [:], now: now, clockOffset: offset))
    }

    // This searches the actual plan, so the old dropped timestamp fails at runtime rather than compilation.
    private func retainedSource(_ value: Any) -> ObservedPlayback? {
        if let source = value as? ObservedPlayback { return source }
        return Mirror(reflecting: value).children.compactMap { retainedSource($0.value) }.first
    }

    func testWinningRecordDateSurvivesTheReadyPlan() throws {
        let winner = try observed()
        XCTAssertEqual(retainedSource(try plan([winner], cached: revision)), winner)
    }

    func testHigherEpochRetainsOlderServerDateDespitePublisherClock() throws {
        let olderWinner = try observed(epoch: 9, date: 9_000, published: 99_999)
        let newerLoser = try observed(epoch: 8, date: 9_999, device: "other", published: 1)
        XCTAssertEqual(try plan([newerLoser, olderWinner], cached: revision).source, olderWinner)
    }

    func testEqualEpochChoosesServerDateRatherThanPublishedAt() throws {
        let winner = try observed(date: 9_990, published: 1)
        let loser = try observed(date: 9_980, device: "other", published: 999_999)
        XCTAssertEqual(try plan([winner, loser]).source, winner)
    }

    func testNeedsAudioAndCachedRevisionRefusalRetainOriginalObservation() throws {
        let source = try observed()
        let missing = try plan([source])
        guard case .needsAudio = missing else { return XCTFail("missing audio must be requested") }
        XCTAssertEqual(missing.source, source)
        let refused = try plan([source], cached: RevisionID(rawValue: "different"))
        guard case .refused = refused else { return XCTFail("wrong revision must be refused") }
        XCTAssertEqual(refused.source, source)
        XCTAssertTrue(LibraryContinuationAge(source: refused.source, now: now, clockOffset: 0).isStale)
    }

    func testStaleBoundaryUsesServerClockOffsetAndOriginalPlayingFlag() throws {
        let source = try observed(date: 10_100)
        let boundary = LibraryContinuationAge(source: source, now: now, clockOffset: 190)
        XCTAssertEqual(boundary.seconds, SyncCadence.staleAfter)
        XCTAssertFalse(boundary.isStale)
        XCTAssertTrue(LibraryContinuationAge(source: source, now: now, clockOffset: 190.01).isStale)
        let continuation = try plan([source], cached: revision, offset: 191)
        guard case let .ready(_, position, _, playing, _, _) = continuation else { return XCTFail("ready") }
        XCTAssertEqual(position, 120)
        XCTAssertFalse(playing)
        XCTAssertTrue(continuation.source.record.isPlaying, "normalization must not erase the original flag")
    }

    func testPausedOldCheckpointHasFactualAgeWithoutStaleDeviceClaim() throws {
        let source = try observed(date: 1_000, playing: false)
        let age = LibraryContinuationAge(source: source, now: now, clockOffset: 0)
        XCTAssertEqual(age.seconds, 9_000)
        XCTAssertFalse(age.isStale)
        XCTAssertTrue(age.text.contains("ago"))
    }

    func testFutureOrInvalidClockHasUncertainAge() throws {
        let source = try observed(date: 10_001)
        for offset in [0.0, Double.nan, Double.infinity] {
            let age = LibraryContinuationAge(source: source, now: now, clockOffset: offset)
            XCTAssertNil(age.seconds)
            XCTAssertFalse(age.isStale)
            XCTAssertEqual(age.text, "Mac playback position age uncertain.")
        }
    }

    func testOwnSupersedingRecordStillPreventsAnOffer() throws {
        let mac = try observed(epoch: 1)
        let own = try observed(epoch: 2, device: "phone")
        XCTAssertNil(LibraryContinuationPlanner.plan(records: LibraryDeviceRecords(nowPlaying: [mac, own]),
            deviceID: "phone", cachedRevisions: [entryID: revision], durations: [:], now: now, clockOffset: 0))
    }

    func testRefusalOverrideAndFreshOfferMismatchKeepWinningServerRecord() async throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        try await fixture.queue(["a"])
        try await fixture.offer("a")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: fixture.server, verifiedOwnerToken: "fixture-owner")
        let record = try DevicePlaybackPosition(deviceID: "mac", entryID: fixture.id("a"),
            revision: RevisionID(rawValue: "other-revision"), positionSeconds: 80, isPlaying: true,
            epoch: 5, publishedAt: Date(timeIntervalSince1970: 1))
        await fixture.server.setClock(now.addingTimeInterval(-200))
        try await mac.publish(record, as: .nowPlaying)
        await fixture.model.refresh()
        let original = try XCTUnwrap(fixture.model.continuation).source
        fixture.model.attachPlayer(fixture.makePlayer())
        // A newer server checkpoint must be the one retained after continueFromMac's fresh reread.
        await fixture.server.setClock(now.addingTimeInterval(-150))
        try await mac.publish(record, as: .nowPlaying)
        await fixture.model.continueFromMac()
        let refused = try XCTUnwrap(fixture.model.continuation)
        guard case .refused = refused else { return XCTFail("mismatching offer must refuse") }
        XCTAssertEqual(refused.source.serverModifiedAt, now.addingTimeInterval(-150))
        XCTAssertNotEqual(refused.source.serverModifiedAt, original.serverModifiedAt)
        let latest = try await mac.fetchDeviceRecords()
        await fixture.model.updateContinuation(from: latest)
        XCTAssertEqual(fixture.model.continuation?.source, refused.source, "persisted refusal must preserve the fresh winner")
        XCTAssertEqual(fixture.model.continuation?.source.record.isPlaying, true)
    }

    private func render(_ continuation: LibraryContinuation?, width: CGFloat, scheme: ColorScheme,
                        message: String? = nil) throws -> ContinuationCapture {
        try ContinuationCapture(LibraryContinueBannerContent(continuation: continuation, title: title,
            media: .available, message: message, now: now, clockOffset: 0, onContinue: {}), width: width, scheme: scheme)
    }

    func testShippingStaleBannerWrapsWholeTitleAgeAndActionAcrossPhoneMatrix() async throws {
        await HostedAccessibility.prepare()
        let continuation = try plan([observed()], cached: revision)
        for width: CGFloat in [320, 390] {
            for scheme: ColorScheme in [.light, .dark] {
                let capture = try render(continuation, width: width, scheme: scheme)
                XCTAssertTrue(capture.compactText.contains(ContinuationCapture.compact(title)), capture.text)
                XCTAssertTrue(capture.compactText.contains("continuefrommac"), capture.text)
                XCTAssertTrue(capture.compactText.contains("macplaybackposition"), capture.text)
                XCTAssertTrue(capture.compactText.contains("macplaybackmaybeoutofdate"), capture.text)
                capture.attach("continue-stale-\(Int(width))-\(scheme)")
                let hosted = HostedView(LibraryContinueBannerContent(continuation: continuation, title: title,
                    media: .onPhone, message: nil, now: now, clockOffset: 0, onContinue: {}),
                    size: CGSize(width: width, height: 568), dark: scheme == .dark)
                let button = try XCTUnwrap(hosted.element("wilted-handoff-continue"))
                XCTAssertGreaterThanOrEqual(button.frame.height, WiltedTheme.Spacing.minimumTouchTarget - 0.001)
                XCTAssertGreaterThanOrEqual(button.frame.width, WiltedTheme.Spacing.minimumTouchTarget - 0.001)
                XCTAssertTrue(hosted.window.bounds.contains(button.frame), "action must stay fully visible")
            }
        }
    }

    func testShippingFutureAndRefusedBannerRenderTruthfulAgeAtSmallWidths() throws {
        for (width, scheme): (CGFloat, ColorScheme) in [(320, .dark), (390, .light)] {
            let future = try plan([observed(date: 10_060)])
            let capture = try render(future, width: width, scheme: scheme)
            XCTAssertTrue(capture.compactText.contains(ContinuationCapture.compact(title)), capture.text)
            XCTAssertTrue(capture.compactText.contains("ageuncertain"), capture.text)
            XCTAssertTrue(capture.compactText.contains("getaudioandcontinue"), capture.text)
            XCTAssertFalse(capture.compactText.contains("outofdate"), capture.text)
            capture.attach("continue-future-\(Int(width))-\(scheme)")
            let refused = try plan([observed()], cached: RevisionID(rawValue: "wrong"))
            let refusal = try render(refused, width: width, scheme: scheme)
            XCTAssertTrue(refusal.compactText.contains("differentversion"), refusal.text)
            XCTAssertTrue(refusal.compactText.contains("macplaybackposition"), refusal.text)
            XCTAssertTrue(refusal.compactText.contains("outofdate"), refusal.text)
            XCTAssertFalse(refusal.compactText.contains("continuefrommac"), refusal.text)
            refusal.attach("continue-refused-\(Int(width))-\(scheme)")
        }
    }

    func testMessageOnlyBannerAndInFlightAudioPreserveExistingActionSemantics() throws {
        let capture = try render(nil, width: 320, scheme: .light, message: "Handoff is unavailable. Check your connection.")
        XCTAssertTrue(capture.compactText.contains("handoffisunavailable"), capture.text)
        XCTAssertFalse(capture.compactText.contains("macplaybackposition"), capture.text)
        let missing = try plan([observed()])
        XCTAssertNil(LibraryContinueBanner.actionTitle(missing, media: .requested(since: now)))
        XCTAssertEqual(LibraryContinueBanner.actionTitle(missing, media: .available), "Get audio and continue")
        let stale = try render(missing, width: 320, scheme: .light)
        XCTAssertTrue(stale.compactText.contains("outofdate"), stale.text)
        stale.attach("continue-needs-audio-stale-320-light")
    }

    func testShippingLongTitleRemainsCompleteAt320() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let sourceID = try ItemID(rawValue: "continue-show")
        let pushed = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .source(LibrarySource(id: sourceID, kind: .podcastFeed, title: "Show")), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .entry(try LibraryEntry(id: entryID, kind: .podcastEpisode,
                sourceID: sourceID, title: title, summary: "", publishedAt: now)), baseVersion: 0)])
        XCTAssertTrue(pushed.failures.isEmpty)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("continue-red-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "continue-red-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = LibraryAppModel(transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            deviceID: "phone", mediaCache: FileMediaCache(rootURL: scratch), preferences: preferences)
        await model.refresh()
        await model.updateContinuation(from: LibraryDeviceRecords(nowPlaying: [try observed()]))
        let capture = try ContinuationCapture(LibraryContinueBanner(model: model), width: 320, scheme: .light)
        XCTAssertTrue(capture.compactText.contains(ContinuationCapture.compact(title)), capture.text)
        XCTAssertTrue(capture.compactText.contains("getaudioandcontinue"), capture.text)
        capture.attach("continue-model-320-light")
    }
}

@MainActor
private struct ContinuationCapture {
    let image: UIImage
    let observations: [VNRecognizedTextObservation]
    var text: String { observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") }
    var compactText: String { Self.compact(text) }
    static func compact(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }

    init<Content: View>(_ content: Content, width: CGFloat, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: content.frame(width: width)
            .tint(WiltedTheme.color(.wiltedLeaf, scheme: scheme))
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US")))
        renderer.scale = 2
        image = try XCTUnwrap(renderer.uiImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
        observations = request.results ?? []
        XCTAssertEqual(image.size.width, width, accuracy: 0.1)
        for line in observations {
            XCTAssertGreaterThan(line.boundingBox.minX, 0)
            XCTAssertLessThan(line.boundingBox.maxX, 1)
            XCTAssertGreaterThan(line.boundingBox.minY, 0)
            XCTAssertLessThan(line.boundingBox.maxY, 1)
        }
    }
    func attach(_ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { activity in
            activity.add(attachment)
            let evidence = XCTAttachment(string: "size=\(image.size) OCR=\(text) bounds=\(observations.map { $0.boundingBox })")
            evidence.name = name + "-ocr-geometry"
            evidence.lifetime = .keepAlways
            activity.add(evidence)
        }
    }
}
