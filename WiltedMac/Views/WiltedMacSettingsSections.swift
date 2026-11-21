import SwiftUI

enum WiltedMacSettingsSection: String, CaseIterable {
    case general, newEpisodes = "new-episodes", preparing, ads, reports, devices, about

    var title: String {
        self == .newEpisodes ? "New episodes" : rawValue.capitalized
    }

    init(savedAnchor: String?) {
        switch savedAnchor {
        case "settings-appearance": self = .general
        case "settings-statistics": self = .about
        case "settings-automation": self = .newEpisodes
        case "settings-ad-finding", "settings-ad-feedback": self = .ads
        case "settings-reports": self = .reports
        case "settings-sync": self = .devices
        default: self = Self(rawValue: savedAnchor ?? "") ?? .general
        }
    }
}

#if os(macOS)
extension WiltedMacModel {
    var settingsSection: WiltedMacSettingsSection {
        get { WiltedMacSettingsSection(savedAnchor: scrollAnchor(for: .settings).wrappedValue) }
        set { scrollAnchor(for: .settings).wrappedValue = newValue.rawValue }
    }
}

extension WiltedMacSettingsView {
    @ViewBuilder var sectionContent: some View {
        switch model.settingsSection {
        case .general:
            appearanceCard
        case .newEpisodes:
            automationCard
        case .preparing:
            preparingCard
        case .ads:
            adRemovalCard
            WiltedMacAdFindingSettingsView(model: model, board: feedPolicyBoard)
            WiltedMacAdFeedbackCard(feedback: model.adFeedback)
        case .reports:
            WiltedMacReportsCard(model: model, location: location)
        case .devices:
            syncCard
        case .about:
            WiltedMacLifetimeStatisticsCard(model: model)
        }
    }
}
#endif
