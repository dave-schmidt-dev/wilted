import Foundation
import WatchConnectivity

/// Carries one received application context from `WCSession`'s callback queue to
/// the main actor. `@unchecked Sendable`: the dictionary is a property list the
/// view model only reads.
private struct WatchContextEnvelope: @unchecked Sendable {
    let context: [String: Any]
}

/// The Watch app's half of the Watch link.
///
/// At launch it sets itself as `WCSession.default`'s delegate and activates the
/// session when the device supports it. It feeds every received application
/// context (including the one already waiting after activation) into
/// `WatchViewModel`, mirrors the session's reachability, and sends the model's
/// commands back to the phone with `sendMessage(_:replyHandler:errorHandler:)`.
@MainActor
final class WatchSessionClient: NSObject, WCSessionDelegate {
    /// The view model the watch screens render and this client feeds.
    let model: WatchViewModel
    private var started = false

    /// Wraps `model` and points its command sender at this client.
    init(model: WatchViewModel) {
        self.model = model
        super.init()
        model.commandSender = { [weak self] command in self?.send(command) }
    }

    /// Activates the session once at launch, when the device supports it.
    func start() {
        guard !started else { return }
        started = true
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func send(_ command: WatchCommand) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.isReachable else { return }
        guard let payload = try? WatchLinkCodec.encode(command) else { return }
        session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
    }

    private func activationCompleted() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        model.isPhoneReachable = session.isReachable
        model.receive(context: session.receivedApplicationContext)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor [weak self] in self?.activationCompleted() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in self?.model.isPhoneReachable = isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let envelope = WatchContextEnvelope(context: applicationContext)
        Task { @MainActor [weak self] in self?.model.receive(context: envelope.context) }
    }
}
