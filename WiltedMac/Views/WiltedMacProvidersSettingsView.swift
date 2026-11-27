import SwiftUI
import WiltedProducer

/// The Providers section in Settings: command-line tools and key providers,
/// readiness checks, and key storage and removal.
struct WiltedMacProvidersSettingsView: View {
    private let appModel: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model appModel: WiltedMacModel) {
        self.appModel = appModel
    }

    private var providers: WiltedMacProviderSettings {
        appModel.providers
    }

    private var help: WiltedMacHelpContent {
        WiltedMacHelpContent(
            title: "Providers",
            text: "Subscription tools use their own sign-in. Checking a saved key sends a short test message to that provider."
        )
    }

    var body: some View {
        let rows = providers.rows
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack {
                Text("Command-line tools (use your subscription)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-providers-heading-cli")
                Spacer()
                Button("Check all") {
                    Task { await providers.checkAll() }
                }
                .disabled(providers.isCheckingAny)
                .accessibilityIdentifier("wilted-providers-check-all")
                WiltedMacHelpButton(content: help, identifier: "wilted-providers-help")
            }

            ForEach(rows.filter { !$0.provider.requiresSavedKey }) { row in
                WiltedMacProviderRow(
                    providers: providers, row: row,
                    lastEpisodeReply: appModel.providerEpisodeReplies[row.provider]
                )
            }

            Text("Keys")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-providers-heading-keys")

            ForEach(rows.filter { $0.provider.requiresSavedKey }) { row in
                WiltedMacProviderRow(
                    providers: providers, row: row,
                    lastEpisodeReply: appModel.providerEpisodeReplies[row.provider]
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-providers-page")
    }
}

/// A provider's readiness, check action and (where applicable) key controls.
private struct WiltedMacProviderRow: View {
    let providers: WiltedMacProviderSettings
    let row: WiltedMacProviderSettings.Row
    let lastEpisodeReply: WiltedMacProviderEpisodeReply?
    @Environment(\.colorScheme) private var colorScheme
    @State private var typedKey = ""
    @State private var isConfirmingKeyRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.small) {
                Button {
                    if !row.isChosen {
                        providers.setProvider(row.provider)
                    }
                } label: {
                    HStack(spacing: WiltedTheme.Spacing.small) {
                        Image(systemName: row.isChosen ? "circle.inset.filled" : "circle")
                            .foregroundStyle(row.isChosen
                                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
                                : WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .font(.system(size: 13))
                            .accessibilityHidden(true)
                        Text(row.name)
                            .wiltedFont(.body)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wilted-providers-choice-\(row.provider.rawValue)")
                .accessibilityLabel(row.name)
                .accessibilityValue(row.isChosen ? "Selected for ad finding" : "Not selected for ad finding")
                .accessibilityAddTraits(row.isChosen ? [.isSelected] : [])

                Spacer(minLength: WiltedTheme.Spacing.small)
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text(row.status)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-providers-status-\(row.provider.rawValue)")
                    if let lastResult = row.lastCheckResult {
                        Text("Last provider check: \(lastResult)")
                            .wiltedFont(.caption)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-providers-last-check-\(row.provider.rawValue)")
                    }
                }
                Button("Check") {
                    Task { await providers.check(row.provider) }
                }
                .disabled(row.status == "Checking...")
                .accessibilityIdentifier("wilted-providers-check-\(row.provider.rawValue)")
            }
            if let lastEpisodeReply {
                Text("Last episode result: \(lastEpisodeReply.detail)")
                    .wiltedFont(.caption)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-providers-last-episode-result-\(row.provider.rawValue)")
            }
            if row.provider.requiresSavedKey { keyControls }
            if row.isChosen {
                WiltedMacAdFindingModelSection(providers: providers)
                    .padding(.leading, WiltedTheme.Spacing.large)
                    .padding(.top, WiltedTheme.Spacing.xSmall)
            }
        }
        .controlSize(.small)
        .alert("Remove the provider key?", isPresented: $isConfirmingKeyRemoval) {
            Button("Remove", role: .destructive) {
                providers.removeKey(for: row.provider)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Online ad finding stops until you save one again.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-providers-card-\(row.provider.rawValue)")
    }

    @ViewBuilder private var keyControls: some View {
        if row.hasSavedKey {
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text("Key saved")
                    .wiltedFont(.utility)
                    .accessibilityIdentifier("wilted-providers-key-saved-\(row.provider.rawValue)")
                Button("Remove") { isConfirmingKeyRemoval = true }
                    .accessibilityIdentifier("wilted-providers-key-remove-\(row.provider.rawValue)")
            }
        } else {
            HStack(spacing: WiltedTheme.Spacing.small) {
                SecureField("Provider key", text: $typedKey)
                    .frame(maxWidth: 240)
                    .accessibilityIdentifier("wilted-providers-key-field-\(row.provider.rawValue)")
                Button("Save") {
                    providers.saveKey(typedKey, for: row.provider)
                    if providers.keyMessage == nil { typedKey = "" }
                }
                .disabled(typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("wilted-providers-key-save-\(row.provider.rawValue)")
            }
            if let message = providers.keyMessage {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-providers-key-message-\(row.provider.rawValue)")
            }
        }
    }
}
