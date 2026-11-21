import SwiftUI
import WiltedDomain

/// The library publisher's Sync card (Task 5.2): one status line, this Mac's own send and read
/// times, one Sync now, and the account review. Times are local; the phone reports its own fetch.
struct WiltedMacLibrarySyncCard: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isReviewing = false

    var body: some View {
        let status = model.librarySyncStatus
        let activity = model.librarySyncActivity
        WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedPublicationNotice(summary: model.libraryPublicationSummary, detail: model.libraryPublicationDetail,
                qualifier: model.libraryPublicationQualifier)
            WiltedSettingsRow("Status", value: status.headline, identifier: "wilted-sync-status", tone: status.tone)
            if let throttle = model.libraryThrottle {
                Divider()
                // The retry time while it is ahead, "Retrying now…" once it has passed (never a time
                // that has gone by); cleared by the next call that succeeds.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WiltedSettingsRow(
                        "iCloud", value: throttle.noticeWithResumeTime(now: context.date, retrying: false),
                        identifier: "wilted-sync-throttle", tone: .caution)
                }
            }
            Divider()
            WiltedSettingsRow(
                "Sent from this Mac", value: WiltedMacLibrarySyncStatus.timeLabel(activity.lastSentAt),
                identifier: "wilted-sync-last-send")
            Divider()
            WiltedSettingsRow(
                "Device changes read", value: WiltedMacLibrarySyncStatus.timeLabel(activity.lastCheckedAt),
                identifier: "wilted-sync-last-check")
            Divider()
            Toggle("Direct downloads from this Mac", isOn: Binding(
                get: { model.isDirectDownloadsEnabled },
                set: { model.setDirectDownloadsEnabled($0) }
            ))
            .wiltedFont(.utility)
            .accessibilityIdentifier("wilted-sync-direct-downloads-toggle")
            // Each iPhone and iPad this Mac links as soon as it syncs, and the requests it is answering.
            ForEach(WiltedMacLibrarySyncStatus.deviceRows(activity.devices)) { row in
                Divider()
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    WiltedSettingsRow(row.label, value: row.value, identifier: "wilted-sync-device")
                    if row.label.hasPrefix("iPhone") {
                        Button("Stop direct downloads for this iPhone") {
                            model.stopDirectDownloads(for: row.id)
                        }
                        .wiltedFont(.utility)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("wilted-sync-stop-direct-\(row.id)")
                    }
                }
            }
            // The counters are not observed, so the line re-reads them on a 30 s timeline. Without
            // counters there is no timeline at all, so the card's spacing stays as before.
            if model.librarySyncDiagnostics != nil {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(model.librarySyncDiagnostics ?? "")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-sync-diagnostics")
                }
            }
            Text(WiltedMacLibrarySyncStatus.scopeNote)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-sync-scope-note")
            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Sync now") { model.syncLibraryNow() }
                    .disabled(!status.canSyncNow)
                    .accessibilityIdentifier("wilted-sync-now")
                if status.reviewContext != nil {
                    Button("Review account…") { isReviewing = true }
                        .accessibilityIdentifier("wilted-sync-review-account")
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)
        }
        .alert(WiltedMacLibrarySyncStatus.reviewTitle, isPresented: $isReviewing) {
            Button(WiltedMacLibrarySyncStatus.approveReview) { model.reviewLibraryAccount() }
                .accessibilityIdentifier("wilted-sync-review-approve")
            Button(WiltedMacLibrarySyncStatus.keepHeld, role: .cancel) {}
                .accessibilityIdentifier("wilted-sync-review-keep-held")
        } message: {
            Text("\(status.reviewContext ?? "") \(WiltedMacLibrarySyncStatus.reviewExplanation)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-controls")
    }
}
