import SwiftUI
import WiltedProducer

/// The "Ad finding model" section inside the Ad finding settings card:
/// provider picker, model picker (or typed model text field with Save), thinking level picker,
/// and a readiness line with a "Set up providers" button that switches Settings to Providers.
struct WiltedMacAdFindingModelSection: View {
    private let appModel: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model appModel: WiltedMacModel) {
        self.appModel = appModel
    }

    private var providers: WiltedMacProviderSettings {
        appModel.providers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Ad finding model")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))

            Picker("Provider", selection: Binding(
                get: { providers.provider },
                set: { providers.setProvider($0) }
            )) {
                ForEach(WiltedMacProviderSettings.rowOrder, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .accessibilityIdentifier("wilted-ad-finding-provider-picker")

            if providers.usesTypedModel {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    HStack(spacing: WiltedTheme.Spacing.small) {
                        TextField("Model id", text: Binding(
                            get: { providers.typedModel },
                            set: { providers.typedModel = $0 }
                        ))
                        .accessibilityIdentifier("wilted-ad-finding-model-field")

                        Button("Save") {
                            providers.saveTypedModel()
                        }
                        .disabled(providers.typedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("wilted-ad-finding-model-save")
                    }
                    if let message = providers.typedModelMessage {
                        Text(message)
                            .wiltedFont(.utility)
                            .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-ad-finding-model-message")
                    }
                }
            } else {
                Picker("Model", selection: Binding(
                    get: { providers.model },
                    set: { providers.setModel($0) }
                )) {
                    ForEach(providers.modelChoices) { info in
                        Text(info.displayName).tag(info.id)
                    }
                }
                .accessibilityIdentifier("wilted-ad-finding-model-picker")
            }

            Picker("Thinking level", selection: Binding(
                get: { providers.level },
                set: { providers.setLevel($0) }
            )) {
                ForEach(providers.levelChoices, id: \.self) { level in
                    Text(providers.levelLabel(level)).tag(level)
                }
            }
            .accessibilityIdentifier("wilted-ad-finding-level-picker")

            if let message = providers.levelMessage {
                Text(message)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-ad-finding-level-message")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(providers.readinessLine)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-ad-finding-readiness")
                Spacer(minLength: WiltedTheme.Spacing.large)
                Button("Set up providers") {
                    appModel.settingsSection = .providers
                }
                .accessibilityIdentifier("wilted-ad-finding-setup-providers")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-model-controls")
    }
}
