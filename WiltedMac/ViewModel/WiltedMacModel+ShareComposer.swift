import Foundation
import WiltedDomain

#if canImport(WiltedProducer)
import WiltedProducer

@MainActor
final class WiltedMacShareComposerRegistry {
    var states: [WiltedMacShareComposerKey: WiltedMacShareComposerState] = [:]
    var order: [WiltedMacShareComposerKey] = []
}

extension WiltedMacModel {
    var shareComposerSelectionIdentity: WiltedMacShareComposerKey? {
        guard let store, let itemID = playback?.itemID, let revisionID = playback?.revisionID else { return nil }
        let account = libraryAccount
        return WiltedMacShareComposerKey(store: ObjectIdentifier(store), account: account.map { ObjectIdentifier($0) },
            owner: account?.binding?.ownerToken, generation: account?.gate.generation,
            item: itemID.rawValue, revision: revisionID.rawValue)
    }

    func shareComposerState(service: TranscriptSummaryService = TranscriptSummaryService(),
                            configuration: TranscriptSummaryService.Configuration = .resolved(),
                            fingerprint: @escaping @Sendable () async -> String? = {
                                await Task.detached(priority: .utility) {
                                    PodcastPreparationPipeline.resolvedSemanticFingerprint()
                                }.value
                            })
        -> WiltedMacShareComposerState {
        guard let key = shareComposerSelectionIdentity else {
            return WiltedMacShareComposerState(model: self, service: service, configuration: configuration,
                                               fingerprint: fingerprint)
        }
        if let existing = shareComposerRegistry.states[key] { return existing }

        let state = WiltedMacShareComposerState(model: self, selectionKey: key, service: service, configuration: configuration,
                                                fingerprint: fingerprint)
        shareComposerRegistry.states[key] = state
        shareComposerRegistry.order.append(key)
        while shareComposerRegistry.order.count > 8 {
            let evicted = shareComposerRegistry.order.removeFirst()
            shareComposerRegistry.states.removeValue(forKey: evicted)?.invalidateContext()
        }
        return state
    }

    func invalidateShareComposerStates() {
        for state in shareComposerRegistry.states.values { state.invalidateContext() }
        shareComposerRegistry.states.removeAll()
        shareComposerRegistry.order.removeAll()
    }
}
#endif
