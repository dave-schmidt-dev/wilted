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
        .task { await model.refreshLifetimeStatistics() }
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
            value: WiltedDuration.spoken(legacy.audioProcessedSeconds),
            identifier: WiltedScreenCopy.audioProcessedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedScreenCopy.speechGenerated,
            value: WiltedDuration.spoken(legacy.speechGeneratedSeconds),
            identifier: WiltedScreenCopy.speechGeneratedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedScreenCopy.confirmedAdTimeRemoved,
            value: WiltedDuration.spoken(legacy.confirmedAdTimeRemovedSeconds),
            identifier: WiltedScreenCopy.confirmedAdTimeRemovedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedScreenCopy.fasterPlaybackTimeSaved,
            value: WiltedDuration.spoken(legacy.fasterPlaybackTimeSavedSeconds),
            identifier: WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier
        )
        Divider()
        WiltedSettingsRow(
            WiltedMacStatisticsCopy.playedTime,
            value: WiltedMacStatisticsCopy.minutes(milliseconds: measured.playedMilliseconds),
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
            value: WiltedMacStatisticsCopy.minutes(milliseconds: measured.manuallySkippedMilliseconds),
            identifier: WiltedMacStatisticsCopy.manuallySkippedIdentifier
        )
        Divider()
        if WiltedMacStatisticsCopy.isEmpty(summary) {
            statisticsNote(WiltedMacStatisticsCopy.empty, identifier: WiltedMacStatisticsCopy.statusIdentifier)
        }
        statisticsNote(
            WiltedMacStatisticsCopy.trackingStart(summary.trackingStartedAt),
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
