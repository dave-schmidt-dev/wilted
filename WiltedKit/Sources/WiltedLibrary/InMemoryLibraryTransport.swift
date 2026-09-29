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
    private var nowPlaying: [String: ObservedPlayback] = [:]
    private var progress: [String: ObservedPlayback] = [:]
    private var manualNow: Date?

    public init(writerDeviceID: String) { self.writerDeviceID = writerDeviceID }

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

    public func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await server.publish(record, as: channel, from: deviceID)
    }

    public func fetchDeviceRecords() async throws -> LibraryDeviceRecords { await server.deviceRecords() }

    public func commitFetchedState(_ token: LibraryChangeToken?) async throws { committedFetchToken = token }

    public func commitSentState(_ token: LibraryChangeToken?) async throws { committedSentToken = token }
}
