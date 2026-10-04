import Foundation
import WiltedDomain
import WiltedLibrary

/// Why a library server call was refused. Carries no account identifier.
enum WiltedMacLibraryAccountError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The account is not approved for sending, so the call never reached the transport.
    case notApproved

    var description: String { "library sync is paused until the iCloud account is confirmed" }
}

// MARK: - Gate

/// The open/closed state every library server call checks, plus the generation that
/// invalidates work admitted before a close. Closing bumps the generation; reopening does not,
/// so a call admitted before a close can never complete after a reopen either.
final class WiltedMacLibraryAccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool
    private var generationValue: UInt64 = 0

    init(open: Bool) { self.open = open }

    var isOpen: Bool { lock.withLock { open } }
    var generation: UInt64 { lock.withLock { generationValue } }

    /// Admits one call, returning the generation it must still hold when it finishes.
    func admit() throws -> UInt64 {
        try lock.withLock {
            guard open else { throw WiltedMacLibraryAccountError.notApproved }
            return generationValue
        }
    }

    /// Throws `superseded` when the gate closed (or closed and reopened) since `generation`.
    func verify(_ generation: UInt64) throws {
        try lock.withLock {
            guard open, generationValue == generation else { throw LibraryTransportError.superseded }
        }
    }

    func close() { lock.withLock { open = false; generationValue &+= 1 } }
    func reopen() { lock.withLock { open = true } }
}

/// A `LibraryTransport` whose every call, local commits included, runs only while the account
/// gate is open and returns only if it is still open at the same generation. A result that
/// arrives after an account change is discarded as `superseded`, so nothing it carried is
/// written locally. Wrap it inside `ThrottledLibraryTransport`, so admission happens when the
/// call actually runs, after any throttle wait.
struct WiltedMacAccountGatedLibraryTransport: LibraryTransport {
    let inner: any LibraryTransport
    let gate: WiltedMacLibraryAccountGate

    /// Runs `operation` under the gate; used for calls made outside the protocol (discovery).
    func run<Result: Sendable>(_ operation: () async throws -> Result) async throws -> Result {
        let generation = try gate.admit()
        let result = try await operation()
        try gate.verify(generation)
        return result
    }

    /// Changes whenever the inner transport's generation or the account gate's does.
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() &+ gate.generation }

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        try await run { try await inner.fetchChanges(since: token) }
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        try await run { try await inner.push(changes: changes) }
    }
    func send(intent: LibraryIntent) async throws { try await run { try await inner.send(intent: intent) } }
    func listIntents() async throws -> [LibraryIntent] { try await run { try await inner.listIntents() } }
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
        try await run { try await inner.publishIntentOutcome(outcome) }
    }
    func intentOutcomes() async throws -> [IntentOutcome] { try await run { try await inner.intentOutcomes() } }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await run { try await inner.publish(record, as: channel) }
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        try await run { try await inner.fetchDeviceRecords() }
    }
    func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
        let generation = try gate.admit()
        try await inner.publish(records)  // The tuple array is not Sendable, so not through `run`.
        try gate.verify(generation)
    }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        try await run { try await inner.poll(options) }
    }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        try await run { try await inner.publishMedia(offer: offer, fileURL: fileURL) }
    }
    func mediaOffers() async throws -> [LibraryMediaOffer] { try await run { try await inner.mediaOffers() } }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await run { try await inner.fetchMedia(offer, progress: progress) }
    }
    func removeMedia(entryID: ItemID) async throws { try await run { try await inner.removeMedia(entryID: entryID) } }
    func publishStats(_ stats: LibraryStats) async throws { try await run { try await inner.publishStats(stats) } }
    func readStats() async throws -> LibraryStats? { try await run { try await inner.readStats() } }
    func publishTranscript(_ transcript: LibraryTranscript) async throws {
        try await run { try await inner.publishTranscript(transcript) }
    }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await run { try await inner.transcript(entryID: entryID, revisionID: revisionID) }
    }
    func removeTranscript(entryID: ItemID) async throws {
        try await run { try await inner.removeTranscript(entryID: entryID) }
    }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws {
        try await run { try await inner.commitFetchedState(token) }
    }
    func commitSentState(_ token: LibraryChangeToken?) async throws {
        try await run { try await inner.commitSentState(token) }
    }
}
