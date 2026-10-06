import AVFoundation
import Foundation

public protocol ListenerAudioEngine: AnyObject, Sendable {
    var duration: Double { get }
    var currentTime: Double { get set }
    var isPlaying: Bool { get }
    func load(url: URL) throws
    func play() -> Bool
    func pause()
    func load(url: URL, completionGeneration: UInt64) throws
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void)
}

public extension ListenerAudioEngine {
    /// Compatibility bridge for engines that do not expose natural completion.
    func load(url: URL, completionGeneration: UInt64) throws { try load(url: url) }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

/// `nonisolated` because `AVAudioPlayerDelegate` is main-actor-isolated in the
/// iOS 27 SDK, and inheriting that isolation would make every member unable to
/// satisfy the nonisolated `ListenerAudioEngine` requirements. The engine was
/// always meant to be callable from any actor -- it is `@unchecked Sendable`
/// and guards its own mutable state with `completionLock`.
nonisolated public final class AVFoundationAudioEngine: NSObject, ListenerAudioEngine, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private let completionLock = NSLock()
    private var playerGeneration: [ObjectIdentifier: UInt64] = [:]
    private var completionHandler: (@Sendable (UInt64) -> Void)?
    public override init() { super.init() }
    public var duration: Double { player?.duration ?? 0 }
    public var currentTime: Double {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = newValue }
    }
    public var isPlaying: Bool { player?.isPlaying ?? false }
    public func load(url: URL) throws {
        try load(url: url, completionGeneration: 0)
    }
    public func load(url: URL, completionGeneration: UInt64) throws {
        let loadedPlayer = try AVAudioPlayer(contentsOf: url)
        loadedPlayer.delegate = self
        loadedPlayer.prepareToPlay()
        completionLock.withLock {
            if let player { playerGeneration.removeValue(forKey: ObjectIdentifier(player)) }
            player = loadedPlayer
            playerGeneration[ObjectIdentifier(loadedPlayer)] = completionGeneration
        }
    }
    public func play() -> Bool { player?.play() ?? false }
    public func pause() { player?.pause() }
    public func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
        completionLock.withLock { completionHandler = handler }
    }
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        let completion: (UInt64, (@Sendable (UInt64) -> Void)?)? = completionLock.withLock {
            guard let generation = playerGeneration.removeValue(forKey: ObjectIdentifier(player)) else { return nil }
            return (generation, completionHandler)
        }
        guard let (generation, handler) = completion else { return }
        handler?(generation)
    }
}

public protocol ListenerAudioSession: Sendable {
    func activate() throws
    func deactivate()
}

public struct AVAudioSessionController: ListenerAudioSession {
    public init() {}
    public func activate() throws {
        #if os(iOS)
        // No options: `allowAirPlay` and `allowBluetoothA2DP` are valid only with
        // `playAndRecord`, and passing them with an output-only category fails the whole
        // activation with OSStatus -50. Both routes are implicitly available for `playback`.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
    public func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
