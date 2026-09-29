import Foundation
import WiltedDomain

/// Shared in-memory backend standing in for CloudKit or a hosted service. One writer
/// device may push library state; every device writes only its own playback records.
/// Each record has a server version; a push whose base version is stale is a conflict.
public actor InMemoryLibraryServer {
    public let writerDeviceID: String
    private var sequence: UInt64 = 0
    private var log: [VersionedLibraryChange] = []
    private var keyVersions: [LibraryRecordKey: UInt64] = [:]
    private var snapshot = LibrarySnapshot()
    private var intents: [LibraryIntent] = []
    private var outcomes: [String: IntentOutcome] = [:]
    private var nowPlaying: [String: ObservedPlayback] = [:]
    private var progress: [String: ObservedPlayback] = [:]
    private var manualNow: Date?
    private var mediaOffers: [ItemID: LibraryMediaOffer] = [:]
    private var mediaFiles: [ItemID: URL] = [:]
    private let mediaDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wilted-inmemory-media-\(UUID().uuidString)", isDirectory: true)

    public init(writerDeviceID: String) { self.writerDeviceID = writerDeviceID }

    deinit { try? FileManager.default.removeItem(at: mediaDirectory) }

    /// Pins the server clock used for `serverModifiedAt`; nil returns to the real clock.
    public func setClock(_ date: Date?) { manualNow = date }

    public var currentSnapshot: LibrarySnapshot { snapshot }

    func fetch(since token: LibraryChangeToken?) -> LibraryChangeBatch {
        let floor = token.flatMap { UInt64($0.rawValue) } ?? 0
        return LibraryChangeBatch(
            generationID: "generation-\(sequence)",
            changes: log.filter { $0.version > floor },
            token: LibraryChangeToken(rawValue: String(sequence))
        )
    }

    func push(_ changes: [PendingLibraryChange], from deviceID: String) throws -> LibraryPushResult {
        guard deviceID == writerDeviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not write library state")
        }
        var acknowledged: [LibraryAcknowledgement] = []
        var failures: [LibraryPushFailure] = []
        for pending in changes {
            let key = pending.key
            let current = keyVersions[key] ?? 0
            guard current == pending.baseVersion else {
                let server = materialized(key).map { VersionedLibraryChange(version: current, change: $0) }
                failures.append(LibraryPushFailure(key: key, disposition: server == nil ? .retryable : .conflict, server: server))
                continue
            }
            sequence += 1
            log.append(VersionedLibraryChange(version: sequence, change: pending.change))
            keyVersions[key] = sequence
            snapshot = snapshot.applying(pending.change)
            acknowledged.append(LibraryAcknowledgement(key: key, version: sequence))
        }
        return LibraryPushResult(token: LibraryChangeToken(rawValue: String(sequence)), acknowledged: acknowledged, failures: failures)
    }

    func submit(_ intent: LibraryIntent) {
        guard !intents.contains(where: { $0.id == intent.id }) else { return }
        intents.append(intent)
    }

    func allIntents() -> [LibraryIntent] { intents }

    func publishOutcome(_ outcome: IntentOutcome, from deviceID: String) throws {
        guard deviceID == writerDeviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not write intent outcomes")
        }
        // An outcome is immutable, so a republish after a restart keeps the first answer.
        if outcomes[outcome.intentID] == nil { outcomes[outcome.intentID] = outcome }
    }

    func allOutcomes() -> [IntentOutcome] {
        outcomes.values.sorted { ($0.decidedAt, $0.intentID) < ($1.decidedAt, $1.intentID) }
    }

    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel, from deviceID: String) throws {
        guard record.deviceID == deviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not write records for \(record.deviceID)")
        }
        let observed = ObservedPlayback(record: record, serverModifiedAt: manualNow ?? Date())
        switch channel {
        case .nowPlaying: nowPlaying[deviceID] = observed
        case .progress: progress["\(deviceID)/\(record.entryID.rawValue)"] = observed
        }
    }

    func publishMedia(_ offer: LibraryMediaOffer, fileURL: URL, from deviceID: String) throws {
        guard deviceID == writerDeviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not publish media")
        }
        var stored: URL?
        if offer.state == .ready {
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let copy = mediaDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: fileURL, to: copy)
            stored = copy
        }
        dropMediaFile(for: offer.entryID)
        mediaOffers[offer.entryID] = offer
        mediaFiles[offer.entryID] = stored
    }

    func allMediaOffers() -> [LibraryMediaOffer] {
        mediaOffers.values.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
    }

    /// The server-held file behind a ready offer still current for that entry and revision.
    func mediaFile(for offer: LibraryMediaOffer) throws -> URL {
        guard let current = mediaOffers[offer.entryID], current == offer, current.state == .ready,
              let file = mediaFiles[offer.entryID]
        else { throw LibraryTransportError.transport("no ready media is offered for \(offer.entryID)") }
        return file
    }

    func removeMedia(entryID: ItemID, from deviceID: String) throws {
        guard deviceID == writerDeviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not remove media")
        }
        dropMediaFile(for: entryID)
        mediaOffers[entryID] = nil
    }

    private func dropMediaFile(for entryID: ItemID) {
        if let old = mediaFiles.removeValue(forKey: entryID) { try? FileManager.default.removeItem(at: old) }
    }

    func deviceRecords() -> LibraryDeviceRecords {
        func ordered(_ records: [String: ObservedPlayback]) -> [ObservedPlayback] {
            records.sorted { $0.key < $1.key }.map(\.value)
        }
        return LibraryDeviceRecords(nowPlaying: ordered(nowPlaying), progress: ordered(progress))
    }

    /// The server's current whole record for a key, used to report conflicts.
    private func materialized(_ key: LibraryRecordKey) -> LibraryChange? {
        switch key.kind {
        case .source: return snapshot.sources[key.id].map(LibraryChange.source)
        case .entry: return snapshot.entries[key.id].map(LibraryChange.entry)
        case .slot: return snapshot.slots[key.id].map(LibraryChange.slot) ?? .slotRemoved(entryID: key.id)
        case .listening: return snapshot.listening[key.id].map(LibraryChange.listening)
        }
    }
}

/// One device's handle on an `InMemoryLibraryServer`. Fetched and sent tokens are
/// provisional until committed, exactly like a real adapter's engine state.
public actor InMemoryLibraryTransport: LibraryTransport {
    public let deviceID: String
    private let server: InMemoryLibraryServer
    private var generation: UInt64 = 0
    private var afterFetch: (@Sendable () async -> Void)?
    private var afterPush: (@Sendable () async -> Void)?
    public private(set) var provisionalFetchToken: LibraryChangeToken?
    public private(set) var committedFetchToken: LibraryChangeToken?
    public private(set) var committedSentToken: LibraryChangeToken?

    public init(deviceID: String, server: InMemoryLibraryServer) {
        self.deviceID = deviceID
        self.server = server
    }

    /// Simulates an account change: results of work started earlier must not commit.
    public func invalidateOperations() { generation += 1 }

    /// Test seams that run after the server responds, before the caller sees the result.
    public func setAfterFetchHook(_ hook: (@Sendable () async -> Void)?) { afterFetch = hook }
    public func setAfterPushHook(_ hook: (@Sendable () async -> Void)?) { afterPush = hook }

    public func operationGeneration() -> UInt64 { generation }

    public func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        let batch = await server.fetch(since: token)
        provisionalFetchToken = batch.token
        await afterFetch?()
        return batch
    }

    public func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        let result = try await server.push(changes, from: deviceID)
        await afterPush?()
        return result
    }

    public func send(intent: LibraryIntent) async throws { await server.submit(intent) }

    public func listIntents() async throws -> [LibraryIntent] { await server.allIntents() }

    public func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
        try await server.publishOutcome(outcome, from: deviceID)
    }

    public func intentOutcomes() async throws -> [IntentOutcome] { await server.allOutcomes() }

    public func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await server.publish(record, as: channel, from: deviceID)
    }

    public func fetchDeviceRecords() async throws -> LibraryDeviceRecords { await server.deviceRecords() }

    public func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        try await server.publishMedia(offer, fileURL: fileURL, from: deviceID)
    }

    public func mediaOffers() async throws -> [LibraryMediaOffer] { await server.allMediaOffers() }

    /// Delivers a private copy in fixed-size chunks so `progress` reports real byte counts.
    public func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        let source = try await server.mediaFile(for: offer)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-media-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw LibraryTransportError.transport("cannot create delivery file")
        }
        do {
            let reader = try FileHandle(forReadingFrom: source)
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? reader.close(); try? writer.close() }
            var received: Int64 = 0
            while let chunk = try reader.read(upToCount: Self.deliveryChunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: chunk)
                received += Int64(chunk.count)
                progress(received)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    public func removeMedia(entryID: ItemID) async throws { try await server.removeMedia(entryID: entryID, from: deviceID) }

    private static let deliveryChunkSize = 1 << 20

    public func commitFetchedState(_ token: LibraryChangeToken?) async throws { committedFetchToken = token }

    public func commitSentState(_ token: LibraryChangeToken?) async throws { committedSentToken = token }
}
