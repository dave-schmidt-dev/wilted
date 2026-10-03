import Foundation
import SwiftUI

/// The factual episode details every list surface shares. Lifecycle state and
/// actions remain with the screen that owns them; this value never infers a
/// publication date from intake, dismissal, or download activity.
struct WiltedMacEpisodePresentation: Equatable, Sendable {
    let title: String
    let showTitle: String?
    let publishedAt: Date?
    let sourceDurationSeconds: TimeInterval?
    let playableDurationSeconds: TimeInterval?

    var showAndPublicationLabel: String {
        let show = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showLabel = (show?.isEmpty == false ? show! : "Show unknown")
        let publicationLabel = publishedAt?.formatted(date: .numeric, time: .omitted)
            ?? "Publication date unknown"
        return "\(showLabel) · \(publicationLabel)"
    }

    var sourceDurationLabel: String {
        "Source duration · \(Self.durationLabel(sourceDurationSeconds))"
    }

    var playableDurationLabel: String? {
        playableDurationSeconds.map { "Playable duration · \(Self.durationLabel($0))" }
    }

    var larderRowLabel: String {
        let show = showTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showLabel = (show?.isEmpty == false ? show! : "Show unknown")
        let duration = Self.durationLabel(sourceDurationSeconds)
        let publicationLabel = publishedAt?.formatted(date: .numeric, time: .omitted)
            ?? "Publication date unknown"
        return "\(showLabel) - \(duration) - \(publicationLabel)"
    }

    var larderPresentationLabel: String {
        larderRowLabel
    }

    /// A stable factual value for native journeys. Lifecycle is intentionally
    /// excluded because it is allowed to change as an episode moves between
    /// Feeds, Off the list, and the Larder. Playable duration is also excluded
    /// because it describes local readiness rather than the source record.
    var accessibilityFactsLabel: String {
        [showAndPublicationLabel, sourceDurationLabel].joined(separator: " · ")
    }

    static func durationLabel(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0, duration < Double(Int.max) else {
            return "Unknown"
        }
        let seconds = Int(duration.rounded())
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "\(minutes)m \(String(format: "%02d", remainingSeconds))s" }
        return "\(remainingSeconds)s"
    }
}

/// Keeps Feeds, Larder, and Off the list on the same two-or-three-line
/// geometry while allowing each surface to supply its own state line.
struct WiltedMacEpisodeMetadata: View {
    let presentation: WiltedMacEpisodePresentation
    let lifecycleLabel: String?
    let identifier: String
    let isLarder: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        episode: WiltedMacEpisode,
        lifecycleLabel: String? = nil,
        identifier: String,
        isLarder: Bool = false
    ) {
        presentation = episode.presentation
        self.lifecycleLabel = lifecycleLabel
        self.identifier = identifier
        self.isLarder = isLarder
    }

    init(
        presentation: WiltedMacEpisodePresentation,
        lifecycleLabel: String? = nil,
        identifier: String,
        isLarder: Bool = false
    ) {
        self.presentation = presentation
        self.lifecycleLabel = lifecycleLabel
        self.identifier = identifier
        self.isLarder = isLarder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isLarder {
                Text(presentation.larderRowLabel)
            } else {
                Text(presentation.showAndPublicationLabel)
                Text(presentation.sourceDurationLabel)
                if let playable = presentation.playableDurationLabel { Text(playable) }
            }
            if let lifecycleLabel { Text(lifecycleLabel) }
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .lineLimit(1)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(presentation.accessibilityFactsLabel)
    }
}
