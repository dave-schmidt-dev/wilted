import Combine
import Foundation
@preconcurrency import Intents
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class MediaSiriContextTests: XCTestCase {
    // MARK: - Donations

    func testPlayFromTheAppRecordsSiriKitDonation() {
        let donor = VoiceRecordingDonor()
        let donations = IntentDonor(donor: donor)
        let item = LibraryPlayer.Item(
            entryID: try! ItemID(rawValue: "ep-1"),
            title: "Tide Pools",
            showTitle: "Short Wave",
            fileURL: URL(fileURLWithPath: "/dev/null")
        )

        donations.played(item)

        XCTAssertEqual(donor.siriKitPlays.count, 1, "a play from the app must record a SiriKit donation")
        guard let episode = donor.siriKitPlays.first,
              let intent = SiriKitPlayDonation.interaction(for: episode).intent as? INPlayMediaIntent else {
            XCTFail("expected INPlayMediaIntent donation")
            return
        }

        let mediaItem = intent.mediaItems?.first
        XCTAssertEqual(mediaItem?.identifier, "ep-1")
        XCTAssertEqual(mediaItem?.title, "Tide Pools")
        XCTAssertEqual(mediaItem?.type, .podcastEpisode)
        XCTAssertEqual(mediaItem?.artist, "Short Wave")

        let container = intent.mediaContainer
        XCTAssertEqual(container?.type, .podcastShow)
        XCTAssertEqual(container?.title, "Short Wave")
    }

    func testSiriRunPlayRecordsNoSiriKitDonation() async {
        let donor = VoiceRecordingDonor()
        let donations = IntentDonor(donor: donor)
        let item = LibraryPlayer.Item(
            entryID: try! ItemID(rawValue: "ep-2"),
            title: "Gold Rush",
            showTitle: "Planet Money",
            fileURL: URL(fileURLWithPath: "/dev/null")
        )

        await donations.withoutDonatingPlay(of: item.entryID) {
            donations.played(item)
        }

        XCTAssertTrue(donor.siriKitPlays.isEmpty, "a Siri-run play must record no SiriKit donation")
        XCTAssertTrue(donor.played.isEmpty, "a Siri-run play must record no AppIntents donation")
    }

    // MARK: - Vocabulary and Library Count

    func testVocabularyEqualsCurrentShowTitlesAfterShowAddedAndRemoved() {
        let service = RecordingMediaSiriContext()
        let context = MediaSiriContext(service: service)

        context.update(downloadedCount: 1, showTitles: ["Short Wave"])
        XCTAssertEqual(service.latestVocabulary, ["Short Wave"])

        // Show added
        context.update(downloadedCount: 2, showTitles: ["Short Wave", "Planet Money"])
        XCTAssertEqual(service.latestVocabulary, ["Short Wave", "Planet Money"])

        // Show removed
        context.update(downloadedCount: 1, showTitles: ["Planet Money"])
        XCTAssertEqual(service.latestVocabulary, ["Planet Money"])

        // Last show removed
        context.update(downloadedCount: 0, showTitles: [])
        XCTAssertEqual(service.latestVocabulary, [])
    }

    func testLibraryCountMatchesDownloadedEpisodeCountAfterAddedAndRemoved() {
        let service = RecordingMediaSiriContext()
        let context = MediaSiriContext(service: service)

        context.update(downloadedCount: 0, showTitles: ["Short Wave"])
        XCTAssertEqual(service.latestLibraryCount, 0)

        // Episode downloaded (added)
        context.update(downloadedCount: 1, showTitles: ["Short Wave"])
        XCTAssertEqual(service.latestLibraryCount, 1)

        // Another episode downloaded
        context.update(downloadedCount: 2, showTitles: ["Short Wave"])
        XCTAssertEqual(service.latestLibraryCount, 2)

        // Episode removed
        context.update(downloadedCount: 1, showTitles: ["Short Wave"])
        XCTAssertEqual(service.latestLibraryCount, 1)

        // All downloaded episodes removed
        context.update(downloadedCount: 0, showTitles: ["Short Wave"])
        XCTAssertEqual(service.latestLibraryCount, 0)
    }

    // MARK: - Model Observation

    func testModelObservationUpdatesVocabularyAndLibraryCount() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "owner"),
            store: InMemoryLibraryStore(),
            deviceID: "phone",
            preferences: UserDefaults(suiteName: "media-siri-context-tests-\(UUID().uuidString)")!,
            timeZone: TimeZone(identifier: "UTC")!
        )

        let service = RecordingMediaSiriContext()
        let context = MediaSiriContext(service: service)
        let cancellable = MediaSiriContext.observe(model, context: context)
        defer { cancellable.cancel() }

        let showAID = try ItemID(rawValue: "show-a")
        let showBID = try ItemID(rawValue: "show-b")
        let ep1ID = try ItemID(rawValue: "ep-1")
        let ep2ID = try ItemID(rawValue: "ep-2")

        let changes: [LibraryChange] = [
            .source(LibrarySource(id: showAID, kind: .podcastFeed, title: "Show A")),
            .source(LibrarySource(id: showBID, kind: .podcastFeed, title: "Show B")),
            .entry(try LibraryEntry(id: ep1ID, kind: .podcastEpisode, sourceID: showAID, title: "Ep 1", summary: "", publishedAt: Date(), durationSeconds: 600)),
            .entry(try LibraryEntry(id: ep2ID, kind: .podcastEpisode, sourceID: showBID, title: "Ep 2", summary: "", publishedAt: Date(), durationSeconds: 600)),
            .slot(try QueueSlot(entryID: ep1ID, sortKey: 1.0)),
            .slot(try QueueSlot(entryID: ep2ID, sortKey: 2.0)),
        ]
        let pushed = try await mac.push(changes: changes.enumerated().map { PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0) })
        let ep2SlotVersion = try XCTUnwrap(pushed.acknowledged.first { $0.key == LibraryRecordKey(kind: .slot, id: ep2ID) }?.version)
        await model.start()

        XCTAssertEqual(service.latestVocabulary, ["Show A", "Show B"], "vocabulary reflects all show titles in queue")
        XCTAssertEqual(service.latestLibraryCount, 0, "nothing downloaded yet")

        // Download ep 1
        model.media[ep1ID] = .onPhone
        XCTAssertEqual(service.latestLibraryCount, 1, "library count rises to 1 when episode downloaded")

        // Download ep 2
        model.media[ep2ID] = .onPhone
        XCTAssertEqual(service.latestLibraryCount, 2, "library count rises to 2 when second episode downloaded")

        // Remove ep 1 download
        model.media[ep1ID] = .available
        XCTAssertEqual(service.latestLibraryCount, 1, "library count falls to 1 when episode removed")

        // Remove ep 2 from queue
        let removeResult = try await mac.push(changes: [PendingLibraryChange(localSeq: 100, change: .slotRemoved(entryID: ep2ID), baseVersion: ep2SlotVersion)])
        XCTAssertTrue(removeResult.failures.isEmpty)
        await model.refresh()

        XCTAssertEqual(service.latestVocabulary, ["Show A"], "vocabulary reflects removal of Show B")
    }
}
