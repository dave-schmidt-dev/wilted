import Foundation
import WiltedProducer

extension WiltedMacAdFindingSettings {
    /// Owner-facing text for a finished backfill, or for a nil summary when
    /// labelling is unavailable in this launch.
    static func backfillEndedMessage(for summary: LabellerBackfill.Summary?) -> String {
        guard let summary else { return "The stored transcripts could not be read" }
        let n = summary.recorded
        let f = summary.failed
        let r = summary.remaining
        switch summary.ending {
        case .finished:
            return f == 0 ? "\(n) labelled" : "\(n) labelled, \(f) failed"
        case .nothingToLabel:
            return "Nothing to label right now"
        case .cancelled:
            return "Stopped. \(n) labelled"
        case .dailyCapReached:
            return "Today's request limit is reached. \(n) labelled, \(r) left for tomorrow"
        case .stopped(let kind):
            switch kind {
            case "rate-limited":
                return "The provider is limiting requests. \(n) labelled, \(r) left"
            case "key-rejected":
                return "The provider rejected the key. \(n) labelled, \(r) left"
            case "model-unavailable":
                return "The provider's model is unavailable. \(n) labelled, \(r) left"
            case "usage-limit":
                return "The provider's usage limit is reached. \(n) labelled, \(r) left"
            default:
                return "The provider could not be reached. \(n) labelled, \(r) left"
            }
        case .inactive:
            return "Turn on online ad finding first"
        case .unavailable:
            return "The stored transcripts could not be read"
        }
    }
}
