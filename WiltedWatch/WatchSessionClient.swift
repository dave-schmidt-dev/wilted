import Foundation
import OSLog
import WatchConnectivity

/// Carries one received application context from `WCSession`'s callback queue to
/// the main actor. `@unchecked Sendable`: the dictionary is a property list the
/// view model only reads.
private struct WatchContextEnvelope: @unchecked Sendable {
    let context: [String: Any]
}

/// The Watch app's log; command payloads are never logged.
private let sessionLog = Logger(subsystem: "com.zerodelta.wilted.watch", category: "Session")

/// The Watch app's half of the Watch link.
///
/// At launch it sets itself as `WCSession.default`'s delegate and activates the
/// session when the device supports it. It feeds every received application
/// context (including the one already waiting after activation) into
/// `WatchViewModel`, mirrors the session's reachability, and sends the model's
/// commands back to the phone with `sendMessage(_:replyHandler:errorHandler:)`.
/// A command the phone refuses or cannot receive clears its pending state and
/// leaves a short note on the model; every silent failure is logged.
@MainActor
final class WatchSessionClient: NSObject, WCSessionDelegate {
    /// The model's short note when the Watch cannot reach the phone.
    static let unreachableNote = "iPhone isn't reachable."
    /// The model's short note when the phone refused the command.
    static let rejectedNote = "iPhone didn't apply that. Try again."

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
        guard WCSession.isSupported() else {
            sessionLog.error("WatchConnectivity is unsupported; the command never left the watch")
            model.commandDidFail(command, note: Self.unreachableNote)
            return
        }
        let session = WCSession.default
        guard session.isReachable else {
            sessionLog.error("iPhone unreachable; the command never left the watch")
            model.commandDidFail(command, note: Self.unreachableNote)
            return
        }
        guard let payload = try? WatchLinkCodec.encode(command) else {
            sessionLog.error("Watch command encoding failed")
            model.commandDidFail(command, note: Self.rejectedNote)
            return
        }
        session.sendMessage(
            payload,
            replyHandler: { [weak self] reply in
                let accepted = reply["ok"] as? Bool == true
                let reason = reply["reason"] as? String
                Task { @MainActor in
                    guard let self, !accepted else { return }
                    sessionLog.error("iPhone refused a watch command: \(reason ?? "unknown", privacy: .public)")
                    self.model.commandDidFail(command, note: Self.rejectedNote)
                }
            },
            errorHandler: { [weak self] error in
                let domain = (error as NSError).domain
                let code = (error as NSError).code
                Task { @MainActor in
                    guard let self else { return }
                    sessionLog.error("Watch command delivery failed: \(domain, privacy: .public) code \(code, privacy: .public)")
                    self.model.commandDidFail(command, note: Self.unreachableNote)
                }
            })
    }

    /// Adopts a context, logging an undecodable one; an empty context means the
    /// phone has not published yet and is not an error.
    private func adopt(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        guard model.receive(context: context) else {
            sessionLog.error("Watch application context did not decode; keeping the last snapshot")
            return
        }
    }

    private func activationCompleted() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        model.isPhoneReachable = session.isReachable
        adopt(session.receivedApplicationContext)
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
        Task { @MainActor [weak self] in self?.adopt(envelope.context) }
    }
}
