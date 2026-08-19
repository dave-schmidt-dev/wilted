import SwiftUI

struct WiltedMacRootView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Library") {
                    ForEach(model.articles) { article in
                        Button {
                            model.openNowPlaying(for: article)
                        } label: {
                            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                                Text(article.title)
                                    .font(WiltedTheme.font(.body))
                                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                                    .lineLimit(2)
                                Text(article.isReady ? "Ready to play" : "Preparing")
                                    .font(WiltedTheme.font(.caption))
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wilted-article-row")
                    }
                    if model.articles.isEmpty {
                        Text("Your library is empty")
                            .font(WiltedTheme.font(.body))
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .accessibilityIdentifier("wilted-mac-empty-library")
                    }
                }
            }
            .navigationTitle("Wilted")
            .accessibilityIdentifier("wilted-mac-library")
        } detail: {
            if model.isNowPlaying, let article = model.currentArticle {
                WiltedMacNowPlayingView(model: model, article: article)
            } else {
                WiltedMacLibraryView(model: model)
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .accessibilityIdentifier("wilted-mac-root")
    }
}

/// The producer card treatment: a `.card` fill with a hairline `.steel` edge,
/// matching `Shared/WiltedStateViews.swift` so the two surfaces cannot drift.
private struct WiltedMacCard: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .padding(WiltedTheme.Spacing.large)
            .background(
                WiltedTheme.color(.card, scheme: colorScheme),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(WiltedTheme.color(.steel, scheme: colorScheme), lineWidth: 1)
            )
    }
}

private extension View {
    func wiltedCard(_ colorScheme: ColorScheme) -> some View {
        modifier(WiltedMacCard(colorScheme: colorScheme))
    }
}

private struct WiltedMacLibraryView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                HStack(spacing: WiltedTheme.Spacing.medium) {
                    WiltedMark(size: 32, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                    Text("Add an article")
                        .font(WiltedTheme.font(.display))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                }
                Text("Paste an HTTPS article URL. Wilted keeps the saved article and audio on this Mac.")
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                WiltedMacSyncControls(model: model)

                HStack(spacing: WiltedTheme.Spacing.medium) {
                    TextField("https://example.com/article", text: $model.urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(WiltedTheme.font(.body))
                        .accessibilityIdentifier("wilted-article-url")
                    Button("Add Article") {
                        model.addArticle()
                    }
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("wilted-add-article-url")
                }

                if let preparation = model.preparation {
                    WiltedMacPreparationView(model: model, preparation: preparation)
                }

                if model.articles.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty", systemImage: "tray",
                        description: Text("Add an article to start listening.")
                    )
                    .accessibilityIdentifier("wilted-mac-empty-state")
                } else {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                        Text("Saved articles")
                            .font(WiltedTheme.font(.title))
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        ForEach(model.articles) { article in
                            WiltedMacArticleRow(model: model, article: article)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(WiltedTheme.Spacing.section)
        }
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier("wilted-mac-library-detail")
    }
}

private struct WiltedMacSyncControls: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                Text(model.syncStatus.phase.rawValue.capitalized)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(
                        model.syncStatus.phase == .failed
                            ? WiltedTheme.color(.error, scheme: colorScheme)
                            : WiltedTheme.color(.secondaryText, scheme: colorScheme)
                    )
                    .accessibilityIdentifier("wilted-sync-status")
            }
            Text(model.syncStatus.detail)
                .font(WiltedTheme.font(.caption))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-sync-detail")
            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Refresh") { model.refreshSync() }
                    .disabled(model.syncStatus.phase == .disabled || model.syncStatus.phase == .quarantined)
                    .accessibilityIdentifier("wilted-sync-refresh")
                Button("Upload") { model.uploadPendingSync() }
                    .disabled(model.syncStatus.phase == .disabled || model.syncStatus.phase == .quarantined)
                    .accessibilityIdentifier("wilted-sync-upload")
                if model.syncStatus.phase == .fetching || model.syncStatus.phase == .sending || model.syncStatus.phase == .staging {
                    Button("Cancel") { model.cancelSync() }
                        .accessibilityIdentifier("wilted-sync-cancel")
                }
                if model.syncStatus.phase == .quarantined {
                    Button("Use Current iCloud Account") { model.resetSyncAccount() }
                        .accessibilityIdentifier("wilted-sync-use-current-account")
                }
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-controls")
    }
}

private struct WiltedMacPreparationView: View {
    let model: WiltedMacModel
    let preparation: WiltedMacPreparation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text(preparation.phase.title)
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                if preparation.cancellable {
                    Button("Cancel") { model.cancelPreparation() }
                        .accessibilityIdentifier("wilted-cancel-preparation")
                }
            }
            if let fraction = preparation.fraction {
                ProgressView(value: fraction)
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-preparation-progress")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-preparation-progress")
            }
            Text(preparation.detail)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-preparation-detail")
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-preparation")
    }
}

private struct WiltedMacArticleRow: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(article.title)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Text(article.source)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Text(article.isReady ? "Ready to play" : "Preparing")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(
                        article.isReady
                            ? WiltedTheme.color(.success, scheme: colorScheme)
                            : WiltedTheme.color(.secondaryText, scheme: colorScheme)
                    )
            }
            Spacer()
            if article.isReady {
                Button("Open Now Playing") {
                    model.openNowPlaying(for: article)
                }
                .accessibilityIdentifier("wilted-open-now-playing")
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-article-row-\(article.id)")
    }
}

private struct WiltedMacNowPlayingView: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: WiltedTheme.Spacing.xLarge) {
            WiltedMark(size: 64, color: WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
            Text("Now Playing")
                .font(WiltedTheme.font(.display))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(article.title)
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .multilineTextAlignment(.center)
            Text(article.source)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))

            HStack(spacing: WiltedTheme.Spacing.large) {
                Button { model.rewind() } label: {
                    Image(systemName: "gobackward.15")
                }
                .accessibilityLabel("Rewind 15 seconds")
                .accessibilityIdentifier("wilted-player-rewind")
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("wilted-player-play-pause")
                Button { model.forward() } label: {
                    Image(systemName: "goforward.30")
                }
                .accessibilityLabel("Skip forward 30 seconds")
                .accessibilityIdentifier("wilted-player-forward")
            }
            .buttonStyle(.bordered)
            .font(WiltedTheme.font(.title))

            Button("Restart") { model.restartPlayback() }
                .accessibilityIdentifier("wilted-player-restart")

            Button("Recover audio route") { model.recoverAudioRoute() }
                .accessibilityIdentifier("wilted-player-route-recovery")
                .font(WiltedTheme.font(.caption))

            if let error = model.playbackError {
                Text(error)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-player-error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WiltedTheme.Spacing.section)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing. \(article.title)")
        .accessibilityIdentifier("wilted-now-playing")
    }
}
