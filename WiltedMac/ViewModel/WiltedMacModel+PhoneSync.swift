import Foundation
import WiltedDomain
import WiltedLibrary

/// What the library sync tells the rest of the Mac app: whether iCloud is pausing it.
#if canImport(WiltedProducer)
extension WiltedMacModel {
    /// Called by the sync's shared gate when it closes, backs off further, or opens again.
    func libraryThrottleChanged(_ state: TransportGateState?) {
        guard libraryThrottle != state else { return }
        libraryThrottle = state
    }
}
#endif
