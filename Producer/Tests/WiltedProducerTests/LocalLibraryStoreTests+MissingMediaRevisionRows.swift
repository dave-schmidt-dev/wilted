import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: Clearing a missing revision (Task DL-9)

    func testSweepClearingAMissingFileRevisionAlsoClearsItsTranscriptPlaybackAndOutcome() async throws {
        let fixture = try mediaSweepRoot("sweep-revision-rows")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "sweep-revision-rows", daysAgo: [1, 2]
        )
        let revisionIDs = [
            try RevisionID(rawValue: "rev-sweep-revision-rows-0"),
            try RevisionID(rawValue: "rev-sweep-revision-rows-1"),
        ]
        let mediaFiles = [
            try await installEpisodeMedia(
                in: fixture, episode: episodes[0], revisionID: revisionIDs[0].rawValue,
                fileName: "episode-0.m4a", hashCharacter: "a"
            ),
            try await installEpisodeMedia(
                in: fixture, episode: episodes[1], revisionID: revisionIDs[1].rawValue,
                fileName: "episode-1.m4a", hashCharacter: "b"
            ),
        ]
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        for (episode, revisionID) in zip(episodes, revisionIDs) {
            try await fixture.store.save(transcript: try Transcript(
                itemID: episode.itemID, revisionID: revisionID, availability: .available,
                text: "Transcript for \(revisionID.rawValue).", updatedAt: when
            ))
            try await fixture.store.save(playback: try PlaybackState(
                itemID: episode.itemID, revisionID: revisionID, sessionID: "s",
                sequence: 1, positionSeconds: 3, durationSeconds: 60,
                completed: false, intent: .progress, deviceID: "mac", updatedAt: when
            ))
            try await fixture.store.savePreparationOutcome(PodcastPreparationOutcome(
                episodeID: episode.itemID, revisionID: revisionID, policyDigest: "d",
                pipelineFingerprint: "f", semanticVersion: "v", producedAt: when,
                eligibility: .current
            ))
        }

        try FileManager.default.removeItem(at: mediaFiles[0])
        let report = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])

        let firstItemID = episodes[0].itemID
        let secondItemID = episodes[1].itemID
        let firstRevisions = try await fixture.store.revisions(for: firstItemID)
        let firstTranscript = try await fixture.store.transcript(
            for: firstItemID, revisionID: revisionIDs[0]
        )
        let firstPlayback = try await fixture.store.playbackState(
            for: firstItemID, revisionID: revisionIDs[0]
        )
        let firstOutcome = try await fixture.store.preparationOutcome(
            for: firstItemID, revisionID: revisionIDs[0]
        )
        let secondRevisions = try await fixture.store.revisions(for: secondItemID)
        let secondTranscript = try await fixture.store.transcript(
            for: secondItemID, revisionID: revisionIDs[1]
        )
        let secondPlayback = try await fixture.store.playbackState(
            for: secondItemID, revisionID: revisionIDs[1]
        )
        let secondOutcome = try await fixture.store.preparationOutcome(
            for: secondItemID, revisionID: revisionIDs[1]
        )

        XCTAssertEqual(report.clearedRecords, 1,
                       "only the revision record whose media is gone is counted")
        XCTAssertTrue(firstRevisions.isEmpty)
        XCTAssertNil(firstTranscript)
        XCTAssertNil(firstPlayback)
        XCTAssertNil(firstOutcome, "a re-download reuses the content-derived revision ID")
        XCTAssertEqual(secondRevisions.map(\.revision.revisionID), [revisionIDs[1]])
        XCTAssertNotNil(secondTranscript)
        XCTAssertNotNil(secondPlayback)
        XCTAssertNotNil(secondOutcome)
    }

    func testReplacingARevisionKeepsTheSupersededOutcomeAsHistory() async throws {
        let fixture = try mediaSweepRoot("replace-keeps-outcome")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let itemID = try immutableRevisionItemID("replace-keeps-outcome")
        let source = try immutableRevisionFixture(
            itemID: itemID, id: "rev-replace-source", hashCharacter: "c",
            path: fixture.media.appendingPathComponent("source.mp3").path
        )
        let prepared = try immutableRevisionFixture(
            itemID: itemID, id: "rev-replace-prepared", hashCharacter: "d",
            path: fixture.media.appendingPathComponent("prepared.m4a").path
        )
        try Data("source".utf8).write(to: source.mediaURL)
        try Data("prepared".utf8).write(to: prepared.mediaURL)
        try await fixture.store.saveReadyRevision(source.revision, mediaURL: source.mediaURL)
        try await fixture.store.save(transcript: source.transcript)
        try await fixture.store.save(playback: try PlaybackState(
            itemID: itemID, revisionID: source.revision.revisionID, sessionID: "s",
            sequence: 1, positionSeconds: 10, durationSeconds: 60,
            completed: false, intent: .progress, deviceID: "mac",
            updatedAt: source.outcome.producedAt
        ))
        try await fixture.store.savePreparationOutcome(source.outcome)

        try await fixture.store.replaceReadyRevision(
            prepared.revision, mediaURL: prepared.mediaURL, transcript: prepared.transcript,
            download: prepared.download, superseding: source.revision.revisionID,
            outcome: prepared.outcome
        )

        let sourceRevisionID = source.revision.revisionID
        let sourceTranscript = try await fixture.store.transcript(
            for: itemID, revisionID: sourceRevisionID
        )
        let sourcePlayback = try await fixture.store.playbackState(
            for: itemID, revisionID: sourceRevisionID
        )
        let sourceOutcome = try await fixture.store.preparationOutcome(
            for: itemID, revisionID: sourceRevisionID
        )

        XCTAssertNil(sourceTranscript)
        XCTAssertNil(sourcePlayback)
        XCTAssertEqual(sourceOutcome, source.outcome,
                       "a superseded revision's outcome is preparation history, not orphaned state")
    }
}
