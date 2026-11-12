import SwiftUI
import WiltedDomain
import WiltedProducer

// MARK: - Settings card

/// The Ad finding card in Settings: the provider key, the global switch, the
/// shows waiting for confirmation, and today's request count. The explanation
/// lives in the help popover, and the confirm sheet decides which shows are sent.
struct WiltedMacAdFindingSettingsView: View {
    let model: WiltedMacAdFindingSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRemovingKey = false

    var body: some View {
        WiltedSettingsCard(title: "Ad finding") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if model.hasKey { savedKeyRow } else { keyEntryRow }
                Divider()
                Toggle("Find ads with the online labeller", isOn: Binding(
                    get: { model.isOnlineFindingOn }, set: { model.setOnlineFinding($0) }
                ))
                .accessibilityIdentifier("wilted-ad-finding-switch")
                if let message = model.switchMessage {
                    Text(message)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-ad-finding-switch-message")
                }
                if model.waitingShowCount > 0 { waitingRow }
                Divider()
                WiltedSettingsRow(
                    "Requests today",
                    value: "\(model.requestsToday) of \(model.dailyCap)",
                    identifier: "wilted-ad-finding-requests"
                )
                if model.offersBackfill {
                    Divider()
                    backfillRow
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            WiltedMacHelpButton(content: help, identifier: "wilted-ad-finding-help")
                .padding(WiltedTheme.Spacing.medium)
        }
        .alert("Remove the provider key?", isPresented: $isRemovingKey) {
            Button("Remove", role: .destructive) { model.removeKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Online ad finding stops until you save one again.")
        }
        .sheet(isPresented: Binding(
            get: { model.isConfirming }, set: { if !$0 { model.cancel() } }
        )) {
            WiltedMacAdFindingConfirmSheet(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-controls")
    }

    /// With a key saved, the field is gone; only the fact and Remove remain.
    private var savedKeyRow: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Text("Key saved")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-ad-finding-key-saved")
            Spacer(minLength: WiltedTheme.Spacing.large)
            Button("Remove") { isRemovingKey = true }
                .accessibilityIdentifier("wilted-ad-finding-key-remove")
        }
    }

    private var keyEntryRow: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                SecureField("Provider key", text: Binding(
                    get: { model.typedKey }, set: { model.typedKey = $0 }
                ))
                .accessibilityIdentifier("wilted-ad-finding-key-field")
                Button("Save") { model.saveKey(model.typedKey) }
                    .disabled(!model.canSaveKey)
                    .accessibilityIdentifier("wilted-ad-finding-key-save")
            }
            if let message = model.keyMessage {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-ad-finding-key-message")
            }
        }
    }

    private var waitingRow: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Text(model.waitingShowCount == 1
                 ? "1 show waiting" : "\(model.waitingShowCount) shows waiting")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-ad-finding-waiting")
            Spacer(minLength: WiltedTheme.Spacing.large)
            Button("Review") { model.reviewWaitingShows() }
                .accessibilityIdentifier("wilted-ad-finding-review")
        }
    }

    @ViewBuilder
    private var backfillRow: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(backfillStatusText)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-ad-finding-backfill-status")
                switch model.backfillState {
                case .ended(let message):
                    Text(message)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-ad-finding-backfill-message")
                case .checking:
                    ProgressView().controlSize(.small)
                case .running(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                case .idle:
                    EmptyView()
                }
            }
            Spacer(minLength: WiltedTheme.Spacing.large)
            switch model.backfillState {
            case .checking, .running:
                Button("Stop") { model.stopBackfill() }
                    .accessibilityIdentifier("wilted-ad-finding-backfill-stop")
            case .idle, .ended:
                Button("Label now") { model.startBackfill() }
                    .accessibilityIdentifier("wilted-ad-finding-backfill-start")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-backfill")
    }

    private var backfillStatusText: String {
        switch model.backfillState {
        case .idle, .ended:
            return "Prepared episodes"
        case .checking:
            return "Checking stored transcripts"
        case .running(let done, let total):
            return "Labelling \(min(done + 1, total)) of \(total)"
        }
    }

    private var help: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Ad finding", text:
            "Only the shows you confirm here are sent: their transcripts go to the online labeller to find ads. "
            + "Private or subscriber shows stay on this Mac, and shows you add later stay on this Mac until you confirm them here. "
            + "Label now sends the transcripts still stored on this Mac for episodes you already prepared; it changes no audio.")
    }
}

// MARK: - Confirm sheet

/// The confirm sheet's content, on its own so a headless test can render it
/// without presenting it.
struct WiltedMacAdFindingConfirmSheet: View {
    let model: WiltedMacAdFindingSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Shows sent for ad finding")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            ScrollView {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    group("Transcripts will be sent", shows: model.sheetSentShows)
                    Divider()
                    group("Stays on this Mac", shows: model.sheetLocalShows)
                    Text("Shows you add later stay on this Mac until you confirm them here.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Cancel") { model.cancel() }
                    .accessibilityIdentifier("wilted-ad-finding-sheet-cancel")
                Spacer()
                Button("Confirm") { model.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("wilted-ad-finding-sheet-confirm")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 460, height: 520)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-sheet")
    }

    /// One group heading and its shows, each with its toggle and, when the
    /// policy forces it local, the reason in plain words.
    private func group(_ title: String, shows: [WiltedMacAdFindingSettings.Show]) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text(title)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            ForEach(shows) { show in
                HStack(alignment: .top, spacing: WiltedTheme.Spacing.small) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                        Text(show.title)
                            .wiltedFont(.body)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        if let reason = model.forcedLocalMessage(for: show) {
                            Text(reason)
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: WiltedTheme.Spacing.large)
                    Toggle(show.title, isOn: Binding(
                        get: { model.sheetSent.contains(show.feedID) },
                        set: { model.setSheetSent($0, for: show) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.forcedLocalReason(for: show) != nil)
                    .accessibilityLabel("Send transcripts of \(show.title)")
                    .accessibilityIdentifier("wilted-ad-finding-sheet-show-\(show.feedID)")
                }
            }
        }
    }
}
