import Foundation
import SwiftUI
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class LibraryNotebookViewTests: XCTestCase {
    func testSavedHeadlinesShareNotebookAndRemainOwnerScoped() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let link = try XCTUnwrap(URL(string: "https://news.example.test/story"))
        let saved = try LibraryHeadlineStory(
            id: "saved-story", title: "A saved headline", publisherID: "news",
            publisherName: "Example News", link: link, publishedAt: now, firstSeenAt: now,
            lastSeenAt: now, savedAt: now, savedRevision: 1)
        let publisher = try LibraryHeadlinePublisher(id: "news", name: "Example News", isMuted: false, revision: 0)
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: now, recent: [], saved: [saved], publishers: [publisher])
        fixture.model.headlinePhoneState.bindLocalOwner("owner-a", generation: 0, reviewHold: false)
        fixture.model.headlinePhoneState.replaceProjection(projection, owner: "owner-a", generation: 0)
        fixture.model.notebookPhoneState.bind(
            ownerToken: "owner-a", deviceID: "phone", generation: 0, reviewHold: false)

        let host = HostedView(LibraryNotebookView(model: fixture.model, player: fixture.makePlayer()))
        XCTAssertEqual(fixture.model.notebookSavedHeadlineStories.map(\.id), [saved.id])
        XCTAssertNotNil(host.element("wilted-library-headline-read-\(saved.id)"))
        XCTAssertNotNil(host.element("wilted-library-headline-save-\(saved.id)"))
        XCTAssertNotNil(host.element("wilted-library-headline-listen-next-\(saved.id)"))
        XCTAssertEqual(fixture.model.notebookSavedHeadlineStories.first?.link, link)

        fixture.model.headlinePhoneState.bindLocalOwner("owner-b", generation: 1, reviewHold: false)
        XCTAssertTrue(fixture.model.notebookSavedHeadlineStories.isEmpty,
                      "saved headlines from the prior account never appear in Notebook")
        XCTAssertNil(fixture.model.headlinePhoneState.projection,
                     "a switch to another account clears the prior owner's cached projection")
        XCTAssertTrue(fixture.model.headlinePhoneState.commands.isEmpty,
                      "the prior owner's commands are canceled on account change")
    }

    func testPendingOfflineHeadlineSaveAppearsOnlyForItsBoundOwner() throws {
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "pending-story", title: "Waiting to sync", publisherID: "news",
            publisherName: "Example News", link: URL(string: "https://news.example.test/pending"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: now, recent: [story], saved: [], publishers: [])
        fixture.model.headlinePhoneState.bindLocalOwner("owner-a", generation: 0, reviewHold: false)
        fixture.model.headlinePhoneState.replaceProjection(projection, owner: "owner-a", generation: 0)
        let command = LibraryStoryCommandOutboxV1.Command(
            id: "pending-save", ownerToken: "owner-a", createdAt: now,
            action: .save(story: story, isSaved: true, basedOnRevision: story.savedRevision),
            delivery: .pending, detail: "Waiting to sync")
        XCTAssertTrue(fixture.model.headlinePhoneState.enqueue(command))

        let saved = try XCTUnwrap(fixture.model.notebookSavedHeadlineStories.first)
        XCTAssertEqual(saved.id, story.id)
        XCTAssertTrue(saved.isSaved)
        XCTAssertEqual(saved.link, story.link)

        let existingSaved = try LibraryHeadlineStory(
            id: "already-saved", title: "Already in Notebook", publisherID: "news",
            publisherName: "Example News", link: URL(string: "https://news.example.test/already-saved"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now, savedAt: now, savedRevision: 1)
        let overlappingProjection = try LibraryHeadlineProjection(
            revision: 2, updatedAt: now, recent: [existingSaved], saved: [existingSaved], publishers: [])
        fixture.model.headlinePhoneState.replaceProjection(
            overlappingProjection, owner: "owner-a", generation: 0)
        let duplicateSave = LibraryStoryCommandOutboxV1.Command(
            id: "duplicate-save", ownerToken: "owner-a", createdAt: now,
            action: .save(story: existingSaved, isSaved: true, basedOnRevision: existingSaved.savedRevision),
            delivery: .pending, detail: "Waiting to sync")
        XCTAssertTrue(fixture.model.headlinePhoneState.enqueue(duplicateSave))
        XCTAssertEqual(
            fixture.model.notebookSavedHeadlineStories.filter { $0.id == existingSaved.id }.count, 1,
            "recent, saved, and pending state for a story share one Notebook row")

        fixture.model.headlinePhoneState.bindLocalOwner("owner-b", generation: 1, reviewHold: false)
        XCTAssertTrue(fixture.model.notebookSavedHeadlineStories.isEmpty)
        XCTAssertTrue(fixture.model.headlinePhoneState.commands.isEmpty,
                      "an offline save is not retried under a different account")
    }

    func testOfflineHeadlinesShowAvailabilityInsteadOfAnEmptyNotebook() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }
        fixture.model.headlinePhoneState.bindLocalOwner("owner-a", generation: 0, reviewHold: false)
        fixture.model.headlinePhoneState.noteRefreshFailure(true)

        let unavailableHost = HostedView(
            LibraryNotebookView(model: fixture.model, player: fixture.makePlayer()))
        let unavailableState = try XCTUnwrap(unavailableHost.element("wilted-notebook-empty"))
        XCTAssertEqual(unavailableState.label, "Saved stories are unavailable",
                       "offline unknown headlines must not be labelled as an empty Notebook")
        XCTAssertEqual(unavailableState.value, "Saved headlines are unavailable while offline.")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let story = try LibraryHeadlineStory(
            id: "cached-story", title: "Saved while offline", publisherID: "news",
            publisherName: "Example News", link: URL(string: "https://news.example.test/cached"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now, savedAt: now, savedRevision: 1)
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: now, recent: [], saved: [story], publishers: [])
        fixture.model.headlinePhoneState.replaceProjection(projection, owner: "owner-a", generation: 0)

        let cachedHost = HostedView(
            LibraryNotebookView(model: fixture.model, player: fixture.makePlayer()))
        XCTAssertNotNil(cachedHost.element("wilted-notebook-headline-availability"))
        XCTAssertNotNil(cachedHost.element("wilted-library-headline-read-cached-story"),
                        "cached saved stories remain available offline")
    }

    func testEmptyOfflineAndUnreadableStatesRemainAccessibleInLightAndDark() async throws {
        await HostedAccessibility.prepare()
        let fixture = try LibraryViewFixture()
        defer { fixture.tearDown() }

        fixture.model.notebookPhoneState.bind(ownerToken: nil, deviceID: "phone", generation: 0, reviewHold: false)
        fixture.model.notebookPhoneState.notice = "Saved on this phone · waiting to sync"
        for dark in [false, true] {
            let hosted = HostedView(
                LibraryNotebookView(model: fixture.model, player: fixture.makePlayer()), dark: dark)
            XCTAssertNotNil(hosted.element("wilted-notebook-empty"), "empty state remains visible, dark=\(dark)")
            let emptyState = try XCTUnwrap(hosted.element("wilted-notebook-empty"))
            XCTAssertEqual(emptyState.label, "Notebook is waiting to sync")
            XCTAssertEqual(emptyState.value, "Saved headlines appear after this library syncs.")
            XCTAssertNotNil(hosted.element("wilted-notebook-notice"), "offline status remains visible, dark=\(dark)")
        }

        let unreadableURL = fixture.scratch.appendingPathComponent("unreadable-notebook.json")
        try Data("not-json".utf8).write(to: unreadableURL)
        let failedModel = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "Offline fixture"),
            store: InMemoryLibraryStore(), deviceID: "phone", mediaCache: fixture.cache,
            notebookOutboxURL: unreadableURL)
        XCTAssertTrue(failedModel.notebookPhoneState.readFailed)
        for dark in [false, true] {
            let hosted = HostedView(
                LibraryNotebookView(model: failedModel, player: fixture.makePlayer()), dark: dark)
            XCTAssertNotNil(hosted.element("wilted-notebook-empty"), "error does not hide retained empty state, dark=\(dark)")
            let emptyState = try XCTUnwrap(hosted.element("wilted-notebook-empty"))
            XCTAssertEqual(emptyState.label, "Notebook is waiting to sync")
            XCTAssertEqual(emptyState.value, "Saved headlines appear after this library syncs.")
            XCTAssertNotNil(hosted.element("wilted-notebook-notice"), "read error has a visible status, dark=\(dark)")
        }
    }
}
