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
                WiltedMacDeviceDownloadsRow(row: row, macEnabled: model.isDirectDownloadsEnabled) {
                    model.stopDirectDownloads(for: row.id)
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

struct WiltedMacDeviceDownloadsRow: View {
    let row: WiltedMacLibrarySyncStatus.DeviceRow
    let macEnabled: Bool
    let onStop: () -> Void
    @State private var showsMenu = false

    var body: some View {
        HStack {
            WiltedSettingsRow(row.label, value: row.value, identifier: "wilted-sync-device")
            Button { showsMenu.toggle() } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Options for \(row.label)")
            .help("Options for \(row.label)")
            .accessibilityIdentifier("wilted-sync-device-menu-\(row.id)")
            .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
                WiltedMacDeviceDownloadsMenu(row: row, macEnabled: macEnabled, onStop: onStop)
            }
        }
    }
}

struct WiltedMacDeviceDownloadsMenu: View {
    let row: WiltedMacLibrarySyncStatus.DeviceRow
    let macEnabled: Bool
    let onStop: () -> Void

    var canStop: Bool { macEnabled && !row.isDirectDownloadsStopped }

    var downloads: Binding<Bool> {
        Binding(get: { !row.isDirectDownloadsStopped }, set: { enabled in
            if !enabled && canStop { onStop() }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Toggle("Direct downloads", isOn: downloads)
                .toggleStyle(.switch)
                .disabled(!canStop)
                .accessibilityIdentifier("wilted-sync-device-toggle-\(row.id)")
            if row.isDirectDownloadsStopped {
                Text("Pair again to turn direct downloads back on.")
                    .wiltedFont(.utility)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(WiltedTheme.Spacing.medium)
        .frame(width: 248, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-stop-direct-\(row.id)")
    }
}
