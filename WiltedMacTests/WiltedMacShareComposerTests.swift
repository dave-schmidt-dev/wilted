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
    private var models: [WiltedMacModel] = []

    override func tearDown() async throws {
        for model in models { await model.close() }
        models.removeAll()
        try await super.tearDown()
    }

    func testSingleShareMenuOffersPageOrTextAndTranscriptSummary() throws {
        let state = WiltedMacShareComposerState(model: makeModel())
        XCTAssertFalse(state.presented)
        XCTAssertFalse(state.includeSummary)
        let player = try WiltedMacHeadless.viewSource("WiltedMacPlayerContent.swift")
        let composer = try WiltedMacHeadless.viewSource("WiltedMacShareComposer.swift")
        let menuStart = try XCTUnwrap(composer.range(of: "Menu {"))
        let menuEnd = try XCTUnwrap(composer.range(of: "} label:", range: menuStart.upperBound..<composer.endIndex))
        let items = composer[menuStart.upperBound..<menuEnd.lowerBound]
        XCTAssertTrue(items.contains("WiltedMacPlaybackShareItems(model: model)"))
        XCTAssertTrue(composer.contains(#"Text("Share with summary")"#),
                      "the one-click action has visible text")
        XCTAssertTrue(composer.contains("Button {\n                state.startOrAttach()"),
                      "the visible Share with summary button starts work in one click")
        XCTAssertTrue(composer.contains(#".accessibilityLabel("More share options")"#))
        XCTAssertTrue(composer.contains(#".accessibilityIdentifier("wilted-player-share-options")"#))
        XCTAssertTrue(composer.contains(".accessibilityHint(\"Create and review a local summary."))
        XCTAssertTrue(composer.contains("if let preview {"), "the share control appears only after a verified preview exists")
        XCTAssertTrue(composer.contains("ShareLink(item: payload(preview)"), "sending remains an explicit follow-up action")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "Menu {", in: composer), 1)
        let playerStart = try XCTUnwrap(player.range(of: "struct WiltedMacPlaybackShareLink:"))
        let shippingBranch = try XCTUnwrap(player.range(of: "#else", range: playerStart.upperBound..<player.endIndex))
        let body = player[playerStart.upperBound..<shippingBranch.lowerBound]
        XCTAssertTrue(body.contains("WiltedMacShareComposer(model: model)"))
        XCTAssertFalse(body.contains("ShareLink("))
        XCTAssertTrue(player.contains("item: shareURL"))
        XCTAssertTrue(player.contains("item: shareText"))
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

    func testCancelTeardownAndOptionOffRejectCancellationIgnoringLateReply() async throws {
        for mode in ["cancel", "off", "teardown"] {
            let rig = try await realRig(); let runner = ComposerRunner(held: true); let state = composer(rig, runner)
            state.presented = true; state.setIncludeSummary(true); await runner.waitUntilHeld()
            if mode == "cancel" { state.cancel() }
            else if mode == "off" { state.setIncludeSummary(false) }
            else { state.teardown() }
            await runner.release(); await state.waitForCompletion()
            await Task.yield()
            XCTAssertNil(state.preview, mode); XCTAssertEqual(state.cachedCount, 0, mode)
            XCTAssertNil(state.activeID, mode)
        }
    }

    func testDismissWhileRunningPreservesJobAndReopeningShowsProgressOrCompletedPreview() async throws {
        let rig = try await realRig(); let runner = ComposerRunner(held: true); let state = composer(rig, runner)
        state.presented = true; state.setIncludeSummary(true)
        await runner.waitUntilHeld()

        // Dismissing popover while running must not cancel the task or reset progress
        state.dismiss()
        XCTAssertFalse(state.presented)
        XCTAssertTrue(state.includeSummary)
        XCTAssertNotNil(state.activeID)

        // Reopening while still running must show progress without restarting
        state.present()
        XCTAssertNotNil(state.progress)
        XCTAssertNil(state.preview)
        let initialCalls = await runner.count()
        XCTAssertEqual(initialCalls, 1, "reopening while running must not restart")

        // Dismiss again while running
        state.dismiss()
        XCTAssertFalse(state.presented)

        // Runner completes while dismissed
        await runner.release()
        await state.waitForCompletion()
        await Task.yield()

        // Job completed and cached the preview in the background
        XCTAssertFalse(state.presented)
        XCTAssertNotNil(state.preview)
        XCTAssertEqual(state.cachedCount, 1)
        XCTAssertNil(state.activeID)
        XCTAssertNil(state.progress)

        // Reopening validates the finished preview without restarting generation.
        state.present()
        XCTAssertNil(state.preview)
        await state.waitForCompletion()
        let completedCalls = await runner.count()
        XCTAssertEqual(completedCalls, 1, "reopening completed job must not restart generation")
        XCTAssertEqual(state.preview?.text, "Summary of: " + rig.text)
        XCTAssertEqual(state.preview?.title, "Loaded store episode")
        XCTAssertEqual(state.preview?.url, URL(string: "https://example.test/loaded"))
        XCTAssertTrue(state.includeSummary)

        // Intentional cancel resets state
        state.cancel()
        XCTAssertNil(state.preview)
        XCTAssertFalse(state.includeSummary)
    }

    func testOneClickStartsSummaryAndAtoBtoAReturnReattachesWithoutShowingWrongPreview() async throws {
        let rig = try await realRig()
        let aRunner = ComposerRunner(held: true)
        let aSemantic = ComposerFingerprintGate()
        let aState = rig.model.shareComposerState(service: TranscriptSummaryService(runner: aRunner),
            configuration: .init(modelURL: rig.modelURL), fingerprint: { await aSemantic.value() })
        aState.startOrAttach()
        XCTAssertTrue(aState.presented, "one Share with summary action opens feedback immediately")
        await aSemantic.waitUntilHeld()

        let b = try await addSecondEpisode(to: rig)
        let bController = PlaybackController(store: rig.store, backend: WiltedFixturePlaybackBackend())
        try await bController.load(revision: b.revision, mediaURL: b.audioURL)
        rig.model.playback = bController

        let bRunner = ComposerRunner()
        let bSemantic = ComposerSemantic()
        let bState = rig.model.shareComposerState(service: TranscriptSummaryService(runner: bRunner),
            configuration: .init(modelURL: rig.modelURL), fingerprint: { await bSemantic.value() })
        XCTAssertFalse(aState === bState, "each transcript has independent progress and preview")
        bState.startOrAttach()
        await bState.waitForCompletion()
        XCTAssertEqual(bState.preview?.text, "Summary of: " + b.text)
        XCTAssertNil(aState.preview, "episode A's preview is never exposed while B is selected")

        // Playback has moved before A's first async snapshot read begins.
        await aSemantic.release()
        await aRunner.waitUntilHeld()
        let aInput = await aRunner.lastTranscript()
        XCTAssertEqual(aInput, rig.text, "the one-click action is bound to A before any await")

        await aRunner.release()
        await aState.waitForCompletion()
        XCTAssertNil(aState.preview, "completion while B is selected keeps A hidden")
        XCTAssertEqual(aState.cachedCount, 1, "A's verified result remains ready in its own state")
        let aCallsBeforeReturn = await aRunner.count()
        XCTAssertEqual(aCallsBeforeReturn, 1)

        let returnToA = PlaybackController(store: rig.store, backend: WiltedFixturePlaybackBackend())
        try await returnToA.load(revision: rig.revision, mediaURL: rig.audioURL)
        rig.model.playback = returnToA
        let reattached = rig.model.shareComposerState(service: TranscriptSummaryService(runner: ComposerRunner()),
            configuration: .init(modelURL: rig.modelURL), fingerprint: { await aSemantic.value() })
        XCTAssertTrue(reattached === aState, "returning to the same owner and revision reuses A's job state")
        reattached.startOrAttach()
        XCTAssertNil(reattached.preview, "preview stays hidden during revalidation")
        await reattached.waitForCompletion()
        XCTAssertEqual(reattached.preview?.text, "Summary of: " + rig.text)
        XCTAssertEqual(reattached.preview?.title, "Loaded store episode")
        let aCallsAfterReturn = await aRunner.count()
        XCTAssertEqual(aCallsAfterReturn, 1, "returning to A reuses the ready summary")
        XCTAssertEqual(bState.preview?.text, "Summary of: " + b.text)
    }

    func testSameModelLibraryReloadKeepsHeldSummaryAttachedToItsRevision() async throws {
        let rig = try await realRig()
        let runner = ComposerRunner(held: true)
        let semantic = ComposerSemantic()
        let service = TranscriptSummaryService(runner: runner)
        let configuration = TranscriptSummaryService.Configuration(modelURL: rig.modelURL)
        let state = rig.model.shareComposerState(service: service, configuration: configuration,
            fingerprint: { await semantic.value() })
        let selection = rig.model.shareComposerSelectionIdentity

        state.startOrAttach()
        await runner.waitUntilHeld()
        state.dismiss()
        await rig.model.reloadLibraryRows()

        XCTAssertEqual(rig.model.shareComposerSelectionIdentity, selection,
                       "a same-store library refresh preserves the selected item and revision")
        let reattached = rig.model.shareComposerState(service: service, configuration: configuration,
            fingerprint: { await semantic.value() })
        XCTAssertTrue(reattached === state, "a same-model reload keeps the held job in its registry")
        reattached.startOrAttach()
        XCTAssertTrue(reattached.presented)
        let callsWhileHeld = await runner.count()
        XCTAssertEqual(callsWhileHeld, 1, "reattaching after reload does not start a second worker")

        await runner.release()
        await reattached.waitForCompletion()
        XCTAssertEqual(reattached.preview?.text, "Summary of: " + rig.text)
        XCTAssertEqual(reattached.preview?.title, "Loaded store episode")
        XCTAssertEqual(reattached.preview?.url, URL(string: "https://example.test/loaded"))
        let callsAfterReload = await runner.count()
        XCTAssertEqual(callsAfterReload, 1)
    }

    func testReopeningRejectsCompletedPreviewAfterContextChanges() async throws {
        for mode in ["transcript", "owner", "model", "worker"] {
            let rig = try await realRig(); let runner = ComposerRunner(); let semantic = ComposerSemantic()
            let state = composer(rig, runner, semantic)
            state.presented = true; state.setIncludeSummary(true); await state.waitForCompletion()
            XCTAssertNotNil(state.preview, mode)
            state.dismiss()
            switch mode {
            case "transcript":
                try await rig.store.save(transcript: transcript(rig, text: "Changed transcript"))
            case "owner":
                try await rig.store.save(libraryAccountBinding: LocalLibraryAccountBinding(state: .bound,
                    ownerToken: CloudKitAccountIdentity.token(for: "changed-owner")))
            case "model":
                try Data("changed synthetic model".utf8).write(to: rig.modelURL)
            case "worker": await semantic.set("worker-source-v2")
            default: XCTFail("Unhandled test mode: \(mode)")
            }
            state.present()
            XCTAssertNil(state.preview, mode)
            await state.waitForCompletion()
            XCTAssertNil(state.preview, mode); XCTAssertFalse(state.includeSummary, mode)
            XCTAssertEqual(state.cachedCount, 0, mode)
            let calls = await runner.count(); XCTAssertEqual(calls, 1, mode)
        }
    }

    func testDurableOwnerChangeAndCloseWhileHeldCannotDisplayOrCache() async throws {
        for mode in ["owner", "close"] {
            let rig = try await realRig(); let runner = ComposerRunner(held: true); let state = composer(rig, runner)
            state.presented = true; state.setIncludeSummary(true); await runner.waitUntilHeld()
            state.dismiss()
            if mode == "owner" {
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
    private func addSecondEpisode(to rig: Rig) async throws -> (revision: AudioRevision, audioURL: URL, text: String) {
        let feedURL = URL(string: "https://example.test/feed")!
        let enclosureURL = URL(string: "https://example.test/audio-b")!
        let item = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "share-item-b", enclosureURL: enclosureURL)
        let bytes = Data([4, 5, 6])
        let audioURL = rig.audioURL.deletingLastPathComponent().appendingPathComponent("audio-b.m4a")
        try bytes.write(to: audioURL)
        let created = Timestamp(Date())
        let revision = try AudioRevision(itemID: item, revisionID: RevisionID(rawValue: "rev-share-b"),
            durationSeconds: 45, byteCount: Int64(bytes.count), contentHash: "sha256:" + composerDigest(bytes),
            mediaType: "audio/mp4", createdAt: created, schemaVersion: 1)
        try await rig.store.save(episode: PodcastEpisode(itemID: item, feedID: try ItemID.derivePodcastFeed(from: feedURL),
            feedURL: feedURL, rssGUID: "share-item-b", title: "Second episode", enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mp4", episodeLink: URL(string: "https://example.test/second"), createdAt: created))
        try await rig.store.saveReadyRevision(revision, mediaURL: audioURL)
        let text = "Invented transcript for episode B; nothing personal."
        try await rig.store.save(transcript: Transcript(itemID: item, revisionID: revision.revisionID,
            availability: .available, text: text, updatedAt: created))
        return (revision, audioURL, text)
    }
    private func composer(_ rig: Rig, _ runner: ComposerRunner, _ semantic: ComposerSemantic = ComposerSemantic()) -> WiltedMacShareComposerState {
        WiltedMacShareComposerState(model: rig.model, service: TranscriptSummaryService(runner: runner),
            configuration: .init(modelURL: rig.modelURL), fingerprint: { await semantic.value() })
    }

    private func makeModel() -> WiltedMacModel {
        let suite = WiltedMacTestPreferences.suiteName("share-composer")
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
private actor ComposerFingerprintGate {
    private var didStart = false
    private var isReleased = false
    private var started: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func value() async -> String? {
        guard !isReleased else { return "worker-source-v1" }
        didStart = true
        started?.resume(); started = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return "worker-source-v1"
    }
    func waitUntilHeld() async {
        guard !didStart else { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        isReleased = true
        releaseWaiter?.resume(); releaseWaiter = nil
    }
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
