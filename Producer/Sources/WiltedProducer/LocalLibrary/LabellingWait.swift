import Foundation
import WiltedDomain

/// Why a deferred preparation ticket is waiting on the ad labeller, and until when.
///
/// Only a ticket whose `failureKind` parses as ``WorkTicketDeferralReason`` is a
/// labelling wait. An off-peak or other deferral without that reason is not one.
public struct LabellingWait: Sendable, Equatable {
    public let reason: WorkTicketDeferralReason
    public let retryAt: Timestamp
    /// How many times this request has been deferred so far.
    public let waitCount: Int

    /// Builds a wait from the raw ticket fields already in hand. Returns nil unless
    /// the ticket is deferred and `failureKind` is a labelling deferral reason with
    /// a retry time.
    public init?(
        state: WorkTicketState,
        failureKind: String?,
        nextEligibleAt: Timestamp?,
        deferralCount: Int?
    ) {
        guard state == .deferred,
              let failureKind,
              let reason = WorkTicketDeferralReason(rawValue: failureKind),
              let nextEligibleAt else { return nil }
        self.reason = reason
        self.retryAt = nextEligibleAt
        self.waitCount = max(0, deferralCount ?? 0)
    }

    /// The same failable read, from a decoded ticket.
    public init?(_ ticket: WorkTicket) {
        self.init(
            state: ticket.state,
            failureKind: ticket.failureKind,
            nextEligibleAt: ticket.nextEligibleAt,
            deferralCount: ticket.deferralCount
        )
    }
}
