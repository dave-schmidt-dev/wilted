import Foundation
import WiltedProducer

/// Why a report or bulletin check failed, as far as Settings needs to say.
///
/// Settings shows a fixed sentence per cause; the raw error goes to the log only, through
/// `LogSafeError`.
enum ReportFailureCause: Equatable, Sendable {
    case offline
    case timedOut
    case speechUnavailable
    case other

    /// Classifies `error`, looking once at its underlying error when it is otherwise unknown.
    static func of(_ error: Error) -> ReportFailureCause {
        let cause = classify(error)
        guard cause == .other,
              let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error else {
            return cause
        }
        return classify(underlying)
    }

    private static func classify(_ error: Error) -> ReportFailureCause {
        let nsError = error as NSError
        switch nsError.domain {
        case NSURLErrorDomain:
            if offlineURLErrorCodes.contains(nsError.code) { return .offline }
            if nsError.code == NSURLErrorTimedOut { return .timedOut }
        case "CKErrorDomain":
            if nsError.code == 3 || nsError.code == 4 { return .offline }
        default:
            break
        }
        if error is SpeechIPCError { return .speechUnavailable }
        return .other
    }

    private static let offlineURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
    ]
}
