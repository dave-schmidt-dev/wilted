import Foundation

enum LibrarySettingsSection: String, CaseIterable {
    case general, playback, storage, reports, devices, about

    var title: String { rawValue.capitalized }

    func footnote(deviceKind: String) -> String {
        switch self {
        case .general: "Text and icon size applies to this \(deviceKind)."
        case .playback: "Auto-play, spoken interruptions, default speed and skip times apply to this \(deviceKind)."
        case .storage: "Removing audio frees space on this \(deviceKind)."
        case .reports: "Bulletins are read on this \(deviceKind) while Spoken interruptions is on under Playback."
        case .devices: "Sync status and direct downloads are for this \(deviceKind)."
        case .about: "Statistics, version and diagnostics are for this \(deviceKind)."
        }
    }
}
