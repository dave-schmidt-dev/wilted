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
                WiltedMacDeviceDownloadsRow(row: row, macEnabled: model.isDirectDownloadsEnabled,
                    onStop: { model.stopDirectDownloads(for: row.id) },
                    onRename: { try await model.renameDevice(row.id, to: $0) },
                    onRemove: { try await model.removeDevice(row.id) },
                    hasActiveLANTransfer: { model.hasActiveLANTransfer })
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
    var onRename: @MainActor (String) async throws -> Void = { _ in }
    var onRemove: @MainActor () async throws -> Void = {}
    var hasActiveLANTransfer: () -> Bool = { false }
    @State private var showsMenu = false
    @State private var showsRename = false
    @State private var name = ""
    @State private var renameError: String?
    @State private var saving = false
    @State private var removal = WiltedMacDeviceRemovalPrompt()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                WiltedSettingsRow(row.label, value: row.value, identifier: "wilted-sync-device")
                Text("Last announced: \(row.lastAnnouncedLabel)")
                    .wiltedFont(.utility)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("wilted-sync-device-last-announced-\(row.id)")
            }
            .fixedSize(horizontal: false, vertical: true)
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
                WiltedMacDeviceDownloadsMenu(row: row, macEnabled: macEnabled, onStop: onStop, onRename: {
                    showsMenu = false
                    name = row.label
                    renameError = nil
                    showsRename = true
                }, onRemove: {
                    showsMenu = false
                    removal.ask()
                })
            }
        }
        .sheet(isPresented: $showsRename) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Text("Rename device").font(.headline)
                TextField("Device name on this Mac", text: $name)
                    .accessibilityIdentifier("wilted-sync-device-name-field")
                if let renameError { Text(renameError).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { showsRename = false }.keyboardShortcut(.cancelAction)
                    Button(saving ? "Saving…" : "Save") {
                        guard !saving else { return }
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do {
                                try await onRename(name)
                                showsRename = false
                            } catch {
                                renameError = "Couldn’t save this name. Try again."
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .padding()
            .frame(width: 340)
        }
        .sheet(isPresented: Binding(get: { removal.isPresented }, set: { if !$0 { removal.cancel() } })) {
            WiltedMacDeviceRemovalConfirmation(deviceName: row.label,
                transferInFlight: row.hasInFlightTransfer || hasActiveLANTransfer(),
                onCancel: { removal.cancel() },
                onRemove: { Task { await removal.confirm(onRemove) } },
                isRemoving: removal.isRemoving, errorMessage: removal.errorMessage)
                .interactiveDismissDisabled(removal.isRemoving)
        }
    }
}

struct WiltedMacDeviceDownloadsMenu: View {
    let row: WiltedMacLibrarySyncStatus.DeviceRow
    let macEnabled: Bool
    let onStop: () -> Void

    var onRename: () -> Void = {}
    var onRemove: () -> Void = {}

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
            Divider()
            Button("Rename…", action: onRename)
                .accessibilityIdentifier("wilted-sync-device-rename-\(row.id)")
            Button("Remove device…", role: .destructive, action: onRemove)
                .accessibilityIdentifier("wilted-sync-device-remove-\(row.id)")
        }
        .padding(WiltedTheme.Spacing.medium)
        .frame(width: 248, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-stop-direct-\(row.id)")
    }
}

@MainActor @Observable
final class WiltedMacDeviceRemovalPrompt {
    private(set) var isPresented = false
    private(set) var isRemoving = false
    private(set) var errorMessage: String?

    func ask() {
        guard !isRemoving else { return }
        errorMessage = nil
        isPresented = true
    }

    func cancel() {
        guard !isRemoving else { return }
        isPresented = false
    }

    func confirm(_ remove: @MainActor () async throws -> Void) async {
        guard isPresented, !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        errorMessage = nil
        do {
            try await remove()
            isPresented = false
        } catch {
            errorMessage = "Couldn’t remove this device. Try again."
        }
    }
}

struct WiltedMacDeviceRemovalConfirmation: View {
    let deviceName: String
    let transferInFlight: Bool
    let onCancel: () -> Void
    let onRemove: () -> Void
    var isRemoving = false
    var errorMessage: String?

    static func message(transferInFlight: Bool) -> String {
        let detail = "This device can link again later. Direct downloads will need pairing again."
        return transferInFlight ? "A transfer is pending or in progress and may be interrupted. " + detail : detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Remove \(deviceName)?").font(.headline)
            Text(Self.message(transferInFlight: transferInFlight))
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isRemoving ? "Removing…" : "Remove device", role: .destructive, action: onRemove)
                    .accessibilityIdentifier("wilted-sync-device-confirm-remove")
            }
            .disabled(isRemoving)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .frame(width: 340)
    }
}
