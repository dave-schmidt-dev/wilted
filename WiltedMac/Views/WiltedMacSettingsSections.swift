import SwiftUI

enum WiltedMacSettingsTab: String, CaseIterable, Identifiable {
    case listening = "listening"
    case feedsAndReports = "feeds-reports"
    case adsAndProviders = "ads-providers"
    case libraryAndSync = "library-sync"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listening: "Listening"
        case .feedsAndReports: "Feeds & Reports"
        case .adsAndProviders: "Ads & Providers"
        case .libraryAndSync: "Library & Sync"
        }
    }

    var sections: [WiltedMacSettingsSection] {
        switch self {
        case .listening: [.general, .preparing]
        case .feedsAndReports: [.newEpisodes, .reports]
        case .adsAndProviders: [.ads, .providers]
        case .libraryAndSync: [.devices, .about]
        }
    }

    init(section: WiltedMacSettingsSection) {
        self = Self.allCases.first { $0.sections.contains(section) } ?? .listening
    }

    init(savedAnchor: String?) {
        if let savedAnchor, let tab = Self(rawValue: savedAnchor) {
            self = tab
        } else {
            self.init(section: WiltedMacSettingsSection(savedAnchor: savedAnchor))
        }
    }
}

enum WiltedMacSettingsSection: String, CaseIterable, Identifiable {
    case general, newEpisodes = "new-episodes", preparing, ads, providers, reports, devices, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newEpisodes: "New episodes"
        default: rawValue.capitalized
        }
    }

    init(savedAnchor: String?) {
        switch savedAnchor {
        case "settings-appearance": self = .general
        case "settings-statistics": self = .about
        case "settings-automation": self = .newEpisodes
        case "settings-ad-finding", "settings-ad-feedback": self = .ads
        case "settings-reports": self = .reports
        case "settings-sync": self = .devices
        default:
            let anchor = savedAnchor ?? ""
            let raw = anchor.hasPrefix("settings-") ? String(anchor.dropFirst("settings-".count)) : anchor
            self = Self(rawValue: raw) ?? .general
        }
    }
}

#if os(macOS)
extension WiltedMacModel {
    var settingsSection: WiltedMacSettingsSection {
        get {
            let anchor = scrollAnchor(for: .settings).wrappedValue
            if let tab = WiltedMacSettingsTab(rawValue: anchor ?? "") { return tab.sections[0] }
            return WiltedMacSettingsSection(savedAnchor: anchor)
        }
        set {
            let anchor = scrollAnchor(for: .settings)
            if anchor.wrappedValue != newValue.rawValue {
                anchor.wrappedValue = newValue.rawValue
            }
        }
    }

    var settingsTab: WiltedMacSettingsTab {
        get { WiltedMacSettingsTab(savedAnchor: scrollAnchor(for: .settings).wrappedValue) }
        set { scrollAnchor(for: .settings).wrappedValue = newValue.sections[0].rawValue }
    }

    func persistSettingsScrollPosition(_ position: String?) {
        guard let position else { return }
        let anchor = scrollAnchor(for: .settings)
        if position == "destination-top" {
            if anchor.wrappedValue != nil { anchor.wrappedValue = nil }
        } else if WiltedMacSettingsSection(rawValue: position) != nil,
                  anchor.wrappedValue != position {
            anchor.wrappedValue = position
        }
    }

    var settingsScrollPosition: Binding<String?> {
        let savedAnchor = scrollAnchor(for: .settings)
        return Binding(
            get: {
                guard let anchor = savedAnchor.wrappedValue else { return "destination-top" }
                if let tab = WiltedMacSettingsTab(rawValue: anchor) {
                    return tab.sections[0].rawValue
                }
                return WiltedMacSettingsSection(savedAnchor: anchor).rawValue
            },
            set: { self.persistSettingsScrollPosition($0) }
        )
    }
}

extension WiltedMacSettingsView {
    @ViewBuilder func settingsSectionContent(for section: WiltedMacSettingsSection) -> some View {
        switch section {
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
        case .providers:
            WiltedMacProvidersSettingsView(model: model)
        case .reports:
            WiltedMacReportsCard(model: model, location: location, policyBoard: feedPolicyBoard)
        case .devices:
            syncCard
        case .about:
            WiltedMacLifetimeStatisticsCard(model: model)
        }
    }
}
#endif
