#if DEBUG
import CryptoKit
import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedListener

/// What the production-root UI fixture makes the phone's dependencies do, chosen by
/// `--wilted-library-root-scenario=<rawValue>` beside `LibraryUITestFixture.argument`.
enum LibraryUITestScenario: String, Sendable {
    /// Seeded episodes on the phone; the engine plays and the in-memory Mac answers every call.
    case normal
    /// Every cache lookup, the one a start makes before the engine included, waits `startDelay` first.
    case delayedStart = "delayed-start"
    /// The engine refuses to play, as a backend that rejects the start does.
    case startError = "start-error"
    /// The first library fetch succeeds; every later read is answered "rate limited" by iCloud.
    case throttled
}

/// DEBUG-only deterministic dependencies for the production `LibraryRoot`.
///
/// A launch with `--wilted-library-root-fixture` renders the real `LibraryRoot` over an in-memory
/// Mac, a scratch media cache, a fake audio engine and an isolated defaults suite, injected together
/// so `LibraryRoot` never reads `LibraryRuntime.shared`. Nothing here touches CloudKit, an account,
/// the network or the standard defaults the live stack keeps its device id in.
@MainActor
enum LibraryUITestFixture {
    static let argument = "--wilted-library-root-fixture"
    static let scenarioPrefix = "--wilted-library-root-scenario="
    /// The production-root marker: present only when the fixture host rendered `LibraryRoot`.
    static let rootMarker = "wilted-library-root-fixture"
    /// Shown while the fixture seeds its in-memory Mac, before `LibraryRoot` exists.
    static let loadingMarker = "wilted-library-root-fixture-loading"
    /// How long a delayed-start cache lookup waits.
    static let startDelay: Duration = .seconds(3)
    static let suiteName = "wilted-library-root-fixture"
    static let episodeIDs = ["fixture-episode-1", "fixture-episode-2"]

    /// The scenario this launch asked for, or nil for any other launch.
    static func scenario(arguments: [String] = ProcessInfo.processInfo.arguments) -> LibraryUITestScenario? {
        guard arguments.contains(argument) else { return nil }
        let raw = arguments.first { $0.hasPrefix(scenarioPrefix) }?.dropFirst(scenarioPrefix.count)
        return raw.flatMap { LibraryUITestScenario(rawValue: String($0)) } ?? .normal
    }

    /// Live library constructions seen since launch. `LibraryEnvironment.makeModel`, the only builder of the
    /// live transport (and what `LibraryRuntime.shared` and a default `LibraryRoot` call), always ensures
    /// the per-install device id in the standard defaults first. The fixture removes that key at launch,
    /// so the key's presence means a live transport was constructed in this process.
    static var liveTransportConstructions: Int {
        UserDefaults.standard.string(forKey: LibraryEnvironment.deviceIDKey) == nil ? 0 : 1
    }

    /// The one fixture stack of this process, built by `launch(_:)`.
    private(set) static var stack: Stack?

    /// Builds the fixture stack before any scene exists. Clears the spy's key and the fixture's own
    /// defaults and scratch files, then points the voice intents at the fixture objects so a system
    /// query from Siri or Shortcuts cannot build `LibraryRuntime.shared`.
    static func launch(_ scenario: LibraryUITestScenario) {
        guard stack == nil else { return }
        UserDefaults.standard.removeObject(forKey: LibraryEnvironment.deviceIDKey)
        UserDefaults().removePersistentDomain(forName: suiteName)
        let built = Stack(scenario: scenario)
        stack = built
        VoiceRuntime.provider = {
            LibraryVoiceTarget(model: built.model, player: built.player, settings: built.settings)
        }
    }

    /// The injected model, player and settings, with the in-memory Mac that seeds them.
    @MainActor
    final class Stack {
        let scenario: LibraryUITestScenario
        let model: LibraryAppModel
        let player: LibraryPlayer
        let settings: LibrarySettingsStore
        private let server = InMemoryLibraryServer(writerDeviceID: "mac")
        private let cache: FileMediaCache
        private let scratch: URL
        private var seedTask: Task<Void, Never>?

        init(scenario: LibraryUITestScenario) {
            self.scenario = scenario
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-library-root-fixture", isDirectory: true)
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: LibraryUITestFixture.suiteName) ?? UserDefaults()
            cache = FileMediaCache(rootURL: scratch.appendingPathComponent("media", isDirectory: true))
            let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
            let transport: any LibraryTransport = scenario == .throttled ? LibraryUITestPressureTransport(inner: phone) : phone
            let mediaCache: any LibraryMediaCache = scenario == .delayedStart
                ? LibraryUITestDelayedCache(inner: cache, delay: LibraryUITestFixture.startDelay) : cache
            model = LibraryAppModel(
                transport: transport, deviceID: "phone", mediaCache: mediaCache, preferences: defaults,
                ownPositionsURL: scratch.appendingPathComponent("own-positions.json"))
            player = LibraryPlayer(
                engine: LibraryUITestEngine(refusesPlay: scenario == .startError), session: LibraryUITestSession(),
                nowPlaying: LibraryUITestNowPlaying(), remoteCommands: LibraryUITestRemote(),
                sessionEvents: LibraryUITestSessionEvents())
            settings = LibrarySettingsStore(defaults: defaults)
        }

        /// Queues the seeded episodes on the in-memory Mac and puts their audio on the phone. Runs once.
        func seed() async {
            if seedTask == nil { seedTask = Task { await performSeed() } }
            await seedTask?.value
        }

        private func performSeed() async {
            let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
            do {
                let showID = try ItemID(rawValue: "fixture-show")
                var changes: [LibraryChange] = [.source(LibrarySource(id: showID, kind: .podcastFeed, title: "Fixture Show"))]
                for (index, raw) in LibraryUITestFixture.episodeIDs.enumerated() {
                    let id = try ItemID(rawValue: raw)
                    changes.append(.entry(try LibraryEntry(
                        id: id, kind: .podcastEpisode, sourceID: showID, title: "Fixture Episode \(index + 1)",
                        summary: "A local fixture episode.", publishedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                        durationSeconds: LibraryUITestEngine.length)))
                    changes.append(.slot(try QueueSlot(entryID: id, sortKey: Double(index))))
                }
                let pending = changes.enumerated().map {
                    PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
                }
                _ = try await mac.push(changes: pending)
                let audio = Data(repeating: 7, count: 512)
                let hash = MediaHash.prefix + SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
                for raw in LibraryUITestFixture.episodeIDs {
                    let offer = try LibraryMediaOffer(
                        entryID: try ItemID(rawValue: raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash,
                        byteCount: Int64(audio.count), mediaType: "audio/mp4", durationSeconds: LibraryUITestEngine.length)
                    let file = scratch.appendingPathComponent(UUID().uuidString)
                    try audio.write(to: file)
                    _ = try await cache.adopt(verifiedFile: file, for: offer)
                }
            } catch {
                assertionFailure("Library root fixture could not seed: \(error)")
            }
        }
    }
}

/// Seeds the fixture, then hosts the production `LibraryRoot` with the injected objects and the
/// production-root marker. Not a root view of its own: before seeding it shows only a progress marker.
struct LibraryUITestFixtureHost: View {
    let stack: LibraryUITestFixture.Stack
    @State private var isSeeded = false

    var body: some View {
        if isSeeded {
            LibraryRoot(model: stack.model, player: stack.player, settings: stack.settings)
                .overlay(alignment: .bottomLeading) { LibraryUITestFixtureMarker(scenario: stack.scenario) }
        } else {
            ProgressView()
                .accessibilityIdentifier(LibraryUITestFixture.loadingMarker)
                .task {
                    await stack.seed()
                    isSeeded = true
                }
        }
    }
}

/// A tiny, non-interactive element naming the production root and carrying the live-construction spy
/// as its value, re-read whenever the standard defaults change.
private struct LibraryUITestFixtureMarker: View {
    let scenario: LibraryUITestScenario
    @State private var liveConstructions = LibraryUITestFixture.liveTransportConstructions

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .accessibilityElement()
            .accessibilityLabel("Library root fixture \(scenario.rawValue)")
            .accessibilityValue("\(liveConstructions)")
            .accessibilityIdentifier(LibraryUITestFixture.rootMarker)
            .allowsHitTesting(false)
            // The notification posts on whichever thread changed the defaults; the state is read on main.
            .onReceive(
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            ) { _ in
                liveConstructions = LibraryUITestFixture.liveTransportConstructions
            }
    }
}

// MARK: - Fakes

/// An engine with no audio: a still clock that plays unless told to refuse.
final class LibraryUITestEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    static let length: Double = 600
    private let lock = NSLock()
    private let refusesPlay: Bool
    private var time = 0.0
    private var playing = false
    private var storedRate: Float = 1
    let duration = LibraryUITestEngine.length

    init(refusesPlay: Bool) { self.refusesPlay = refusesPlay }

    var currentTime: Double {
        get { lock.withLock { time } }
        set { lock.withLock { time = newValue } }
    }
    var rate: Float {
        get { lock.withLock { storedRate } }
        set { lock.withLock { storedRate = newValue } }
    }
    var isPlaying: Bool { lock.withLock { playing } }
    func load(url: URL) throws { lock.withLock { time = 0 } }
    func play() -> Bool {
        guard !refusesPlay else { return false }
        lock.withLock { playing = true }
        return true
    }
    func pause() { lock.withLock { playing = false } }
}

final class LibraryUITestSession: ListenerAudioSession, @unchecked Sendable {
    func activate() throws {}
    func deactivate() {}
}

final class LibraryUITestNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor final class LibraryUITestRemote: LibraryRemoteCommands {
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func uninstall() {}
}

@MainActor final class LibraryUITestSessionEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

/// The scratch cache, with every `cachedEntries()` (the lookup a start makes) held for `delay` first.
struct LibraryUITestDelayedCache: LibraryMediaCache {
    let inner: FileMediaCache
    let delay: Duration

    func cachedEntries() async -> [ItemID: CachedMedia] {
        try? await Task.sleep(for: delay)
        return await inner.cachedEntries()
    }
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        await inner.cachedTranscript(entryID: entryID, revisionID: revisionID)
    }
    func storeTranscript(_ transcript: LibraryTranscript) async { await inner.storeTranscript(transcript) }
    func cachedFile(for offer: LibraryMediaOffer) async -> URL? { await inner.cachedFile(for: offer) }
    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer) async throws -> URL {
        try await inner.adopt(verifiedFile: verifiedFile, for: offer)
    }
    func remove(entryID: ItemID) async throws { try await inner.remove(entryID: entryID) }
}

/// The in-memory Mac behind iCloud pressure: the first library fetch and its commits pass through; every
/// later fetch and every other call fails with CloudKit's request-rate-limited error, so the model's own
/// gate closes as it would live, and no later fetch can reopen it.
final class LibraryUITestPressureTransport: LibraryTransport, @unchecked Sendable {
    let inner: InMemoryLibraryTransport
    private let lock = NSLock()
    private var fetched = false

    init(inner: InMemoryLibraryTransport) { self.inner = inner }

    /// `CKError.Code.requestRateLimited` with a ten-minute retry-after, in the shape CloudKit reports it.
    static var rateLimited: NSError {
        NSError(domain: "CKErrorDomain", code: 7, userInfo: ["CKErrorRetryAfterKey": NSNumber(value: 600)])
    }

    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        let isFirst = lock.withLock {
            defer { fetched = true }
            return !fetched
        }
        guard isFirst else { throw Self.rateLimited }
        return try await inner.fetchChanges(since: token)
    }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await inner.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await inner.commitSentState(token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { throw Self.rateLimited }
    func listIntents() async throws -> [LibraryIntent] { throw Self.rateLimited }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { throw Self.rateLimited }
    func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
        throw Self.rateLimited
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { throw Self.rateLimited }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult { throw Self.rateLimited }
    func mediaOffers() async throws -> [LibraryMediaOffer] { throw Self.rateLimited }
    func intentOutcomes() async throws -> [IntentOutcome] { throw Self.rateLimited }
}
#endif
