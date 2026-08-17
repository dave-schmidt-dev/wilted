import Foundation

/// A monotonic, user-visible progress event for an operation owned by an iOS adapter.
///
/// Adapters must emit an event when work starts, while a cancellable operation is
/// waiting, and when it reaches a terminal outcome.  The contract deliberately
/// contains no UIKit, AVFoundation, or MediaPlayer types.
public struct PlatformProgress: Codable, Equatable, Sendable {
    /// Maximum allowed gap between status events while an operation is alive.
    public static let maximumStatusSilenceSeconds: TimeInterval = 5

    public enum Outcome: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case cancelled
    }

    public let sequence: UInt64
    public let stage: String
    public let detail: String
    public let fraction: Double?
    public let cancellable: Bool
    public let outcome: Outcome

    public init(
        sequence: UInt64,
        stage: String,
        detail: String,
        fraction: Double? = nil,
        cancellable: Bool,
        outcome: Outcome = .running
    ) {
        self.sequence = sequence
        self.stage = stage
        self.detail = detail
        self.fraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        // Terminal events are the cancellation/success/failure boundary and cannot
        // advertise another cancellation action.
        self.cancellable = outcome == .running && cancellable
        self.outcome = outcome
    }
}

// MARK: Audio session

public enum AudioRoute: String, Codable, Equatable, Sendable {
    case unknown
    case builtInSpeaker
    case headphones
    case bluetooth
    case carPlay
}

public enum AudioSessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case activating
    case active
    case interrupted
    case deactivating
    case failed
}

public struct AudioSessionState: Codable, Equatable, Sendable {
    public let phase: AudioSessionPhase
    public let route: AudioRoute
    public let resumeAfterInterruption: Bool
    public let lastError: String?
    public let lastProgress: PlatformProgress?

    public init(
        phase: AudioSessionPhase = .idle,
        route: AudioRoute = .unknown,
        resumeAfterInterruption: Bool = false,
        lastError: String? = nil,
        lastProgress: PlatformProgress? = nil
    ) {
        self.phase = phase
        self.route = route
        self.resumeAfterInterruption = resumeAfterInterruption
        self.lastError = lastError
        self.lastProgress = lastProgress
    }
}

public enum AudioSessionEvent: Equatable, Sendable {
    case activationRequested
    case activationSucceeded(route: AudioRoute)
    case activationFailed(reason: String)
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(AudioRoute)
    case deactivationRequested
    case deactivationSucceeded
    case cancelled
    case progress(PlatformProgress)
}

/// Pure state transition for audio-session lifecycle notifications.
public enum AudioSessionReducer {
    public static func reduce(_ state: AudioSessionState, _ event: AudioSessionEvent) -> AudioSessionState {
        switch event {
        case .activationRequested:
            return AudioSessionState(
                phase: .activating,
                route: state.route,
                lastProgress: state.lastProgress
            )
        case let .activationSucceeded(route):
            return AudioSessionState(phase: .active, route: route, lastProgress: state.lastProgress)
        case let .activationFailed(reason):
            return AudioSessionState(
                phase: .failed,
                route: state.route,
                lastError: reason,
                lastProgress: state.lastProgress
            )
        case .interruptionBegan:
            guard state.phase == .active else { return state }
            return AudioSessionState(
                phase: .interrupted,
                route: state.route,
                resumeAfterInterruption: true,
                lastProgress: state.lastProgress
            )
        case let .interruptionEnded(shouldResume):
            return AudioSessionState(
                phase: shouldResume && state.resumeAfterInterruption ? .active : .idle,
                route: state.route,
                resumeAfterInterruption: false,
                lastProgress: state.lastProgress
            )
        case let .routeChanged(route):
            return AudioSessionState(
                phase: state.phase,
                route: route,
                resumeAfterInterruption: state.resumeAfterInterruption,
                lastError: state.lastError,
                lastProgress: state.lastProgress
            )
        case .deactivationRequested:
            return AudioSessionState(
                phase: .deactivating,
                route: state.route,
                resumeAfterInterruption: state.resumeAfterInterruption,
                lastProgress: state.lastProgress
            )
        case .deactivationSucceeded, .cancelled:
            return AudioSessionState(phase: .idle, route: state.route, lastProgress: state.lastProgress)
        case let .progress(progress):
            return AudioSessionState(
                phase: state.phase,
                route: state.route,
                resumeAfterInterruption: state.resumeAfterInterruption,
                lastError: state.lastError,
                lastProgress: progress
            )
        }
    }
}

/// Platform code supplies the actual AVAudioSession implementation through this boundary.
public protocol AudioSessionControlling: Sendable {
    func events(for request: AudioSessionRequest) -> AsyncThrowingStream<AudioSessionEvent, Error>
}

public enum AudioSessionRequest: Sendable {
    case activate
    case deactivate
    case cancel
}

// MARK: Background playback

public enum BackgroundEligibility: Equatable, Sendable {
    case unknown
    case eligible
    case unavailable(reason: String)
}

public enum BackgroundPlaybackPhase: String, Codable, Equatable, Sendable {
    case foreground
    case enteringBackground
    case backgroundReady
    case playing
    case paused
    case recovering
    case ended
    case failed
}

public struct BackgroundPlaybackState: Equatable, Sendable {
    public let eligibility: BackgroundEligibility
    public let phase: BackgroundPlaybackPhase
    public let lastProgress: PlatformProgress?
    public let lastError: String?

    public init(
        eligibility: BackgroundEligibility = .unknown,
        phase: BackgroundPlaybackPhase = .foreground,
        lastProgress: PlatformProgress? = nil,
        lastError: String? = nil
    ) {
        self.eligibility = eligibility
        self.phase = phase
        self.lastProgress = lastProgress
        self.lastError = lastError
    }
}

public enum BackgroundPlaybackEvent: Equatable, Sendable {
    case eligibilityChanged(BackgroundEligibility)
    case enteredBackground
    case mediaReady
    case playbackStarted
    case playbackPaused
    case interruptionBegan
    case recovered
    case failed(reason: String)
    case cancelled
    case ended
    case progress(PlatformProgress)
}

public enum BackgroundPlaybackReducer {
    public static func reduce(
        _ state: BackgroundPlaybackState,
        _ event: BackgroundPlaybackEvent
    ) -> BackgroundPlaybackState {
        switch event {
        case let .eligibilityChanged(eligibility):
            return BackgroundPlaybackState(
                eligibility: eligibility,
                phase: eligibility == .eligible ? state.phase : .failed,
                lastProgress: state.lastProgress,
                lastError: eligibility.errorMessage ?? state.lastError
            )
        case .enteredBackground:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .enteringBackground,
                lastProgress: state.lastProgress,
                lastError: state.lastError
            )
        case .mediaReady:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .backgroundReady,
                lastProgress: state.lastProgress
            )
        case .playbackStarted:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .playing,
                lastProgress: state.lastProgress
            )
        case .playbackPaused:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .paused,
                lastProgress: state.lastProgress
            )
        case .interruptionBegan:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .recovering,
                lastProgress: state.lastProgress
            )
        case .recovered:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .backgroundReady,
                lastProgress: state.lastProgress
            )
        case let .failed(reason):
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .failed,
                lastProgress: state.lastProgress,
                lastError: reason
            )
        case .cancelled:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .ended,
                lastProgress: state.lastProgress
            )
        case .ended:
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: .ended,
                lastProgress: state.lastProgress
            )
        case let .progress(progress):
            return BackgroundPlaybackState(
                eligibility: state.eligibility,
                phase: state.phase,
                lastProgress: progress,
                lastError: state.lastError
            )
        }
    }
}

private extension BackgroundEligibility {
    var errorMessage: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

public protocol BackgroundPlaybackCoordinating: Sendable {
    func status(for request: BackgroundPlaybackRequest) -> AsyncThrowingStream<BackgroundPlaybackEvent, Error>
}

public enum BackgroundPlaybackRequest: Sendable {
    case prepare
    case cancel
}

// MARK: Now Playing

public struct NowPlayingProjectionInput: Equatable, Sendable {
    public let title: String?
    public let source: String?
    public let author: String?
    public let duration: TimeInterval?
    public let position: TimeInterval
    public let isPlaying: Bool

    public init(
        title: String?,
        source: String? = nil,
        author: String? = nil,
        duration: TimeInterval?,
        position: TimeInterval,
        isPlaying: Bool
    ) {
        self.title = title
        self.source = source
        self.author = author
        self.duration = duration
        self.position = position
        self.isPlaying = isPlaying
    }
}

public struct NowPlayingMetadata: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: TimeInterval?
    public let elapsed: TimeInterval
    public let playbackRate: Double

    public init(
        title: String?,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        elapsed: TimeInterval,
        playbackRate: Double
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.playbackRate = playbackRate
    }
}

public enum NowPlayingProjector {
    public static func project(_ input: NowPlayingProjectionInput) -> NowPlayingMetadata {
        let duration = input.duration.flatMap { $0 >= 0 ? $0 : nil }
        let elapsed = max(0, min(input.position, duration ?? .greatestFiniteMagnitude))
        return NowPlayingMetadata(
            title: input.title,
            artist: input.author,
            album: input.source,
            duration: duration,
            elapsed: elapsed,
            playbackRate: input.isPlaying ? 1 : 0
        )
    }
}

// MARK: Remote commands

public enum RemotePlaybackCommand: Equatable, Sendable {
    case play
    case pause
    case seekForward(seconds: TimeInterval)
    case seekBackward(seconds: TimeInterval)
    case seek(to: TimeInterval)
}

public struct RemotePlaybackState: Equatable, Sendable {
    public let hasMedia: Bool
    public let position: TimeInterval
    public let duration: TimeInterval?
    public let isPlaying: Bool

    public init(hasMedia: Bool, position: TimeInterval, duration: TimeInterval?, isPlaying: Bool) {
        self.hasMedia = hasMedia
        self.position = position
        self.duration = duration
        self.isPlaying = isPlaying
    }
}

public enum RemotePlaybackIntent: Equatable, Sendable {
    case play
    case pause
    case seek(to: TimeInterval)
}

public enum RemoteCommandRejection: Equatable, Sendable {
    case noMedia
    case invalidSeek
}

public enum RemoteCommandRouteResult: Equatable, Sendable {
    case accepted(RemotePlaybackIntent)
    case rejected(RemoteCommandRejection)
}

public enum RemoteCommandRouter {
    public static func route(_ command: RemotePlaybackCommand, state: RemotePlaybackState) -> RemoteCommandRouteResult {
        guard state.hasMedia else { return .rejected(.noMedia) }
        switch command {
        case .play:
            return .accepted(.play)
        case .pause:
            return .accepted(.pause)
        case let .seekForward(seconds):
            return seekResult(position: state.position + seconds, state: state, seconds: seconds)
        case let .seekBackward(seconds):
            return seekResult(position: state.position - seconds, state: state, seconds: seconds)
        case let .seek(to):
            return seekResult(position: to, state: state, seconds: 0)
        }
    }

    private static func seekResult(
        position: TimeInterval,
        state: RemotePlaybackState,
        seconds: TimeInterval
    ) -> RemoteCommandRouteResult {
        guard position.isFinite, seconds.isFinite, seconds >= 0 else { return .rejected(.invalidSeek) }
        let bounded = max(0, min(position, state.duration ?? .greatestFiniteMagnitude))
        return .accepted(.seek(to: bounded))
    }
}

public protocol RemotePlaybackCommandHandling: Sendable {
    func handle(_ command: RemotePlaybackCommand) async -> AsyncStream<PlatformProgress>
}
