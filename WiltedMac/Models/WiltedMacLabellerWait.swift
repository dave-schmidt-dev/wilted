import Foundation
import WiltedLibrary
import WiltedProducer

/// Listener-facing wording for an ad-labeller wait, shared by publication, the
/// Mac row, and the info-popover stamp. Pure and injectable for tests.
enum WiltedMacLabellerWait {
    /// Shown only on the Mac stamp, never on the published iPhone detail.
    static let phoneNote = "Not playable on iPhone until this finishes."

    /// Default short time style shared with labeller stop sentences.
    static func defaultFormatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Published status detail and stamp waiting sentence (sentence plus count).
    /// Stays at or under ``LibraryPreparationStatus/maximumDetailBytes``.
    static func publishedDetail(
        reason: WorkTicketDeferralReason,
        retryAt: Date,
        waitCount: Int,
        formatTime: (Date) -> String = defaultFormatTime
    ) -> String {
        boundedDetail(sentence(reason: reason, retryAt: retryAt, formatTime: formatTime)
            + countSuffix(reason: reason, waitCount: waitCount))
    }

    static func publishedDetail(
        _ wait: LabellingWait,
        formatTime: (Date) -> String = defaultFormatTime
    ) -> String {
        publishedDetail(
            reason: wait.reason, retryAt: wait.retryAt.date,
            waitCount: wait.waitCount, formatTime: formatTime
        )
    }

    /// Short Mac library-row label while a labelling wait is parked.
    static func rowLabel(
        reason: WorkTicketDeferralReason,
        retryAt: Date,
        formatTime: (Date) -> String = defaultFormatTime
    ) -> String {
        let time = formatTime(retryAt)
        switch reason {
        case .providerRateLimited, .providerUnavailable, .providerUsageLimit:
            return "Waiting on the provider · retrying \(time)"
        case .dailyRequestCap:
            return "Reached today's labelling limit · retrying \(time)"
        }
    }

    static func rowLabel(
        _ wait: LabellingWait,
        formatTime: (Date) -> String = defaultFormatTime
    ) -> String {
        rowLabel(reason: wait.reason, retryAt: wait.retryAt.date, formatTime: formatTime)
    }

    private static func sentence(
        reason: WorkTicketDeferralReason,
        retryAt: Date,
        formatTime: (Date) -> String
    ) -> String {
        let time = formatTime(retryAt)
        switch reason {
        case .providerRateLimited, .providerUnavailable, .providerUsageLimit:
            return "Ad removal is waiting on the provider. Retrying at \(time)."
        case .dailyRequestCap:
            return "Ad removal reached today's limit for online labelling. Retrying at \(time)."
        }
    }

    /// Provider waits carry a count; a daily-cap wait never does.
    private static func countSuffix(reason: WorkTicketDeferralReason, waitCount: Int) -> String {
        switch reason {
        case .dailyRequestCap:
            return ""
        case .providerRateLimited, .providerUnavailable, .providerUsageLimit:
            switch waitCount {
            case 0: return ""
            case 1: return " Tried once so far."
            default: return " Tried \(waitCount) times so far."
            }
        }
    }

    private static func boundedDetail(_ text: String) -> String {
        let limit = LibraryPreparationStatus.maximumDetailBytes
        guard text.utf8.count > limit else { return text }
        var end = text.endIndex
        while text[..<end].utf8.count > limit, end > text.startIndex {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }
}
