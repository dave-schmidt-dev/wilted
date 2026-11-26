import CryptoKit
import Foundation
import WiltedDomain

#if canImport(WiltedProducer)
import WiltedProducer

struct WiltedMacShareSelection: Sendable {
    let store: LocalLibraryStore
    let account: WiltedMacLibraryAccountController?
    let storeID: ObjectIdentifier
    let accountID: ObjectIdentifier?
    let itemID: ItemID
    let revisionID: RevisionID
    let binding: LocalLibraryAccountBinding?
    let accountGateGeneration: UInt64?
}

struct WiltedMacShareContext: Sendable {
    let store: LocalLibraryStore
    let account: WiltedMacLibraryAccountController?
    let storeID: ObjectIdentifier
    let accountID: ObjectIdentifier?
    let itemID: ItemID
    let revisionID: RevisionID
    let binding: LocalLibraryAccountBinding?
    let accountGateGeneration: UInt64?
    let transcript: String
    let transcriptDigest: String
    let title: String
    let shareURL: URL?
}

enum WiltedMacShareContextError: LocalizedError {
    case unavailable
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "The current item is no longer available to share."
        case .transcriptUnavailable: "A complete local transcript is not available for this item."
        }
    }
}

extension WiltedMacModel {
    /// Freezes the selected revision and owner before the async summary job starts.
    func captureShareSelection() throws -> WiltedMacShareSelection {
        guard !isClosingTemporaryState, let store, let playback,
              let itemID = playback.itemID, let revisionID = playback.revisionID else {
            throw WiltedMacShareContextError.unavailable
        }
        let account = libraryAccount
        let binding: LocalLibraryAccountBinding?
        let gateGeneration: UInt64?
        let accountID: ObjectIdentifier?
        if let account {
            guard let current = account.binding, account.gate.isOpen else {
                throw WiltedMacShareContextError.unavailable
            }
            binding = current
            gateGeneration = account.gate.generation
            accountID = ObjectIdentifier(account)
        } else {
            binding = nil
            gateGeneration = nil
            accountID = nil
        }
        return WiltedMacShareSelection(store: store, account: account, storeID: ObjectIdentifier(store),
            accountID: accountID, itemID: itemID, revisionID: revisionID,
            binding: binding, accountGateGeneration: gateGeneration)
    }

    /// Captures the frozen revision even after playback moves to another item.
    func captureShareContext(for selection: WiltedMacShareSelection) async throws -> WiltedMacShareContext {
        guard !isClosingTemporaryState, store === selection.store,
              ObjectIdentifier(selection.store) == selection.storeID,
              shareSelectionAccountMatches(selection), await stillOwnsShareSelection(selection) else {
            throw WiltedMacShareContextError.unavailable
        }
        guard let transcript = try await selection.store.transcript(for: selection.itemID, revisionID: selection.revisionID),
              transcript.itemID == selection.itemID, transcript.revisionID == selection.revisionID,
              transcript.availability == .available, let text = transcript.text, !text.isEmpty else {
            throw WiltedMacShareContextError.transcriptUnavailable
        }
        guard await stillOwnsShareSelection(selection) else { throw WiltedMacShareContextError.unavailable }
        let (title, shareURL) = try await shareMetadata(for: selection.itemID, in: selection.store)
        let context = WiltedMacShareContext(store: selection.store, account: selection.account,
            storeID: selection.storeID, accountID: selection.accountID, itemID: selection.itemID,
            revisionID: selection.revisionID, binding: selection.binding,
            accountGateGeneration: selection.accountGateGeneration,
            transcript: text, transcriptDigest: Self.shareTranscriptDigest(text), title: title, shareURL: shareURL)
        guard await stillOwnsShareContext(context) else {
            throw WiltedMacShareContextError.unavailable
        }
        return context
    }

    /// Convenience entry for callers whose selection should be captured at call time.
    func captureShareContext() async throws -> WiltedMacShareContext {
        let selection = try captureShareSelection()
        return try await captureShareContext(for: selection)
    }

    /// Checks whether this revision is selected now; playback sessions may change while a job runs.
    func matchesShareContext(_ context: WiltedMacShareContext) -> Bool {
        guard !isClosingTemporaryState, store === context.store,
              playback?.itemID == context.itemID, playback?.revisionID == context.revisionID else { return false }
        return shareContextAccountMatches(context)
    }

    /// Verifies stored ownership and exact source data without requiring the item to remain selected.
    func stillOwnsShareContext(_ context: WiltedMacShareContext) async -> Bool {
        guard !isClosingTemporaryState, store === context.store,
              ObjectIdentifier(context.store) == context.storeID,
              shareContextAccountMatches(context) else { return false }

        guard (try? await context.store.readyRevision(for: context.itemID, revisionID: context.revisionID)) != nil,
              !isClosingTemporaryState, store === context.store, shareContextAccountMatches(context),
              let transcript = try? await context.store.transcript(for: context.itemID, revisionID: context.revisionID),
              transcript.itemID == context.itemID, transcript.revisionID == context.revisionID,
              transcript.availability == .available, transcript.text == context.transcript,
              !isClosingTemporaryState, store === context.store, shareContextAccountMatches(context) else { return false }

        guard let (title, shareURL) = try? await shareMetadata(for: context.itemID, in: context.store),
              title == context.title, shareURL == context.shareURL else { return false }
        let persistedBinding = try? await context.store.libraryAccountBinding()
        return !isClosingTemporaryState && store === context.store
            && shareContextAccountMatches(context) && persistedBinding == context.binding
    }

    private func stillOwnsShareSelection(_ selection: WiltedMacShareSelection) async -> Bool {
        guard !isClosingTemporaryState, store === selection.store,
              shareSelectionAccountMatches(selection),
              (try? await selection.store.readyRevision(for: selection.itemID, revisionID: selection.revisionID)) != nil,
              !isClosingTemporaryState, store === selection.store, shareSelectionAccountMatches(selection),
              (try? await selection.store.libraryAccountBinding()) == selection.binding else { return false }
        return !isClosingTemporaryState && store === selection.store && shareSelectionAccountMatches(selection)
    }

    private func shareSelectionAccountMatches(_ selection: WiltedMacShareSelection) -> Bool {
        if let account = selection.account, let accountID = selection.accountID,
           let generation = selection.accountGateGeneration {
            return libraryAccount === account && ObjectIdentifier(account) == accountID
                && account.binding == selection.binding && account.gate.isOpen
                && account.gate.generation == generation
        }
        return selection.account == nil && selection.accountID == nil
            && selection.binding == nil && selection.accountGateGeneration == nil
            && libraryAccount == nil
    }

    private func shareContextAccountMatches(_ context: WiltedMacShareContext) -> Bool {
        if let account = context.account, let accountID = context.accountID,
           let generation = context.accountGateGeneration {
            return libraryAccount === account && ObjectIdentifier(account) == accountID
                && account.binding == context.binding && account.gate.isOpen
                && account.gate.generation == generation
        }
        return context.account == nil && context.accountID == nil
            && context.binding == nil && context.accountGateGeneration == nil
            && libraryAccount == nil
    }

    private func shareMetadata(for itemID: ItemID, in store: LocalLibraryStore) async throws -> (String, URL?) {
        if let episode = try await store.podcastEpisode(for: itemID) {
            guard try await store.removalKind(for: itemID) == nil else { throw WiltedMacShareContextError.unavailable }
            return (episode.title, episode.episodeLink)
        }
        if let article = try await store.article(for: itemID), !article.isDeleted {
            return (article.title, article.canonicalURL)
        }
        throw WiltedMacShareContextError.unavailable
    }

    private static func shareTranscriptDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
