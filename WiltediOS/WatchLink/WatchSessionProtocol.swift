import Foundation

/// The activation states the watch bridge cares about, mirrored from `WCSessionActivationState`
/// so this shared file does not import WatchConnectivity.
enum WatchSessionActivationState: Equatable, Sendable {
    /// The session is not activated.
    case notActivated
    /// The session is inactive or becoming active; it can neither publish nor receive yet.
    case inactive
    /// The session is active.
    case activated
}

/// The parts of `WCSession` the watch bridge uses, Foundation-only so the same protocol can be
/// shared with watchOS later and a test fake can stand in for the system session.
@MainActor
protocol WatchSessionProtocol: AnyObject {
    /// Whether this device supports watch connectivity at all.
    var isSupported: Bool { get }
    /// The system's current activation state.
    var activationState: WatchSessionActivationState { get }
    /// Whether a Watch is paired with this phone.
    var isPaired: Bool { get }
    /// Whether the Wilted Watch app is installed on the paired Watch.
    var isWatchAppInstalled: Bool { get }
    /// The bridge's callback sink, forwarded from `WCSession`'s own delegate.
    var delegate: (any WatchSessionDelegate)? { get set }
    /// Starts activation; the answer arrives through `delegate`.
    func activate()
    /// Replaces the application context the Watch reads.
    func updateApplicationContext(_ context: [String: Any]) throws
}

/// The session callbacks `WatchBridge` answers. The production adapter delivers every one on the
/// main actor, and a test fake calls them directly.
@MainActor
protocol WatchSessionDelegate: AnyObject {
    /// Activation finished; `isPaired` and `isWatchAppInstalled` are now meaningful.
    func watchSessionDidActivate()
    /// The session went inactive, typically while the Watch switches away from the app.
    func watchSessionDidBecomeInactive()
    /// The session deactivated and must be activated again before it is used.
    func watchSessionDidDeactivate()
    /// The paired or installed state changed.
    func watchSessionWatchStateDidChange()
    /// A command arrived; `replyHandler` must be called with the answer.
    func watchSessionDidReceiveMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void)
}
