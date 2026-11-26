import SwiftUI
import WiltedLibrary

/// Keeps the spoken alert and its official wording together in the full player, including offline.
struct LibraryNowPlayingWeatherAlertCard: View {
    @ObservedObject var controller: LibraryInterruptionController
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsOriginal = false

    private var bulletin: Bulletin? { controller.nowPlayingWeatherAlert }

    var body: some View {
        if let bulletin {
            let isReading = controller.activeSpokenWeatherAlert?.id == bulletin.id
                && controller.activeSpokenWeatherAlert?.text == bulletin.text
            let hasBeenRead = controller.lastSpokenWeatherAlert?.id == bulletin.id
                && controller.lastSpokenWeatherAlert?.text == bulletin.text
            let stateLabel = isReading ? "Reading this weather alert"
                : hasBeenRead ? "Last weather alert read" : "Weather alert available"
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Label(
                    stateLabel,
                    systemImage: isReading ? "speaker.wave.2.fill" : "cloud.bolt.fill")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-player-weather-alert-state")

                Text(bulletin.text)
                    .wiltedFont(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-player-weather-alert-summary")

                if let originalText = bulletin.originalText {
                    Button {
                        showsOriginal.toggle()
                    } label: {
                        Label(
                            showsOriginal ? "Hide official alert text" : "Show official alert text",
                            systemImage: showsOriginal ? "chevron.up" : "chevron.down")
                            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wilted-player-weather-alert-original-toggle")

                    if showsOriginal {
                        Text(originalText)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-player-weather-alert-original-text")
                    }
                } else {
                    Text("Original alert text was not saved with this bulletin.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-weather-alert-original-unavailable")
                }
                if let issue = controller.bulletinAudioIssue(for: bulletin) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text(issue)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-player-weather-alert-audio-issue")
                        Button("Retry") { controller.retryBulletinAudio(bulletin) }
                            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                            .accessibilityIdentifier("wilted-player-weather-alert-audio-retry")
                    }
                }
                if let link = bulletin.link {
                    Link("Open official NWS alert", destination: link)
                        .wiltedFont(.body)
                        .accessibilityIdentifier("wilted-player-weather-alert-open-official")
                }
            }
            .wiltedCard(colorScheme, padding: WiltedTheme.Spacing.medium)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-weather-alert-card")
        }
    }
}
