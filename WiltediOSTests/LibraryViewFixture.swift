import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A `LibraryAppModel` over an in-memory Mac, seeded with queued episodes whose audio is already on the
/// phone, for the hosted view tests. Create one per test and call `seed(...)`.
@MainActor
final class LibraryViewFixture {
    let server = InMemoryLibraryServer(writerDeviceID: "mac")
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-view-\(UUID().uuidString)")
    let suite = "library-view-fixture-\(UUID().uuidString)"
    let defaults: UserDefaults
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private var localSeq: UInt64 = 0
    let model: LibraryAppModel

    init() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        self.cache = cache
        model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            preferences: defaults, timeZone: TimeZone(identifier: "UTC")!)
    }

    let cache: FileMediaCache

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    /// Queues one episode per id (oldest first), with no offer and no audio; `summary` is its notes.
    func queue(_ raws: [String], summary: String = "First paragraph.\n\nSecond paragraph.") async throws {
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (index, raw) in raws.enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(raw), kind: .podcastEpisode, sourceID: id("show"), title: "Title \(raw)", summary: summary,
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), durationSeconds: 600)))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(index))))
        }
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: 0)
        }
        let pushed = try await mac.push(changes: pending)
        XCTAssertTrue(pushed.failures.isEmpty)
    }

    /// The Mac's offer for `raw`: `.ready` uploads real bytes, `.available` lists it before any upload,
    /// `.notReady` says there is no ready audio.
    func offer(_ raw: String, _ state: LibraryMediaOffer.State = .ready) async throws {
        switch state {
        case .notReady:
            try await mac.publishMedia(offer: .notReady(entryID: id(raw)), fileURL: URL(fileURLWithPath: "/dev/null"))
        case .available:
            try await mac.publishMedia(
                offer: try LibraryMediaOffer(
                    entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: "", byteCount: 500,
                    mediaType: "audio/mp4", durationSeconds: 600, state: .available),
                fileURL: URL(fileURLWithPath: "/dev/null"))
        case .ready:
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try audio.write(to: file)
            try await mac.publishMedia(offer: try readyOffer(raw), fileURL: file)
        }
    }

    /// A player over fake audio (600 s long) that never ticks by itself.
    func makePlayer() -> LibraryPlayer {
        LibraryPlayer(
            engine: VoiceFakeEngine(), session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(),
            remoteCommands: VoiceFakeRemote(), sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
    }

    /// Waits for `condition` for up to three seconds of run-loop time.
    func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    /// The Mac has played the episode partway, so it is started (Mark completed applies) after the next refresh.
    func startOnMac(_ raw: String, at seconds: Double = 30) async throws {
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: RevisionID(rawValue: "rev-1"), positionSeconds: seconds,
            isPlaying: false, epoch: 1)
        try await mac.publish(record, as: .progress)
    }

    /// Puts the episode's audio on the phone, as a finished download leaves it.
    func cacheAudio(_ raw: String) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try audio.write(to: file)
        _ = try await cache.adopt(verifiedFile: file, for: readyOffer(raw))
    }

    /// Queues one episode per id with a ready offer and its audio already on the phone, then refreshes.
    func seed(_ raws: [String], summary: String = "First paragraph.\n\nSecond paragraph.") async throws {
        try await queue(raws, summary: summary)
        for raw in raws {
            try await offer(raw)
            try await cacheAudio(raw)
        }
        await model.refresh()
    }

    private let audio = Data(repeating: 7, count: 500)

    private func readyOffer(_ raw: String) throws -> LibraryMediaOffer {
        let hash = MediaHash.prefix + SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        return try LibraryMediaOffer(
            entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash, byteCount: 500,
            mediaType: "audio/mp4", durationSeconds: 600)
    }
}
