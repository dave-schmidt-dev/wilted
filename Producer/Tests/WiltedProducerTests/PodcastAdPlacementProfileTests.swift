import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Podcast ad placement profiles")
struct PodcastAdPlacementProfileTests {
    private func identity(_ value: Int) throws -> ItemID {
        try ItemID(rawValue: "item-" + String(format: "%064x", value))
    }

    private func addFeed(_ number: Int, to store: LocalLibraryStore) async throws -> ItemID {
        let url = URL(string: "https://profiles.example.test/feed-\(number).xml")!
        let feedID = try ItemID.derivePodcastFeed(from: url)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: url, title: "Profile Test Feed \(number)",
                                   createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        try await store.save(feed: feed)
        return feedID
    }

    private func observation(feedID: ItemID, episodeID: ItemID, source: Int,
                             slots: [PodcastAdProfileSlot]) -> PodcastAdProfileObservation {
        PodcastAdProfileObservation(feedID: feedID.rawValue, episodeID: episodeID.rawValue,
                                    sourceHash: String(format: "%064x", source), slots: slots)
    }

    private func slot(_ position: PodcastAdProfileSlot.Position = .pre,
                      start: Int = 0, end: Int = 800,
                      entry: [String] = ["Welcome to the show"],
                      returned: [String] = ["Back to the episode"]) -> PodcastAdProfileSlot {
        PodcastAdProfileSlot(position: position, startBasisPoints: start, endBasisPoints: end,
                             entryPhrases: entry, returnPhrases: returned)
    }

    @Test func maximumRevisionFallsBackWithoutOverflowOrPreparationFailure() async throws {
        let directory = try PodcastPreparationPipelineTests.Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedID = try await addFeed(10, to: store)
        let epoch = 1_700_000_000.5
        try await store.save(subscription: PodcastSubscription(feedID: feedID,
            subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let imported = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: Int.max,
            sampleCount: 2, slots: [slot(.pre, start: 0, end: 500)])
        try await store.upsertImportedAdPlacementProfile(imported, feedID: feedID)
        #expect(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: try identity(11), source: 11,
                        slots: [slot(.mid, start: 4_000, end: 5_000)]),
            expectedSubscriptionEpoch: epoch))
        let current = try #require(await store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        #expect(current == imported, "an unrepresentable merged revision leaves the valid imported profile usable")
    }

    @Test func profilePayloadRejectsFloatingPointRevisionIntegers() {
        let feedID = "feed-synth-001"
        let payload = "{\"schemaVersion\":1,\"feedID\":\"feed-synth-001\",\"revision\":1.0,\"sampleCount\":1,\"slots\":[]}"
        let envelope = PodcastAdProfileEnvelope(payload: payload,
            digest: PodcastAdProfileEnvelope.sha256(Data(payload.utf8)))
        #expect(envelope.validatedPayload(expectedFeedID: feedID) == nil)
    }

    @Test func pythonSharedFixtureDecodesWithTheSameExactEnvelopeBytes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = root.appendingPathComponent("Producer/Workers/tests/fixtures/feed_profile_v1.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try #require(try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let envelopeData = try JSONSerialization.data(withJSONObject: fixture["validEnvelope"]!)
        let envelope = try JSONDecoder().decode(PodcastAdProfileEnvelope.self, from: envelopeData)
        let feedID = try #require(fixture["feedID"] as? String)
        let payload = try #require(envelope.validatedPayload(expectedFeedID: feedID))
        #expect(payload.sampleCount == 5)
        #expect(envelope.digest == "c30f57f2c39fcbc52b0e1c2b1e727715282fadf20f258698969ed438a44f07b5")
        let observationData = try JSONSerialization.data(withJSONObject: fixture["validObservation"]!)
        let observation = try JSONDecoder().decode(PodcastAdProfileObservation.self, from: observationData)
        #expect(observation.isValid(feedID: feedID, episodeID: try #require(fixture["episodeID"] as? String),
                                   sourceHash: try #require(fixture["sourceHash"] as? String)))
    }

    @Test func workerNullObservationPreservesConsumedProfileStatusAndDigests() {
        let digest = String(repeating: "a", count: 64)
        let result = PodcastPreparationPipeline.decodeAdProfileResult(from: [
            "adProfileObservation": NSNull(), "adProfileStatus": "applied",
            "adProfileRequestedDigest": digest, "adProfileAppliedDigest": digest
        ])
        #expect(result.observation == nil)
        #expect(result.status == "applied")
        #expect(result.requestedDigest == digest)
        #expect(result.appliedDigest == digest)
    }

    @Test func newSubscriptionStartsUnknownAndLearnsOnlyFromIndependentObservations() async throws {
        let directory = try PodcastPreparationPipelineTests.Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedID = try await addFeed(1, to: store)
        let epoch = 1_700_000_000.25
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))

        let unknown = try #require(await store.adPlacementProfileSnapshot(for: feedID))
        #expect(unknown.subscriptionEpoch == epoch)
        #expect(unknown.envelope == nil)

        let episodeID = try identity(2)
        let independent = observation(feedID: feedID, episodeID: episodeID, source: 1, slots: [slot()])
        let added = try await store.recordAdPlacementObservation(independent, expectedSubscriptionEpoch: epoch)
        #expect(added)
        let learned = try #require(await store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        let decoded = try #require(learned.validatedPayload(expectedFeedID: feedID.rawValue))
        #expect(decoded.sampleCount == 1)
        #expect(decoded.slots == [slot()])
    }

    @Test func observationsDeduplicateSourceAudioAndReplaceChangedEpisodeSources() async throws {
        let directory = try PodcastPreparationPipelineTests.Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedID = try await addFeed(3, to: store)
        let epoch = 1_700_000_001.5
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let episodeID = try identity(4)
        #expect(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: episodeID, source: 10, slots: [slot()]),
            expectedSubscriptionEpoch: epoch))
        #expect(!(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: try identity(5), source: 10, slots: [slot(.mid, start: 4_000, end: 6_000)]),
            expectedSubscriptionEpoch: epoch)), "the same source audio cannot count twice across episode IDs")
        #expect(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: episodeID, source: 11, slots: [slot(.mid, start: 4_000, end: 6_000)]),
            expectedSubscriptionEpoch: epoch), "a changed source replaces this episode's prior analysis")
        for value in 12...32 {
            #expect(try await store.recordAdPlacementObservation(
                observation(feedID: feedID, episodeID: try identity(value), source: value, slots: [slot()]),
                expectedSubscriptionEpoch: epoch))
        }
        let profile = try #require(await store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        #expect(try #require(profile.validatedPayload(expectedFeedID: feedID.rawValue)).sampleCount == 20)
    }

    @Test func importedHintsStayExactUntilIndependentEvidenceAddsNewSlots() async throws {
        let directory = try PodcastPreparationPipelineTests.Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedID = try await addFeed(6, to: store)
        let epoch = 1_700_000_002.75
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let imported = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: 7, sampleCount: 4,
                                                         slots: [slot(.pre, start: 0, end: 500)])
        try await store.upsertImportedAdPlacementProfile(imported, feedID: feedID)
        let initial = try #require(await store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        #expect(initial == imported, "unchanged reviewed bytes and digest are preserved")

        let mid = slot(.mid, start: 3_500, end: 5_000, entry: ["A message from"], returned: ["Now back to"])
        #expect(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: try identity(7), source: 70, slots: [mid]),
            expectedSubscriptionEpoch: epoch))
        let merged = try #require(await store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        #expect(merged != imported)
        let payload = try #require(merged.validatedPayload(expectedFeedID: feedID.rawValue))
        #expect(payload.slots == [slot(.pre, start: 0, end: 500), mid])
        #expect(payload.revision > 7)

        let file = directory.appendingPathComponent("ad-placement-profiles.json")
        let bytes = try Data(contentsOf: file)
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let record = try #require((object["feeds"] as? [[String: Any]])?.first)
        #expect(record["importedProfile"] as? [String: String] == ["payload": imported.payload, "digest": imported.digest])
    }

    @Test func unsubscribeAndResubscribeRejectAnOldInFlightGeneration() async throws {
        let directory = try PodcastPreparationPipelineTests.Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feedID = try await addFeed(8, to: store)
        let firstEpoch = 1_700_000_003.125
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: firstEpoch))))
        #expect(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: try identity(9), source: 90, slots: [slot()]),
            expectedSubscriptionEpoch: firstEpoch))
        _ = try await store.unsubscribeFromPodcast(feedID: feedID)

        let newEpoch = firstEpoch + 10
        let feedURL = URL(string: "https://profiles.example.test/feed-8.xml")!
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Resubscribed Feed",
            createdAt: Timestamp(Date(timeIntervalSince1970: newEpoch))))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: newEpoch))))
        let current = try #require(await store.adPlacementProfileSnapshot(for: feedID))
        #expect(current.envelope == nil)
        #expect(current.subscriptionEpoch == newEpoch)
        #expect(!(try await store.recordAdPlacementObservation(
            observation(feedID: feedID, episodeID: try identity(9), source: 90, slots: [slot()]),
            expectedSubscriptionEpoch: firstEpoch)), "a stale worker result cannot repopulate a later subscription")
    }

    @Test func firstPreparationBuildsAProfileUsedByTheNextPreparation() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedID = try ItemID.derivePodcastFeed(from: URL(string: "https://feeds.example.test/show.xml")!)
        let epoch = 1_700_000_011.25
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let rawHash = String(fixture.contentHash.dropFirst("sha256:".count))
        let learnedSlot = slot(.pre, start: 0, end: 700, entry: ["This is our show"], returned: ["Back to the conversation"])
        let observed = PodcastAdProfileObservation(feedID: feedID.rawValue, episodeID: fixture.episodeID.rawValue,
                                                   sourceHash: rawHash, slots: [learnedSlot])
        let observationObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed))
        let firstWorker = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adProfileObservation": observationObject
        ])
        _ = try await fixture.pipeline(firstWorker).prepare(episodeID: fixture.episodeID)
        let firstRequest = try #require(await firstWorker.lastRequest())
        let firstObject = try #require(try JSONSerialization.jsonObject(with: firstRequest) as? [String: Any])
        #expect(firstObject["feedID"] as? String == feedID.rawValue)
        #expect(firstObject["episodeID"] as? String == fixture.episodeID.rawValue)
        #expect(firstObject["adProfile"] == nil, "a new feed begins with generic analysis")

        let learned = try #require(await fixture.store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        let secondWorker = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adProfileObservation": NSNull(), "adProfileStatus": "applied",
            "adProfileRequestedDigest": learned.digest, "adProfileAppliedDigest": learned.digest
        ])
        _ = try await fixture.pipeline(secondWorker).prepare(episodeID: fixture.episodeID)
        let secondRequest = try #require(await secondWorker.lastRequest())
        let secondObject = try #require(try JSONSerialization.jsonObject(with: secondRequest) as? [String: Any])
        #expect(secondObject["adProfile"] as? [String: String] == ["payload": learned.payload, "digest": learned.digest])
    }

    @Test func prepareAgainKeepsItsProfileSnapshotWhileStagingUpdatesTheStore() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedID = try ItemID.derivePodcastFeed(from: URL(string: "https://feeds.example.test/show.xml")!)
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        let epoch = 1_700_000_012.75
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let oldSlot = slot(.pre, start: 0, end: 800)
        let oldProfile = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: 3, sampleCount: 2, slots: [oldSlot])
        try await fixture.store.upsertImportedAdPlacementProfile(oldProfile, feedID: feedID)

        let ready = try #require(try await fixture.store.readyRevision(for: fixture.episodeID))
        let candidate = PodcastPrepareAgainCandidate(episodeID: fixture.episodeID, readyRevision: ready,
            isCut: false, keptTimeline: nil, sourceHash: fixture.contentHash,
            enclosureURL: feedURL)
        let staged = try fixture.staged(PodcastPreparationPipelineTests.Fixture.originalBody)
        let newSlot = slot(.post, start: 9_000, end: 10_000, entry: ["Thank you for listening"], returned: [])
        let newProfile = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: 1, sampleCount: 1, slots: [newSlot])
        let rawHash = String(fixture.contentHash.dropFirst("sha256:".count))
        let observedSlot = slot(.mid, start: 3_000, end: 4_500, entry: ["A message from"], returned: ["Back to the show"])
        let observation = PodcastAdProfileObservation(feedID: feedID.rawValue, episodeID: fixture.episodeID.rawValue,
                                                       sourceHash: rawHash, slots: [observedSlot])
        let observationObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))
        let worker = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": staged.url.path, "audioChanged": false,
            "adProfileObservation": observationObject, "adProfileStatus": "applied",
            "adProfileRequestedDigest": oldProfile.digest, "adProfileAppliedDigest": oldProfile.digest
        ])
        _ = try await fixture.pipeline(worker).prepareAgain(candidate: candidate, stage: {
            try await fixture.store.upsertImportedAdPlacementProfile(newProfile, feedID: feedID)
            return staged
        })
        let requestBytes = try #require(await worker.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any])
        #expect(request["adProfile"] as? [String: String] == ["payload": oldProfile.payload, "digest": oldProfile.digest],
                "staging changes apply to future attempts only")
        let stored = try #require(await fixture.store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        let effective = try #require(stored.validatedPayload(expectedFeedID: feedID.rawValue))
        #expect(effective.slots.contains(newSlot))
        #expect(effective.slots.contains(observedSlot))
    }

    @Test func oversizedProfileStoreFallsBackToGenericPreparation() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_020))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID,
            subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_020))))
        let profileFile = fixture.root.appendingPathComponent("ad-placement-profiles.json")
        try Data(repeating: 0x41, count: 1_048_577).write(to: profileFile)
        let worker = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false
        ])
        _ = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        let requestBytes = try #require(await worker.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any])
        #expect(request["adProfile"] == nil)
    }

    @Test func adsDisabledNeverSendsAnAvailableProfile() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let epoch = 1_700_000_022.5
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID,
            subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let profile = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: 1, sampleCount: 1, slots: [slot()])
        try await fixture.store.upsertImportedAdPlacementProfile(profile, feedID: feedID)
        let worker = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false
        ])
        _ = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID,
            policy: PodcastPreparationPolicySnapshot(transcriptPolicy: .noLocalSTT, removeAds: false))
        let request = try #require(await worker.lastRequest())
        let object = try #require(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(object["adProfile"] == nil)
        let journal = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let requestEvidence = journal.compactMap(\.status.evidence).first { $0.kind == "ad-profile-request" }
        #expect(requestEvidence?.fields["status"] == "not-requested")
    }

    @Test func mismatchedWorkerDigestIsNotReportedAsApplied() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let epoch = 1_700_000_023.5
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID,
            subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let imported = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: 1, sampleCount: 1, slots: [slot()])
        try await fixture.store.upsertImportedAdPlacementProfile(imported, feedID: feedID)
        let worker = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adProfileStatus": "applied", "adProfileRequestedDigest": String(repeating: "f", count: 64),
            "adProfileAppliedDigest": imported.digest
        ])
        _ = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        let journal = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let evidence = journal.compactMap(\.status.evidence).first { $0.kind == "ad-profile-result" }
        #expect(evidence?.fields["status"] == "invalid")
        #expect(evidence?.fields["requestedDigest"] == imported.digest)
        #expect(evidence?.fields["appliedDigest"] == nil)

        let unused = WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adProfileStatus": "absent", "adProfileRequestedDigest": imported.digest,
            "adProfileAppliedDigest": NSNull()
        ])
        _ = try await fixture.pipeline(unused).prepare(episodeID: fixture.episodeID)
        let unusedJournal = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let unusedEvidence = unusedJournal.compactMap(\.status.evidence).first { $0.kind == "ad-profile-result" }
        #expect(unusedEvidence?.fields["status"] == "absent")
        #expect(unusedEvidence?.fields["requestedDigest"] == imported.digest)
        #expect(unusedEvidence?.fields["appliedDigest"] == nil)
    }

    @Test func cancelledWorkerResultCannotTeachAnAutomaticProfile() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let epoch = 1_700_000_024.5
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID,
            subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let observation = PodcastAdProfileObservation(feedID: feedID.rawValue, episodeID: fixture.episodeID.rawValue,
            sourceHash: String(fixture.contentHash.dropFirst("sha256:".count)), slots: [slot()])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))
        let worker = CancellingAfterResponseWorker(WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adProfileObservation": object
        ]))
        let pipeline = fixture.pipeline(worker)
        let task = Task { try await pipeline.prepare(episodeID: fixture.episodeID) }
        _ = try? await task.value
        let profile = try #require(await fixture.store.adPlacementProfileSnapshot(for: feedID))
        #expect(profile.envelope == nil)
    }

    @Test func failedWorkerCannotTeachAnAutomaticProfile() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let epoch = 1_700_000_021.25
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let observation = PodcastAdProfileObservation(feedID: feedID.rawValue, episodeID: fixture.episodeID.rawValue,
            sourceHash: String(fixture.contentHash.dropFirst("sha256:".count)), slots: [slot()])
        let observationObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))
        let worker = WorkerStub(response: ["ok": false, "code": "model-failed", "message": "failed",
                                            "adProfileObservation": observationObject])
        await #expect(throws: PodcastPreparationError.workerFailed(code: "model-failed", message: "failed")) {
            _ = try await fixture.pipeline(worker).prepare(episodeID: fixture.episodeID)
        }
        let profile = try #require(await fixture.store.adPlacementProfileSnapshot(for: feedID))
        #expect(profile.envelope == nil)
    }

    @Test func preparationSendsTheExactProfileAndSavesItsIndependentObservation() async throws {
        let fixture = try await PodcastPreparationPipelineTests.Fixture()
        defer { fixture.remove() }
        let feedID = try ItemID.derivePodcastFeed(from: URL(string: "https://feeds.example.test/show.xml")!)
        let epoch = 1_700_000_010.5
        let feedURL = URL(string: "https://feeds.example.test/show.xml")!
        try await fixture.store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        try await fixture.store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: epoch))))
        let importedSlot = slot(.pre, start: 0, end: 900)
        let imported = try PodcastAdProfileEnvelope.make(feedID: feedID.rawValue, revision: 2, sampleCount: 3,
                                                         slots: [importedSlot])
        try await fixture.store.upsertImportedAdPlacementProfile(imported, feedID: feedID)
        let rawSourceHash = String(fixture.contentHash.dropFirst("sha256:".count))
        let observedSlot = slot(.mid, start: 3_000, end: 4_800, entry: ["A message from"], returned: ["Back to the show"])
        let observed = PodcastAdProfileObservation(feedID: feedID.rawValue, episodeID: fixture.episodeID.rawValue,
                                                   sourceHash: rawSourceHash, slots: [observedSlot])
        let observationObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(observed)) as? [String: Any])
        let response: [String: Any] = [
            "ok": true, "timing": "none", "audioPath": fixture.audioURL.path, "audioChanged": false,
            "adProfileObservation": observationObject, "adProfileStatus": "applied",
            "adProfileRequestedDigest": imported.digest, "adProfileAppliedDigest": imported.digest
        ]
        let stub = WorkerStub(response: response)
        _ = try await fixture.pipeline(stub).prepare(episodeID: fixture.episodeID)

        let requestBytes = try #require(await stub.lastRequest())
        let request = try #require(try JSONSerialization.jsonObject(with: requestBytes) as? [String: Any])
        #expect(request["feedID"] as? String == feedID.rawValue)
        #expect(request["episodeID"] as? String == fixture.episodeID.rawValue)
        let sentProfile = try #require(request["adProfile"] as? [String: String])
        #expect(sentProfile == ["payload": imported.payload, "digest": imported.digest])
        let journal = try await fixture.store.preparationJournal(
            for: PodcastPreparationPipeline.requestID(for: fixture.episodeID))
        let requestEvidence = journal.compactMap(\.status.evidence).first { $0.kind == "ad-profile-request" }
        #expect(requestEvidence?.fields["status"] == "not-observed")
        #expect(requestEvidence?.fields["requestedDigest"] == imported.digest)
        let resultEvidence = journal.compactMap(\.status.evidence).first { $0.kind == "ad-profile-result" }
        #expect(resultEvidence?.fields["status"] == "applied")
        #expect(resultEvidence?.fields["appliedDigest"] == imported.digest)
        let learned = try #require(await fixture.store.adPlacementProfileSnapshot(for: feedID)?.envelope)
        let payload = try #require(learned.validatedPayload(expectedFeedID: feedID.rawValue))
        #expect(payload.slots.contains(observedSlot))
        #expect(payload.slots.contains(importedSlot))
    }
}


private actor CancellingAfterResponseWorker: PodcastPipelineRunning {
    private let delegate: WorkerStub

    init(_ delegate: WorkerStub) { self.delegate = delegate }

    func codeRevision() async -> String? { nil }

    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        let response = try await delegate.run(request: request, onProgress: onProgress)
        withUnsafeCurrentTask { $0?.cancel() }
        return response
    }
}
