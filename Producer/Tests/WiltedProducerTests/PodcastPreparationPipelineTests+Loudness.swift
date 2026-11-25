import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    @Test func loudnessPolicyDefaultsOffAndOnlyChangesItsOwnDigestWhenEnabled() throws {
        let oldShape = Data(#"{"transcriptPolicy":"bestAvailable","removeAds":false}"#.utf8)
        let decoded = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: oldShape)
        #expect(!decoded.evenOutVoiceLoudness)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
        #expect((encoded as? [String: Any])?.keys.sorted() == ["removeAds", "transcriptPolicy"])

        let optedIn = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: false, evenOutVoiceLoudness: true)
        #expect(PodcastPreparationPipeline.policyDigest(decoded) != PodcastPreparationPipeline.policyDigest(optedIn))
    }

    @Test func newVoiceLevelChoiceDoesNotMarkOldReadyStaleButExplicitPreparationUsesIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let cues: [[String: Any]] = [
            ["startSeconds": 1.25, "endSeconds": 2.5, "text": "Quiet guest."],
            ["startSeconds": 5.0, "endSeconds": 6.5, "text": "Loud host."],
        ]
        let baselinePolicy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: false)
        let baselineWorker = WorkerStub(response: [
            "ok": true, "timing": "published", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "durationSeconds": 12.0, "text": "Quiet guest. Loud host.", "cues": cues,
            "adSegments": [[String: Any]](), "keepIntervals": [[String: Any]](), "removedSeconds": 0.0,
        ])
        let first = try await fixture.pipeline(baselineWorker).prepare(
            episodeID: fixture.episodeID, policy: baselinePolicy)
        try await fixture.store.save(playback: try PlaybackState(
            itemID: fixture.episodeID, revisionID: first.revision.revisionID, sessionID: "listen-1",
            sequence: 7, positionSeconds: 5.25, durationSeconds: 12, completed: false,
            intent: .progress, deviceID: "mac-1",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_250))))

        let optedInPolicy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: false, evenOutVoiceLoudness: true)
        let currentDigest = PodcastPreparationPipeline.policyDigest(optedInPolicy)
        let alternateDigest = PodcastPreparationPipeline.policyDigest(baselinePolicy)
        let offered = try await fixture.store.podcastEpisodesToPrepareAgain(
            preparationPolicyDigestsInForce: { _, _ in
                (current: currentDigest, alternateVoiceLevel: alternateDigest)
            })
        #expect(offered.isEmpty, "the new default alone does not make existing Ready audio stale")

        let changedPolicy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: false, evenOutVoiceLoudness: true)
        let changedAlternate = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: false, evenOutVoiceLoudness: false)
        let changed = try await fixture.store.podcastEpisodesToPrepareAgain(
            preparationPolicyDigestsInForce: { _, _ in
                (current: PodcastPreparationPipeline.policyDigest(changedPolicy),
                 alternateVoiceLevel: PodcastPreparationPipeline.policyDigest(changedAlternate))
            })
        #expect(changed.count == 1, "an independent transcript policy change remains eligible")

        let outputBytes = Data("dynamically-levelled-audio".utf8)
        let worker = WorkerStub(response: [
            "ok": true, "timing": "published", "audioChanged": true, "durationSeconds": 12.0,
            "text": "Quiet guest. Loud host.", "cues": cues,
            "adSegments": [[String: Any]](), "keepIntervals": [[
                "startSeconds": 0.0, "endSeconds": 12.0, "outputStartSeconds": 0.0,
            ]], "removedSeconds": 0.0,
            "audioLoudness": ["inputIntegratedLufs": -19.0, "inputTruePeakDbtp": -4.0,
                               "outputIntegratedLufs": -16.2, "outputTruePeakDbtp": -2.0,
                               "targetIntegratedLufs": -16.0, "truePeakCeilingDbtp": -1.5],
        ], writesCutAudio: outputBytes)

        // The Mac's uncut Prepare Again route admits a fresh ordinary job;
        // this also verifies the immutable policy reaches that worker request.
        let result = try await fixture.pipeline(worker).prepare(
            episodeID: fixture.episodeID, policy: optedInPolicy)
        let requestData = try #require(await worker.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        #expect(request["evenOutVoiceLoudness"] as? Bool == true)
        #expect(result.adRemovalOutcome == "disabled")
        #expect(result.removedSeconds == 0)
        #expect(result.transcript.cues?.map(\.startSeconds) == [1.25, 5.0])
        #expect(result.transcript.cues?.map(\.endSeconds) == [2.5, 6.5])
        #expect(result.transcript.cues?.map(\.text) == ["Quiet guest.", "Loud host."])
        let carried = try #require(try await fixture.store.playbackState(
            for: fixture.episodeID, revisionID: result.revision.revisionID))
        #expect(carried.positionSeconds == 5.25, "identity keeps must not map the playhead to the end")
        #expect(carried.durationSeconds == 12.0)
        #expect(result.revision.revisionID != first.revision.revisionID)
        #expect(try await fixture.store.podcastEpisodesToPrepareAgain(
            preparationPolicyDigestsInForce: { _, _ in
                (current: currentDigest, alternateVoiceLevel: alternateDigest)
            }).isEmpty,
            "after applying this show's policy it is no longer offered")
    }
}
