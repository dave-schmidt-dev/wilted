import AVFoundation
import Foundation
import OSLog

/// Speaks one bulletin. Injected so tests never speak.
@MainActor
protocol LibrarySpeaking: AnyObject {
    /// Starts speaking and calls `onFinish` once on the main actor when the speech ends or fails.
    /// Returns false, never calling `onFinish`, when speech cannot start.
    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool
    /// Stops silently: `onFinish` is not called.
    func stop()
}

private let librarySpeechLog = Logger(subsystem: "com.zerodelta.wilted", category: "LibraryInterruptions")

/// Gives up if speech has not started within the deadline so playback can continue.
@MainActor
final class LibrarySpeechSynthesizer: NSObject, LibrarySpeaking, AVSpeechSynthesizerDelegate {
    static let startTimeout: Duration = .seconds(3)
    private let synthesizer = AVSpeechSynthesizer()
    private var current: (id: ObjectIdentifier, finish: @MainActor () -> Void)?
    private var startedUtterance: ObjectIdentifier?
    private var startWatch: Task<Void, Never>?
    private(set) var currentUtterance: AVSpeechUtterance?

    init(usesApplicationAudioSession: Bool = true) {
        super.init()
        synthesizer.usesApplicationAudioSession = usesApplicationAudioSession
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard !text.isEmpty else { return false }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let id = ObjectIdentifier(utterance)
        current = (id, onFinish)
        currentUtterance = utterance
        startedUtterance = nil
        synthesizer.speak(utterance)
        startWatch = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.current?.id == id, self.startedUtterance != id else { return }
            librarySpeechLog.error("Speech did not start; giving up on this bulletin")
            self.synthesizer.stopSpeaking(at: .immediate)
            self.complete(id)
        }
        return true
    }

    func stop() {
        guard current != nil else { return }
        current = nil
        currentUtterance = nil
        startedUtterance = nil
        startWatch?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func complete(_ id: ObjectIdentifier) {
        guard let current, current.id == id else { return }
        self.current = nil
        self.currentUtterance = nil
        self.startedUtterance = nil
        startWatch?.cancel()
        current.finish()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.current?.id == id else { return }
            self.startedUtterance = id
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(id) }
    }
}
