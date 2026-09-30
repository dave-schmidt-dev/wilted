import Foundation
import WiltedDomain

/// A `LibraryTransport` whose every server call goes through one shared `TransportGate`.
///
/// Wrapping the transport once, where it is built, is what makes the gate shared: the poller, the
/// handoff coordinator, the library publisher, intents and media all hold the wrapper, so a rate
/// limit any of them meets pauses all of them, and none of them needs its own retry timer.
/// Local bookkeeping (`operationGeneration`, the two commit calls) never touches the server and is
/// not gated.
public struct ThrottledLibraryTransport: LibraryTransport {
    private let inner: any LibraryTransport
    public let gate: TransportGate

    public init(wrapping inner: any LibraryTransport, gate: TransportGate) {
        self.inner = inner
        self.gate = gate
    }

    public func operationGeneration() async -> UInt64 { await inner.operationGeneration() }

    public func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        try await gate.run { try await inner.fetchChanges(since: token) }
    }

    public func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        try await gate.run { try await inner.push(changes: changes) }
    }

    public func send(intent: LibraryIntent) async throws {
        try await gate.run { try await inner.send(intent: intent) }
    }

    public func listIntents() async throws -> [LibraryIntent] {
        try await gate.run { try await inner.listIntents() }
    }

    public func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
        try await gate.run { try await inner.publishIntentOutcome(outcome) }
    }

    public func intentOutcomes() async throws -> [IntentOutcome] {
        try await gate.run { try await inner.intentOutcomes() }
    }

    public func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await gate.run { try await inner.publish(record, as: channel) }
    }

    public func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        try await gate.run { try await inner.fetchDeviceRecords() }
    }

    public func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
        try await gate.run { try await inner.publishMedia(offer: offer, fileURL: fileURL) }
    }

    public func mediaOffers() async throws -> [LibraryMediaOffer] {
        try await gate.run { try await inner.mediaOffers() }
    }

    public func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await gate.run { try await inner.fetchMedia(offer, progress: progress) }
    }

    public func removeMedia(entryID: ItemID) async throws {
        try await gate.run { try await inner.removeMedia(entryID: entryID) }
    }

    public func publishStats(_ stats: LibraryStats) async throws {
        try await gate.run { try await inner.publishStats(stats) }
    }

    public func readStats() async throws -> LibraryStats? {
        try await gate.run { try await inner.readStats() }
    }

    public func publishTranscript(_ transcript: LibraryTranscript) async throws {
        try await gate.run { try await inner.publishTranscript(transcript) }
    }

    public func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await gate.run { try await inner.transcript(entryID: entryID, revisionID: revisionID) }
    }

    public func removeTranscript(entryID: ItemID) async throws {
        try await gate.run { try await inner.removeTranscript(entryID: entryID) }
    }

    public func commitFetchedState(_ token: LibraryChangeToken?) async throws {
        try await inner.commitFetchedState(token)
    }

    public func commitSentState(_ token: LibraryChangeToken?) async throws {
        try await inner.commitSentState(token)
    }
}
