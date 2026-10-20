import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

/// The per-feed "Remove the show's own promotion" choice: a snapshot field
/// that must leave every snapshot, digest, and worker request made without it
/// exactly as it was before the option existed.
extension PodcastPreparationPipelineTests {
    @Test func policySnapshotStoredBeforeTheOptionDecodesWithItOff() throws {
        let data = Data(#"{"transcriptPolicy":"noLocalSTT","removeAds":false}"#.utf8)

        let snapshot = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: data)

        #expect(snapshot.removeSelfPromotion == false)
        #expect(snapshot == PodcastPreparationPolicySnapshot(transcriptPolicy: .noLocalSTT, removeAds: false))
    }

    @Test func policySnapshotWithTheOptionOffEncodesWithoutTheKey() throws {
        let snapshot = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)

        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )

        #expect(Set(encoded.keys) == ["transcriptPolicy", "removeAds"])
    }

    @Test func policySnapshotWithTheOptionOnRoundTrips() throws {
        let snapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: true, removeSelfPromotion: true
        )

        let data = try JSONEncoder().encode(snapshot)
        let encoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(encoded["removeSelfPromotion"] as? Bool == true)
        #expect(try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: data) == snapshot)
    }

    /// Pinned to the values the digest produced before the option existed, so
    /// a stored outcome never reads as prepared under a different policy.
    @Test(arguments: [
        (PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true),
         "sha256:aba0d63d8fa246707f5baeaf453159ccda1392c7fc912c7c3ba4edb968c311ca"),
        (PodcastPreparationPolicySnapshot(transcriptPolicy: .noLocalSTT, removeAds: false),
         "sha256:590c6406048353349e909bf48b44441c6e9229c1ea88c3e93a918c567c06f2bd"),
    ])
    func policyDigestWithTheOptionOffIsUnchanged(argument: (PodcastPreparationPolicySnapshot, String)) {
        let (policy, pinned) = argument
        let explicitlyOff = PodcastPreparationPolicySnapshot(
            transcriptPolicy: policy.transcriptPolicy, removeAds: policy.removeAds, removeSelfPromotion: false
        )

        #expect(PodcastPreparationPipeline.policyDigest(policy) == pinned)
        #expect(PodcastPreparationPipeline.policyDigest(explicitlyOff) == pinned)
    }

    @Test func policyDigestWithTheOptionOnDiffers() {
        let off = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: true)
        let on = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: true, removeSelfPromotion: true
        )

        #expect(PodcastPreparationPipeline.policyDigest(on) != PodcastPreparationPipeline.policyDigest(off))
        #expect(PodcastPreparationPipeline.policyDigest(on)
            == "sha256:f27960565da9795cd088b63afb14c3c3ae927acc0002a08f079b7bd8b14ce96a")
    }

    @Test(arguments: [false, true])
    func workerRequestCarriesTheOptionOnlyWhenOn(removeSelfPromotion: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let stub = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
        ])
        let policy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: true, removeSelfPromotion: removeSelfPromotion
        )

        let result = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID, policy: policy)

        let data = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if removeSelfPromotion {
            #expect(request["removeSelfPromotion"] as? Bool == true)
        } else {
            #expect(request.keys.contains("removeSelfPromotion") == false)
        }
        let outcome = try #require(
            try await fixture.store.preparationOutcome(for: fixture.episodeID, revisionID: result.revision.revisionID)
        )
        #expect(outcome.policyDigest == PodcastPreparationPipeline.policyDigest(policy))
    }
}
