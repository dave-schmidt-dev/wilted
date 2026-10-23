import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// An older run could only report `uncertain`, so it kept the original audio
/// with every advertisement. Running the current pipeline over that same
/// original has to remove what it can now resolve and carry the listener's
/// place across the cut -- which is why the store refuses to offer an episode
/// whose newest revision is already a cut one.
extension PodcastPreparationPipelineTests {
    /// The worker's own report for a run that could not resolve an
    /// advertisement. W-INV-013 keeps the whole original, so audio, duration
    /// and removed time say exactly that.
    private static func uncertainResponse(audioURL: URL) -> [String: Any] {
        let warning = "original audio includes ads: classifier could not resolve IDs 0"
        var audit: [String: Any] = WorkerStub.cleanAudit()
        audit["unresolvedIds"] = [0]
        audit["incompleteError"] = "classifier could not resolve IDs 0"
        audit["warning"] = warning
        // The uncertain contract requires both diagnostic lists to be present.
        audit["heldSpans"] = [[String: Any]]()
        audit["declinedCommercialEvidenceSeeds"] = [[String: Any]]()
        return [
            "ok": true, "protocolVersion": 2, "timing": "none", "audioPath": audioURL.path,
            "audioChanged": false, "durationSeconds": 12, "removedSeconds": 0.0,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](),
            "report": ["outcome": "uncertain", "rawNominations": [[String: Any]](),
                       "warning": warning, "audit": audit],
        ]
    }

    @Test func preparingAgainCarriesTheListeningPositionThroughTheCut() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let position = 9.0
        try await fixture.store.save(playback: try PlaybackState(
            itemID: fixture.episodeID, revisionID: fixture.revisionID, sessionID: "session-1", sequence: 4,
            positionSeconds: position, durationSeconds: 12, completed: false, intent: .progress,
            deviceID: "mac-1", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_150))
        ))

        // First run: the old pipeline's answer. The audio does not change, so
        // the episode stays on its original revision and offers a re-preparation.
        let uncertain = WorkerStub(response: Self.uncertainResponse(audioURL: fixture.audioURL))
        let first = try await fixture.pipeline(uncertain).prepare(episodeID: fixture.episodeID)
        #expect(first.adRemovalOutcome == "uncertain")
        #expect(first.revision.revisionID == fixture.revisionID)
        #expect(try await fixture.store.podcastEpisodesKeepingAds() == [fixture.episodeID])
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: fixture.revisionID
        )?.positionSeconds == position)

        // Second run: the current pipeline removes 3.0-7.5, which is entirely
        // before the saved position, so the place maps onto the cut clock.
        let second = try await fixture.pipeline(Fixture.cuttingStub()).prepare(episodeID: fixture.episodeID)
        #expect(second.adRemovalOutcome == "cut")
        #expect(second.revision.revisionID != fixture.revisionID)
        #expect(try await fixture.store.revisions(for: fixture.episodeID).map(\.revisionID)
            == [second.revision.revisionID])

        // The same mapping `carriedPlayback` uses: 9.0 - 3.0 removed + 3.0 kept
        // in front of it, on a 7.5 second file.
        let carried = try #require(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: second.revision.revisionID
        ))
        #expect(carried.positionSeconds == 4.5)
        #expect(carried.durationSeconds == 7.5)
        #expect(carried.sessionID == "session-1")
        #expect(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: fixture.revisionID
        ) == nil)

        // The cut is now the episode's only preparation, and it removed ads.
        #expect(try await fixture.store.podcastEpisodesKeepingAds().isEmpty)
    }
}
