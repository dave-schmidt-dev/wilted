import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Everything a player publishes about what is playing, for players that show more than a title.
public struct ListenerNowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var duration: Double
    public var position: Double
    /// The speed playing right now: 0 while paused.
    public var rate: Double
    /// The speed a resume would use. The system shows this, not `rate`, on a paused rate control
    /// (CarPlay's reads "0x" without it) and needs it for a working scrubber.
    public var defaultRate: Double
    /// Encoded image bytes from a local cache. Never fetched here.
    public var artworkData: Data?

    public init(
        title: String, artist: String? = nil, duration: Double, position: Double, rate: Double,
        defaultRate: Double, artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
        self.rate = rate
        self.defaultRate = defaultRate
        self.artworkData = artworkData
    }
}

public protocol ListenerNowPlaying: Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double)
    /// The full publication. Conformers that only know the title form inherit a default that drops
    /// the extras.
    func update(_ info: ListenerNowPlayingInfo)
    func clear()
}

public extension ListenerNowPlaying {
    func update(_ info: ListenerNowPlayingInfo) {
        update(title: info.title, duration: info.duration, position: info.position, rate: info.rate)
    }
}

public struct MediaPlayerNowPlaying: ListenerNowPlaying {
    public init() {}
    public func update(title: String, duration: Double, position: Double, rate: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
    }

    public func update(_ info: ListenerNowPlayingInfo) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.payload(for: info)
    }

    /// The dictionary the system gets. Split out so a test can read it without the shared center.
    public static func payload(for info: ListenerNowPlayingInfo) -> [String: Any] {
        var payload: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.position,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: info.defaultRate,
        ]
        if let artist = info.artist, !artist.isEmpty { payload[MPMediaItemPropertyArtist] = artist }
        if let data = info.artworkData, let artwork = artwork(from: data) { payload[MPMediaItemPropertyArtwork] = artwork }
        return payload
    }

    /// Built outside any actor: the system calls the image handler on its own queue, and a handler
    /// formed inside a main-actor method would trap there.
    private static func artwork(from data: Data) -> MPMediaItemArtwork? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    public func clear() { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
}
