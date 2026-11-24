import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryHeadlineCardsTests: XCTestCase {
    func testProjectionAndCommandsSurviveOfflineRelaunchWithoutChangingDecisionOutbox() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-headlines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let story = try sampleStory()
        let projection = try sampleProjection(story: story)
        let headlineFile = directory.appendingPathComponent("headline-state.json")
        let legacyFile = directory.appendingPathComponent("pending-intents.json")
        let phone = LibraryHeadlinePhoneState(url: headlineFile)
        phone.bindLocalOwner("owner-a", generation: 7, reviewHold: false)
        phone.replaceProjection(projection, owner: "owner-a", generation: 7)
        let command = LibraryStoryCommandOutboxV1.Command(
            id: "save-1", ownerToken: "owner-a", createdAt: Date(timeIntervalSince1970: 100),
            action: .save(story: story, isSaved: true, basedOnRevision: story.savedRevision),
            delivery: .pending, detail: "Waiting to sync")
        XCTAssertTrue(phone.enqueue(command))

        let legacyIntent = try LibraryIntent.keep(
            entryID: ItemID(rawValue: "episode-1"), deviceID: "phone", id: "legacy-keep")
        let legacyOutbox = LibraryIntentOutbox(url: legacyFile)
        try legacyOutbox.save(.init(
            ownerToken: "owner-a",
            decisions: [LibraryIntentOutbox.Decision(
                intent: legacyIntent,
                baseline: EntryPlacement(removal: .none, isQueued: false, predecessor: nil),
                isSilent: false, retiresEpisode: true, supersededByRestore: false)]))

        let relaunched = LibraryHeadlinePhoneState(url: headlineFile)
        XCTAssertEqual(relaunched.projection, projection)
        XCTAssertEqual(relaunched.commands, [command])
        XCTAssertFalse(relaunched.isBoundToLocalOwner)
        guard case let .saved(legacySaved) = legacyOutbox.load() else { return XCTFail("legacy decisions were not retained") }
        XCTAssertEqual(legacySaved.intents.map(\.id), [legacyIntent.id])

        relaunched.bindLocalOwner("owner-b", generation: 8, reviewHold: false)
        XCTAssertTrue(relaunched.isBoundToLocalOwner)
        XCTAssertNil(relaunched.projection)
        XCTAssertTrue(relaunched.commands.isEmpty)
    }

    func testAccountReviewDoesNotExposeOrRewriteCachedProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-headline-review-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("headline-state.json")
        let story = try sampleStory()
        let projection = try sampleProjection(story: story)
        let state = LibraryHeadlinePhoneState(url: file)
        state.bindLocalOwner("owner-a", generation: 1, reviewHold: false)
        state.replaceProjection(projection, owner: "owner-a", generation: 1)
        let before = try Data(contentsOf: file)

        let held = LibraryHeadlinePhoneState(url: file)
        held.bindLocalOwner("owner-a", generation: 2, reviewHold: true)

        XCTAssertFalse(held.isBoundToLocalOwner)
        XCTAssertEqual(held.projection, projection)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testSaveAndMuteActionsAreOnDiskBeforeTheirSendTasksCanRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-headline-actions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("headline-state.json")
        let owner = "owner-a"
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        let model = LibraryAppModel(transport: transport, deviceID: "phone", headlineStateURL: file)
        let generation = await model.transport.operationGeneration()
        let currentTime = Date()
        let story = try sampleStory(firstSeenAt: currentTime, lastSeenAt: currentTime)
        let projection = try sampleProjection(story: story, updatedAt: currentTime)
        model.headlinePhoneState.bindLocalOwner(owner, generation: generation, reviewHold: false)
        model.headlinePhoneState.replaceProjection(projection, owner: owner, generation: generation)

        model.saveHeadline(story.id, isSaved: true)
        model.setHeadlinePublisherMuted(story.publisherID, isMuted: true)

        guard case let .saved(saved) = LibraryStoryCommandOutboxV1(url: file).load() else {
            return XCTFail("the new commands were not written to the phone")
        }
        XCTAssertEqual(saved.ownerToken, owner)
        XCTAssertEqual(saved.commands.count, 2)
        XCTAssertTrue(saved.commands.allSatisfy { $0.delivery == .pending })
        XCTAssertTrue(saved.commands.contains {
            if case let .save(value, desired, revision) = $0.action {
                return value.id == story.id && desired && revision == story.savedRevision
            }
            return false
        })
        XCTAssertTrue(saved.commands.contains {
            if case let .mute(publisherID, desired, revision) = $0.action {
                return publisherID == story.publisherID && desired && revision == 0
            }
            return false
        })
    }

    func testRecentProjectionDropsExpiredCardsButKeepsSavedStories() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try sampleStory(
            id: "old-story", firstSeenAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            lastSeenAt: now.addingTimeInterval(-8 * 24 * 60 * 60), savedAt: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let oldFeedItem = try sampleStory(
            id: "old-feed-item", firstSeenAt: now, lastSeenAt: now,
            publishedAt: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let recent = try sampleStory(id: "recent-story", firstSeenAt: now, lastSeenAt: now)
        let projection = try sampleProjection(stories: [old, oldFeedItem, recent], revision: 2, updatedAt: now)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner-a"),
            deviceID: "phone", now: { now })
        model.headlinePhoneState.bindLocalOwner("owner-a", generation: 0, reviewHold: false)
        model.headlinePhoneState.replaceProjection(projection, owner: "owner-a", generation: 0)

        XCTAssertEqual(model.recentHeadlineStories.map(\.id), ["recent-story"])
        XCTAssertEqual(Set(model.headlineStories.map(\.id)), ["old-story", "recent-story"])
    }

    func testStaleSaveOutcomeShowsConflictAndExplicitReapplyUsesCurrentRevision() async throws {
        let owner = "owner-a"
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        let model = LibraryAppModel(transport: transport, deviceID: "phone")
        let generation = await model.transport.operationGeneration()
        let currentTime = Date()
        let story = try sampleStory(firstSeenAt: currentTime, lastSeenAt: currentTime)
        let latestStory = try sampleStory(
            id: story.id, firstSeenAt: currentTime, lastSeenAt: currentTime, savedRevision: 1)
        let latest = try sampleProjection(story: latestStory, revision: 2, updatedAt: currentTime)
        model.headlinePhoneState.bindLocalOwner(owner, generation: generation, reviewHold: false)
        model.headlinePhoneState.replaceProjection(latest, owner: owner, generation: generation)
        let command = LibraryStoryCommandOutboxV1.Command(
            id: "save-stale", ownerToken: owner, createdAt: Date(timeIntervalSince1970: 200),
            action: .save(story: story, isSaved: true, basedOnRevision: 0), delivery: .sent,
            detail: "Waiting for your Mac to confirm.")
        XCTAssertTrue(model.headlinePhoneState.enqueue(command))
        let intent = try LibraryIntent.setHeadlineSaved(
            story: story, isSaved: true, basedOnRevision: 0, deviceID: "phone",
            createdAt: command.createdAt, id: command.id)
        let stale = try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonStaleRevision)

        await model.reconcileHeadlineProjection(
            outcomes: [stale], expectedOwner: owner, generation: generation, isCurrent: { true })

        XCTAssertEqual(model.headlinePhoneState.projection, latest)
        XCTAssertEqual(model.headlinePhoneState.commands.first?.delivery, .conflict)
        XCTAssertEqual(model.headlinePhoneState.commands.first?.detail,
                       "The Mac changed this headline. Review the current value, then reapply.")

        model.reapplyHeadlineCommand(command.id)
        let reapplied = try XCTUnwrap(model.headlinePhoneState.commands.first { $0.id != command.id })
        guard case let .save(reappliedStory, isSaved, revision) = reapplied.action else {
            return XCTFail("Reapply did not create a saved-state command")
        }
        XCTAssertEqual(reappliedStory.id, story.id)
        XCTAssertTrue(isSaved)
        XCTAssertEqual(revision, latestStory.savedRevision)
    }

    func testExpiredOfflineSaveRetainsItsCardAndReapplyUsesTheMacIdentityRevision() async throws {
        let owner = "owner-a"
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        let model = LibraryAppModel(transport: transport, deviceID: "phone")
        let generation = await model.transport.operationGeneration()
        let now = Date()
        let story = try sampleStory(
            id: "expired-story", firstSeenAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            lastSeenAt: now.addingTimeInterval(-10 * 24 * 60 * 60))
        let identity = try LibraryHeadlineStoryIdentity(
            id: story.id, publisherID: story.publisherID, link: story.link, savedRevision: 1)
        let publisher = try LibraryHeadlinePublisher(
            id: story.publisherID, name: story.publisherName, isMuted: false, revision: 0)
        let latest = try LibraryHeadlineProjection(
            revision: 2, updatedAt: now, recent: [], saved: [], publishers: [publisher], expiredIdentities: [identity])
        model.headlinePhoneState.bindLocalOwner(owner, generation: generation, reviewHold: false)
        model.headlinePhoneState.replaceProjection(latest, owner: owner, generation: generation)
        let command = LibraryStoryCommandOutboxV1.Command(
            id: "save-expired", ownerToken: owner, createdAt: now,
            action: .save(story: story, isSaved: true, basedOnRevision: 0), delivery: .sent,
            detail: "Waiting for your Mac to confirm.")
        XCTAssertTrue(model.headlinePhoneState.enqueue(command))
        let intent = try LibraryIntent.setHeadlineSaved(
            story: story, isSaved: true, basedOnRevision: 0, deviceID: "phone",
            createdAt: now, id: command.id)
        let stale = try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonStaleRevision)

        await model.reconcileHeadlineProjection(
            outcomes: [stale], expectedOwner: owner, generation: generation, isCurrent: { true })

        XCTAssertTrue(model.recentHeadlineStories.isEmpty)
        XCTAssertEqual(model.headlineCommandStories.map(\.id), [story.id])
        XCTAssertEqual(model.headlinePhoneState.commands.first?.delivery, .conflict)
        model.reapplyHeadlineCommand(command.id)
        let reapplied = try XCTUnwrap(model.headlinePhoneState.commands.first { $0.id != command.id })
        guard case let .save(snapshot, isSaved, revision) = reapplied.action else {
            return XCTFail("Reapply did not preserve the expired story snapshot")
        }
        XCTAssertEqual(snapshot.id, story.id)
        XCTAssertTrue(isSaved)
        XCTAssertEqual(revision, identity.savedRevision)
    }

    func testStaleMuteOutcomeShowsConflictAndExplicitReapplyUsesCurrentRevision() async throws {
        let owner = "owner-a"
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        let model = LibraryAppModel(transport: transport, deviceID: "phone")
        let generation = await model.transport.operationGeneration()
        let story = try sampleStory()
        let publisher = try LibraryHeadlinePublisher(
            id: story.publisherID, name: story.publisherName, isMuted: false, revision: 1)
        let latest = try LibraryHeadlineProjection(
            revision: 2, updatedAt: Date(timeIntervalSince1970: 400), recent: [story], saved: [], publishers: [publisher])
        model.headlinePhoneState.bindLocalOwner(owner, generation: generation, reviewHold: false)
        model.headlinePhoneState.replaceProjection(latest, owner: owner, generation: generation)
        let command = LibraryStoryCommandOutboxV1.Command(
            id: "mute-stale", ownerToken: owner, createdAt: Date(timeIntervalSince1970: 401),
            action: .mute(publisherID: story.publisherID, isMuted: true, basedOnRevision: 0),
            delivery: .sent, detail: "Waiting for your Mac to confirm.")
        XCTAssertTrue(model.headlinePhoneState.enqueue(command))
        let intent = try LibraryIntent.setHeadlinePublisherMuted(
            publisherID: story.publisherID, isMuted: true, basedOnRevision: 0,
            deviceID: "phone", createdAt: command.createdAt, id: command.id)
        let stale = try IntentOutcome.rejected(for: intent, reason: IntentOutcome.reasonStaleRevision)

        await model.reconcileHeadlineProjection(
            outcomes: [stale], expectedOwner: owner, generation: generation, isCurrent: { true })

        XCTAssertEqual(model.headlinePhoneState.projection, latest)
        XCTAssertEqual(model.headlinePhoneState.commands.first?.delivery, .conflict)
        model.reapplyHeadlineCommand(command.id)
        let reapplied = try XCTUnwrap(model.headlinePhoneState.commands.first { $0.id != command.id })
        guard case let .mute(publisherID, isMuted, revision) = reapplied.action else {
            return XCTFail("Reapply did not create a publisher-mute command")
        }
        XCTAssertEqual(publisherID, story.publisherID)
        XCTAssertTrue(isMuted)
        XCTAssertEqual(revision, publisher.revision)
    }

    func testAppliedSaveSettlesOnlyAfterCanonicalProjectionConfirmsIt() async throws {
        let owner = "owner-a"
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: owner)
        let model = LibraryAppModel(transport: transport, deviceID: "phone")
        let generation = await model.transport.operationGeneration()
        let story = try sampleStory()
        let projection = try sampleProjection(story: story)
        model.headlinePhoneState.bindLocalOwner(owner, generation: generation, reviewHold: false)
        model.headlinePhoneState.replaceProjection(projection, owner: owner, generation: generation)
        let command = LibraryStoryCommandOutboxV1.Command(
            id: "save-applied", ownerToken: owner, createdAt: Date(timeIntervalSince1970: 300),
            action: .save(story: story, isSaved: true, basedOnRevision: 0), delivery: .sent,
            detail: "Waiting for your Mac to confirm.")
        XCTAssertTrue(model.headlinePhoneState.enqueue(command))
        let intent = try LibraryIntent.setHeadlineSaved(
            story: story, isSaved: true, basedOnRevision: 0, deviceID: "phone",
            createdAt: command.createdAt, id: command.id)
        let applied = try IntentOutcome.applied(for: intent)

        await model.reconcileHeadlineProjection(
            outcomes: [applied], expectedOwner: owner, generation: generation, isCurrent: { true })
        XCTAssertEqual(model.headlinePhoneState.commands.first?.delivery, .sent)

        let savedStory = try sampleStory(savedAt: Date(timeIntervalSince1970: 301))
        let canonical = try sampleProjection(story: savedStory, revision: 2)
        model.headlinePhoneState.replaceProjection(canonical, owner: owner, generation: generation)
        await model.reconcileHeadlineProjection(
            outcomes: [applied], expectedOwner: owner, generation: generation, isCurrent: { true })

        XCTAssertTrue(model.headlinePhoneState.commands.isEmpty)
        XCTAssertEqual(model.headlinePhoneState.projection, canonical)
    }

    private func sampleStory(
        id: String = "story-1",
        firstSeenAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        savedAt: Date? = nil,
        savedRevision: Int64? = nil,
        publishedAt: Date? = nil
    ) throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: id, title: "A readable headline", publisherID: "feed-1", publisherName: "Example News",
            link: URL(string: "https://example.com/story"), publishedAt: publishedAt ?? firstSeenAt,
            firstSeenAt: firstSeenAt, lastSeenAt: lastSeenAt, savedAt: savedAt,
            savedRevision: savedRevision ?? (savedAt == nil ? 0 : 1))
    }

    private func sampleProjection(
        story: LibraryHeadlineStory,
        revision: Int64 = 1,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> LibraryHeadlineProjection {
        try sampleProjection(stories: [story], revision: revision, updatedAt: updatedAt)
    }

    private func sampleProjection(
        stories: [LibraryHeadlineStory], revision: Int64, updatedAt: Date
    ) throws -> LibraryHeadlineProjection {
        try LibraryHeadlineProjection(
            revision: revision, updatedAt: updatedAt,
            recent: stories.filter { $0.lastSeenAt >= updatedAt.addingTimeInterval(-LibraryHeadlineProjection.recentRetention) },
            saved: stories.filter(\.isSaved),
            publishers: [try LibraryHeadlinePublisher(id: "feed-1", name: "Example News", isMuted: false, revision: 0)])
    }
}
