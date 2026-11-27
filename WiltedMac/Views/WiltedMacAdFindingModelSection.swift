import SwiftUI
import WiltedProducer

/// Model and thinking-level controls for the provider selected in Settings > Providers.
struct WiltedMacAdFindingModelSection: View {
    let providers: WiltedMacProviderSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Ad finding model")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))

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

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-ad-finding-model-controls")
    }
}
