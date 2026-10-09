import CryptoKit
import Foundation
import WiltedDomain

#if canImport(WiltedProducer)
import WiltedProducer

struct WiltedMacShareContext: Sendable {
    let store: LocalLibraryStore
    let controller: PlaybackController
    let account: WiltedMacLibraryAccountController?
    let storeID: ObjectIdentifier
    let controllerID: ObjectIdentifier
    let accountID: ObjectIdentifier?
    let itemID: ItemID
    let revisionID: RevisionID
    let sessionID: String
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
    /// Captures the loaded revision and its durable transcript, never presentation text or notes.
    func captureShareContext() async throws -> WiltedMacShareContext {
        guard !isClosingTemporaryState, let store, let playback,
              let itemID = playback.itemID, let revisionID = playback.revisionID,
              let sessionID = playback.sessionID else { throw WiltedMacShareContextError.unavailable }
        let account = libraryAccount
        let binding: LocalLibraryAccountBinding?
        let gateGeneration: UInt64?
        let accountID: ObjectIdentifier?
        if let account {
            guard let current = account.binding, account.gate.isOpen else { throw WiltedMacShareContextError.unavailable }
            binding = current
            gateGeneration = account.gate.generation
            accountID = ObjectIdentifier(account)
        } else {
            binding = nil
            gateGeneration = nil
            accountID = nil
        }
        guard let transcript = try await store.transcript(for: itemID, revisionID: revisionID),
              transcript.itemID == itemID, transcript.revisionID == revisionID,
              transcript.availability == .available, let text = transcript.text, !text.isEmpty else {
            throw WiltedMacShareContextError.transcriptUnavailable
        }
        guard try await stillOwnsShareContext(store: store, playback: playback, itemID: itemID,
                                               revisionID: revisionID, sessionID: sessionID,
                                               accountID: accountID, binding: binding, gateGeneration: gateGeneration) else {
            throw WiltedMacShareContextError.unavailable
        }
        let title: String
        let shareURL: URL?
        if let episode = try await store.podcastEpisode(for: itemID) {
            title = episode.title
            shareURL = episode.episodeLink
        } else if let article = try await store.article(for: itemID), !article.isDeleted {
            title = article.title
            shareURL = article.canonicalURL
        } else { throw WiltedMacShareContextError.unavailable }
        guard try await stillOwnsShareContext(store: store, playback: playback, itemID: itemID,
            revisionID: revisionID, sessionID: sessionID, accountID: accountID,
            binding: binding, gateGeneration: gateGeneration) else { throw WiltedMacShareContextError.unavailable }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return WiltedMacShareContext(store: store, controller: playback, account: account,
                                     storeID: ObjectIdentifier(store), controllerID: ObjectIdentifier(playback),
                                     accountID: accountID, itemID: itemID, revisionID: revisionID, sessionID: sessionID,
                                     binding: binding, accountGateGeneration: gateGeneration,
                                     transcript: text, transcriptDigest: digest, title: title, shareURL: shareURL)
    }

    func matchesShareContext(_ context: WiltedMacShareContext) -> Bool {
        guard !isClosingTemporaryState, store === context.store, playback === context.controller,
              playback?.itemID == context.itemID, playback?.revisionID == context.revisionID,
              playback?.sessionID == context.sessionID else { return false }
        if let account = context.account {
            return libraryAccount === account && account.binding == context.binding
                && account.gate.isOpen && account.gate.generation == context.accountGateGeneration
        }
        return libraryAccount == nil && context.binding == nil
    }

    func stillOwnsShareContext(_ context: WiltedMacShareContext) async -> Bool {
        guard let store, let playback, store === context.store, playback === context.controller,
              ObjectIdentifier(store) == context.storeID, ObjectIdentifier(playback) == context.controllerID else { return false }
        guard (try? await stillOwnsShareContext(store: store, playback: playback, itemID: context.itemID,
                                                  revisionID: context.revisionID, sessionID: context.sessionID,
                                                  accountID: context.accountID, binding: context.binding,
                                                  gateGeneration: context.accountGateGeneration)) == true else { return false }
        guard let transcript = try? await store.transcript(for: context.itemID, revisionID: context.revisionID),
              transcript.availability == .available, transcript.text == context.transcript else { return false }
        return (try? await stillOwnsShareContext(store: store, playback: playback, itemID: context.itemID,
            revisionID: context.revisionID, sessionID: context.sessionID, accountID: context.accountID,
            binding: context.binding, gateGeneration: context.accountGateGeneration)) ?? false
    }

    private func stillOwnsShareContext(store: LocalLibraryStore, playback: PlaybackController,
                                       itemID: ItemID, revisionID: RevisionID, sessionID: String,
                                       accountID: ObjectIdentifier?, binding: LocalLibraryAccountBinding?,
                                       gateGeneration: UInt64?) async throws -> Bool {
        guard !isClosingTemporaryState, self.store === store, self.playback === playback,
              ObjectIdentifier(store) == ObjectIdentifier(self.store!),
              ObjectIdentifier(playback) == ObjectIdentifier(self.playback!),
              playback.itemID == itemID, playback.revisionID == revisionID, playback.sessionID == sessionID else { return false }
        let persisted = try await store.libraryAccountBinding()
        guard !isClosingTemporaryState, self.store === store, self.playback === playback,
              playback.itemID == itemID, playback.revisionID == revisionID, playback.sessionID == sessionID else { return false }
        if let binding, let gateGeneration, let account = libraryAccount, let accountID {
            return ObjectIdentifier(account) == accountID && account.binding == binding
                && account.gate.generation == gateGeneration && account.gate.isOpen && persisted == binding
        }
        return accountID == nil && libraryAccount == nil && persisted == nil
    }
}
#endif
