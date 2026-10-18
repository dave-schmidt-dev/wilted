import Foundation
import os

#if canImport(WiltedProducer)
import WiltedProducer

extension WiltedMacModel {
    /// Every failed download lands here at `.error`, so a listener's report can
    /// be matched to the episode, the attempt, and the typed cause.
    nonisolated static let downloadLog = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Download")

    /// The plain sentence one failed download shows its reader.
    ///
    /// The cause is the coordinator's own typed error, never its
    /// `String(describing:)` text: only transport hiccups and malformed
    /// responses keep the retry-online wording, and every other cause names
    /// what actually happened.
    nonisolated static func downloadFailureMessage(for error: Error) -> String {
        guard let typed = error as? PodcastDownloadCoordinatorError else {
            let domain = (error as NSError).domain
            if domain == NSCocoaErrorDomain || domain == NSPOSIXErrorDomain {
                return "Wilted could not save the episode file to disk."
            }
            return "Download failed. Retry when you are online."
        }
        switch typed {
        case .transport(let detail):
            // The coordinator wraps its own staging and write failures as
            // `.transport` with the original error's description.
            if detail.contains("NSCocoaErrorDomain") || detail.contains("NSPOSIXErrorDomain") {
                return "Wilted could not save the episode file to disk."
            }
            return "Download failed. Retry when you are online."
        case .invalidResponse:
            return "Download failed. Retry when you are online."
        case .declaredSizeTooLarge, .streamedSizeTooLarge:
            return "The episode file is larger than Wilted can download."
        case .declaredSizeMismatch:
            return "The episode file size did not match what the server promised."
        case .hashMismatch, .invalidExpectedHash:
            return "The downloaded episode failed its integrity check."
        case .unsupportedMediaType, .mediaTypeMismatch:
            return "The episode uses an audio format Wilted cannot play."
        case .insecureRedirect, .invalidURL:
            return "The episode server did not offer a secure connection."
        case .destinationExists:
            return "Wilted could not save the episode file to disk."
        case .invalidAudio:
            return "The downloaded episode is not playable audio."
        case .episodeNotFound:
            return "The episode is no longer in the library."
        case .cancelled:
            return "Download cancelled."
        case .interrupted:
            return "Download interrupted by quit."
        }
    }
}
#endif
