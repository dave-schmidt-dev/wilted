import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The phone reports the Mac's bulletin settings and this device's alert location.
struct LibrarySettingsBulletinsCard: View {
    @ObservedObject var model: LibraryAppModel

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(LibraryInterruptionPreferences.speakKey) private var speaksInterruptions = true

    var body: some View {
        WiltedSettingsCard(title: LibrarySettingsSection.reports.title) {
            if speaksInterruptions {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .wiltedFont(.utility)
                        .foregroundStyle(color(for: line))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-library-settings-bulletins-line-\(index)")
                }
                Button(action: playTestBulletin) {
                    Text("Play a test bulletin").wiltedFont(.body)
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget - 16)
                }
                .buttonStyle(.bordered)
                .disabled(model.handoffState.interruptions?.canSpeakTestBulletin != true)
                .accessibilityIdentifier("wilted-library-settings-test-bulletin")
            } else {
                Text("Spoken interruptions is off under Playback, so no bulletin is read.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-library-settings-bulletins-off")
            }
            Text(LibrarySettingsSection.reports.footnote(deviceKind: model.deviceKind))
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-settings-reports")
        .onDisappear(perform: stopTestBulletin)
        .onChange(of: speaksInterruptions) { _, enabled in
            if !enabled { stopTestBulletin() }
        }
    }

    private var lines: [String] {
        let controller = model.handoffState.interruptions
        return LibrarySettingsFormat.bulletinLines(
            channel: controller?.observedChannel,
            hasCheckedChannel: controller?.hasCheckedChannel == true,
            articleFeedCount: articleFeedCount,
            location: controller?.locationStatus ?? .none,
            channelCheckFailed: controller?.channelCheckFailed == true,
            isRefreshingLibrary: model.isRefreshing,
            deviceKind: model.deviceKind)
    }

    private var articleFeedCount: Int? {
        let count = model.decisionContent.sources.values.filter { $0.kind == .articleFeed }.count
        guard count > 0 || model.lastSynchronizedAt != nil else { return nil }
        return count
    }

    private func color(for line: String) -> Color {
        if line == BulletinReadiness.Line.ready.text {
            return WiltedStatusTone.positive.color(colorScheme)
        }
        if line == "Check Wilted on your Mac." || line == BulletinReadiness.Line.checkingNews.text {
            return WiltedTheme.color(.secondaryText, scheme: colorScheme)
        }
        return WiltedTheme.color(.degraded, scheme: colorScheme)
    }

    private func playTestBulletin() {
        model.handoffState.interruptions?.speakTestBulletin()
    }

    private func stopTestBulletin() {
        model.handoffState.interruptions?.stopTestBulletin()
    }
}
