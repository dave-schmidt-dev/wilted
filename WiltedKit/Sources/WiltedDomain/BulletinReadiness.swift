/// The setup steps still needed for the bulletin types the listener has turned on.
public struct BulletinReadiness: Equatable, Sendable {
    public enum NewsCheck: Equatable, Sendable { case checked, checking, unavailable }

    public enum Line: Hashable, Sendable {
        case news, checkingNews, unknownNews, weather, locationDenied, sound, chooseSources, ready

        public var text: String {
            switch self {
            case .news: "No news source yet. Add a news feed and mark it as News."
            case .checkingNews: "Checking for a news source…"
            case .unknownNews: "Wilted couldn’t check your news feeds."
            case .weather: "Weather alerts need a location."
            case .locationDenied: "Location access is off. Allow access or enter a location for weather alerts."
            case .sound: "Bulletins are paused because Wilted couldn’t check the sound output."
            case .chooseSources: "Turn on Headlines or Weather alerts to hear bulletins."
            case .ready:
                "Ready: Wilted can read bulletins while an episode plays. It waits for a break or until the wait time runs out. The most serious weather alerts play right away."
            }
        }
    }

    public let lines: [Line]

    public init(hasNewsSource: Bool, hasWeatherLocation: Bool, soundCheckPaused: Bool,
                headlinesEnabled: Bool = true, alertsEnabled: Bool = true, newsCheck: NewsCheck = .checked,
                locationAccessDenied: Bool = false) {
        var needed: [Line] = []
        if headlinesEnabled {
            switch newsCheck {
            case .checked:
                if !hasNewsSource { needed.append(.news) }
            case .checking: needed.append(.checkingNews)
            case .unavailable: needed.append(.unknownNews)
            }
        }
        if alertsEnabled && !hasWeatherLocation { needed.append(locationAccessDenied ? .locationDenied : .weather) }
        if soundCheckPaused { needed.append(.sound) }
        if !headlinesEnabled && !alertsEnabled { needed.append(.chooseSources) }
        lines = needed.isEmpty ? [.ready] : needed
    }
}
