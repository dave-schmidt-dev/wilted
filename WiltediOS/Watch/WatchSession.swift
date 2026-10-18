import Foundation
import WatchConnectivity

/// Carries one received message and its reply handler from WCSession's callback queue to the main
/// actor. `@unchecked Sendable`: the dictionary is a property list the bridge only reads.
private struct WatchMessageEnvelope: @unchecked Sendable {
    let message: [String: Any]
    let replyHandler: ([String: Any]) -> Void
}

/// The production `WatchSessionProtocol`: a thin main-actor adapter over `WCSession.default`.
///
/// `WCSession` delivers its delegate callbacks on its own queue, so each one hops to the main
/// actor before it reaches the bridge. The adapter is iOS-only; the shared protocol under
/// `WatchLink/` is the part a watchOS target can reuse.
@MainActor
final class WatchSession: NSObject, WatchSessionProtocol, WCSessionDelegate {
    private let session: WCSession
    /// Whether `activate()` already asked the system; cleared when the session deactivates.
    private var requestedActivation = false

    /// Wraps `session`; production passes `WCSession.default`. The delegate is set in `activate()`,
    /// which the bridge calls only when `WCSession.isSupported()`.
    init(session: WCSession = .default) {
        self.session = session
        super.init()
    }

    var isSupported: Bool { WCSession.isSupported() }
    var activationState: WatchSessionActivationState { Self.state(session.activationState) }
    var isPaired: Bool { session.isPaired }
    var isWatchAppInstalled: Bool { session.isWatchAppInstalled }
    weak var delegate: (any WatchSessionDelegate)?

    func activate() {
        session.delegate = self
        guard !requestedActivation else { return }
        requestedActivation = true
        session.activate()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor [weak self] in self?.delegate?.watchSessionDidActivate() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.requestedActivation = false
            self?.delegate?.watchSessionDidBecomeInactive()
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.requestedActivation = false
            self?.delegate?.watchSessionDidDeactivate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.delegate?.watchSessionWatchStateDidChange() }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let envelope = WatchMessageEnvelope(message: message, replyHandler: replyHandler)
        Task { @MainActor [weak self] in
            self?.delegate?.watchSessionDidReceiveMessage(envelope.message, replyHandler: envelope.replyHandler)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let envelope = WatchMessageEnvelope(message: message, replyHandler: { _ in })
        Task { @MainActor [weak self] in
            self?.delegate?.watchSessionDidReceiveMessage(envelope.message, replyHandler: envelope.replyHandler)
        }
    }

    private static func state(_ state: WCSessionActivationState) -> WatchSessionActivationState {
        switch state {
        case .notActivated: .notActivated
        case .inactive: .inactive
        case .activated: .activated
        @unknown default: .inactive
        }
    }
}

/// Forwards to the real session but ignores an activation request while that session is already
/// active, so the early background activation and the bridge's own `activate()` count as one.
@MainActor
final class WatchSessionActivationGate: WatchSessionProtocol {
    private let session: any WatchSessionProtocol
    private var requestedActivation = false

    init(_ session: any WatchSessionProtocol) {
        self.session = session
    }

    var isSupported: Bool { session.isSupported }
    var activationState: WatchSessionActivationState { session.activationState }
    var isPaired: Bool { session.isPaired }
    var isWatchAppInstalled: Bool { session.isWatchAppInstalled }

    var delegate: (any WatchSessionDelegate)? {
        get { session.delegate }
        set { session.delegate = newValue }
    }

    func activate() {
        guard !(requestedActivation && session.activationState == .activated) else { return }
        requestedActivation = true
        session.activate()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }
}

/// Holds the Watch callbacks that arrive after the background bootstrap activated the session but
/// before `prepare()` starts the bridge, then replays them to the bridge in arrival order. Only the
/// newest 32 messages are kept; an evicted message, like one that never reaches a bridge, is
/// answered with a rejection instead of leaving its Watch waiting.
@MainActor
final class WatchSessionBackgroundBuffer: WatchSessionDelegate {
    /// How many unhandled messages are kept before the oldest is evicted.
    static let maximumPendingMessages = 32

    private enum Callback {
        case activated
        case becameInactive
        case deactivated
        case watchStateChanged
        case message([String: Any], ([String: Any]) -> Void)
    }

    private var callbacks: [Callback] = []
    private var pendingMessages = 0

    func watchSessionDidActivate() {
        callbacks.append(.activated)
    }

    func watchSessionDidBecomeInactive() {
        callbacks.append(.becameInactive)
    }

    func watchSessionDidDeactivate() {
        callbacks.append(.deactivated)
    }

    func watchSessionWatchStateDidChange() {
        callbacks.append(.watchStateChanged)
    }

    func watchSessionDidReceiveMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        while pendingMessages >= Self.maximumPendingMessages {
            guard let index = callbacks.firstIndex(where: { if case .message = $0 { return true }; return false })
            else { break }
            if case let .message(_, evictedReply) = callbacks.remove(at: index) {
                evictedReply(Self.rejection)
                pendingMessages -= 1
            }
        }
        callbacks.append(.message(message, replyHandler))
        pendingMessages += 1
    }

    /// Replays everything buffered to the now-started bridge, oldest first.
    func flush(to delegate: any WatchSessionDelegate) {
        let buffered = callbacks
        callbacks = []
        pendingMessages = 0
        for callback in buffered {
            switch callback {
            case .activated: delegate.watchSessionDidActivate()
            case .becameInactive: delegate.watchSessionDidBecomeInactive()
            case .deactivated: delegate.watchSessionDidDeactivate()
            case .watchStateChanged: delegate.watchSessionWatchStateDidChange()
            case let .message(message, replyHandler):
                delegate.watchSessionDidReceiveMessage(message, replyHandler: replyHandler)
            }
        }
    }

    /// Answers every buffered message when the bridge can never start.
    func rejectPending() {
        let buffered = callbacks
        callbacks = []
        pendingMessages = 0
        for callback in buffered {
            if case let .message(_, replyHandler) = callback {
                replyHandler(Self.rejection)
            }
        }
    }

    private static var rejection: [String: Any] {
        [WatchBridge.okKey: false, WatchBridge.reasonKey: WatchRejection.notReady.rawValue]
    }
}
