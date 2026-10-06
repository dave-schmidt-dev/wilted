import Foundation
import MediaPlayer
import Testing
@testable import WiltedPlayback

private final class RecordingEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration = 0.0
    var currentTime = 0.0
    var isPlaying = false
    var loaded: [URL] = []
    func load(url: URL) throws { loaded.append(url) }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
}

private final class TitleOnlyNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    var updates: [(title: String, duration: Double, position: Double, rate: Double)] = []
    func update(title: String, duration: Double, position: Double, rate: Double) {
        updates.append((title, duration, position, rate))
    }
    func clear() {}
}

@Test("an engine without natural completion still loads through the generation entry point")
func engineCompatibilityBridgeLoadsThroughPlainLoad() throws {
    let engine = RecordingEngine()
    let url = URL(fileURLWithPath: "/tmp/episode.mp3")
    try engine.load(url: url, completionGeneration: 7)
    #expect(engine.loaded == [url])
    engine.installCompletionHandler { _ in }
}

@Test("a now-playing sink that only knows the title form receives the full publication's title fields")
func nowPlayingDefaultDropsExtras() {
    let sink = TitleOnlyNowPlaying()
    sink.update(ListenerNowPlayingInfo(
        title: "Episode", artist: "Show", duration: 600, position: 42, rate: 1.5, defaultRate: 1.25,
        artworkData: Data([1, 2, 3])))
    #expect(sink.updates.count == 1)
    #expect(sink.updates.first?.title == "Episode")
    #expect(sink.updates.first?.duration == 600)
    #expect(sink.updates.first?.position == 42)
    #expect(sink.updates.first?.rate == 1.5)
}

@Test("the system payload carries the rates, a podcast media type, and the artist only when present")
func nowPlayingPayloadFields() {
    let withArtist = MediaPlayerNowPlaying.payload(for: ListenerNowPlayingInfo(
        title: "Episode", artist: "Show", duration: 600, position: 42, rate: 0, defaultRate: 1.25))
    #expect(withArtist[MPMediaItemPropertyTitle] as? String == "Episode")
    #expect(withArtist[MPMediaItemPropertyArtist] as? String == "Show")
    #expect(withArtist[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    #expect(withArtist[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.25)
    let withoutArtist = MediaPlayerNowPlaying.payload(for: ListenerNowPlayingInfo(
        title: "Episode", artist: "", duration: 600, position: 0, rate: 1, defaultRate: 1))
    #expect(withoutArtist[MPMediaItemPropertyArtist] == nil)
    #expect(withoutArtist[MPMediaItemPropertyArtwork] == nil)
}

@Test("undecodable artwork bytes leave the payload without artwork")
func nowPlayingIgnoresUndecodableArtwork() {
    let payload = MediaPlayerNowPlaying.payload(for: ListenerNowPlayingInfo(
        title: "Episode", duration: 1, position: 0, rate: 1, defaultRate: 1, artworkData: Data([0, 1, 2])))
    #expect(payload[MPMediaItemPropertyArtwork] == nil)
}
