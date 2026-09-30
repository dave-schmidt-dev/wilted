import Foundation

/// A transient reply from the server that asks the caller to wait: rate limited, service
/// unavailable or a busy zone. Everything else (offline, conflicts, bad data) is not pressure.
public struct TransportPressure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case rateLimited, serviceUnavailable }

    public let kind: Kind
    /// The wait the server asked for, when the error carried one.
    public let retryAfter: TimeInterval?

    public init(kind: Kind, retryAfter: TimeInterval?) {
        self.kind = kind
        self.retryAfter = retryAfter
    }
}

/// Recognises CloudKit's transient errors without importing CloudKit.
///
/// `CKError.retryAfterSeconds` is lost when the CloudKit adapter turns an error into
/// `CloudKitSyncError.cloudKit(code:message:)`, keeping only the code and the localized message,
/// so three shapes are read: a `CKErrorDomain` error with its `CKErrorRetryAfterKey`, that
/// adapter's error by its printed form, and, for either, the "Retry after N seconds" the
/// message carries for a throttled request. Without a stated wait the gate backs off by itself.
public enum TransportPressureClassifier {
    /// `CKError.Code.serviceUnavailable`.
    static let serviceUnavailableCode = 6
    /// `CKError.Code.requestRateLimited`.
    static let requestRateLimitedCode = 7
    /// `CKError.Code.zoneBusy`.
    static let zoneBusyCode = 23

    public static func classify(_ error: Error) -> TransportPressure? {
        if error is TransportThrottled { return nil }
        let nsError = error as NSError
        let text = String(describing: error)
        var code: Int?
        var retryAfter: TimeInterval?
        if nsError.domain == "CKErrorDomain" {
            code = nsError.code
            retryAfter = (nsError.userInfo["CKErrorRetryAfterKey"] as? NSNumber)?.doubleValue
        } else if let found = firstMatch(#"cloudKit\(code: (-?\d+)"#, in: text) {
            code = Int(found)
        }
        guard let code, let kind = kind(of: code) else { return nil }
        if retryAfter == nil, let seconds = firstMatch(#"Retry after ([0-9]+(?:\.[0-9]+)?) seconds"#, in: text) {
            retryAfter = Double(seconds)
        }
        return TransportPressure(kind: kind, retryAfter: retryAfter)
    }

    private static func kind(of code: Int) -> TransportPressure.Kind? {
        switch code {
        case requestRateLimitedCode, zoneBusyCode: .rateLimited
        case serviceUnavailableCode: .serviceUnavailable
        default: nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Thrown instead of touching the network while a `TransportGate` is closed.
public struct TransportThrottled: Error, Equatable, Sendable, CustomStringConvertible {
    public let retryAt: Date
    public init(retryAt: Date) { self.retryAt = retryAt }
    public var description: String { "throttled until \(retryAt.formatted(date: .omitted, time: .standard))" }
}

/// What a closed gate is waiting for, for a status line.
public struct TransportGateState: Sendable, Equatable {
    public let kind: TransportPressure.Kind
    public let retryAt: Date
    /// Consecutive pressure replies that closed the gate, 1 for the first.
    public let consecutiveFailures: Int

    public init(kind: TransportPressure.Kind, retryAt: Date, consecutiveFailures: Int) {
        self.kind = kind
        self.retryAt = retryAt
        self.consecutiveFailures = consecutiveFailures
    }

    /// The status line, in words: "iCloud is rate limiting sync. Retrying in 45 s."
    public func notice(now: Date) -> String {
        let remaining = retryAt.timeIntervalSince(now)
        return remaining <= 0
            ? "\(Self.cause(kind)) Retrying now."
            : "\(Self.cause(kind)) Retrying in \(Self.wait(remaining))."
    }

    /// The same line with the resume time instead of a countdown, for a place that does not tick.
    public var noticeWithResumeTime: String {
        "\(Self.cause(kind)) Retrying at \(retryAt.formatted(date: .omitted, time: .standard))."
    }

    static func cause(_ kind: TransportPressure.Kind) -> String {
        switch kind {
        case .rateLimited: "iCloud is rate limiting sync."
        case .serviceUnavailable: "iCloud is temporarily unavailable."
        }
    }

    static func wait(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded(.up)))
        return whole < 60 ? "\(whole) s" : "\((whole + 59) / 60) min"
    }
}

/// One gate per device, shared by everything that talks to the server (poller, handoff, library
/// publish, intents, media), so a rate limit pauses all of them together instead of each
/// retrying on its own timer.
///
/// A pressure reply closes the gate until the server's requested wait or an exponential backoff
/// (`SyncCadence.backoffBase`, doubling per consecutive reply, capped at `backoffCap`), whichever
/// is longer. While closed, `run` fails at once with `TransportThrottled` and sends nothing. When
/// the time has passed one caller is let through as a probe; success reopens the gate and resets
/// the count, another pressure reply closes it again for longer.
public actor TransportGate {
    private let clock: @Sendable () -> Date
    private let onChange: (@Sendable (TransportGateState?) -> Void)?
    private var closed: TransportGateState?
    private var failures = 0
    private var probing = false

    /// - Parameters:
    ///   - onChange: called when the gate closes (with the new state) and when it reopens (nil).
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        onChange: (@Sendable (TransportGateState?) -> Void)? = nil
    ) {
        self.clock = clock
        self.onChange = onChange
    }

    /// The wait for `failures` consecutive pressure replies, given what the server asked for.
    static func delay(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponent = Double(min(max(failures, 1) - 1, 20))
        let backoff = min(SyncCadence.backoffCap, SyncCadence.backoffBase * pow(2, exponent))
        return min(3_600, max(backoff, retryAfter ?? 0))
    }

    public var state: TransportGateState? { closed }

    /// Runs `operation` unless the gate is closed, and learns from how it ends.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let isProbe = try admit()
        do {
            let value = try await operation()
            succeeded(isProbe: isProbe)
            return value
        } catch {
            failed(error, isProbe: isProbe)
            throw error
        }
    }

    /// Whether the caller admitted is the probe that follows a closure. A request admitted while
    /// the gate was open is not: its outcome must not reopen or re-close a later closure.
    private func admit() throws -> Bool {
        guard let current = closed else { return false }
        let now = clock()
        if now < current.retryAt { throw TransportThrottled(retryAt: current.retryAt) }
        if probing { throw TransportThrottled(retryAt: now.addingTimeInterval(1)) }
        probing = true
        return true
    }

    private func succeeded(isProbe: Bool) {
        if isProbe { probing = false }
        // A request admitted before the gate closed says nothing about the server now.
        guard isProbe || closed == nil else { return }
        failures = 0
        guard closed != nil else { return }
        closed = nil
        onChange?(nil)
    }

    private func failed(_ error: Error, isProbe: Bool) {
        if isProbe { probing = false }
        // A throttled or unrelated failure says nothing new about the server; a probe that failed
        // some other way leaves the gate as it was, so the next caller probes again. A pressure
        // reply to a request admitted before the gate closed is the same closure, not a new one.
        guard isProbe || closed == nil else { return }
        guard let pressure = TransportPressureClassifier.classify(error) else { return }
        failures += 1
        let wait = Self.delay(failures: failures, retryAfter: pressure.retryAfter)
        let state = TransportGateState(
            kind: pressure.kind, retryAt: clock().addingTimeInterval(wait), consecutiveFailures: failures)
        closed = state
        onChange?(state)
    }
}
