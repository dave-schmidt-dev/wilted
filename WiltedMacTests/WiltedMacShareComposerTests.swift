import AppKit
import CryptoKit
import WiltedDomain
import WiltedLibrary
import WiltedCloudKit
import Foundation
import SwiftUI
import XCTest
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacShareComposerTests: XCTestCase {
    private var suiteNames: [String] = []
    private var models: [WiltedMacModel] = []

    override func tearDown() async throws {
        for model in models { await model.close() }
        models.removeAll()
        suiteNames.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        try await super.tearDown()
    }

    func testSummaryDefaultsOffAndKeepsTheDirectShareControl() throws {
        let model = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: false, position: 0, duration: 60)
        let source = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent.swift")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "wilted-player-share", in: source), 2)
        XCTAssertTrue(source.contains("WiltedMacShareComposer(model: model)"))
        let labels = try WiltedMacHeadless.recognizedText(
            WiltedMacPlaybackShareLink(model: model).padding(12), size: CGSize(width: 360, height: 100))
        XCTAssertFalse(labels.contains(where: { $0.localizedCaseInsensitiveContains("transcript summary") }), labels.description)
    }

    func testShareContextRefusesPresentationOnlyPlayback() async {
        let model = makeModel()
        model.installPlaybackStateForTesting(episode: episode(), isPlaying: false, position: 0, duration: 60)
        do {
            _ = try await model.captureShareContext()
            XCTFail("presentation state is not a loaded store revision")
        } catch { XCTAssertTrue(error is WiltedMacShareContextError) }
    }

    func testKnownServiceErrorsMapToSafeInlineCopy() {
        XCTAssertEqual(WiltedMacShareComposer.message(for: TranscriptSummaryError.modelUnavailable),
                       "Select an available local model and try again.")
        XCTAssertEqual(WiltedMacShareComposer.message(for: TranscriptSummaryError.malformedResponse),
                       "The local summary could not be verified. Try again.")
    }

    func testFourComposerStatesRenderThroughTheShippingPanel() throws {
        let states: [(String, String?, String?, (String, String, URL?)?)] = [
            ("off", nil, nil, nil),
            ("progress", "Summarizing locally…", nil, nil),
            ("preview", nil, nil, ("Full locally generated summary for review.", "Episode", URL(string: "https://example.test/episode"))),
            ("error", nil, "The local model is unavailable.", nil)
        ]
        for (name, progress, failure, preview) in states {
            let view = WiltedMacShareComposerPanel(includeSummary: .constant(name != "off"), progress: progress, failure: failure,
                preview: preview.map { (text: $0.0, title: $0.1, url: $0.2) }, onRetry: {}, onCancel: {},
                payload: { value in value.url.map { "\(value.text)\n\n\($0.absoluteString)" } ?? value.text })
            let text = try WiltedMacHeadless.recognizedText(view.padding(), size: CGSize(width: 430, height: 360)).joined(separator: " ")
            XCTAssertTrue(text.contains("Include transcript summary"), "\(name): \(text)")
            if let progress { XCTAssertTrue(text.replacingOccurrences(of: "...", with: "…").contains(progress), "\(name): \(text)") }
            if let failure { XCTAssertTrue(text.contains(failure), "\(name): \(text)") }
            if preview != nil { XCTAssertTrue(text.contains("Preview"), "\(name): \(text)") }
        }
    }

    func testActualLoadedTranscriptAndMetadataIgnoreConflictingBrowsedArticleAndNotes() async throws {
        let rig = try await realRig()
        rig.model.installPlaybackStateForTesting(episode: episode(), isPlaying: false, position: 0, duration: 60)
        let browsed = WiltedMacArticle(id: "browsed", title: "Unrelated article", source: "other",
            url: URL(string: "https://example.test/unrelated")!, isReady: true,
            durationSeconds: 30, createdAt: Date())
        rig.model.installPlaybackStateForTesting(article: browsed, isPlaying: false, position: 0, duration: 30)
        let context = try await rig.model.captureShareContext()
        XCTAssertEqual(context.transcript, rig.text)
        XCTAssertEqual(context.title, "Loaded store episode")
        XCTAssertEqual(context.shareURL, URL(string: "https://example.test/loaded"))
        let runner = ComposerRunner()
        let state = composer(rig, runner)
        state.presented = true; state.setIncludeSummary(true); await state.waitForCompletion()
        XCTAssertEqual(state.preview?.text, "Summary of: " + rig.text)
        XCTAssertEqual(state.preview?.title, "Loaded store episode")
        XCTAssertEqual(state.preview?.url, URL(string: "https://example.test/loaded"))
        XCTAssertFalse(try XCTUnwrap(state.preview).text.contains("Notes are not input"))
        let capturedTranscript = await runner.lastTranscript(); XCTAssertEqual(capturedTranscript, rig.text)
    }

    func testSameIdentityUsesCacheButTranscriptModelAndWorkerChangesRegenerate() async throws {
        let rig = try await realRig(); let runner = ComposerRunner(); let semantics = ComposerSemantic()
        let state = composer(rig, runner, semantics)
        state.presented = true; state.setIncludeSummary(true); await state.waitForCompletion()
        let calls1 = await runner.count(); XCTAssertEqual(calls1, 1); XCTAssertEqual(state.cachedCount, 1)
        state.setIncludeSummary(false); state.setIncludeSummary(true); await state.waitForCompletion()
        let calls2 = await runner.count(); XCTAssertEqual(calls2, 1, "second preview uses verified memory cache")
        try await rig.store.save(transcript: transcript(rig, text: "Changed actual transcript"))
        state.setIncludeSummary(false); state.setIncludeSummary(true); await state.waitForCompletion()
        let calls3 = await runner.count(); XCTAssertEqual(calls3, 2)
        try Data("changed synthetic model".utf8).write(to: rig.modelURL)
        state.setIncludeSummary(false); state.setIncludeSummary(true); await state.waitForCompletion()
        let calls4 = await runner.count(); XCTAssertEqual(calls4, 3)
        await semantics.set("worker-source-v2")
        state.setIncludeSummary(false); state.setIncludeSummary(true); await state.waitForCompletion()
        let calls5 = await runner.count(); XCTAssertEqual(calls5, 4)
        XCTAssertNotNil(state.preview); XCTAssertNil(state.failure)
    }

    func testCacheIsBoundedToEightAndLinklessPayloadContainsOnlyActualSummary() async throws {
        let rig = try await realRig(link: nil); let runner = ComposerRunner(); let state = composer(rig, runner)
        state.presented = true
        for index in 0..<10 {
            try await rig.store.save(transcript: transcript(rig, text: "Actual passage \(index)"))
            state.setIncludeSummary(true); await state.waitForCompletion(); state.setIncludeSummary(false)
        }
        let calls6 = await runner.count(); XCTAssertEqual(calls6, 10); XCTAssertEqual(state.cachedCount, 8)
        state.setIncludeSummary(true); await state.waitForCompletion()
        let preview = try XCTUnwrap(state.preview)
        XCTAssertNil(preview.url); XCTAssertEqual(state.payload(preview), preview.text)
        XCTAssertFalse(state.payload(preview).contains("https://"))
    }

    func testCancelDismissAndOptionOffRejectCancellationIgnoringLateReply() async throws {
        for mode in ["cancel", "dismiss", "off"] {
            let rig = try await realRig(); let runner = ComposerRunner(held: true); let state = composer(rig, runner)
            state.presented = true; state.setIncludeSummary(true); await runner.waitUntilHeld()
            if mode == "cancel" { state.cancel() }
            else if mode == "dismiss" { state.dismiss() }
            else { state.setIncludeSummary(false) }
            await runner.release(); await state.waitForCompletion()
            await Task.yield()
            XCTAssertNil(state.preview, mode); XCTAssertEqual(state.cachedCount, 0, mode)
            XCTAssertNil(state.activeID, mode)
        }
    }

    func testReloadAndDurableOwnerChangeWhileHeldCannotDisplayOrCache() async throws {
        for mode in ["reload", "owner", "close"] {
            let rig = try await realRig(); let runner = ComposerRunner(held: true); let state = composer(rig, runner)
            state.presented = true; state.setIncludeSummary(true); await runner.waitUntilHeld()
            if mode == "reload" {
                let replacement = PlaybackController(store: rig.store, backend: WiltedFixturePlaybackBackend())
                try await replacement.load(revision: rig.revision, mediaURL: rig.audioURL)
                rig.model.playback = replacement
            } else if mode == "owner" {
                try await rig.store.save(libraryAccountBinding: LocalLibraryAccountBinding(state: .bound, ownerToken: CloudKitAccountIdentity.token(for: "share-changed-synthetic-owner")))
            } else { await rig.model.close() }
            await runner.release(); await state.waitForCompletion()
            XCTAssertNil(state.preview, mode); XCTAssertEqual(state.cachedCount, 0, mode)
        }
    }

    func testLiveAccountCloseReopenGenerationInvalidatesHeldSummary() async throws {
        let rig = try await realRig(); let fixture = WiltedMacLibraryAccountFixture()
        let owner = CloudKitAccountIdentity.token(for: "share-synthetic-owner")
        try await rig.store.save(libraryAccountBinding: LocalLibraryAccountBinding(state: .bound, ownerToken: owner))
        let server = InMemoryLibraryServer(writerDeviceID: "share-test")
        let transport = InMemoryLibraryTransport(deviceID: "share-test", server: server, verifiedOwnerToken: owner)
        XCTAssertTrue(rig.model.startLibrarySyncIfEnabled(environment: ["WILTED_LIBRARY_SYNC": "1"], transport: transport,
                                                        debounce: .milliseconds(10), account: fixture.source))
        fixture.signIn(recordName: "share-synthetic-owner")
        await WiltedMacHeadless.eventually("active synthetic owner") { rig.model.libraryAccount?.status == .active }
        let runner = ComposerRunner(held: true); let state = composer(rig, runner)
        state.presented = true; state.setIncludeSummary(true); await runner.waitUntilHeld()
        let account = try XCTUnwrap(rig.model.libraryAccount)
        account.gate.close(); account.gate.reopen()
        await runner.release(); await state.waitForCompletion()
        XCTAssertNil(state.preview); XCTAssertEqual(state.cachedCount, 0)
    }

    func testLateProgressCannotReopenCompletedSuccessOrError() async throws {
        for fail in [false, true] {
            let rig = try await realRig(); let runner = ComposerRunner(fail: fail); let state = composer(rig, runner)
            state.presented = true; state.setIncludeSummary(true); await state.waitForCompletion()
            let preview = state.preview?.text; let failure = state.failure
            XCTAssertNil(state.activeID); XCTAssertNil(state.progress)
            if fail { XCTAssertNotNil(failure); XCTAssertNil(preview) }
            else { XCTAssertNotNil(preview); XCTAssertNil(failure) }
            await runner.emitLateProgress()
            for _ in 0..<5 { await Task.yield() }
            XCTAssertNil(state.progress, "late correlated progress must not recreate the spinner")
            XCTAssertEqual(state.preview?.text, preview); XCTAssertEqual(state.failure, failure)
            XCTAssertNil(state.activeID)
        }
    }

    func testFourShippingPanelPNGsAreRetained() throws {
        let states: [(String, String?, String?, (String, String, URL?)?)] = [
            ("off", nil, nil, nil), ("progress", "Summarizing locally…", nil, nil),
            ("preview", nil, nil, ("Full locally generated summary for review.", "Episode", nil)),
            ("error", nil, "The local model is unavailable.", nil)
        ]
        let size = CGSize(width: 430, height: 360)
        let page = WiltedTheme.color(.page, scheme: .light)
        for (name, progress, failure, preview) in states {
            let panel = WiltedMacShareComposerPanel(includeSummary: .constant(name != "off"), progress: progress, failure: failure,
                preview: preview.map { (text: $0.0, title: $0.1, url: $0.2) }, onRetry: {}, onCancel: {}, payload: { $0.text })
            let capture = ZStack(alignment: .topLeading) {
                page
                panel.padding()
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(page)
            .environment(\.colorScheme, .light)
            let bitmap = try WiltedMacHeadless.render(capture, size: size)
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width), "\(name): capture uses the full canvas width")
            XCTAssertEqual(bitmap.pixelsHigh, Int(size.height), "\(name): capture uses the full canvas height")
            let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThanOrEqual(corner.alphaComponent, 0.99, "\(name): page background covers the full capture")
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "share-summary-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private struct Rig {
        let model: WiltedMacModel; let store: LocalLibraryStore; let revision: AudioRevision
        let audioURL: URL; let modelURL: URL; let text: String
    }
    private func realRig(link: URL? = URL(string: "https://example.test/loaded")) async throws -> Rig {
        let model = makeModel(); model.startStoreBootstrap(); await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let directory = wiltedTemporaryDirectory("share-real-bytes")
        let audioURL = directory.appendingPathComponent("audio.m4a"); let bytes = Data([1, 2, 3])
        try bytes.write(to: audioURL)
        let modelURL = directory.appendingPathComponent("synthetic.gguf")
        try Data("synthetic model; no inference".utf8).write(to: modelURL)
        let feedURL = URL(string: "https://example.test/feed")!; let created = Timestamp(Date())
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let item = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "loaded",
            enclosureURL: URL(string: "https://example.test/audio")!)
        let revision = try AudioRevision(itemID: item, revisionID: RevisionID(rawValue: "rev-share"), durationSeconds: 60,
            byteCount: Int64(bytes.count), contentHash: "sha256:" + composerDigest(bytes), mediaType: "audio/mp4", createdAt: created, schemaVersion: 1)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        try await store.save(episode: PodcastEpisode(itemID: item, feedID: feedID, feedURL: feedURL, rssGUID: "loaded",
            title: "Loaded store episode", enclosureURL: URL(string: "https://example.test/audio")!, enclosureMediaType: "audio/mp4",
            notes: "Notes are not input.", episodeLink: link, createdAt: created))
        try await store.saveReadyRevision(revision, mediaURL: audioURL)
        let text = "Actual stored transcript café 水 🌱 ending."
        try await store.save(transcript: Transcript(itemID: item, revisionID: revision.revisionID,
            availability: .available, text: text, updatedAt: created))
        let controller = PlaybackController(store: store, backend: WiltedFixturePlaybackBackend())
        try await controller.load(revision: revision, mediaURL: audioURL); model.playback = controller
        return Rig(model: model, store: store, revision: revision, audioURL: audioURL, modelURL: modelURL, text: text)
    }
    private func transcript(_ rig: Rig, text: String) throws -> Transcript {
        try Transcript(itemID: rig.revision.itemID, revisionID: rig.revision.revisionID, availability: .available,
                       text: text, updatedAt: Timestamp(Date()))
    }
    private func composer(_ rig: Rig, _ runner: ComposerRunner, _ semantic: ComposerSemantic = ComposerSemantic()) -> WiltedMacShareComposerState {
        WiltedMacShareComposerState(model: rig.model, service: TranscriptSummaryService(runner: runner),
            configuration: .init(modelURL: rig.modelURL), fingerprint: { await semantic.value() })
    }

    private func makeModel() -> WiltedMacModel {
        let suite = "com.zerodelta.wilted.mac.share-composer.\(UUID().uuidString)"
        suiteNames.append(suite)
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("share-composer"),
                                   preferences: UserDefaults(suiteName: suite) ?? .standard)
        models.append(model)
        return model
    }

    private func episode() -> WiltedMacEpisode {
        WiltedMacEpisode(id: "share-episode", title: "Episode", feedTitle: "Show", summary: "Notes are not input.",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 60,
            playbackSeconds: 0, downloadState: .completed, isReadyMediaAvailable: true,
            feedURL: URL(string: "https://example.test/feed")!, episodeLink: URL(string: "https://example.test/episode"))
    }
}

private func composerDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private actor ComposerSemantic {
    private var current = "worker-source-v1"
    func value() -> String { current }
    func set(_ value: String) { current = value }
}
private actor ComposerRunner: PodcastPipelineRunning {
    private let held: Bool
    private let fail: Bool
    private var progressCallback: (@Sendable (PodcastPreparationProgress) -> Void)?
    private var requestID: UUID?

    private var calls = 0
    private var text: String?
    private var arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    init(held: Bool = false, fail: Bool = false) { self.held = held; self.fail = fail }
    func emitLateProgress() {
        progressCallback?(PodcastPreparationProgress(stage: "summary.generate", detail: "Late progress", requestID: requestID))
    }
    func count() -> Int { calls }
    func lastTranscript() -> String? { text }
    func waitUntilHeld() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        let input = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        let transcript = input["transcriptText"] as! String; text = transcript; calls += 1
        if held {
            arrived = true; arrival?.resume(); arrival = nil
            await withCheckedContinuation { continuation = $0 }
        }
        let id = input["requestID"] as! String
        requestID = UUID(uuidString: id); progressCallback = onProgress
        if fail { throw URLError(.cannotDecodeContentData) }
        onProgress(PodcastPreparationProgress(stage: "summary.generate", detail: "Summarizing locally…", requestID: UUID(uuidString: id)))
        let path = input["llmModel"] as! String
        return try JSONSerialization.data(withJSONObject: [
            "ok": true, "protocolVersion": 2, "operation": "summary", "requestID": id,
            "summary": "Summary of: " + transcript, "coverage": "whole", "inputCharacters": transcript.unicodeScalars.count,
            "coverageRanges": [[0, transcript.unicodeScalars.count]], "reductionLevels": 0, "completionTokens": 3,
            "transcriptDigest": composerDigest(Data(transcript.utf8)), "promptIdentity": String(repeating: "b", count: 64),
            "modelIdentity": composerDigest(try Data(contentsOf: URL(fileURLWithPath: path))), "modelPath": path
        ])
    }
}
