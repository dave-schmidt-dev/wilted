import SwiftUI

struct WiltedMacRootView: View {
    @Bindable private var model: WiltedMacModel

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
                            VStack(alignment: .leading, spacing: 3) {
                                Text(article.title)
                                    .lineLimit(2)
                                Text(article.isReady ? "Ready to play" : "Preparing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("wilted-article-row")
                    }
                    if model.articles.isEmpty {
                        Text("Your library is empty")
                            .foregroundStyle(.secondary)
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
        .accessibilityIdentifier("wilted-mac-root")
    }
}

private struct WiltedMacLibraryView: View {
    @Bindable private var model: WiltedMacModel

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Add an article")
                    .font(.largeTitle.weight(.semibold))
                Text("Paste an HTTPS article URL. Wilted keeps the saved article and audio on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    TextField("https://example.com/article", text: $model.urlDraft)
                        .textFieldStyle(.roundedBorder)
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
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Saved articles")
                            .font(.title2.weight(.semibold))
                        ForEach(model.articles) { article in
                            WiltedMacArticleRow(model: model, article: article)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("wilted-mac-library-detail")
    }
}

private struct WiltedMacPreparationView: View {
    let model: WiltedMacModel
    let preparation: WiltedMacPreparation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(preparation.phase.title)
                    .font(.headline)
                Spacer()
                if preparation.cancellable {
                    Button("Cancel") { model.cancelPreparation() }
                        .accessibilityIdentifier("wilted-cancel-preparation")
                }
            }
            if let fraction = preparation.fraction {
                ProgressView(value: fraction)
                    .accessibilityIdentifier("wilted-preparation-progress")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .accessibilityIdentifier("wilted-preparation-progress")
            }
            Text(preparation.detail)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("wilted-preparation-detail")
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-preparation")
    }
}

private struct WiltedMacArticleRow: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                Text(article.source)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(article.isReady ? "Ready to play" : "Preparing")
                    .font(.caption)
                    .foregroundStyle(article.isReady ? .green : .secondary)
            }
            Spacer()
            if article.isReady {
                Button("Open Now Playing") {
                    model.openNowPlaying(for: article)
                }
                .accessibilityIdentifier("wilted-open-now-playing")
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-article-row-\(article.id)")
    }
}

private struct WiltedMacNowPlayingView: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Now Playing")
                .font(.largeTitle.weight(.semibold))
            Text(article.title)
                .font(.title2)
                .multilineTextAlignment(.center)
            Text(article.source)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
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
            .font(.title2)

            Button("Recover audio route") { model.recoverAudioRoute() }
                .accessibilityIdentifier("wilted-player-route-recovery")
                .font(.caption)

            if let error = model.playbackError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("wilted-player-error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing. \(article.title)")
        .accessibilityIdentifier("wilted-now-playing")
    }
}
