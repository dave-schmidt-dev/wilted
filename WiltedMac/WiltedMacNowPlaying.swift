import Foundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// What the system needs to draw Wilted in Control Center and the menu bar.
///
/// A value rather than a series of setter calls, so the model can compare what
/// it is about to publish with what it published last. The readout is refreshed
/// on a one-second timer while a window is open, and re-publishing an identical
/// dictionary sixty times a minute is work the system did not ask for: it
/// extrapolates elapsed time from `positionSeconds` and `rate` on its own.
struct WiltedNowPlayingInfo: Equatable, Sendable {
    var episodeID: String
    var title: String
    var showTitle: String
    var durationSeconds: TimeInterval
    var positionSeconds: TimeInterval
    /// The effective rate: the chosen speed while playing, zero while paused.
    /// This is what the system uses to advance its own clock, so a paused
    /// episode has to report zero rather than the speed it will resume at.
    var rate: Double
    /// The speed a resume would use. Reported separately because the effective
    /// rate above is zero while paused, and the system needs the real one to
    /// know what "normal" means for this item.
    var chosenRate: Double
    var isPlaying: Bool
    var artworkURL: URL?

    /// Whether re-publishing is worth it.
    ///
    /// Everything except position is compared exactly. Position is allowed to
    /// drift, because the system advances its own copy from `rate` and only
    /// needs correcting when playback actually jumps — a seek, a new episode,
    /// or the accumulated error of a long session.
    static let positionDriftTolerance: TimeInterval = 3

    func differsMateriallyFrom(_ other: WiltedNowPlayingInfo?) -> Bool {
        guard let other else { return true }
        if episodeID != other.episodeID || title != other.title || showTitle != other.showTitle { return true }
        if isPlaying != other.isPlaying || rate != other.rate || chosenRate != other.chosenRate { return true }
        if durationSeconds != other.durationSeconds || artworkURL != other.artworkURL { return true }
        return abs(positionSeconds - other.positionSeconds) > Self.positionDriftTolerance
    }
}

/// Where Now Playing information goes.
///
/// A protocol because the real destination is process-global system state.
/// Tests need to prove the model publishes the right thing at the right moment
/// without the run leaving the machine's media widget pointing at a fixture.
@MainActor
protocol WiltedNowPlayingSink: AnyObject {
    func publish(_ info: WiltedNowPlayingInfo)
    func clear()
}

/// A transport press that arrived from outside the app: a media key, a headset
/// button, the Control Center widget, or an AirPods pinch.
enum WiltedRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case skipForward
    case skipBackward
    case nextTrack
    case previousTrack
    /// An absolute scrub from the widget's own progress bar.
    case seek(TimeInterval)
    case changeRate(Double)
}

/// Where remote transport presses come from.
@MainActor
protocol WiltedRemoteCommandSource: AnyObject {
    func install(handler: @escaping @MainActor (WiltedRemoteCommand) -> Void)
    /// Greys out the queue controls the current item cannot honour. An enabled
    /// command tells the system the app handles it, so leaving next enabled at
    /// the end of Up Next draws a button that does nothing.
    func updateQueueAvailability(hasNext: Bool, hasPrevious: Bool)
}

#if canImport(MediaPlayer)

/// Publishes to `MPNowPlayingInfoCenter`.
@MainActor
final class MediaPlayerNowPlayingSink: WiltedNowPlayingSink {
    private let center: MPNowPlayingInfoCenter
    /// One decoded image per artwork URL. Show artwork is a feed URL, so
    /// building an `MPMediaItemArtwork` means a download; the episode does not
    /// change between publications, so doing that on each would be pure waste.
    private var artworkCache: (url: URL, artwork: MPMediaItemArtwork)?
    private var artworkLoad: Task<Void, Never>?
    private let loadImageData: @Sendable (URL) async -> Data?

    init(center: MPNowPlayingInfoCenter = .default(),
         loadImageData: @escaping @Sendable (URL) async -> Data? = { url in
             if url.isFileURL { return try? Data(contentsOf: url) }
             return try? await URLSession.shared.data(from: url).0
         }) {
        self.center = center
        self.loadImageData = loadImageData
    }

    func publish(_ info: WiltedNowPlayingInfo) {
        var payload: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.showTitle,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPMediaItemPropertyPlaybackDuration: info.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            // Without this the widget's scrubber is inert: the system needs to
            // know the rate a resume would use, not just the current one.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: info.chosenRate,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if let cached = artworkCache, cached.url == info.artworkURL {
            payload[MPMediaItemPropertyArtwork] = cached.artwork
        }
        center.nowPlayingInfo = payload
        // macOS only, and required rather than advisory. The SDK header is
        // explicit: "This property must be set every time the app begins or
        // halts playback, otherwise remote control functionality may not work
        // as expected." Without it the app never appears in the menu bar.
        center.playbackState = info.isPlaying ? .playing : .paused
        loadArtworkIfNeeded(for: info)
    }

    func clear() {
        artworkLoad?.cancel()
        artworkLoad = nil
        artworkCache = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// Builds the artwork outside any actor.
    ///
    /// `MPMediaItemArtwork` calls its request handler on whatever queue the
    /// system is drawing from, so a handler formed inside a main-actor method
    /// inherits that isolation and traps the first time the system asks for an
    /// image. Building it here makes the handler unisolated, which is what the
    /// framework requires of it.
    nonisolated static func artwork(from data: Data) -> MPMediaItemArtwork? {
        guard let image = NSImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Fetches show artwork once per URL and republishes with it.
    ///
    /// Deliberately after the text has already been published rather than
    /// before: the title and scrubber are what the listener is waiting to see,
    /// and holding them behind an image download would put the widget's
    /// appearance on the network's schedule.
    private func loadArtworkIfNeeded(for info: WiltedNowPlayingInfo) {
        guard let url = info.artworkURL, artworkCache?.url != url else { return }
        artworkLoad?.cancel()
        let load = loadImageData
        artworkLoad = Task { [weak self] in
            guard let data = await load(url), !Task.isCancelled,
                  let artwork = Self.artwork(from: data) else { return }
            guard let self else { return }
            self.artworkCache = (url, artwork)
            // Only the artwork key is added. Rebuilding the whole payload here
            // would publish an elapsed time that is now stale by however long
            // the download took.
            guard var payload = self.center.nowPlayingInfo else { return }
            payload[MPMediaItemPropertyArtwork] = artwork
            self.center.nowPlayingInfo = payload
        }
    }
}

/// Bridges `MPRemoteCommandCenter` into one handler.
///
/// Every command Wilted answers is enabled and every command it does not is
/// explicitly disabled, because an enabled command with no target still tells
/// the system the app handles it, and the widget then draws a control that does
/// nothing.
@MainActor
final class MediaPlayerRemoteCommandSource: WiltedRemoteCommandSource {
    private let center: MPRemoteCommandCenter
    private var installed = false

    init(center: MPRemoteCommandCenter = .shared()) { self.center = center }

    func install(handler: @escaping @MainActor (WiltedRemoteCommand) -> Void) {
        guard !installed else { return }
        installed = true

        func target(_ command: MPRemoteCommand, _ make: @escaping (MPRemoteCommandEvent) -> WiltedRemoteCommand?) {
            command.isEnabled = true
            command.addTarget { event in
                guard let resolved = make(event) else { return .commandFailed }
                // The system calls these off the main actor. The model is main
                // actor isolated, so the hop is not optional.
                Task { @MainActor in handler(resolved) }
                return .success
            }
        }

        target(center.playCommand) { _ in .play }
        target(center.pauseCommand) { _ in .pause }
        target(center.togglePlayPauseCommand) { _ in .toggle }
        target(center.nextTrackCommand) { _ in .nextTrack }
        target(center.previousTrackCommand) { _ in .previousTrack }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: WiltedMacModel.forwardSkipSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: WiltedMacModel.backwardSkipSeconds)]
        target(center.skipForwardCommand) { _ in .skipForward }
        target(center.skipBackwardCommand) { _ in .skipBackward }

        target(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
            return .seek(event.positionTime)
        }
        target(center.changePlaybackRateCommand) { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return nil }
            return .changeRate(Double(event.playbackRate))
        }
        center.changePlaybackRateCommand.supportedPlaybackRates =
            WiltedMacModel.playbackRateChoices.map { NSNumber(value: $0) }

        // Not a podcast's controls, and leaving them enabled draws dead buttons.
        for unsupported in [center.stopCommand, center.seekForwardCommand, center.seekBackwardCommand,
                            center.ratingCommand, center.likeCommand, center.dislikeCommand,
                            center.bookmarkCommand, center.changeRepeatModeCommand,
                            center.changeShuffleModeCommand] {
            unsupported.isEnabled = false
        }
    }

    func updateQueueAvailability(hasNext: Bool, hasPrevious: Bool) {
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = hasPrevious
    }
}

#endif
