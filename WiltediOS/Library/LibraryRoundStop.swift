import Foundation
import os

private let roundLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibrarySyncRound")

/// Why a sync round may no longer write what it read. A round logs its first stop and its failure, with
/// no account values, so a round that ends early shows in the device log instead of ending silently.
enum LibraryRoundStop: String, Equatable {
    case cancelled = "the round was cancelled"
    case generationChanged = "the transport moved to a new operation generation"
    case ownerUnverified = "the saved library's account is not verified yet this launch"
    case ownerDiffers = "the signed-in account is not the saved library's"
    case reviewHold = "the account is held for review"
    case quarantined = "the account is quarantined"
    case storeReplaced = "the library store was replaced"

    /// The first reason the round must stop, or nil while it may continue.
    static func check(
        cancelled: Bool, generationMatches: Bool, savedOwner: String?, verifiedOwner: String?,
        reviewHold: Bool, quarantined: Bool, sameStore: Bool
    ) -> LibraryRoundStop? {
        if cancelled { return .cancelled }
        if !generationMatches { return .generationChanged }
        if let savedOwner, savedOwner != verifiedOwner { return verifiedOwner == nil ? .ownerUnverified : .ownerDiffers }
        if reviewHold { return .reviewHold }
        if quarantined { return .quarantined }
        if !sameStore { return .storeReplaced }
        return nil
    }

    func log() { roundLog.notice("Sync round stopped: \(rawValue, privacy: .public)") }

    /// Logs a failed round by error domain and code only; descriptions can carry record names.
    static func logFailure(_ error: any Error) {
        let ns = error as NSError
        roundLog.notice("Sync round failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
    }
}
