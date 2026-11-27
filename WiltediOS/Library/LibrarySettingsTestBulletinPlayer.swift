import Combine
import Foundation
import WiltedLibrary

/// Requests the deterministic test bulletin and plays it only after its Mac-rendered clip is verified.
@MainActor
final class LibrarySettingsTestBulletinPlayer: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case playing
        case completed
        case waiting
        case failed
    }

    typealias SleepOperation = @Sendable (TimeInterval) async throws -> Void

    @Published private(set) var state: State = .idle

    private let audio: LibraryBulletinAudioManager
    private let speaker: any LibrarySpeaking
    private let now: @Sendable () -> Date
    private let sleep: SleepOperation
    private var preparation: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0

    init(
        audio: LibraryBulletinAudioManager,
        speaker: any LibrarySpeaking,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping SleepOperation = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.audio = audio
        self.speaker = speaker
        self.now = now
        self.sleep = sleep
    }

    var isWorking: Bool { state == .preparing || state == .playing }

    var message: String? {
        return switch state {
        case .idle: nil
        case .preparing: "Preparing the approved voice on your Mac. This can take a few minutes."
        case .playing: "Playing the headline voice."
        case .completed: "Test bulletin finished."
        case .waiting: "No voice clip is ready yet. Check Wilted on your Mac, then try again."
        case .failed: "The approved voice clip could not be played. No system voice was used."
        }
    }

    @discardableResult
    func play() -> Task<Void, Never>? {
        guard !isWorking, let bulletin = LibraryBulletinAudioTestSample.make(at: now()) else { return nil }
        if audio.canSpeak(bulletin) {
            startPlayback(bulletin)
            return nil
        }
        guard audio.canRequestAudio else {
            state = .waiting
            return nil
        }
        audio.prepare(bulletin)
        state = .preparing
        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepareAndPlay(bulletin)
        }
        preparation = task
        return task
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
        playbackGeneration &+= 1
        speaker.stop()
        state = .idle
    }

    private func prepareAndPlay(_ bulletin: Bulletin) async {
        let waits: [TimeInterval] = [10, 30, 120, 300]
        for attempt in 0...waits.count {
            guard !Task.isCancelled else { return }
            await audio.refreshPreparedAudio()
            guard !Task.isCancelled else { return }
            if audio.canSpeak(bulletin) {
                preparation = nil
                startPlayback(bulletin)
                return
            }
            if let failure = audio.failure(for: bulletin) {
                preparation = nil
                if case .missingVoice = failure { state = .waiting }
                else { state = .failed }
                return
            }
            guard attempt < waits.count, bulletin.expiresAt > now() else {
                preparation = nil
                state = .waiting
                return
            }
            do { try await sleep(waits[attempt]) }
            catch {
                preparation = nil
                return
            }
        }
        preparation = nil
        state = .waiting
    }

    private func startPlayback(_ bulletin: Bulletin) {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        let started = speaker.speak(bulletin) { [weak self] in
            guard let self, self.playbackGeneration == generation else { return }
            self.state = .completed
        }
        state = started ? .playing : .failed
    }
}
