import AppKit
import Foundation
import Observation
import WiltedProducer

private nonisolated(unsafe) var readingVoiceSelectionKey: UInt8 = 0

@MainActor
@Observable
final class WiltedMacReadingVoiceSelection {
    static let preferenceKey = "wilted.headlines.readingVoiceID"

    @ObservationIgnored private let preferences: UserDefaults
    private(set) var selectedReadingVoiceID: String?

    init(preferences: UserDefaults) {
        self.preferences = preferences
        selectedReadingVoiceID = preferences.string(forKey: Self.preferenceKey)
    }

    var selectedVoice: ApprovedReadingVoiceID? {
        selectedReadingVoiceID.flatMap(ApprovedReadingVoiceID.init(rawValue:))
    }

    var readingVoiceRevision: String? {
        selectedVoice.map(ArticleNarrationCoordinator.voiceRevision(for:))
    }

    func select(_ rawValue: String?) {
        guard let rawValue, let voice = ApprovedReadingVoiceID(rawValue: rawValue) else {
            selectedReadingVoiceID = nil
            preferences.removeObject(forKey: Self.preferenceKey)
            return
        }
        selectedReadingVoiceID = voice.rawValue
        preferences.set(voice.rawValue, forKey: Self.preferenceKey)
    }

    func availability(for voice: ApprovedReadingVoiceID) -> ArticleVoiceAvailability {
        ArticleNarrationCoordinator().availability(for: voice)
    }

    var selectedStatus: String {
        guard let voice = selectedVoice else { return "Choose a reading voice before you queue a story." }
        switch availability(for: voice) {
        case .available: return "\(voice.displayName) is ready for local narration."
        case .missingVoice: return "The selected voice files are missing. Choose an available voice."
        case .missingModel: return "The Chatterbox model is missing."
        case .missingRuntime: return "The local narration runtime is unavailable."
        }
    }

    var selectedVoiceIsAvailable: Bool {
        guard let selectedVoice else { return false }
        return isAvailable(availability(for: selectedVoice))
    }

    func availabilityText(for voice: ApprovedReadingVoiceID) -> String {
        switch availability(for: voice) {
        case .available: "Ready"
        case .missingVoice: "Voice files missing"
        case .missingModel: "Model missing"
        case .missingRuntime: "Runtime unavailable"
        }
    }

    func isAvailable(_ availability: ArticleVoiceAvailability) -> Bool {
        if case .available = availability { return true }
        return false
    }
}

extension WiltedMacModel {
    var readingVoiceSelection: WiltedMacReadingVoiceSelection {
        if let state = objc_getAssociatedObject(self, &readingVoiceSelectionKey) as? WiltedMacReadingVoiceSelection {
            return state
        }
        let state = WiltedMacReadingVoiceSelection(preferences: preferences)
        objc_setAssociatedObject(self, &readingVoiceSelectionKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// Raw stable voice ID shared with the local request and narration services.
    var selectedReadingVoiceID: String? { readingVoiceSelection.selectedReadingVoiceID }

    /// Local voice/model/runtime revision attached to queued requests.
    var readingVoiceRevision: String? { readingVoiceSelection.readingVoiceRevision }

    func selectReadingVoice(_ rawValue: String?) {
        readingVoiceSelection.select(rawValue)
    }

    func readingVoiceAvailability(for voice: ApprovedReadingVoiceID) -> ArticleVoiceAvailability {
        readingVoiceSelection.availability(for: voice)
    }

    func readingVoiceAvailabilityText(for voice: ApprovedReadingVoiceID) -> String {
        readingVoiceSelection.availabilityText(for: voice)
    }

    func readingVoiceIsAvailable(_ voice: ApprovedReadingVoiceID) -> Bool {
        readingVoiceSelection.isAvailable(readingVoiceAvailability(for: voice))
    }

    func openReadingVoiceSettings() {
        selectedNavigation = .settings
        settingsSection = .reports
    }
}
