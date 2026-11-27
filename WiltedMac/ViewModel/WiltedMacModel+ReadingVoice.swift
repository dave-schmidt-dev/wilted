import AppKit
import Foundation
import Observation
import WiltedLibrary
import WiltedProducer

private nonisolated(unsafe) var readingVoiceSelectionKey: UInt8 = 0

@MainActor
@Observable
final class WiltedMacReadingVoiceSelection {
    static let preferenceKey = "wilted.headlines.readingVoiceID"
    static let headlinePreferenceKey = "wilted.reports.headlineVoiceID"
    static let weatherPreferenceKey = "wilted.reports.weatherVoiceID"
    static let morningReportPreferenceKey = "wilted.reports.morningReportVoiceID"

    @ObservationIgnored private let preferences: UserDefaults
    private(set) var selectedReadingVoiceID: String?
    private(set) var headlineVoiceID: ApprovedReadingVoiceID
    private(set) var weatherVoiceID: ApprovedReadingVoiceID
    private(set) var morningReportVoiceID: ApprovedReadingVoiceID

    init(preferences: UserDefaults) {
        self.preferences = preferences
        let legacyVoiceID = preferences.string(forKey: Self.preferenceKey)
        selectedReadingVoiceID = legacyVoiceID

        let inheritedHeadlineVoice = preferences.string(forKey: Self.headlinePreferenceKey)
            .flatMap(ApprovedReadingVoiceID.init(rawValue:))
        let legacyHeadlineVoice = legacyVoiceID.flatMap(ApprovedReadingVoiceID.init(rawValue:))
        let headlineVoice = inheritedHeadlineVoice ?? legacyHeadlineVoice ?? .paulHarvey
        headlineVoiceID = headlineVoice
        preferences.set(headlineVoice.rawValue, forKey: Self.headlinePreferenceKey)

        weatherVoiceID = Self.storedVoice(
            forKey: Self.weatherPreferenceKey, default: .rodSerling, in: preferences)
        morningReportVoiceID = Self.storedVoice(
            forKey: Self.morningReportPreferenceKey, default: .caseyKasem, in: preferences)
    }

    private static func storedVoice(
        forKey key: String, default defaultVoice: ApprovedReadingVoiceID, in preferences: UserDefaults
    ) -> ApprovedReadingVoiceID {
        let voice = preferences.string(forKey: key).flatMap(ApprovedReadingVoiceID.init(rawValue:)) ?? defaultVoice
        preferences.set(voice.rawValue, forKey: key)
        return voice
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

    func selectHeadlineVoice(_ voice: ApprovedReadingVoiceID) {
        headlineVoiceID = voice
        preferences.set(voice.rawValue, forKey: Self.headlinePreferenceKey)
    }

    func selectWeatherVoice(_ voice: ApprovedReadingVoiceID) {
        weatherVoiceID = voice
        preferences.set(voice.rawValue, forKey: Self.weatherPreferenceKey)
    }

    func selectMorningReportVoice(_ voice: ApprovedReadingVoiceID) {
        morningReportVoiceID = voice
        preferences.set(voice.rawValue, forKey: Self.morningReportPreferenceKey)
    }

    func availability(for voice: ApprovedReadingVoiceID) -> ArticleVoiceAvailability {
        ArticleNarrationCoordinator().availability(for: voice)
    }

    var selectedStatus: String {
        guard let voice = selectedVoice else { return "Choose a voice for stories you queue." }
        switch availability(for: voice) {
        case .available: return "\(voice.displayName) is ready for story narration."
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

    var headlineVoiceID: ApprovedReadingVoiceID { readingVoiceSelection.headlineVoiceID }

    var weatherVoiceID: ApprovedReadingVoiceID { readingVoiceSelection.weatherVoiceID }

    var morningReportVoiceID: ApprovedReadingVoiceID { readingVoiceSelection.morningReportVoiceID }

    /// Local voice/model/runtime revision attached to queued requests.
    var readingVoiceRevision: String? { readingVoiceSelection.readingVoiceRevision }

    func selectReadingVoice(_ rawValue: String?) {
        readingVoiceSelection.select(rawValue)
        bulletinHub.readingVoiceSelectionChanged()
    }

    func selectHeadlineVoice(_ voice: ApprovedReadingVoiceID) {
        readingVoiceSelection.selectHeadlineVoice(voice)
        bulletinHub.readingVoiceSelectionChanged()
    }

    func selectWeatherVoice(_ voice: ApprovedReadingVoiceID) {
        readingVoiceSelection.selectWeatherVoice(voice)
        bulletinHub.readingVoiceSelectionChanged()
    }

    func selectMorningReportVoice(_ voice: ApprovedReadingVoiceID) {
        readingVoiceSelection.selectMorningReportVoice(voice)
        bulletinHub.readingVoiceSelectionChanged()
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

    /// The UI action fixes its queue anchor at the moment the listener presses Listen next.
    func requestListenNext(_ story: LibraryHeadlineStory) {
        let anchor = playback?.itemID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await listenNextRequest(story: story, anchorID: anchor) }
            catch { /* The request presentation object carries the visible failure state. */ }
        }
    }

    func openReadingVoiceSettings() {
        selectedNavigation = .settings
        settingsSection = .reports
    }
}
