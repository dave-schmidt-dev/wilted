import WiltedLibrary
import WiltedProducer

/// Remembers the last weather bulletin that actually began speaking.
@MainActor
final class WiltedMacRememberingWeatherAlertSpeaker: BulletinSpeaking {
    private let base: any BulletinSpeaking
    private let didStartWeatherAlert: @MainActor (Bulletin) -> Void

    init(base: any BulletinSpeaking,
         didStartWeatherAlert: @escaping @MainActor (Bulletin) -> Void) {
        self.base = base
        self.didStartWeatherAlert = didStartWeatherAlert
    }

    func speak(_ text: String, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        base.speak(text, playbackVolume: playbackVolume, finished: finished)
    }

    func speak(_ bulletin: Bulletin, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        let started = base.speak(bulletin, playbackVolume: playbackVolume, finished: finished)
        if started, bulletin.kind == .alert {
            didStartWeatherAlert(bulletin)
        }
        return started
    }

    func stop() { base.stop() }
}
