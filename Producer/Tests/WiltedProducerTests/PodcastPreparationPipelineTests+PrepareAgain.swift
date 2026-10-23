import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// Preparing a cut episode again fetches its original into a staging file,
/// runs the current engine over it, and swaps the result in. The old cut has
/// to stay the ready revision, and playable, until the very last step, and the
/// listener's place has to arrive where it was or the run has to decline.
extension PodcastPreparationPipelineTests {
    // MARK: Helpers

    static let recutAudio = Data("different-cut-bytes".utf8)
    static let changedOriginal = Data("the-publisher-replaced-this-file".utf8)

    /// Removes 2.0-6.0 from the twelve second original: a different cut from
    /// `cuttingStub`'s 3.0-7.5, so the result is new bytes.
    static func recuttingWorker() -> WorkerStub {
        WorkerStub(response: [
            "ok": true, "timing": "aligned", "audioChanged": true, "durationSeconds": 8.0,
            "text": "Other words.", "cues": [["startSeconds": 0.0, "endSeconds": 2.0, "text": "Other words."]],
            "removedSeconds": 4.0,
            "adSegments": [["startSeconds": 2.0, "endSeconds": 6.0, "label": "host read", "confidence": 0.9]],
            "keepIntervals": [["startSeconds": 0.0, "endSeconds": 2.0, "outputStartSeconds": 0.0],
                              ["startSeconds": 6.0, "endSeconds": 12.0, "outputStartSeconds": 2.0]],
        ], writesCutAudio: recutAudio)
    }

    /// An original with nothing to cut.
    static func uncutResponse(audioURL: URL) -> [String: Any] {
        ["ok": true, "timing": "none", "audioPath": audioURL.path, "audioChanged": false,
         "durationSeconds": 12, "text": "No ads here.", "cues": [[String: Any]](), "removedSeconds": 0.0,
         "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]]()]
    }

    /// An episode an older engine cut, listened to up to `position` on the cut.
    private func olderCut(_ fixture: Fixture, position: Double?) async throws -> PodcastPreparationResult {
        let cut = try await fixture.pipeline(Fixture.cuttingStub(), engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        if let position {
            try await fixture.store.save(playback: try PlaybackState(
                itemID: fixture.episodeID, revisionID: cut.revision.revisionID, sessionID: "session-1",
                sequence: 4, positionSeconds: position, durationSeconds: 7.5, completed: false,
                intent: .progress, deviceID: "mac-1",
                updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_250))))
        }
        return cut
    }

    private func candidate(_ fixture: Fixture) async throws -> PodcastPrepareAgainCandidate {
        try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
    }

    private func mediaFiles(_ fixture: Fixture) -> [String] {
        let directory = fixture.audioURL.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func stagedFiles(_ fixture: Fixture) -> [String] {
        let directory = fixture.libraryDirectory.appendingPathComponent(".podcast-staging")
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: Cases

    @Test func preparingAgainReplacesTheCutAndCarriesThePlaceExactly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let oldURL = try #require(try await fixture.store.readyRevision(for: fixture.episodeID)).mediaURL
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)

        let outcome = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
            candidate: target, stage: { staged })
        guard case .prepared(let result) = outcome else { Issue.record("expected a new cut, got \(outcome)"); return }

        // 4.5 on the old cut is 9.0 on the original (the old cut dropped 3.0-7.5),
        // which is 5.0 on the new cut (2.0-6.0 dropped, 2.0 kept before it).
        let carried = try #require(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        #expect(carried.positionSeconds == 5.0)
        #expect(carried.durationSeconds == 8.0)
        #expect(carried.sessionID == "session-1")

        #expect(result.revision.revisionID != old.revision.revisionID)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).map(\.revisionID)
            == [result.revision.revisionID])
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID) == nil)
        #expect(try await fixture.store.download(for: fixture.episodeID)?.localURL == result.mediaURL)
        #expect(try await fixture.store.preparationOutcome(
            for: fixture.episodeID, revisionID: result.revision.revisionID)?.semanticVersion
            == PodcastPreparationPipeline.semanticVersion)

        #expect(!FileManager.default.fileExists(atPath: oldURL.path), "the old cut's file is reclaimed")
        #expect(try Data(contentsOf: result.mediaURL) == Self.recutAudio)
        #expect(mediaFiles(fixture) == [result.mediaURL.lastPathComponent], "no orphan file is left")
        #expect(stagedFiles(fixture).isEmpty)
        #expect(!fixture.store.inFlightMedia.isInFlight(staged.url))
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func theOldCutStaysReadyAndPlayableWhileTheOriginalIsFetched() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let oldURL = try #require(try await fixture.store.readyRevision(for: fixture.episodeID)).mediaURL
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)
        let store = fixture.store
        let episodeID = fixture.episodeID

        _ = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(candidate: target, stage: {
            let ready = try await store.readyRevision(for: episodeID)
            #expect(ready?.revision.revisionID == old.revision.revisionID)
            #expect(FileManager.default.fileExists(atPath: oldURL.path))
            #expect(try await store.download(for: episodeID)?.status == .completed)
            return staged
        })
    }

    @Test func aRunOverAnOriginalWithNothingToCutBecomesTheOriginal() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)
        let worker = WorkerStub(response: Self.uncutResponse(audioURL: staged.url))

        let outcome = try await fixture.pipeline(worker).prepareAgain(candidate: target, stage: { staged })
        guard case .prepared(let result) = outcome else { Issue.record("expected a result, got \(outcome)"); return }

        // The original earns the identity a fresh download of those bytes would.
        let expectedID = try RevisionID.derive(podcastDownloadedAudioItemID: fixture.episodeID,
                                               contentHash: fixture.contentHash)
        #expect(result.revision.revisionID == expectedID)
        #expect(result.revision.contentHash == fixture.contentHash)
        #expect(result.mediaURL == fixture.audioURL.deletingLastPathComponent()
            .appendingPathComponent(expectedID.rawValue + ".mp3"))
        #expect(try Data(contentsOf: result.mediaURL) == Fixture.originalBody)
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: expectedID)?.positionSeconds == 9.0)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).map(\.revisionID) == [expectedID])
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID) == nil)
        #expect(mediaFiles(fixture) == [result.mediaURL.lastPathComponent])
        #expect(stagedFiles(fixture).isEmpty)
    }

    @Test func aRunThatReachesTheSameCutKeepsTheRevisionAndThePlace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)

        let outcome = try await fixture.pipeline(Fixture.cuttingStub()).prepareAgain(
            candidate: target, stage: { staged })
        guard case .prepared(let result) = outcome else { Issue.record("expected a result, got \(outcome)"); return }

        #expect(result.revision.revisionID == old.revision.revisionID)
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID)?.positionSeconds == 4.5)
        #expect(FileManager.default.fileExists(atPath: result.mediaURL.path))
        #expect(mediaFiles(fixture) == [result.mediaURL.lastPathComponent])
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func aChangedOriginalIsRefusedWhenThereIsAPlaceToCarry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Self.changedOriginal)
        let worker = Self.recuttingWorker()

        let outcome = try await fixture.pipeline(worker).prepareAgain(candidate: target, stage: { staged })
        guard case .refused(let reason) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(reason == .publisherFileChanged)
        #expect(reason.message == "The publisher's file changed, so your place could not be carried")

        #expect(await worker.lastRequest() == nil, "no engine time is spent on a run that cannot land")
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        #expect(ready.revision.revisionID == old.revision.revisionID)
        #expect(FileManager.default.fileExists(atPath: ready.mediaURL.path))
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID)?.positionSeconds == 4.5)
        #expect(stagedFiles(fixture).isEmpty)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty,
                "the refusal is recorded as a try by the current engine")
    }

    @Test func aChangedOriginalIsFineWhenThereIsNoPlaceToCarry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: nil)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Self.changedOriginal)

        let outcome = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
            candidate: target, stage: { staged })
        guard case .prepared(let result) = outcome else { Issue.record("expected a new cut, got \(outcome)"); return }
        #expect(result.revision.revisionID != old.revision.revisionID)
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: result.revision.revisionID) == nil)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).count == 1)
    }

    @Test func aPlaceAtTheStartDoesNotGateTheRun() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await olderCut(fixture, position: 0)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Self.changedOriginal)

        let outcome = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
            candidate: target, stage: { staged })
        guard case .prepared(let result) = outcome else { Issue.record("expected a new cut, got \(outcome)"); return }
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: result.revision.revisionID)?.positionSeconds == 0)
    }

    @Test func aCutWithNoRecordOfItsRemovalsIsRefusedBeforeDownloading() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let real = try await candidate(fixture)
        let legacy = PodcastPrepareAgainCandidate(
            episodeID: real.episodeID, readyRevision: real.readyRevision, isCut: true,
            keptTimeline: nil, sourceHash: nil, enclosureURL: real.enclosureURL)
        let fetched = FetchCounter()

        let outcome = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
            candidate: legacy, stage: { fetched.increment(); return try fixture.staged(Fixture.originalBody) })
        guard case .refused(let reason) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(reason == .noRecordOfRemovals)
        #expect(reason.message == "This episode's old cut has no record of what was removed")
        #expect(fetched.count == 0)
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID)?.revision.revisionID
            == old.revision.revisionID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    @Test func aWorkerFailureLeavesThePlayableCutAndNoStagedFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let oldURL = try #require(try await fixture.store.readyRevision(for: fixture.episodeID)).mediaURL
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)

        await #expect(throws: PodcastPreparationError.self) {
            _ = try await fixture.pipeline(ProbingWorker {}).prepareAgain(candidate: target, stage: { staged })
        }
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        #expect(ready.revision.revisionID == old.revision.revisionID)
        #expect(ready.mediaURL == oldURL)
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID)?.positionSeconds == 4.5)
        #expect(stagedFiles(fixture).isEmpty)
        #expect(!fixture.store.inFlightMedia.isInFlight(staged.url))
    }

    /// The phone can sync a newer place on the old cut after the carry was
    /// read. The save deletes the old cut's place, so it must carry that newer
    /// one, not the place read before it. The new file is flushed to disk
    /// before any record names it.
    @Test func aPlaceSyncedJustBeforeTheSwapIsTheOneCarried() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)
        let store = fixture.store
        let episodeID = fixture.episodeID
        let synced = PhoneSyncOnce()
        let flushes = DurableFileEventRecorder()

        let outcome = try await DurableFile.$observer.withValue({ flushes.append($0) }) {
            try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
                candidate: target, stage: { staged },
                mayReplace: {
                    await synced.once {
                        try? await store.save(playback: try PlaybackState(
                            itemID: episodeID, revisionID: old.revision.revisionID, sessionID: "phone-session",
                            sequence: 9, positionSeconds: 6.0, durationSeconds: 7.5, completed: false,
                            intent: .progress, deviceID: "phone-1",
                            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_400))))
                    }
                    return true
                })
        }
        guard case .prepared(let result) = outcome else { Issue.record("expected a new cut, got \(outcome)"); return }

        // 6.0 on the old cut is 10.5 on the original, which is 6.5 on the new cut.
        let carried = try #require(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        #expect(carried.positionSeconds == 6.5)
        #expect(carried.sessionID == "phone-session")
        #expect(flushes.fullSyncSnapshots.contains { $0.url == result.mediaURL && $0.exists })
    }

    /// Stop, or the Mac loading the cut into its player, after the engine has
    /// run but before the swap leaves the library exactly as it was.
    @Test func aRunStoppedAtTheSwapLeavesTheCutAndNoNewFile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let oldURL = try #require(try await fixture.store.readyRevision(for: fixture.episodeID)).mediaURL
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
                candidate: target, stage: { staged }, mayReplace: { false })
        }
        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        #expect(ready.revision.revisionID == old.revision.revisionID)
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID)?.positionSeconds == 4.5)
        #expect(mediaFiles(fixture) == [oldURL.lastPathComponent], "the placed file is removed again")
        #expect(stagedFiles(fixture).isEmpty)
        let again = try await candidate(fixture)
        #expect(again.readyRevision == target.readyRevision, "a stopped run is not a try")
    }

    @Test func anUncertainResultKeepsTheCut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let target = try await candidate(fixture)
        let staged = try fixture.staged(Fixture.originalBody)
        let worker = WorkerStub(response: Self.uncertainResponse(audioURL: staged.url))

        let outcome = try await fixture.pipeline(worker).prepareAgain(candidate: target, stage: { staged })
        guard case .keptExisting = outcome else { Issue.record("expected the cut to be kept, got \(outcome)"); return }
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID)?.revision.revisionID
            == old.revision.revisionID)
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: old.revision.revisionID)?.positionSeconds == 4.5)
        #expect(stagedFiles(fixture).isEmpty)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }

    /// A download that fails or is stopped decided nothing, so the episode is
    /// still offered.
    @Test func aFailedOrStoppedDownloadChangesNothingAndStaysOffered() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let old = try await olderCut(fixture, position: 4.5)
        let target = try await candidate(fixture)

        await #expect(throws: PodcastPreparationError.cancelled) {
            _ = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
                candidate: target, stage: { throw PodcastDownloadCoordinatorError.cancelled })
        }
        await #expect(throws: PodcastDownloadCoordinatorError.invalidResponse(503)) {
            _ = try await fixture.pipeline(Self.recuttingWorker()).prepareAgain(
                candidate: target, stage: { throw PodcastDownloadCoordinatorError.invalidResponse(503) })
        }
        #expect(try await fixture.store.readyRevision(for: fixture.episodeID)?.revision.revisionID
            == old.revision.revisionID)
        let again = try await candidate(fixture)
        #expect(again.readyRevision == target.readyRevision)
        #expect(again.isCut)
    }

    /// Reproduces the earlier flow in `prepare` itself: an uncertain run keeps
    /// the original, a later run cuts it, and the place follows.
    @Test func anUncertainOriginalPreparedAgainCarriesThePlaceThroughTheCut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.store.save(playback: try PlaybackState(
            itemID: fixture.episodeID, revisionID: fixture.revisionID, sessionID: "session-1", sequence: 4,
            positionSeconds: 9.0, durationSeconds: 12, completed: false, intent: .progress,
            deviceID: "mac-1", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_150))))
        let uncertain = WorkerStub(response: Self.uncertainResponse(audioURL: fixture.audioURL))
        let first = try await fixture.pipeline(uncertain, engineVersion: Self.olderEngine)
            .prepare(episodeID: fixture.episodeID)
        #expect(first.revision.revisionID == fixture.revisionID)
        let offered = try await fixture.store.podcastEpisodesToPrepareAgain()
        #expect(offered.map(\.episodeID) == [fixture.episodeID])
        #expect(offered.first?.isCut == false, "the original is on disk: the ordinary path applies")

        let second = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        #expect(second.adRemovalOutcome == "cut")
        let carried = try #require(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: second.revision.revisionID))
        #expect(carried.positionSeconds == 4.5)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain().isEmpty)
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

extension PodcastPreparationPipelineTests.Fixture {
    /// An original in the staging directory, as `stageOriginal` leaves it.
    func staged(_ body: Data, duration: Double = 12) throws -> StagedPodcastAudio {
        let directory = libraryDirectory.appendingPathComponent(".podcast-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp3")
        try body.write(to: url)
        store.inFlightMedia.begin(url)
        return StagedPodcastAudio(url: url, contentHash: Self.contentHash(body), byteCount: Int64(body.count),
                                  durationSeconds: duration, mediaType: "audio/mpeg")
    }
}

/// Runs a side effect the first time it is asked.
private actor PhoneSyncOnce {
    private var done = false
    func once(_ body: () async -> Void) async {
        guard !done else { return }
        done = true
        await body()
    }
}
