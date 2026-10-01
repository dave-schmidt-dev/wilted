import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The Larder list: prepared-only rows, Mac-parity sorting, filtering, search, row detail, and
/// where Play resumes. Pure logic first, then the model against the in-memory transport.
@MainActor
final class LibraryLarderTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let suite = "library-larder-tests"
    private var scratch: URL!
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    private let payload = Data((0..<20_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-larder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func ids(_ rows: [LibraryRow]) -> [String] { rows.map(\.id.rawValue) }

    private func row(
        _ raw: String, title: String? = nil, show: String = "Show", published: TimeInterval = 1_000,
        duration: Double? = 600, summary: String = ""
    ) -> LibraryRow {
        LibraryRow(
            id: id(raw), title: title ?? raw, showTitle: show,
            durationText: duration.map(LibraryClockFormat.duration), durationSeconds: duration,
            removal: .none, publishedAt: Date(timeIntervalSince1970: published), removalText: nil,
            checkpointText: nil, summary: summary)
    }

    private func list(
        _ rows: [LibraryRow], offered: [String] = [], onPhone: [String] = [],
        filter: LibraryFilter = .all, query: String = ""
    ) -> [String] {
        ids(LibraryListing.rows(
            rows, offered: Set(offered.map(id)), onPhone: Set(onPhone.map(id)), filter: filter, query: query))
    }

    // MARK: pure listing

    func testOnlyOfferedOrCachedRowsAreListed() {
        let rows = ["a", "b", "c", "d"].map { row($0) }
        XCTAssertEqual(list(rows, offered: ["b"], onPhone: ["d"]), ["b", "d"])
        XCTAssertEqual(list(rows), [])
    }

    func testListIsAlwaysThePlayOrderNotTheMacsQueueOrder() {
        let rows = [
            row("a", title: "Beta", published: 300),
            row("b", title: "alpha 10", published: 100),
            row("c", title: "Alpha 2", published: 200),
            row("d", title: "Gamma", published: 200),
        ]
        XCTAssertEqual(list(rows, offered: ["a", "b", "c", "d"]), ["b", "c", "d", "a"], "oldest published first, ties in queue order")
    }

    func testFilterSplitsOnPhoneFromAvailable() {
        let rows = ["a", "b", "c"].map { row($0) }
        XCTAssertEqual(list(rows, offered: ["a", "b"], onPhone: ["c"], filter: .onPhone), ["c"])
        XCTAssertEqual(list(rows, offered: ["a", "b"], onPhone: ["c"], filter: .available), ["a", "b"])
        XCTAssertEqual(list(rows, offered: ["a", "b", "c"], onPhone: ["c"], filter: .available), ["a", "b"], "on phone is not available")
    }

    func testSearchMatchesTitleShowAndNotesIgnoringCaseAndPadding() {
        let rows = [
            row("a", title: "Rust Belt", show: "Radio"),
            row("b", title: "Other", show: "Rusty Nail"),
            row("c", title: "Third", show: "Radio", summary: "A history of RUST."),
            row("d", title: "Fourth", show: "Radio"),
        ]
        XCTAssertEqual(list(rows, offered: ["a", "b", "c", "d"], query: "  rust "), ["a", "b", "c"])
        XCTAssertEqual(list(rows, offered: ["a", "b", "c", "d"], query: ""), ["a", "b", "c", "d"])
        XCTAssertEqual(list(rows, offered: ["a", "b", "c", "d"], query: "nothing"), [])
    }

    func testResumePositionIgnoresStartAndEnd() {
        func observed(_ position: Double) throws -> ObservedPlayback {
            ObservedPlayback(
                record: try DevicePlaybackPosition(
                    deviceID: "mac", entryID: id("a"), revision: RevisionID(rawValue: "rev-1"),
                    positionSeconds: position, isPlaying: false, epoch: 1),
                serverModifiedAt: Date())
        }
        XCTAssertNil(LibraryRowBuilder.resumeSeconds(nil, duration: 600))
        XCTAssertNil(LibraryRowBuilder.resumeSeconds(try observed(0), duration: 600))
        XCTAssertEqual(LibraryRowBuilder.resumeSeconds(try observed(754), duration: 1_800), 754)
        XCTAssertEqual(LibraryRowBuilder.resumeSeconds(try observed(754), duration: nil), 754)
        XCTAssertNil(LibraryRowBuilder.resumeSeconds(try observed(600), duration: 600))
    }

    func testArtworkOnlyLoadsFromWebAddresses() {
        XCTAssertEqual(LibraryRowBuilder.artworkURL("https://example.com/a.jpg")?.absoluteString, "https://example.com/a.jpg")
        XCTAssertNil(LibraryRowBuilder.artworkURL("file:///etc/passwd"))
        XCTAssertNil(LibraryRowBuilder.artworkURL("not a url"))
        XCTAssertNil(LibraryRowBuilder.artworkURL(nil))
    }

    func testDownloadingTextShowsRateAndTimeLeftOnceThereIsData() {
        XCTAssertEqual(LibraryMediaState.rateSuffix(bytes: 0, total: 1_000, elapsed: 10), "")
        XCTAssertEqual(LibraryMediaState.rateSuffix(bytes: 500, total: 1_000, elapsed: 1), "")
        let suffix = LibraryMediaState.rateSuffix(bytes: 5_000_000, total: 10_000_000, elapsed: 10)
        XCTAssertTrue(suffix.hasSuffix("00:10 left"), suffix)
        XCTAssertTrue(suffix.contains("/s"))
    }

    // MARK: model

    private func makeModel(preferences: UserDefaults? = nil, cache: FileMediaCache? = nil) -> LibraryAppModel {
        LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            mediaCache: cache ?? FileMediaCache(rootURL: scratch.appendingPathComponent("cache")),
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            preferences: preferences ?? UserDefaults(suiteName: suite)!, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    private func seed(_ raws: [String]) async throws {
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (index, raw) in raws.enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: "Notes about \(raw)",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), durationSeconds: 600,
                artworkRef: "https://example.com/\(raw).jpg")))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(index))))
        }
        try await macPush(changes)
    }

    private func offer(_ raw: String, state: LibraryMediaOffer.State = .ready) async throws {
        if state == .notReady {
            try await mac.publishMedia(offer: .notReady(entryID: id(raw)), fileURL: URL(fileURLWithPath: "/dev/null"))
            return
        }
        if state == .available {
            try await mac.publishMedia(
                offer: try LibraryMediaOffer(
                    entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: "",
                    byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600, state: .available),
                fileURL: URL(fileURLWithPath: "/dev/null"))
            return
        }
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        let digest = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try await mac.publishMedia(
            offer: try LibraryMediaOffer(
                entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: digest,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600),
            fileURL: file)
    }

    func testOnlyQueuedRowsWithAReadyOfferAppearAndNotReadyOffersStayHidden() async throws {
        try await seed(["a", "b", "c"])
        try await offer("a")
        try await offer("c", state: .notReady)
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"], "the mirror keeps every queued entry")
        XCTAssertEqual(ids(model.visibleRows), ["a"])
        XCTAssertEqual(model.preparedCount, 1)
        // The Mac prepares another episode; the next refresh lists it in queue order.
        try await offer("b")
        await model.refresh()
        XCTAssertEqual(ids(model.visibleRows), ["a", "b"])
    }

    func testAnAvailableOfferListsTheRowBeforeAnyAudioIsUploaded() async throws {
        try await seed(["a", "b"])
        try await offer("a", state: .available)
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(ids(model.visibleRows), ["a"])
        XCTAssertEqual(model.preparedCount, 1)
        XCTAssertEqual(model.mediaState(for: id("a")), .available, "still Get audio: nothing is on the phone")
    }

    func testAnEntryNotInTheMacQueueNeverAppearsEvenWithAnOffer() async throws {
        try await seed(["a"])
        try await macPush([.entry(try LibraryEntry(
            id: id("loose"), kind: .podcastEpisode, sourceID: id("show"), title: "Loose", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000)))])
        try await offer("loose")
        let model = makeModel()
        await model.refresh()
        XCTAssertTrue(model.visibleRows.isEmpty)
    }

    func testCachedAudioStaysListedAfterTheOfferIsGone() async throws {
        try await seed(["a"])
        try await offer("a")
        let model = makeModel()
        await model.refresh()
        model.performMediaAction(.request, entryID: id("a"))
        await model.waitForMedia(entryID: id("a"))
        XCTAssertEqual(model.mediaState(for: id("a")), .onPhone)

        try await mac.removeMedia(entryID: id("a"))
        await model.refresh()
        XCTAssertTrue(model.readyOffers.isEmpty)
        XCTAssertEqual(ids(model.visibleRows), ["a"])
        model.filter = .onPhone
        XCTAssertEqual(ids(model.visibleRows), ["a"])
        model.filter = .available
        XCTAssertTrue(model.visibleRows.isEmpty)
    }

    func testRowCarriesArtworkNotesAndTheMacPositionToResumeFrom() async throws {
        try await seed(["a", "b"])
        try await offer("a")
        try await offer("b")
        try await InMemoryLibraryTransport(deviceID: "mac", server: server).publish(
            try DevicePlaybackPosition(
                deviceID: "mac", entryID: id("a"), revision: RevisionID(rawValue: "rev-1"),
                positionSeconds: 254, isPlaying: false, epoch: 1),
            as: .progress)
        let model = makeModel()
        await model.refresh()
        let first = try XCTUnwrap(model.visibleRows.first { $0.id == id("a") })
        XCTAssertEqual(first.resumeSeconds, 254)
        XCTAssertEqual(first.artworkURL?.absoluteString, "https://example.com/a.jpg")
        XCTAssertEqual(first.summary, "Notes about a")
        XCTAssertEqual(first.durationSeconds, 600)
        XCTAssertNil(try XCTUnwrap(model.visibleRows.first { $0.id == id("b") }).resumeSeconds, "no checkpoint: start at 0")
    }

    func testFilterAndSearchStartCleanOnLaunch() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        let model = makeModel(preferences: defaults)
        model.filter = .onPhone
        model.searchText = "x"
        let reopened = makeModel(preferences: defaults)
        XCTAssertEqual(reopened.filter, .all)
        XCTAssertEqual(reopened.searchText, "")
    }

    func testModelFilterAndSearchNarrowTheListWithoutAFetch() async throws {
        try await seed(["a", "b", "c"])
        for raw in ["a", "b", "c"] { try await offer(raw) }
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(ids(model.visibleRows), ["a", "b", "c"])
        model.searchText = "about b"
        XCTAssertEqual(ids(model.visibleRows), ["b"])
        XCTAssertEqual(model.preparedCount, 3, "search does not change what is prepared")
        model.searchText = "zzz"
        XCTAssertTrue(model.visibleRows.isEmpty)
        XCTAssertEqual(model.preparedCount, 3)
    }

    func testRemoveFromLarderIsTheOnlyDecisionOnAnUnstartedRow() async throws {
        try await seed(["a", "b"])
        try await offer("a")
        try await offer("b")
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.decisionActions(for: model.visibleRows[0]), [.removeFromLarder])
    }

    func testCheckpointLineSpeaksForThisPhoneOnceItHasTheEpisode() {
        XCTAssertEqual(LibraryCheckpointLine.localText(isPlaying: true, position: 252), "Playing on this iPhone at 04:12")
        XCTAssertEqual(LibraryCheckpointLine.localText(isPlaying: false, position: 3_725), "Paused on this iPhone at 1:02:05")
    }

    // MARK: phone row progress

    func testPhoneRowShowsTimeLeftProgressAndPlayedLikeTheCarRows() {
        let r = row("a", show: "Alpha", published: 0, duration: 600)
        let date = r.publishedAt.formatted(.dateTime.month(.abbreviated).day().year())
        let started = EpisodeProgress(positionSeconds: 150, lastPlayedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(LibraryRowView.detail(row: r, progress: started, completed: false), "07:30 left · \(date)")
        XCTAssertEqual(LibraryRowView.detail(row: r, progress: nil, completed: false), "10:00 · \(date)")
        XCTAssertEqual(LibraryRowView.detail(row: r, progress: started, completed: true), "Played · \(date)")
        XCTAssertEqual(CarEpisodeList.fraction(started, duration: 600), 0.25)
        // The car row carries the same time left for the same data.
        XCTAssertTrue(CarEpisodeList.detail(r, progress: started).hasSuffix("07:30 left"))
        let untimed = row("b", duration: nil)
        XCTAssertEqual(LibraryRowView.detail(row: untimed, progress: started, completed: false), untimed.publishedAt
            .formatted(.dateTime.month(.abbreviated).day().year()))
        XCTAssertNil(CarEpisodeList.fraction(started, duration: nil))
    }
}
