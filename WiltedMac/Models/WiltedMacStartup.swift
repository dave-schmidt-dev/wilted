import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

enum WiltedMacNavigation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case menu
    case feeds
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .feeds: WiltedScreenCopy.feeds
        case .menu: WiltedScreenCopy.library
        case .settings: WiltedScreenCopy.settings
        }
    }

    var symbolName: String {
        switch self {
        case .feeds: WiltedSymbol.broccoli.rawValue
        case .menu: "list.number"
        case .settings: "gearshape"
        }
    }

    /// Resolve a persisted selection, including one that names a destination
    /// this build no longer has.
    ///
    /// The retired Larder and Prep were both places episodes waited, and the
    /// Menu is now the one place episodes wait, so a stored `library` or
    /// `processor` resolves there. An unreadable or absent value takes the
    /// same answer: the Menu is where the reader's episodes are.
    static func restored(from rawValue: String?) -> WiltedMacNavigation {
        guard let rawValue, let restored = WiltedMacNavigation(rawValue: rawValue) else {
            return .menu
        }
        return restored
    }

    /// Compatibility names for the retired destinations. Neither is a case:
    /// `allCases` is exactly Feeds, Menu and Settings, and source that still
    /// says `library` or `processor` means the Menu now. Remove these when the
    /// host test target that still names them is updated.
    static var library: WiltedMacNavigation { .menu }
    static var processor: WiltedMacNavigation { .menu }
}

#if canImport(WiltedProducer)
typealias WiltedMacStoreBootstrap = @Sendable (URL) async throws -> LocalLibraryStore
/// The stale-preparation pass at bootstrap, injectable so a failure there can
/// be exercised apart from a store that will not open.
typealias WiltedMacStaleInvalidation =
    @Sendable (LocalLibraryStore, String) async throws -> PodcastPreparationInvalidationResult
typealias WiltedMacPodcastDownloadTransportFactory = @Sendable () -> any PodcastDownloadTransporting
typealias WiltedMacPodcastMediaValidatorFactory = @Sendable () -> any PodcastMediaValidating
typealias WiltedMacPodcastPipelineRunnerFactory = @Sendable () -> any PodcastPipelineRunning
#endif

/// Seam over the one filesystem call `loadLibrary` needs to know whether a
/// ready revision's media is still on disk. Deliberately just `stat`, not a
/// read: a test double can count calls to prove the snapshot never hashes or
/// opens media it doesn't have to.
protocol WiltedMacMediaAvailabilityChecking {
    func fileExists(atPath path: String) -> Bool
}

extension FileManager: WiltedMacMediaAvailabilityChecking {}

struct WiltedMacStartupFailure: Equatable, Sendable {
    let message: String
    let detail: String?
    let retainedV5StoreURL: URL?
    let canRetry: Bool
}

#if canImport(WiltedProducer)
/// Marks a bootstrap failure that happened in the stale-preparation pass, so
/// it can report itself as its own condition instead of "could not open your
/// larder" when the store opened perfectly well.
/// Thrown where a durable write needs a fingerprint and none resolved.
///
/// Not a failure of the work it interrupts: the download succeeded, only its
/// recovery checkpoint is withheld until a launch can resolve the pipeline.
struct WiltedMacUnresolvedFingerprint: Error {}

struct WiltedMacStaleInvalidationFailure: Error {
    let underlying: Error
}
#endif

/// One awaited phase of store bootstrap, named so the startup readout can say
/// what the wait is for instead of showing one fixed sentence through all of it.
enum WiltedMacStartupStep: String, Equatable, Sendable {
    case openingStore = "Opening your larder"
    case updatingLibraryFormat = "Updating the library format"
    case retiringFinishedEpisodes = "Tidying finished episodes"
    case checkingPreparationFingerprint = "Checking preparation fingerprints"
    case closingInterruptedRuns = "Closing interrupted preparations"
    case reconcilingWork = "Reconciling background work"
    case loadingLibrary = "Loading saved episodes and articles"
    case restoringPlayback = "Restoring playback"

    /// The readout's line: the step's own words, with the ellipsis the old
    /// fixed sentence carried.
    var label: String { rawValue + "\u{2026}" }
}

enum WiltedMacStartupState: Equatable, Sendable {
    case loading(attempt: Int, step: WiltedMacStartupStep)
    case ready
    case failed(WiltedMacStartupFailure)

    /// The step the readout should show, when one is loading.
    var loadingStep: WiltedMacStartupStep? {
        if case let .loading(_, step) = self { return step }
        return nil
    }
}
