import AVFoundation
import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Morning report store")
struct LocalLibraryStoreReportTests {
    private struct Fixture {
        let root: URL
        let store: LocalLibraryStore
    }

    private func fixture() throws -> Fixture {
        let root = try AudiobookTestAudio.ownedDirectory("report")
        return Fixture(root: root, store: try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite")))
    }

    private func tone(seconds: Double) -> [Float] {
        let rate = 24_000.0
        return (0..<Int(seconds * rate)).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / rate)) }
    }

    /// Writes a real report file and builds its save for `script` on `day`.
    private func makeSave(_ fixture: Fixture, script: String, day: String, createdAt: Date) throws -> MorningReportSave {
        let itemID = try LocalLibraryStore.reportItemID(script: script, day: day)
        let media = fixture.store.mediaDirectory
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent("report-\(itemID.rawValue)-\(UUID().uuidString).m4a")
        let duration = try MorningReportAudio.write(samples: tone(seconds: 2), sampleRate: 24_000, to: url)
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: RevisionID.derive(
                extractedTextSHA256: SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined(), voiceID: "daemon-default", synthesisSettingsCanonicalJSON: "{}",
                audioFormatCanonicalJSON: "{\"container\":\"m4a\"}"),
            durationSeconds: duration, byteCount: Int64(try Data(contentsOf: url).count), contentHash: "sha256:\(hash)",
            mediaType: AudioAssembler.mediaType, createdAt: Timestamp(createdAt), schemaVersion: 1)
        return MorningReportSave(itemID: itemID, revision: revision, mediaURL: url, title: "Morning report, \(day)", createdAt: createdAt)
    }

    @Test func aNewReportRetiresThePreviousUnplayedOneAndSitsFirstInTheQueue() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        let other = try ItemID.audiobook(contentDigest: String(repeating: "a", count: 64), layout: "x", volume: 0)
        try await store.addPodcastQueueEpisode(other)

        let first = try makeSave(fixture, script: "one", day: "October 9", createdAt: Date(timeIntervalSince1970: 1_000))
        #expect(try await store.saveMorningReport(first) == .saved(retired: []))
        #expect(try await store.podcastQueueState().episodeIDs == [first.itemID, other])

        let second = try makeSave(fixture, script: "two", day: "October 10", createdAt: Date(timeIntervalSince1970: 2_000))
        #expect(try await store.saveMorningReport(second) == .saved(retired: [first.itemID]))

        #expect(try await store.podcastQueueState().episodeIDs == [second.itemID, other])
        let books = try await store.audiobooks()
        #expect(books.first { $0.itemID == first.itemID }?.isRemoved == true)
        #expect(books.first { $0.itemID == second.itemID }?.isRemoved == false)
        #expect(books.allSatisfy { $0.sourceFormat == LocalLibraryStore.reportSourceFormat })
        // Saving the same report again changes nothing.
        #expect(try await store.saveMorningReport(second) == .alreadyExists)
        #expect(try await store.podcastQueueState().episodeIDs == [second.itemID, other])
    }

    @Test func aSavedReportFileLoadsWithAVURLAsset() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let save = try makeSave(fixture, script: "three", day: "October 10", createdAt: Date())
        _ = try await fixture.store.saveMorningReport(save)
        #expect(save.mediaURL.pathExtension == "m4a")
        let loaded = try await AVURLAsset(url: save.mediaURL).load(.duration).seconds
        #expect(abs(loaded - 2) < 0.2)
        let ready = try await fixture.store.podcastLibrarySnapshot().readyRevisions[save.itemID]
        #expect(ready?.mediaURL == save.mediaURL)
    }

    @Test func hasMorningReportIsFalseUntilTheReportIsSaved() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let save = try makeSave(fixture, script: "four", day: "October 10", createdAt: Date())
        #expect(try await fixture.store.hasMorningReport(save.itemID) == false)
        _ = try await fixture.store.saveMorningReport(save)
        #expect(try await fixture.store.hasMorningReport(save.itemID))
    }
}
