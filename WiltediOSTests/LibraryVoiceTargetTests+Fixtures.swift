import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// In-memory Mac/phone, verified file cache and fake player fixtures shared by the voice behavior cases.
@MainActor
extension LibraryVoiceTargetTests {
    // MARK: fixtures

    struct Rig {
        let target: LibraryVoiceTarget
        let model: LibraryAppModel
        let player: LibraryPlayer
        let engine: VoiceFakeEngine
        let cache: GatedMediaCache
        let cachedURLs: [ItemID: URL]
    }

    func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    func hash(_ data: Data) -> String {
        MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    /// The Mac's queue: shows, episodes and their slot order.
    func seed(shows: [ShowSpec], episodes: [EpisodeSpec]) async throws {
        var changes = shows.map { LibraryChange.source(LibrarySource(id: id($0.raw), kind: .podcastFeed, title: $0.title)) }
        for spec in episodes {
            changes.append(.entry(try LibraryEntry(
                id: id(spec.raw), kind: .podcastEpisode, sourceID: id(spec.show), title: spec.title, summary: "",
                publishedAt: Date(timeIntervalSince1970: spec.published), durationSeconds: 600)))
            changes.append(.slot(try QueueSlot(entryID: id(spec.raw), sortKey: spec.sortKey)))
        }
        try await macPush(changes)
    }

    /// The Mac's stored position for a paused episode: what marks a row as started.
    func macPublishesProgress(_ raw: String, position: Double) async throws {
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: position, isPlaying: false, epoch: 1)
        try await mac.publish(record, as: .progress)
    }

    func seedStartedEpisodeA() async throws {
        try await seed(shows: [ShowSpec(raw: "show", title: "The Show")], episodes: [
            EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0),
        ])
        try await macPublishesProgress("a", position: 100)
    }

    /// A phone whose media cache already holds `raws`, verified against the Mac's offer for them.
    func makeRig(cached raws: [String], sendsIntents: Bool = true) async throws -> Rig {
        let phoneTransport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phoneTransport)
        let files = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let cache = GatedMediaCache(files)
        var cachedURLs: [ItemID: URL] = [:]
        for raw in raws {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash(payload),
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
            cachedURLs[id(raw)] = try await PreparedMediaFixture.adopt(into: files, verifiedFile: file, for: offer, owner: "fixture-owner")
        }
        let engine = VoiceFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(),
            remoteCommands: VoiceFakeRemote(), sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
        let sleeper = sleeper
        let model = LibraryAppModel(
            transport: sendsIntents ? phoneTransport : SendFailingTransport(base: phoneTransport),
            store: mirror, deviceID: "phone", mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.phoneObserveInterval, sleep: { try await sleeper.sleep($0) }, settleSleep: { _ in }),
            decisionTiming: LibraryDecisionTiming(confirmationTimeout: 60),
            preferences: UserDefaults(suiteName: suite)!, now: { Date(timeIntervalSince1970: 1_000) },
            timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(player)
        await model.refresh()
        return Rig(
            target: LibraryVoiceTarget(model: model, player: player), model: model, player: player,
            engine: engine, cache: cache, cachedURLs: cachedURLs)
    }

    func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now >= deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func loadedRig(twoEpisodes: Bool = false) async throws -> Rig {
        try? FileManager.default.removeItem(at: scratch.appendingPathComponent("cache"))
        var episodes = [EpisodeSpec(raw: "a", title: "Episode A", show: "show", sortKey: 0)]
        if twoEpisodes { episodes.append(EpisodeSpec(raw: "b", title: "Episode B", show: "show", sortKey: 1)) }
        try await seed(shows: [ShowSpec(raw: "show", title: "Garden Radio")], episodes: episodes)
        let rig = try await makeRig(cached: twoEpisodes ? ["a", "b"] : ["a"])
        await rig.target.perform(.play(id("a")))
        rig.player.seek(to: 120)
        rig.player.pause()
        await settleVoiceRig(rig)
        return rig
    }

    func settleVoiceRig(_ rig: Rig) async {
        await rig.model.waitForHandoff()
        for _ in 0..<20 { await Task.yield() }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func replaceCachedA(_ rig: Rig) async throws -> URL {
        try await rig.cache.remove(entryID: id("a"))
        let bytes = payload + Data([254])
        let incoming = scratch.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: incoming)
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: id("a"), revisionID: RevisionID(rawValue: "rev-2"), contentHash: hash(bytes),
            byteCount: Int64(bytes.count), mediaType: "audio/mp4", durationSeconds: 600))
        return try await PreparedMediaFixture.adopt(into: rig.cache, verifiedFile: incoming, for: offer, owner: "fixture-owner")
    }

}
