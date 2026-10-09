import Foundation
import WiltedDomain
import WiltedLibrary

/// Atomic phone mirror envelope. Legacy rows remain visible, but only a verified full
/// bootstrap can bind and replace them; every final installation is serialized with holds.
actor FileLibraryStore: LibraryStore {
    private struct CompletedDisplay: Codable {
        var sources: [LibrarySource]; var entries: [LibraryEntry]; var slots: [QueueSlot]; var listening: [ListeningRecord]
        var preparedIDs: Set<ItemID>
        init(_ content: LibrarySnapshot, ids: Set<ItemID>) {
            sources = Array(content.sources.values); entries = Array(content.entries.values)
            slots = content.queue; listening = Array(content.listening.values); preparedIDs = ids
        }
        var content: LibrarySnapshot { LibrarySnapshot(sources: sources, entries: entries, slots: slots, listening: listening) }
    }
    private struct Versioned: Codable { let key: LibraryRecordKey; let version: UInt64 }
    private struct Persisted: Codable {
        var sources: [LibrarySource]
        var entries: [LibraryEntry]
        var slots: [QueueSlot]
        var listening: [ListeningRecord]
        var versions: [Versioned]
        var cursor: LibraryChangeToken?
        var ownerToken: String?
        var observedPublication: LibraryPublication?
        var cacheCommittedAt: Date?
        var displayPreparedIDs: Set<ItemID>?
        var completedDisplay: CompletedDisplay?
        var displayRefreshPending: Bool?
        var displayAdmissionRevision: UInt64?
        var reviewHold: Bool?
        var revision: UInt64?

        private enum CodingKeys: String, CodingKey {
            case sources, entries, slots, listening, versions, cursor, ownerToken, observedPublication, cacheCommittedAt, displayPreparedIDs, completedDisplay, displayRefreshPending, displayAdmissionRevision, reviewHold, revision
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sources = try values.decode([LibrarySource].self, forKey: .sources)
            entries = try values.decode([LibraryEntry].self, forKey: .entries)
            slots = try values.decode([QueueSlot].self, forKey: .slots)
            listening = try values.decode([ListeningRecord].self, forKey: .listening)
            versions = try values.decode([Versioned].self, forKey: .versions)
            var damagedBinding = false
            do { cursor = try values.decodeIfPresent(LibraryChangeToken.self, forKey: .cursor) }
            catch { cursor = nil; damagedBinding = true }
            do {
                ownerToken = try values.decodeIfPresent(String.self, forKey: .ownerToken)
                if ownerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    ownerToken = nil
                    damagedBinding = true
                }
            } catch { ownerToken = nil; damagedBinding = true }
            // Optional damaged author metadata never hides otherwise valid saved rows.
            observedPublication = try? values.decodeIfPresent(LibraryPublication.self, forKey: .observedPublication)
            cacheCommittedAt = try? values.decodeIfPresent(Date.self, forKey: .cacheCommittedAt)
            displayPreparedIDs = try? values.decodeIfPresent(Set<ItemID>.self, forKey: .displayPreparedIDs)
            completedDisplay = try? values.decodeIfPresent(CompletedDisplay.self, forKey: .completedDisplay)
            displayRefreshPending = try? values.decodeIfPresent(Bool.self, forKey: .displayRefreshPending)
            do { reviewHold = try values.decodeIfPresent(Bool.self, forKey: .reviewHold) }
            catch { reviewHold = true; damagedBinding = true }
            do { revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) }
            catch { revision = nil; damagedBinding = true }
            do { displayAdmissionRevision = try values.decodeIfPresent(UInt64.self, forKey: .displayAdmissionRevision) }
            catch { displayAdmissionRevision = nil; damagedBinding = true }
            // Missing legacy metadata remains unbound; damaged binding requires explicit recovery.
            if damagedBinding { ownerToken = nil; reviewHold = true }

        }
        init(_ state: LibraryStoreState) {
            let content = state.content
            sources = Array(content.sources.values); entries = Array(content.entries.values)
            slots = Array(content.slots.values); listening = Array(content.listening.values)
            versions = state.versions.map { Versioned(key: $0.key, version: $0.value) }
            cursor = state.cursor; ownerToken = state.ownerToken
            observedPublication = state.observedPublication; cacheCommittedAt = state.cacheCommittedAt
            displayPreparedIDs = state.displayPreparedIDs
            completedDisplay = state.completedDisplay.map { CompletedDisplay($0, ids: state.completedDisplayPreparedIDs ?? []) }
            displayRefreshPending = state.displayRefreshPending
            displayAdmissionRevision = state.displayAdmissionRevision
            reviewHold = state.reviewHold; revision = state.revision
        }
    }

    private let url: URL
    private let historicalOwner: String?
    private let clock: @Sendable () -> Date
    private let writeData: @Sendable (Data, URL) throws -> Void
    private var current = LibraryStoreState()
    nonisolated let initialCursor: LibraryChangeToken?
    nonisolated let initialOwnerToken: String?
    nonisolated let initialReviewHold: Bool

    init(url: URL, historicalOwner: String? = nil, clock: @escaping @Sendable () -> Date = { Date() },
         writeData: @escaping @Sendable (Data, URL) throws -> Void = {
             try $0.write(to: $1, options: [.atomic, LibraryFileProtection.writingOption])
         }) {
        self.url = url
        self.historicalOwner = historicalOwner
        self.clock = clock
        self.writeData = writeData
        var loaded = LibraryStoreState()
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            loaded.content = LibrarySnapshot(sources: saved.sources, entries: saved.entries, slots: saved.slots, listening: saved.listening)
            loaded.versions = Dictionary(saved.versions.map { ($0.key, $0.version) }, uniquingKeysWith: { _, last in last })
            loaded.cursor = saved.cursor
            loaded.ownerToken = saved.ownerToken
            loaded.observedPublication = saved.ownerToken == nil ? nil : saved.observedPublication
            loaded.cacheCommittedAt = saved.cacheCommittedAt
            loaded.displayPreparedIDs = saved.displayPreparedIDs
            if saved.ownerToken != nil, let display = saved.completedDisplay,
               Set(display.entries.map(\.id)).count == display.entries.count,
               Set(display.sources.map(\.id)).count == display.sources.count,
               Set(display.listening.map(\.itemID)).count == display.listening.count,
               display.preparedIDs.isSubset(of: Set(display.slots.map(\.entryID))),
               display.preparedIDs.isSubset(of: Set(display.entries.map(\.id))) {
                loaded.completedDisplay = display.content
                loaded.completedDisplayPreparedIDs = display.preparedIDs
                loaded.displayRefreshPending = saved.displayRefreshPending ?? false
            }
            loaded.reviewHold = saved.reviewHold ?? false
            loaded.revision = saved.revision ?? 0
            loaded.displayAdmissionRevision = saved.displayAdmissionRevision ?? loaded.revision
        }
        current = loaded
        initialCursor = loaded.ownerToken == nil || loaded.reviewHold ? nil : loaded.cursor
        initialOwnerToken = loaded.ownerToken ?? historicalOwner
        initialReviewHold = loaded.reviewHold
    }

    /// Explicit recovery only. A failed removal preserves state and reports failure.
    func discard() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        current = LibraryStoreState()
    }

    func state() -> LibraryStoreState { current }
    func fetchCursor() -> LibraryChangeToken? { current.ownerToken == nil || current.reviewHold ? nil : current.cursor }

    /// Persists the fence before account-review notification. A failed save still closes this actor.
    func quarantine() throws {
        var held = current
        held.reviewHold = true
        held.reviewHoldPersistenceFailed = false
        held.revision &+= 1
        do {
            try write(held)
            current = held
        } catch {
            held.reviewHoldPersistenceFailed = true
            current = held
            throw error
        }
    }

    /// Calls without current transport verification cannot install owner-scoped content.
    func commit(_ staged: StagedLibraryBatch) throws {
        throw LibraryTransportError.ownershipViolation("A verified account operation is required")
    }

    func commit(_ staged: StagedLibraryBatch, transport: any LibraryTransport, expectedGeneration: UInt64) async throws {
        guard let proof = staged.batch.provenance,
              proof.operationGeneration == expectedGeneration,
              !proof.ownerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              await transport.verifiedOwnerToken() == proof.ownerToken,
              await transport.operationGeneration() == expectedGeneration else {
            throw LibraryTransportError.superseded
        }
        // No await from here through file installation: a hold that won the actor updates the revision.
        guard !current.reviewHold else { throw LibraryTransportError.ownershipViolation("Account review is required") }
        guard current.revision == staged.priorState.revision else { throw LibraryTransportError.staleStagedBatch }
        guard (current.ownerToken ?? historicalOwner).map({ $0 == proof.ownerToken }) ?? true else {
            throw LibraryTransportError.ownershipViolation("The saved library belongs to a different account")
        }
        guard current.ownerToken != nil || proof.isFullBootstrap else {
            throw LibraryTransportError.ownershipViolation("An unbound library requires a verified full bootstrap")
        }
        var base = proof.isFullBootstrap ? LibraryStoreState() : current
        // A full scan replaces content/versions/cursor from empty remote state, but keeps same-owner author evidence.
        base.observedPublication = current.ownerToken == proof.ownerToken ? current.observedPublication : nil
        base.displayPreparedIDs = current.ownerToken == proof.ownerToken ? current.displayPreparedIDs : nil
        if current.ownerToken == proof.ownerToken {
            base.completedDisplay = current.completedDisplay
            base.completedDisplayPreparedIDs = current.completedDisplayPreparedIDs
            base.displayRefreshPending = current.displayRefreshPending
        }
        var next = LibraryReconciler.reconcile(base, with: staged.batch)
        next.ownerToken = proof.ownerToken
        next.displayPreparedIDs = next.displayPreparedIDs?.intersection(Set(next.content.queue.map(\.entryID)))
        next.observedPublication = Self.newerPublication(staged.batch.observedPublication, than: base.observedPublication)
        next.cacheCommittedAt = clock()
        next.revision = current.revision &+ 1
        next.displayAdmissionRevision = next.revision
        try write(next)
        current = next
    }

    func beginDisplayRefresh(transport: any LibraryTransport, expectedGeneration: UInt64) async throws {
        guard let owner = current.ownerToken else { return }
        let revision = current.revision
        guard await transport.verifiedOwnerToken() == owner, await transport.operationGeneration() == expectedGeneration,
              current.ownerToken == owner, current.revision == revision, !current.reviewHold else { throw LibraryTransportError.superseded }
        var next = current
        if next.completedDisplay == nil, let ids = next.displayPreparedIDs {
            next.completedDisplay = next.content; next.completedDisplayPreparedIDs = ids
        }
        next.displayRefreshPending = true; next.revision &+= 1
        try write(next); current = next
    }
    func completeDisplayRefresh(transport: any LibraryTransport, expectedGeneration: UInt64, expectedRevision: UInt64) async throws {
        guard let owner = current.ownerToken, await transport.verifiedOwnerToken() == owner,
              await transport.operationGeneration() == expectedGeneration, current.ownerToken == owner,
              current.revision == expectedRevision, !current.reviewHold else { throw LibraryTransportError.superseded }
        var next = current
        next.completedDisplay = next.content; next.completedDisplayPreparedIDs = next.displayPreparedIDs ?? []
        next.displayRefreshPending = false; next.revision &+= 1
        try write(next); current = next
    }

    func recordDisplayOffers(_ offers: [LibraryMediaOffer], transport: any LibraryTransport,
                             expectedGeneration: UInt64, expectedRevision: UInt64) async throws {
        guard let owner = current.ownerToken, await transport.verifiedOwnerToken() == owner,
              await transport.operationGeneration() == expectedGeneration else { throw LibraryTransportError.superseded }
        guard current.ownerToken == owner else { throw LibraryTransportError.superseded }
        guard !current.reviewHold else { throw LibraryTransportError.ownershipViolation("Account review is required") }
        guard current.revision == expectedRevision else { throw LibraryTransportError.staleStagedBatch }
        let ids = Set(offers.filter(\.isPrepared).map(\.entryID)).intersection(Set(current.content.queue.map(\.entryID)))
        var next = current
        next.displayPreparedIDs = ids
        next.revision &+= 1
        next.displayAdmissionRevision = next.revision
        try write(next)
        current = next
    }

    func removeDisplayOffer(_ entryID: ItemID, transport: any LibraryTransport,
                            expectedGeneration: UInt64, expectedDisplayRevision: UInt64) async throws {
        guard let owner = current.ownerToken, await transport.verifiedOwnerToken() == owner,
              await transport.operationGeneration() == expectedGeneration else { throw LibraryTransportError.superseded }
        guard current.ownerToken == owner else { throw LibraryTransportError.superseded }
        guard !current.reviewHold else { throw LibraryTransportError.ownershipViolation("Account review is required") }
        guard current.displayAdmissionRevision == expectedDisplayRevision else { throw LibraryTransportError.staleStagedBatch }
        guard var ids = current.displayPreparedIDs, ids.remove(entryID) != nil else { return }
        var next = current
        next.displayPreparedIDs = ids
        next.completedDisplayPreparedIDs?.remove(entryID)
        next.revision &+= 1
        try write(next)
        current = next
    }

    private static func newerPublication(_ incoming: LibraryPublication?, than prior: LibraryPublication?) -> LibraryPublication? {
        guard let incoming else { return prior }
        guard let prior else { return incoming }
        guard incoming.id != prior.id, incoming.publishedAt > prior.publishedAt else { return prior }
        return incoming
    }

    func enqueue(_ change: LibraryChange) throws { throw LibraryTransportError.ownershipViolation("The iPhone does not edit the library") }
    func acknowledge(_ result: LibraryPushResult, sent: [PendingLibraryChange]) throws {}
    func resolveConflict(_ key: LibraryRecordKey, keepLocal: Bool) throws {}

    private func write(_ state: LibraryStoreState) throws {
        let saved = Persisted(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeData(JSONEncoder().encode(saved), url)
    }
}
