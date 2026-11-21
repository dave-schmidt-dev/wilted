import SwiftUI

// MARK: - Settings: global Auto keep and kept limit

/// The two global defaults Settings owns outright. Auto download and Auto
/// prepare keep their existing Larder and Preparing controls.
struct WiltedMacGlobalFeedDefaultsControls: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Toggle("Auto keep", isOn: autoKeepBinding)
                .accessibilityLabel("Auto keep for feeds set to Same as default")
                .accessibilityIdentifier("wilted-automation-feed-default-auto-keep")
            HStack(spacing: WiltedTheme.Spacing.small) {
                Text("Kept limit")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer(minLength: WiltedTheme.Spacing.large)
                Picker("Kept limit", selection: limitModeBinding) {
                    Text("No limit").tag(false)
                    Text("Set a limit").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Kept limit for feeds set to Same as default")
                .accessibilityIdentifier("wilted-automation-feed-default-kept-limit-mode")
                if let limit = model.automationSettings.keptLimitPerFeed {
                    TextField("Episodes", value: limitBinding(limit), format: .number)
                        .frame(width: 64)
                        .accessibilityLabel("Number of episodes kept for feeds set to Same as default")
                        .accessibilityIdentifier("wilted-automation-feed-default-kept-limit")
                    Stepper("Episodes kept", value: limitBinding(limit), in: 1...999)
                        .labelsHidden()
                        .accessibilityLabel("Adjust episodes kept for feeds set to Same as default")
                        .accessibilityIdentifier("wilted-automation-feed-default-kept-limit-stepper")
                }
            }
        }
    }

    private var autoKeepBinding: Binding<Bool> {
        Binding(
            get: { model.automationSettings.autoKeepNewEpisodes },
            set: { value in
                model.updateAutomationSettings { $0.settingAutoKeepNewEpisodes(value) }
                releaseWaiting()
            }
        )
    }

    private var limitModeBinding: Binding<Bool> {
        Binding(
            get: { model.automationSettings.keptLimitPerFeed != nil },
            set: { wantsLimit in
                model.updateAutomationSettings { $0.settingKeptLimitPerFeed(wantsLimit ? 5 : nil) }
                releaseWaiting()
            }
        )
    }

    private func limitBinding(_ current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { value in
                // A value below one is refused; the field keeps showing the stored limit.
                guard value >= 1 else { return }
                model.updateAutomationSettings { $0.settingKeptLimitPerFeed(value) }
                releaseWaiting()
            }
        )
    }

    /// A raised limit, or Auto keep switched on, fills open places on feeds
    /// that follow these values, through the same admission a refresh uses.
    private func releaseWaiting() {
        let feedIDs = Set(model.subscriptions.map(\.id))
        Task { await model.releaseWaitingEpisodes(feedIDs: feedIDs) }
    }
}
