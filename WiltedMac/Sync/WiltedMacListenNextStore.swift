import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary
import WiltedProducer

private let listenNextStoreLog = Logger(subsystem: "com.zerodelta.wilted", category: "ListenNext")

/// Durable Mac-side admission, status, and cancellation state for Listen next.
/// Admission and its idempotency receipt share one atomic file write so a replay can resume work.
actor WiltedMacListenNextStore {
    typealias Writer = @Sendable (Data, URL) throws -> DurableFile.ReplacementResult

    private struct Tombstone: Codable, Equatable {
        let requestID: String
        let requesterDeviceID: String
        let ownerToken: String
        let createdAt: Date
    }

    private struct Stored: Codable {
        var version = 1
        var ownerToken: String?
        var operationGeneration: UInt64?
        var requests: [String: LibraryListenNextRequestSnapshot] = [:]
        var tombstones: [String: Tombstone] = [:]
    }

    private let fileURL: URL?
    private let write: Writer
    private let now: @Sendable () -> Date
    private var state: Stored

    init(
        fileURL: URL?,
        now: @escaping @Sendable () -> Date = { Date() },
        write: @escaping Writer = { try DurableFile.replace($0, to: $1) }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.write = write
        if let fileURL, let bytes = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: bytes), decoded.version == 1 {
            state = decoded
        } else {
            state = Stored()
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                let aside = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                listenNextStoreLog.error("The saved Listen next requests were unreadable and were set aside")
            }
        }
    }

    /// Binds the book to the verified account and current operation generation on this Mac.
    /// A different account discards the old account's headlines and pending requests together.
    @discardableResult
    func activate(ownerToken: String, operationGeneration: UInt64) throws -> [LibraryListenNextRequestSnapshot] {
        guard !ownerToken.isEmpty else { throw LibraryTransportError.superseded }
        if state.ownerToken == ownerToken, state.operationGeneration == operationGeneration {
            return sortedRequests(in: state)
        }
        var next = state
        if next.ownerToken != ownerToken {
            next = Stored(ownerToken: ownerToken, operationGeneration: operationGeneration)
        } else {
            next.operationGeneration = operationGeneration
            next.tombstones = next.tombstones.filter { $0.value.ownerToken == ownerToken }
            next.requests = next.requests.mapValues { snapshot in
                guard !snapshot.isTerminal else { return snapshot }
                return Self.rebinding(snapshot, ownerToken: ownerToken, generation: operationGeneration)
            }
        }
        try persist(next)
        state = next
        return sortedRequests(in: next)
    }

    /// Atomically records request admission before the intent receives an applied outcome.
    /// Replaying the same intent returns the stored ticket and never starts a second ticket.
    @discardableResult
    func admit(
        _ intent: LibraryIntent,
        ownerToken: String,
        operationGeneration: UInt64,
        voiceID: String?,
        voiceRevision: String?
    ) throws -> LibraryListenNextRequestSnapshot {
        guard case let .listenNext(story, anchorID) = intent.action,
              state.ownerToken == ownerToken,
              state.operationGeneration == operationGeneration,
              (voiceID == nil) == (voiceRevision == nil) else {
            throw LibraryTransportError.superseded
        }
        if let existing = state.requests[intent.id] {
            guard existing.requesterDeviceID == intent.deviceID, existing.story == story,
                  existing.ownerToken == ownerToken, existing.anchorID == anchorID,
                  existing.createdAt == intent.createdAt else {
                throw LibraryTransportError.ownershipViolation("The Listen next request id was reused for different content.")
            }
            return existing
        }
        if let tombstone = state.tombstones[intent.id] {
            guard tombstone.requesterDeviceID == intent.deviceID, tombstone.ownerToken == ownerToken else {
                throw LibraryTransportError.ownershipViolation("The Listen next cancellation belongs to another device.")
            }
            let cancelled = try LibraryListenNextRequestSnapshot(
                requestID: intent.id, story: story, requesterDeviceID: intent.deviceID, ownerToken: ownerToken,
                operationGeneration: operationGeneration, anchorID: anchorID, createdAt: intent.createdAt,
                statusUpdatedAt: tombstone.createdAt,
                status: .cancelled, statusRevision: 1)
            var next = state
            next.requests[intent.id] = cancelled
            try persist(next)
            state = next
            return cancelled
        }
        let pending = try LibraryListenNextRequestSnapshot(
            requestID: intent.id, story: story, requesterDeviceID: intent.deviceID, ownerToken: ownerToken,
            operationGeneration: operationGeneration, anchorID: anchorID, createdAt: intent.createdAt,
            statusUpdatedAt: now(),
            status: .preparing, statusRevision: 1, voiceID: voiceID, voiceRevision: voiceRevision)
        var next = state
        next.requests[intent.id] = pending
        try persist(next)
        state = next
        return pending
    }

    /// Advances one request only while its account and operation generation remain current.
    /// A late completion after cancellation cannot recreate its offer or queue row.
    @discardableResult
    func setStatus(
        requestID: String,
        ownerToken: String,
        operationGeneration: UInt64,
        status: LibraryListenNextRequestSnapshot.Status,
        offer: LibraryStoryAudioOffer? = nil,
        failure: LibraryListenNextStatus.Failure? = nil
    ) throws -> LibraryListenNextRequestSnapshot? {
        guard state.ownerToken == ownerToken, state.operationGeneration == operationGeneration,
              let current = state.requests[requestID], current.ownerToken == ownerToken,
              current.operationGeneration == operationGeneration else { return nil }
        guard Self.permits(from: current.status, to: status) else { return nil }
        let newOffer = status == .failed ? nil : (offer ?? current.audioOffer)
        if current.status == status, current.audioOffer == newOffer, current.failure == failure {
            return current
        }
        guard current.statusRevision < UInt64.max else { return nil }
        let revision = current.statusRevision + 1
        let updated = try LibraryListenNextRequestSnapshot(
            requestID: current.requestID, story: current.story, requesterDeviceID: current.requesterDeviceID,
            ownerToken: current.ownerToken, operationGeneration: current.operationGeneration,
            anchorID: current.anchorID, createdAt: current.createdAt, statusUpdatedAt: now(), status: status,
            statusRevision: revision, audioOffer: newOffer,
            voiceID: current.voiceID, voiceRevision: current.voiceRevision, failure: failure)
        var next = state
        next.requests[requestID] = updated
        try persist(next)
        state = next
        return updated
    }

    /// Performs a queue lifecycle transition only when the caller still holds the exact snapshot
    /// it selected. This keeps a delayed player callback from advancing a cancelled or newer row.
    @discardableResult
    func transition(
        from expected: LibraryListenNextRequestSnapshot,
        to status: LibraryListenNextRequestSnapshot.Status,
        failure: LibraryListenNextStatus.Failure? = nil
    ) throws -> LibraryListenNextRequestSnapshot? {
        guard state.requests[expected.requestID] == expected,
              state.ownerToken == expected.ownerToken,
              state.operationGeneration == expected.operationGeneration else { return nil }
        return try setStatus(
            requestID: expected.requestID, ownerToken: expected.ownerToken,
            operationGeneration: expected.operationGeneration, status: status,
            offer: status == .failed ? nil : expected.audioOffer, failure: failure)
    }

    /// Writes a cancellation tombstone even when the original request has not arrived yet.
    @discardableResult
    func cancel(
        requestID: String,
        requesterDeviceID: String,
        ownerToken: String,
        operationGeneration: UInt64
    ) throws -> LibraryListenNextRequestSnapshot? {
        guard state.ownerToken == ownerToken, state.operationGeneration == operationGeneration else { return nil }
        if let current = state.requests[requestID], current.requesterDeviceID != requesterDeviceID {
            throw LibraryTransportError.ownershipViolation("Only the requesting device may cancel this reading.")
        }
        var next = state
        if let existing = next.requests[requestID], existing.status == .cancelled,
           let tombstone = next.tombstones[requestID], tombstone.requesterDeviceID == requesterDeviceID,
           tombstone.ownerToken == ownerToken {
            return existing
        }
        if let tombstone = next.tombstones[requestID], tombstone.requesterDeviceID == requesterDeviceID,
           tombstone.ownerToken == ownerToken, state.requests[requestID] == nil {
            return nil
        }
        next.tombstones[requestID] = Tombstone(
            requestID: requestID, requesterDeviceID: requesterDeviceID, ownerToken: ownerToken, createdAt: now())
        var result = next.requests[requestID]
        if let current = result, !current.isTerminal {
            guard current.statusRevision < UInt64.max else { return nil }
            result = try LibraryListenNextRequestSnapshot(
                requestID: current.requestID, story: current.story, requesterDeviceID: current.requesterDeviceID,
                ownerToken: current.ownerToken, operationGeneration: current.operationGeneration,
                anchorID: current.anchorID, createdAt: current.createdAt, statusUpdatedAt: now(), status: .cancelled,
                statusRevision: current.statusRevision + 1,
                audioOffer: current.audioOffer,
                voiceID: current.voiceID, voiceRevision: current.voiceRevision)
            next.requests[requestID] = result
        }
        try persist(next)
        state = next
        return result
    }

    func snapshot(_ requestID: String) -> LibraryListenNextRequestSnapshot? { state.requests[requestID] }

    func allSnapshots() -> [LibraryListenNextRequestSnapshot] { sortedRequests(in: state) }

    func snapshots(requesterDeviceID: String, ownerToken: String) -> [LibraryListenNextRequestSnapshot] {
        sortedRequests(in: state).filter {
            $0.requesterDeviceID == requesterDeviceID && $0.ownerToken == ownerToken
        }
    }

    private static func permits(
        from old: LibraryListenNextRequestSnapshot.Status,
        to new: LibraryListenNextRequestSnapshot.Status
    ) -> Bool {
        if old == new { return true }
        switch old {
        case .pending: return new == .sent || new == .preparing || new == .failed || new == .cancelled
        case .sent: return new == .preparing || new == .ready || new == .failed || new == .cancelled
        case .preparing: return new == .ready || new == .failed || new == .cancelled
        case .ready: return new == .selected || new == .playing || new == .failed || new == .cancelled
        case .selected: return new == .ready || new == .playing || new == .completed || new == .failed || new == .cancelled
        case .playing: return new == .completed || new == .failed || new == .cancelled
        case .failed, .cancelled, .completed: return false
        }
    }

    private static func rebinding(
        _ value: LibraryListenNextRequestSnapshot, ownerToken: String, generation: UInt64
    ) -> LibraryListenNextRequestSnapshot {
        (try? LibraryListenNextRequestSnapshot(
            requestID: value.requestID, story: value.story, requesterDeviceID: value.requesterDeviceID,
            ownerToken: ownerToken, operationGeneration: generation, anchorID: value.anchorID,
            createdAt: value.createdAt, statusUpdatedAt: value.statusUpdatedAt,
            status: value.status, statusRevision: value.statusRevision,
            audioOffer: value.audioOffer, voiceID: value.voiceID, voiceRevision: value.voiceRevision,
            failure: value.failure)) ?? value
    }

    private func sortedRequests(in stored: Stored) -> [LibraryListenNextRequestSnapshot] {
        stored.requests.values.sorted { ($0.createdAt, $0.requestID) < ($1.createdAt, $1.requestID) }
    }

    private func persist(_ next: Stored) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(next)
        let result = try write(bytes, fileURL)
        if case let .replacedDirectorySyncUncertain(failure) = result {
            listenNextStoreLog.warning("Listen next state landed but folder sync is uncertain: \(failure.description, privacy: .public)")
        }
    }
}
