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
                WiltedMacProviderRow(providers: providers, row: row)
            }

            Text("Keys")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-providers-heading-keys")

            ForEach(rows.filter { $0.provider.requiresSavedKey }) { row in
                WiltedMacProviderRow(providers: providers, row: row)
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var typedKey = ""
    @State private var isConfirmingKeyRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.small) {
                Text(row.name)
                    .wiltedFont(.body)
                if row.isChosen {
                    Text("In use")
                        .wiltedFont(.caption)
                        .fixedSize()
                        .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                        .padding(.horizontal, WiltedTheme.Spacing.xSmall)
                        .background(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12), in: Capsule())
                        .accessibilityLabel("In use for ad finding")
                        .accessibilityIdentifier("wilted-providers-in-use-\(row.provider.rawValue)")
                }
                Spacer(minLength: WiltedTheme.Spacing.small)
                Text(row.status)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-providers-status-\(row.provider.rawValue)")
                Button("Check") {
                    Task { await providers.check(row.provider) }
                }
                .disabled(row.status == "Checking...")
                .accessibilityIdentifier("wilted-providers-check-\(row.provider.rawValue)")
            }
            if row.provider.requiresSavedKey { keyControls }
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
