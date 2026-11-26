import AVFoundation
import Foundation
import WiltedLibrary

/// Plays a bulletin through the approved, Mac-rendered narration path. Implementations never
/// substitute the phone's default system voice when a clip is unavailable.
@MainActor
protocol LibrarySpeaking: AnyObject {
    func prepare(_ bulletin: Bulletin)
    func refreshPreparedAudio() async
    func bulletinAudioIssue(for bulletin: Bulletin) -> String?
    func retryBulletinAudio(_ bulletin: Bulletin)
    func canSpeak(_ bulletin: Bulletin) -> Bool
    /// Duration of the verified cached clip after it has started, when available.
    var expectedPlaybackDuration: TimeInterval? { get }
    func speak(_ bulletin: Bulletin, onFinish: @escaping @MainActor () -> Void) -> Bool
    /// Kept for the generic settings preview; production returns false because it has no approved clip.
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

extension LibrarySpeaking {
    func prepare(_ bulletin: Bulletin) {}
    func refreshPreparedAudio() async {}
    func bulletinAudioIssue(for bulletin: Bulletin) -> String? { nil }
    func retryBulletinAudio(_ bulletin: Bulletin) {}
    func canSpeak(_ bulletin: Bulletin) -> Bool { true }
    var expectedPlaybackDuration: TimeInterval? { nil }
    func speak(_ bulletin: Bulletin, onFinish: @escaping @MainActor () -> Void) -> Bool {
        speak(bulletin.text, onFinish: onFinish)
    }
}

/// Plays only verified, owner-scoped audio previously rendered by the Mac.
@MainActor
final class LibraryBulletinAudioSpeaker: NSObject, LibrarySpeaking, AVAudioPlayerDelegate {
    private let audio: LibraryBulletinAudioManager
    private var player: AVAudioPlayer?
    private var completion: (@MainActor () -> Void)?
    private var playingID: ObjectIdentifier?
    private(set) var expectedPlaybackDuration: TimeInterval?

    init(model: LibraryAppModel) {
        audio = model.bulletinAudioManager
        super.init()
    }

    func prepare(_ bulletin: Bulletin) { audio.prepare(bulletin) }

    func refreshPreparedAudio() async { await audio.refreshPreparedAudio() }

    func bulletinAudioIssue(for bulletin: Bulletin) -> String? { audio.issue(for: bulletin) }

    func retryBulletinAudio(_ bulletin: Bulletin) { audio.retry(bulletin) }

    func canSpeak(_ bulletin: Bulletin) -> Bool { audio.canSpeak(bulletin) }

    func speak(_ bulletin: Bulletin, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard let url = audio.audioURL(for: bulletin) else { return false }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        self.player = player
        completion = onFinish
        player.volume = 1
        player.delegate = self
        guard player.prepareToPlay(), player.duration.isFinite, player.duration > 0 else {
            self.player = nil
            completion = nil
            return false
        }
        expectedPlaybackDuration = player.duration
        guard player.play() else {
            self.player = nil
            completion = nil
            expectedPlaybackDuration = nil
            return false
        }
        playingID = ObjectIdentifier(player)
        return true
    }

    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool {
        false
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        completion = nil
        playingID = nil
        expectedPlaybackDuration = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    private func finish(_ id: ObjectIdentifier) {
        guard playingID == id else { return }
        playingID = nil
        player?.delegate = nil
        player = nil
        let finished = completion
        completion = nil
        finished?()
    }
}
