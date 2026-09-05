import SwiftUI

public struct WiltedStateCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let fixture: WiltedPreviewFixture
    public let actionTitle: String?
    public let action: (() -> Void)?

    public init(
        fixture: WiltedPreviewFixture,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.fixture = fixture
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
                Image(symbol: fixture.state.symbolName)
                    .wiltedFont(.title)
                    .foregroundStyle(tint)
                    .frame(width: WiltedTheme.Spacing.minimumTouchTarget, height: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                    Text(fixture.state.title)
                        .wiltedFont(.title)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Text(fixture.state.detail)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .preparing(let stage) = fixture.state {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    ProgressView(value: stageFraction(stage))
                        .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                        .accessibilityLabel("Preparation progress")
                        .accessibilityValue(stage.title)
                    Text(stage.title.uppercased())
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityHidden(true)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(tint)
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier(WiltedScreenCopy.stateActionIdentifier)
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fixture.state.accessibilityStatus)
        .accessibilityIdentifier(fixture.state.accessibilityIdentifier)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: fixture.state)
    }

    private var tint: Color {
        switch fixture.state {
        case .extractionFailure, .speechUnavailable, .downloadFailure, .incompatibleRevision:
            WiltedTheme.color(.error, scheme: colorScheme)
        case .syncPending, .iCloudUnavailable, .cancelling:
            WiltedTheme.color(.stale, scheme: colorScheme)
        case .preparing:
            WiltedTheme.color(.progress, scheme: colorScheme)
        case .completed, .offlineCached, .ready:
            WiltedTheme.color(.success, scheme: colorScheme)
        default:
            WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
        }
    }

    private func stageFraction(_ stage: WiltedPreviewState.PreparationStage) -> Double {
        let index = WiltedPreviewState.PreparationStage.allCases.firstIndex(of: stage) ?? 0
        return Double(index + 1) / Double(WiltedPreviewState.PreparationStage.allCases.count)
    }
}

public struct WiltedLibraryShell: View {
    @Environment(\.colorScheme) private var colorScheme
    public let fixture: WiltedPreviewFixture
    private let onAddArticle: () -> Void

    public init(
        fixture: WiltedPreviewFixture = WiltedPreviewFixture(state: .emptyLibrary),
        onAddArticle: @escaping () -> Void = {}
    ) {
        self.fixture = fixture
        self.onAddArticle = onAddArticle
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.section) {
                if fixture.state == .emptyLibrary {
                    Text(WiltedScreenCopy.noArticles)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                WiltedStateCard(fixture: fixture)
                if fixture.state == .ready || fixture.state == .playing {
                    NavigationLink(destination: WiltedPlayerShell(fixture: fixture)) {
                        Label(WiltedScreenCopy.openPlayer, systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier(WiltedScreenCopy.openPlayerIdentifier)
                }
                Button(WiltedScreenCopy.addArticle, action: onAddArticle)
                    .buttonStyle(.borderedProminent)
                    .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier(WiltedScreenCopy.addArticleIdentifier)
            }
            .padding(WiltedTheme.Spacing.xLarge)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier(WiltedScreenCopy.libraryIdentifier)
    }
}

public struct WiltedDownloadsShell: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
            Text(WiltedScreenCopy.downloads)
                .wiltedFont(.display)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(WiltedScreenCopy.noDownloads)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier(WiltedScreenCopy.downloadsEmptyIdentifier)
            Spacer()
        }
        .padding(WiltedTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        // Keep the shell addressable while retaining the empty-state text as
        // its own accessibility element for UI automation and VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.downloadsIdentifier)
    }
}

/// Truthful placeholder for a reachable Now Playing destination with no
/// selected article. It stays actionable without pretending playback exists.
public struct WiltedNowPlayingEmptyView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let detail: String

    /// Deliberately without a default. A default would let a new surface
    /// inherit the other platform's wording silently, which is how the Mac
    /// came to point at a Downloads destination it does not have.
    public init(detail: String) {
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: WiltedTheme.Spacing.large) {
            Image(systemName: "waveform")
                .wiltedFont(.display)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            Text(WiltedScreenCopy.nowPlayingEmpty)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(detail)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WiltedTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(WiltedScreenCopy.nowPlayingEmpty). \(detail)")
        .accessibilityIdentifier(WiltedScreenCopy.nowPlayingEmptyIdentifier)
    }
}

public struct WiltedSettingsShell: View {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
            Text(WiltedScreenCopy.settings)
                .wiltedFont(.display)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Spacer()
        }
        .padding(WiltedTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.settingsIdentifier)
    }
}

public struct WiltedPlayerShell: View {
    @Environment(\.colorScheme) private var colorScheme
    public let fixture: WiltedPreviewFixture

    public init(fixture: WiltedPreviewFixture = WiltedPreviewFixture(state: .ready)) {
        self.fixture = fixture
    }

    public var body: some View {
        VStack(spacing: WiltedTheme.Spacing.large) {
            WiltedMark(size: 64, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            Text(fixture.articleTitle)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .multilineTextAlignment(.center)
            Text(fixture.sourceLabel)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            HStack(spacing: WiltedTheme.Spacing.medium) {
                playerButton("gobackward.15", label: "Rewind 15 seconds")
                playerButton(fixture.state == .playing ? "pause.fill" : "play.fill", label: fixture.state == .playing ? "Pause" : "Play")
                playerButton("goforward.30", label: "Skip forward 30 seconds")
            }
        }
        .padding(WiltedTheme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing. \(fixture.articleTitle)")
        .accessibilityIdentifier(WiltedScreenCopy.playerIdentifier)
    }

    private func playerButton(_ systemName: String, label: String) -> some View {
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(width: WiltedTheme.Spacing.minimumTouchTarget, height: WiltedTheme.Spacing.minimumTouchTarget)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
        .accessibilityIdentifier(playerIdentifier(for: systemName))
    }

    private func playerIdentifier(for systemName: String) -> String {
        switch systemName {
        case "gobackward.15": WiltedScreenCopy.playerRewindIdentifier
        case "goforward.30": WiltedScreenCopy.playerForwardIdentifier
        default: WiltedScreenCopy.playerPlayPauseIdentifier
        }
    }
}
