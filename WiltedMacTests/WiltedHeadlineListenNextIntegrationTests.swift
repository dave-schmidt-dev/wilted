import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedHeadlineListenNextIntegrationTests: XCTestCase {
    private let owner = "headline-owner"
    private let macID = "headline-mac"
    private let phoneID = "headline-phone"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let privateArticleMarker = "PRIVATE_ARTICLE_BODY_MUST_STAY_ON_MAC"
    private let generatedAudio = Data("ftypM4A\u{00}\u{00}\u{00}synthetic-audio".utf8)

    func testRequesterFetchesCompletedAudioOutsideLarderWithoutTextPublication() async throws {
        let directory = wiltedTemporaryDirectory("headline-listen-next-delivery")
        let story = try story()
        let model = try makeModel(directory: directory, story: story)
        let backend = SyntheticStoryAudioBackend(owner: owner, generation: 4, directory: directory)
        let macTransport = SyntheticListenNextTransport(deviceID: macID, backend: backend)
        let phoneTransport = SyntheticListenNextTransport(deviceID: phoneID, backend: backend)
        let store = WiltedMacListenNextStore(fileURL: directory.appendingPathComponent("requests.json"))
        let coordinator = try makeCoordinator(
            model: model, transport: macTransport, directory: directory,
            store: store, narrate: immediateNarrator(bytes: generatedAudio))
        let intent = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: phoneID, createdAt: now, id: "request-delivery")

        let outcome = try await coordinator.handle(intent)
        XCTAssertTrue(outcome.isApplied)
        let ready = try await eventuallyStatus("request-delivery", phase: .ready, backend: backend)
        let offer = try XCTUnwrap(ready.audioOffer)
        let deliveredURL = try await phoneTransport.fetchStoryAudio(offer, expectedOwner: owner) { _ in }
        let deliveredBytes = try Data(contentsOf: deliveredURL)
        defer { try? FileManager.default.removeItem(at: deliveredURL) }

        XCTAssertEqual(deliveredBytes, generatedAudio)
        XCTAssertEqual(ready.voiceID, ApprovedReadingVoiceID.caseyKasem.rawValue)
        XCTAssertEqual(ready.voiceRevision, ArticleNarrationCoordinator.voiceRevision(for: .caseyKasem))
        XCTAssertEqual(ready.storyID, story.id)

        let trace = await backend.trace()
        XCTAssertEqual(trace.audioOffers, [offer])
        XCTAssertEqual(trace.audioPayloads, [generatedAudio])
        XCTAssertEqual(trace.transcriptPublications, 0)
        XCTAssertEqual(trace.libraryRecordPublications, 0)
        XCTAssertEqual(trace.legacyMediaPublications, 0)
        XCTAssertFalse(trace.serializedStatus.contains(privateArticleMarker))
        XCTAssertFalse(trace.serializedStatus.contains(story.link?.absoluteString ?? ""))
        XCTAssertFalse(String(decoding: try XCTUnwrap(trace.audioPayloads.first), as: UTF8.self)
            .contains(privateArticleMarker))

        let nonrequester = SyntheticListenNextTransport(deviceID: "other-device", backend: backend)
        do {
            _ = try await nonrequester.fetchStoryAudio(offer, expectedOwner: owner) { _ in }
            XCTFail("A device other than the requester fetched private story audio.")
        } catch LibraryTransportError.ownershipViolation {}
    }

    func testCancellationTombstoneRejectsLateNarrationResult() async throws {
        let directory = wiltedTemporaryDirectory("headline-listen-next-cancel")
        let story = try story()
        let model = try makeModel(directory: directory, story: story)
        let backend = SyntheticStoryAudioBackend(owner: owner, generation: 2, directory: directory)
        let transport = SyntheticListenNextTransport(deviceID: macID, backend: backend)
        let store = WiltedMacListenNextStore(fileURL: directory.appendingPathComponent("requests.json"))
        let narration = SyntheticNarrationGate(bytes: generatedAudio)
        let narrationOperation = await narration.makeOperation()
        let coordinator = try makeCoordinator(
            model: model, transport: transport, directory: directory,
            store: store, narrate: narrationOperation)
        let request = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: phoneID, createdAt: now, id: "request-cancel")
        let cancel = try LibraryIntent.cancelListenNext(requestID: request.id, deviceID: phoneID, createdAt: now)

        _ = try await coordinator.handle(request)
        try await narration.waitUntilStarted()
        let outcome = try await coordinator.handle(cancel)
        XCTAssertTrue(outcome.isApplied)
        await narration.releaseLateResult()

        let cancelled = try await eventuallyStatus("request-cancel", phase: .cancelled, backend: backend)
        XCTAssertNil(cancelled.audioOffer)
        let trace = await backend.trace()
        XCTAssertTrue(trace.audioOffers.isEmpty)
    }

    func testRestartGenerationFencesPendingResultAndRecoveryResumesSameTicket() async throws {
        let directory = wiltedTemporaryDirectory("headline-listen-next-recovery")
        let story = try story()
        let model = try makeModel(directory: directory, story: story)
        let backend = SyntheticStoryAudioBackend(owner: owner, generation: 10, directory: directory)
        let transport = SyntheticListenNextTransport(deviceID: macID, backend: backend)
        let storeURL = directory.appendingPathComponent("requests.json")
        let firstStore = WiltedMacListenNextStore(fileURL: storeURL)
        let delayedNarration = SyntheticNarrationGate(bytes: generatedAudio)
        defer { Task { await delayedNarration.releaseLateResult() } }
        let narrationOperation = await delayedNarration.makeOperation()
        let firstCoordinator = try makeCoordinator(
            model: model, transport: transport, directory: directory,
            store: firstStore, narrate: narrationOperation)
        let request = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: phoneID, createdAt: now, id: "request-recovery")

        _ = try await firstCoordinator.handle(request)
        try await delayedNarration.waitUntilStarted()
        firstCoordinator.invalidate()

        await backend.advanceGeneration()
        let recoveredStore = WiltedMacListenNextStore(fileURL: storeURL)
        let recoveredCoordinator = try makeCoordinator(
            model: model, transport: transport, directory: directory,
            store: recoveredStore, narrate: immediateNarrator(bytes: generatedAudio))
        await recoveredCoordinator.activateAndResume()
        await delayedNarration.releaseLateResult()

        let ready = try await eventuallyStatus("request-recovery", phase: .ready, backend: backend)
        let recoveredValue = await recoveredStore.snapshot(request.id)
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(recovered.requestID, request.id)
        XCTAssertEqual(recovered.operationGeneration, 11)
        XCTAssertEqual(recovered.status, .ready)
        let recoveredOffer = try XCTUnwrap(ready.audioOffer)
        XCTAssertEqual(recoveredOffer.requestID, request.id)
        XCTAssertEqual(recoveredOffer.requesterDeviceID, phoneID)
        XCTAssertEqual(recoveredOffer.storyID, story.id)
        let trace = await backend.trace()
        XCTAssertEqual(trace.audioOffers, [recoveredOffer])
        XCTAssertEqual(trace.audioPayloads, [generatedAudio])
    }

    func testAccountSwitchDuringAudioPublicationRejectsOldOwnerTransfer() async throws {
        let directory = wiltedTemporaryDirectory("headline-listen-next-account-switch")
        let story = try story()
        let model = try makeModel(directory: directory, story: story)
        let backend = SyntheticStoryAudioBackend(owner: owner, generation: 6, directory: directory)
        await backend.holdAudioPublication()
        defer { Task { await backend.releaseAudioPublication() } }
        let transport = SyntheticListenNextTransport(deviceID: macID, backend: backend)
        let store = WiltedMacListenNextStore(fileURL: directory.appendingPathComponent("requests.json"))
        let coordinator = try makeCoordinator(
            model: model, transport: transport, directory: directory,
            store: store, narrate: immediateNarrator(bytes: generatedAudio))
        let request = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: phoneID, createdAt: now, id: "request-account-switch")

        _ = try await coordinator.handle(request)
        try await backend.waitUntilAudioPublicationStarted()
        await backend.switchAccount(to: "replacement-owner")
        await coordinator.activateAndResume()
        await backend.releaseAudioPublication()

        let snapshots = await coordinator.snapshots()
        let trace = await backend.trace()
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(trace.audioOffers.isEmpty)
        XCTAssertTrue(trace.audioPayloads.isEmpty)
    }

    func testCoordinatorStartupSweepsAbandonedStagingAndPreservesFinalAudio() async throws {
        let directory = wiltedTemporaryDirectory("headline-listen-next-staging-startup")
        let audioDirectory = directory.appendingPathComponent("story-audio", isDirectory: true)
        let staging = WiltedMacListenNextStaging(directory: audioDirectory, coordinatorDeviceID: macID)
        let taskID = UUID()
        let metadata = WiltedMacListenNextStaging.LeaseMetadata(
            coordinatorDeviceID: macID, ownerToken: owner, operationGeneration: 3,
            requesterDeviceID: phoneID, requestID: "abandoned-request", taskID: taskID)
        let orphanURL = staging.stagingURL(
            ownerToken: owner, operationGeneration: 3, requesterDeviceID: phoneID,
            requestID: "abandoned-request", taskID: taskID)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data("partial staging".utf8).write(to: orphanURL)
        try JSONEncoder().encode(metadata).write(to: URL(fileURLWithPath: orphanURL.path + ".lease"))
        let finalAudioURL = audioDirectory.appendingPathComponent("listen-next-final.m4a")
        try generatedAudio.write(to: finalAudioURL)

        let story = try story()
        let model = try makeModel(directory: directory, story: story)
        let backend = SyntheticStoryAudioBackend(owner: owner, generation: 4, directory: directory)
        let transport = SyntheticListenNextTransport(deviceID: macID, backend: backend)
        let store = WiltedMacListenNextStore(fileURL: directory.appendingPathComponent("requests.json"))
        let coordinator = try makeCoordinator(
            model: model, transport: transport, directory: directory,
            store: store, narrate: immediateNarrator(bytes: generatedAudio))

        await coordinator.activateAndResume()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path + ".lease"))
        XCTAssertEqual(try Data(contentsOf: finalAudioURL), generatedAudio)
    }

    private func story() throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: "headline-story", title: "A public headline", publisherID: "publisher-1",
            publisherName: "Example Publisher", link: URL(string: "https://example.com/story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
    }

    private func makeModel(directory: URL, story: LibraryHeadlineStory) throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral())
        try model.headlineCatalogStore.mergeRecent([story], at: now)
        model.selectReadingVoice(ApprovedReadingVoiceID.caseyKasem.rawValue)
        return model
    }

    private func makeCoordinator(
        model: WiltedMacModel,
        transport: any LibraryTransport,
        directory: URL,
        store: WiltedMacListenNextStore,
        narrate: @escaping WiltedMacListenNextCoordinator.NarrationOperation
    ) throws -> WiltedMacListenNextCoordinator {
        try WiltedMacListenNextCoordinator(
            model: model, transport: transport,
            directory: directory.appendingPathComponent("story-audio", isDirectory: true),
            deviceID: macID, store: store, narrate: narrate)
    }

    private func immediateNarrator(bytes: Data) -> WiltedMacListenNextCoordinator.NarrationOperation {
        { request, outputURL, _ in
            try bytes.write(to: outputURL, options: .atomic)
            return makeNarrationResult(request: request, outputURL: outputURL, bytes: bytes)
        }
    }

    private func eventuallyStatus(
        _ requestID: String,
        phase: LibraryListenNextStatus.Phase,
        backend: SyntheticStoryAudioBackend
    ) async throws -> LibraryListenNextStatus {
        for _ in 0..<200 {
            if let status = await backend.status(requestID), status.phase == phase { return status }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw IntegrationWaitError.statusDidNotArrive
    }
}

private func makeNarrationResult(
    request: ArticleNarrationRequest,
    outputURL: URL,
    bytes: Data
) -> ArticleNarrationResult {
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return ArticleNarrationResult(
        audioURL: outputURL, revisionID: "audio-revision-1", contentHash: "sha256:\(digest)",
        byteCount: Int64(bytes.count), mediaType: "audio/mp4", duration: 2,
        voiceRevision: request.voiceRevision, canonicalURL: request.originalURL,
        title: request.storyID, source: "fixture")
}

private enum IntegrationWaitError: Error {
    case statusDidNotArrive
    case narrationDidNotStart
    case audioPublicationDidNotStart
}

private actor SyntheticNarrationGate {
    private let bytes: Data
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(bytes: Data) { self.bytes = bytes }

    func makeOperation() -> WiltedMacListenNextCoordinator.NarrationOperation {
        let payload = bytes
        return { request, outputURL, _ in
            await self.markStarted()
            await self.waitForRelease()
            try payload.write(to: outputURL, options: .atomic)
            return makeNarrationResult(request: request, outputURL: outputURL, bytes: payload)
        }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<200 {
            if started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw IntegrationWaitError.narrationDidNotStart
    }

    func releaseLateResult() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func waitForRelease() async {
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    private func markStarted() {
        started = true
    }
}

private actor SyntheticStoryAudioBackend {
    struct Trace: Sendable {
        let audioOffers: [LibraryStoryAudioOffer]
        let audioPayloads: [Data]
        let transcriptPublications: Int
        let libraryRecordPublications: Int
        let legacyMediaPublications: Int
        let serializedStatus: String
    }

    private var owner: String
    private var generation: UInt64
    private let directory: URL
    private var audio: [String: (offer: LibraryStoryAudioOffer, bytes: Data)] = [:]
    private var statuses: [String: LibraryListenNextStatus] = [:]
    private var transcriptPublications = 0
    private var libraryRecordPublications = 0
    private var legacyMediaPublications = 0
    private var holdPublication = false
    private var publicationStarted = false
    private var publicationRelease: CheckedContinuation<Void, Never>?

    init(owner: String, generation: UInt64, directory: URL) {
        self.owner = owner
        self.generation = generation
        self.directory = directory
    }

    func context() -> (owner: String, generation: UInt64) { (owner, generation) }
    func advanceGeneration() { generation &+= 1 }
    func switchAccount(to newOwner: String) { owner = newOwner; generation &+= 1 }
    func holdAudioPublication() { holdPublication = true }

    func waitUntilAudioPublicationStarted() async throws {
        for _ in 0..<200 {
            if publicationStarted { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw IntegrationWaitError.audioPublicationDidNotStart
    }

    func releaseAudioPublication() {
        publicationRelease?.resume()
        publicationRelease = nil
        holdPublication = false
    }

    func verify(_ expectedOwner: String) throws {
        guard owner == expectedOwner else { throw LibraryTransportError.superseded }
    }

    func publishAudio(_ offer: LibraryStoryAudioOffer, fileURL: URL, expectedOwner: String) async throws {
        try verify(expectedOwner)
        guard offer.requestID.isEmpty == false else { throw LibraryTransportError.transport("invalid offer") }
        if holdPublication {
            publicationStarted = true
            await withCheckedContinuation { publicationRelease = $0 }
            try verify(expectedOwner)
        }
        audio[offer.requestID] = (offer, try Data(contentsOf: fileURL))
    }

    func fetchAudio(
        _ offer: LibraryStoryAudioOffer,
        expectedOwner: String,
        requesterDeviceID: String
    ) throws -> (Data, URL) {
        try verify(expectedOwner)
        guard requesterDeviceID == offer.requesterDeviceID,
              let current = audio[offer.requestID], current.offer == offer else {
            throw LibraryTransportError.ownershipViolation("story audio is not authorized for this device")
        }
        let destination = directory.appendingPathComponent("delivery-\(UUID().uuidString).m4a")
        try current.bytes.write(to: destination, options: .atomic)
        return (current.bytes, destination)
    }

    func removeAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) throws {
        try verify(expectedOwner)
        guard audio[offer.requestID]?.offer == offer else { return }
        audio.removeValue(forKey: offer.requestID)
    }

    func publishStatus(_ status: LibraryListenNextStatus, expectedOwner: String) throws {
        try verify(expectedOwner)
        if let current = statuses[status.requestID], current.statusRevision > status.statusRevision { return }
        statuses[status.requestID] = status
    }

    func status(_ requestID: String) -> LibraryListenNextStatus? { statuses[requestID] }

    func statuses(_ requestIDs: Set<String>) -> [LibraryListenNextStatus] {
        statuses.values.filter { requestIDs.contains($0.requestID) }
    }

    func recordTranscriptPublication() { transcriptPublications += 1 }
    func recordLibraryPublication() { libraryRecordPublications += 1 }
    func recordLegacyMediaPublication() { legacyMediaPublications += 1 }

    func trace() -> Trace {
        let statusJSON = statuses.values.compactMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        return Trace(
            audioOffers: audio.values.map { $0.offer }, audioPayloads: audio.values.map { $0.bytes },
            transcriptPublications: transcriptPublications,
            libraryRecordPublications: libraryRecordPublications,
            legacyMediaPublications: legacyMediaPublications, serializedStatus: statusJSON)
    }
}

private actor SyntheticListenNextTransport: LibraryTransport, LibraryStoryAudioTransport {
    private let deviceID: String
    private let backend: SyntheticStoryAudioBackend

    init(deviceID: String, backend: SyntheticStoryAudioBackend) {
        self.deviceID = deviceID
        self.backend = backend
    }

    func operationGeneration() async -> UInt64 {
        let context = await backend.context()
        return context.generation
    }
    func verifiedOwnerToken() async -> String? {
        let context = await backend.context()
        return context.owner
    }
    func verifyOwner() async throws {
        let context = await backend.context()
        try await backend.verify(context.owner)
    }

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        LibraryChangeBatch(generationID: "synthetic", changes: [], token: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { LibraryPushResult() }
    func send(intent: LibraryIntent) async throws {}
    func listIntents() async throws -> [LibraryIntent] { [] }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        await backend.recordLibraryPublication()
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { LibraryDeviceRecords() }

    func publishStoryAudio(offer: LibraryStoryAudioOffer, fileURL: URL, expectedOwner: String) async throws {
        try await backend.publishAudio(offer, fileURL: fileURL, expectedOwner: expectedOwner)
    }
    func fetchStoryAudio(
        _ offer: LibraryStoryAudioOffer,
        expectedOwner: String,
        progress: @escaping MediaProgressHandler
    ) async throws -> URL {
        let (bytes, url) = try await backend.fetchAudio(
            offer, expectedOwner: expectedOwner, requesterDeviceID: deviceID)
        progress(Int64(bytes.count))
        return url
    }
    func removeStoryAudio(_ offer: LibraryStoryAudioOffer, expectedOwner: String) async throws {
        try await backend.removeAudio(offer, expectedOwner: expectedOwner)
    }
    func publishListenNextStatus(_ status: LibraryListenNextStatus, expectedOwner: String) async throws {
        try await backend.publishStatus(status, expectedOwner: expectedOwner)
    }
    func listenNextStatuses(requestIDs: Set<String>, expectedOwner: String) async throws -> [LibraryListenNextStatus] {
        try await backend.verify(expectedOwner)
        return await backend.statuses(requestIDs)
    }

    func publishTranscript(_ transcript: LibraryTranscript) async throws {
        await backend.recordTranscriptPublication()
    }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        await backend.recordLegacyMediaPublication()
    }
}
