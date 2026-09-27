import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

extension WiltedListenerAppModel {
    func invalidateCurrentOperation() {
        cancellationRequested = true
        operationGeneration &+= 1
        // A session-factory transport may have advanced its in-memory engine state
        // after returning a fetch batch but before that batch was promoted. Do not
        // let a later send serialize that provisional state. Directly injected
        // transports intentionally remain reusable after cancellation in tests.
        if sessionFactory != nil, session != nil {
            rebuildSessionBeforeNextTransportOperation = true
        }
        guard operationInFlight else { return }
        releaseOperationSlot()
    }

    func beginOperation() -> UInt64? {
        guard !operationInFlight, !operationHandoffReserved else { return nil }
        return claimOperationSlot()
    }

    func beginQueuedOperation() async -> UInt64 {
        if operationInFlight || operationHandoffReserved {
            await withCheckedContinuation { operationWaiters.append($0) }
            operationHandoffReserved = false
        }
        return claimOperationSlot()
    }

    private func claimOperationSlot() -> UInt64 {
        operationGeneration &+= 1
        operationInFlight = true
        cancellationRequested = false
        return operationGeneration
    }

    func isCurrent(_ operation: UInt64) -> Bool {
        operationGeneration == operation && !cancellationRequested
    }

    func finishOperation(_ operation: UInt64) {
        guard operationGeneration == operation else { return }
        releaseOperationSlot()
    }

    private func releaseOperationSlot() {
        operationInFlight = false
        guard !operationWaiters.isEmpty else {
            operationHandoffReserved = false
            return
        }
        operationHandoffReserved = true
        operationWaiters.removeFirst().resume()
    }

    public func resetAfterAccountChange() async {
        guard let session else { return }
        await session.resetAfterAccountChange()
        accountQuarantined = false
        syncPhase = .ready
    }

    /// The single account-review entry point the listener UI calls.
    ///
    /// `resetAfterAccountChange()` only recovers when a live sync session
    /// exists. A listener can also be quarantined before one is established —
    /// and the account-free fixture never has one — so this covers both rather
    /// than leaving the control inert in exactly the states it is needed.
    public func recoverFromAccountChange() async {
        guard accountQuarantined else { return }
        if session != nil {
            await resetAfterAccountChange()
            return
        }
        accountQuarantined = false
        await updateDownloadedStates()
        syncPhase = .ready
    }

#if DEBUG
    /// Installs deterministic catalog state for the account-free UI fixture.
    /// This is internal to the app target so the production composition cannot
    /// accidentally use fixture data.
    func installMVPFixture(item: ListenerLibraryItem, revision: AudioRevision, asset: WiltedAsset,
                           transcript: Transcript? = nil) {
        items = [item]
        revisionByItem = [item.itemID: revision]
        assetByItem = [item.itemID: asset]
        manifestByItem = [:]
        playbackByItem = [:]
        playbackChangeTagByItem = [:]
        transcriptsByItem = transcript.map { [item.itemID: $0] } ?? [:]
        downloadStatistics = ListenerDownloadStatistics()
        syncPhase = .ready
    }

    /// Drives the recovery state exposed only by the account-free UI fixture.
    func quarantineForMVPFixture() {
        accountQuarantined = true
        invalidateCurrentOperation()
        syncPhase = .failed("iCloud account switch detected; sync is quarantined", retryable: false)
    }

    /// Recovers the account-free UI fixture after its simulated quarantine.
    func recoverMVPFixture() async {
        guard session == nil, accountQuarantined else { return }
        accountQuarantined = false
        await updateDownloadedStates()
        syncPhase = .ready
    }
#endif

    public func install(remoteCommands: any ListenerRemoteCommands) async {
        installedRemoteCommands = remoteCommands
        await playback?.install(remoteCommands: remoteCommands)
    }

    public func installSystemRemoteCommands() async {
        if installedRemoteCommands is MediaPlayerRemoteCommands { return }
        let remoteCommands = MediaPlayerRemoteCommands()
        installedRemoteCommands = remoteCommands
        await playback?.install(remoteCommands: remoteCommands)
    }

#if DEBUG
    var installedSystemRemoteCommandsForTesting: MediaPlayerRemoteCommands? {
        installedRemoteCommands as? MediaPlayerRemoteCommands
    }
#endif

}
