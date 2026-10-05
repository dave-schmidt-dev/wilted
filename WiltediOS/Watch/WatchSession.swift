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

    /// Wraps `session`; production passes `WCSession.default`.
    init(session: WCSession = .default) {
        self.session = session
        super.init()
        session.delegate = self
    }

    var isSupported: Bool { WCSession.isSupported() }
    var activationState: WatchSessionActivationState { Self.state(session.activationState) }
    var isPaired: Bool { session.isPaired }
    var isWatchAppInstalled: Bool { session.isWatchAppInstalled }
    weak var delegate: (any WatchSessionDelegate)?

    func activate() {
        session.delegate = self
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
        Task { @MainActor [weak self] in self?.delegate?.watchSessionDidBecomeInactive() }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.delegate?.watchSessionDidDeactivate() }
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

    private static func state(_ state: WCSessionActivationState) -> WatchSessionActivationState {
        switch state {
        case .notActivated: .notActivated
        case .inactive: .inactive
        case .activated: .activated
        @unknown default: .inactive
        }
    }
}
