import SwiftUI
import WiltedProducer

/// The Providers section in Settings: cards for command-line tools and key providers,
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
            text: "Pick where ad finding is sent. Subscription tools need no key."
        )
    }

    private var commandLineRows: [WiltedMacProviderSettings.Row] {
        providers.rows.filter { !$0.provider.requiresSavedKey }
    }

    private var keyRows: [WiltedMacProviderSettings.Row] {
        providers.rows.filter { $0.provider.requiresSavedKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
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

            ForEach(commandLineRows) { row in
                WiltedMacProviderCard(providers: providers, row: row)
            }

            Text("Keys")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-providers-heading-keys")

            ForEach(keyRows) { row in
                WiltedMacProviderCard(providers: providers, row: row)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-providers-page")
    }
}

/// One card per provider in the Providers settings section.
private struct WiltedMacProviderCard: View {
    let providers: WiltedMacProviderSettings
    let row: WiltedMacProviderSettings.Row
    @Environment(\.colorScheme) private var colorScheme
    @State private var typedKey = ""
    @State private var isConfirmingKeyRemoval = false

    var body: some View {
        WiltedSettingsCard(title: row.name) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if row.isChosen {
                    Text("In use for ad finding")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-providers-in-use-\(row.provider.rawValue)")
                }

                WiltedSettingsRow(
                    "Kind",
                    value: row.kind,
                    identifier: "wilted-providers-kind-\(row.provider.rawValue)"
                )

                WiltedSettingsRow(
                    "Status",
                    value: row.status,
                    identifier: "wilted-providers-status-\(row.provider.rawValue)"
                )

                if !row.provider.requiresSavedKey {
                    HStack {
                        Spacer()
                        Button("Check") {
                            Task { await providers.check(row.provider) }
                        }
                        .disabled(row.status == "Checking...")
                        .accessibilityIdentifier("wilted-providers-check-\(row.provider.rawValue)")
                    }
                } else {
                    if row.hasSavedKey {
                        HStack(spacing: WiltedTheme.Spacing.small) {
                            Text("Key saved")
                                .wiltedFont(.body)
                                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                .accessibilityIdentifier("wilted-providers-key-saved-\(row.provider.rawValue)")
                            Spacer(minLength: WiltedTheme.Spacing.large)
                            Button("Remove") {
                                isConfirmingKeyRemoval = true
                            }
                            .accessibilityIdentifier("wilted-providers-key-remove-\(row.provider.rawValue)")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                            HStack(spacing: WiltedTheme.Spacing.small) {
                                SecureField("Provider key", text: $typedKey)
                                    .accessibilityIdentifier("wilted-providers-key-field-\(row.provider.rawValue)")
                                Button("Save") {
                                    providers.saveKey(typedKey, for: row.provider)
                                    if providers.keyMessage == nil {
                                        typedKey = ""
                                    }
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
            }
        }
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
}
