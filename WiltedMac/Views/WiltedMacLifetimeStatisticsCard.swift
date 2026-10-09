import SwiftUI
import WiltedDomain

/// Seven lifetime totals for this Mac, from one durable summary, with honest
/// loading, rebuilding and unavailable states.
struct WiltedMacLifetimeStatisticsCard: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.lifetimeStatistics) {
            Text(WiltedScreenCopy.lifetimeStatisticsScope)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier(WiltedScreenCopy.lifetimeStatisticsScopeIdentifier)
            Divider()
            lifetimeStatisticsBody
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-lifetime-statistics")
        .overlay(alignment: .topTrailing) {
            WiltedMacHelpButton(content: statisticsHelp, identifier: "wilted-statistics-help")
                .padding(WiltedTheme.Spacing.medium)
        }
        .task { await model.refreshLifetimeStatistics() }
    }

    var statisticsHelp: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Lifetime statistics", text:
            WiltedMacStatisticsCopy.empty + " Earlier listening was not measured.")
    }

    /// Every state but `ready` shows no totals: a zero would claim nothing was
    /// measured when the summary is only loading, rebuilding or unreadable.
    @ViewBuilder
    private var lifetimeStatisticsBody: some View {
        switch model.statisticsState {
        case .loading:
            statisticsStatus(WiltedMacStatisticsCopy.loading, progress: nil, showsSpinner: true)
        case .rebuilding(let progress):
            statisticsStatus(WiltedMacStatisticsCopy.rebuilding, progress: progress?.fraction, showsSpinner: true)
        case .unavailable:
            statisticsStatus(WiltedMacStatisticsCopy.unavailable, progress: nil, showsSpinner: false)
            Button(WiltedMacStatisticsCopy.retry) { model.retryLifetimeStatistics() }
                .accessibilityIdentifier(WiltedMacStatisticsCopy.retryIdentifier)
        case .ready(let summary):
            lifetimeTotals(summary)
        }
    }

    @ViewBuilder
    private func lifetimeTotals(_ summary: LifetimeStatisticsSummary) -> some View {
        let legacy = summary.legacy
        let measured = summary.measured
        WiltedSettingsRow(
            WiltedScreenCopy.audioProcessed,
            value: WiltedMacEpisodePresentation.durationLabel(legacy.audioProcessedSeconds),
            identifier: WiltedScreenCopy.audioProcessedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedScreenCopy.speechGenerated,
            value: WiltedMacEpisodePresentation.durationLabel(legacy.speechGeneratedSeconds),
            identifier: WiltedScreenCopy.speechGeneratedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedScreenCopy.confirmedAdTimeRemoved,
            value: WiltedMacEpisodePresentation.durationLabel(legacy.confirmedAdTimeRemovedSeconds),
            identifier: WiltedScreenCopy.confirmedAdTimeRemovedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedScreenCopy.fasterPlaybackTimeSaved,
            value: WiltedMacEpisodePresentation.durationLabel(legacy.fasterPlaybackTimeSavedSeconds),
            identifier: WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedMacStatisticsCopy.playedTime,
            value: WiltedMacEpisodePresentation.durationLabel(Double(max(0, measured.playedMilliseconds) / 1_000)),
            identifier: WiltedMacStatisticsCopy.playedTimeIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedMacStatisticsCopy.downloaded,
            value: WiltedMacStatisticsCopy.gigabytes(bytes: measured.receivedBytes),
            identifier: WiltedMacStatisticsCopy.downloadedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedMacStatisticsCopy.manuallySkipped,
            value: WiltedMacEpisodePresentation.durationLabel(Double(max(0, measured.manuallySkippedMilliseconds) / 1_000)),
            identifier: WiltedMacStatisticsCopy.manuallySkippedIdentifier
        )
        Divider()
        if WiltedMacStatisticsCopy.isEmpty(summary) {
            statisticsNote("Nothing measured yet.", identifier: WiltedMacStatisticsCopy.statusIdentifier)
        }
        statisticsNote(
            WiltedMacStatisticsCopy.trackingStart(summary.trackingStartedAt)
                .replacingOccurrences(of: " Earlier listening was not measured.", with: ""),
            identifier: WiltedMacStatisticsCopy.trackingStartIdentifier
        )
    }

    private func statisticsStatus(_ text: String, progress: Double?, showsSpinner: Bool) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                if showsSpinner && progress == nil { ProgressView().controlSize(.small) }
                Text(text)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress { ProgressView(value: progress) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(WiltedMacStatisticsCopy.statusIdentifier)
    }

    private func statisticsNote(_ text: String, identifier: String) -> some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}
