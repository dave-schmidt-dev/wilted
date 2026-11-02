import SwiftUI
import WiltedDomain
import WiltedLibrary

/// One-time direct-download onboarding step shown on first launch and first launch after updating
/// to this version. Offers a toggle for Wi-Fi downloads from the Mac and triggers one short browse
/// on Continue when enabled so iOS presents the Local Network permission prompt.
struct LibraryDirectDownloadOnboarding: View {
    @ObservedObject var settings: LibrarySettingsStore
    var model: LibraryAppModel?
    let locator: any LocalMacLocating
    let browseBudget: Duration
    let onContinue: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    /// Shared by reference so `continueAction()` on any copy of this view updates the hosted one.
    @ObservedObject var state: LibraryDirectDownloadOnboardingState

    var isDenied: Bool { state.isDenied }

    static let title = "Download from your Mac over Wi-Fi"
    static let oneLineWhy = "Audio comes straight from your Mac when it is near, with iCloud as fallback."
    static let localNetworkDeniedInstruction = "Allow Wilted under Settings > Privacy & Security > Local Network"
    static let onboardingShownKey = LibrarySettingsStore.directDownloadsOnboardingShownKey

    init(
        settings: LibrarySettingsStore,
        model: LibraryAppModel? = nil,
        locator: (any LocalMacLocating)? = nil,
        browseBudget: Duration = .seconds(1),
        isDenied: Bool = false,
        onContinue: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.model = model
        self.locator = locator ?? model?.directState.environment?.locator ?? LocalMacLocator()
        self.browseBudget = browseBudget
        self.onContinue = onContinue
        self.state = LibraryDirectDownloadOnboardingState(
            isDenied: isDenied || (model?.directState.localNetworkDenied ?? false)
        )
    }

    init(
        model: LibraryAppModel,
        settings: LibrarySettingsStore? = nil,
        locator: (any LocalMacLocating)? = nil,
        browseBudget: Duration = .seconds(1),
        isDenied: Bool = false,
        onContinue: (() -> Void)? = nil
    ) {
        let resolvedSettings = settings ?? LibrarySettingsStore(defaults: model.preferences)
        self.init(
            settings: resolvedSettings,
            model: model,
            locator: locator,
            browseBudget: browseBudget,
            isDenied: isDenied,
            onContinue: onContinue
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                    WiltedSettingsCard(title: Self.title) {
                        Text(Self.oneLineWhy)
                            .wiltedFont(.body)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(Self.title, isOn: $settings.directDownloads)
                            .wiltedFont(.utility)
                            .accessibilityIdentifier("wilted-library-direct-downloads-onboarding-toggle")
                        if isDenied {
                            Text(Self.localNetworkDeniedInstruction)
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("wilted-library-direct-downloads-denied")
                        }
                    }
                    Button {
                        Task { await continueAction() }
                    } label: {
                        HStack {
                            Spacer()
                            if state.isBrowsing {
                                ProgressView()
                                    .padding(.trailing, WiltedTheme.Spacing.small)
                            }
                            Text("Continue")
                                .wiltedFont(.body)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBrowsing)
                    .accessibilityIdentifier("wilted-library-direct-downloads-onboarding-continue")
                }
                .padding(WiltedTheme.Spacing.large)
            }
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Self.title)
                        .wiltedFont(.title)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .accessibilityIdentifier("wilted-library-direct-downloads-onboarding")
    }

    /// Action run when tapping Continue. Starts one short browse when enabled, or skips when off.
    @MainActor
    func continueAction() async {
        if isDenied {
            settings.directDownloadsOnboardingShown = true
            onContinue?()
            return
        }
        if settings.directDownloads {
            state.isBrowsing = true
            defer { state.isBrowsing = false }
            let search = await locator.locate(within: browseBudget)
            if search == .denied {
                state.isDenied = true
                model?.directState.localNetworkDenied = true
                return
            }
        }
        settings.directDownloadsOnboardingShown = true
        onContinue?()
    }

    /// Whether onboarding needs to be shown for the given defaults.
    static func needsOnboarding(in defaults: UserDefaults) -> Bool {
        !LibrarySettingsStore.directDownloadsOnboardingShown(in: defaults)
    }

    /// Record that the direct-download onboarding step has been shown.
    static func recordOnboardingShown(in defaults: UserDefaults) {
        LibrarySettingsStore.recordDirectDownloadsOnboardingShown(in: defaults)
    }
}

/// Browse progress and Local Network denial for the onboarding step.
@MainActor
final class LibraryDirectDownloadOnboardingState: ObservableObject {
    @Published var isDenied: Bool
    @Published var isBrowsing = false

    init(isDenied: Bool) {
        self.isDenied = isDenied
    }
}
